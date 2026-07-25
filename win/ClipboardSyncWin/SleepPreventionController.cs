using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClipboardSyncWin;

// Persisted as integers in config.json, so new members must be appended: inserting one would
// silently reinterpret every saved configuration.
internal enum SleepPreventionDuration
{
    Disabled,
    Forever,
    OneHour,
    TwoHours,
    FourHours,
    SixHours,
    EightHours,
    TimePlan
}

internal enum SleepPreventionSuspensionReason
{
    LowBattery,
    BatteryStatusUnavailable
}

internal static class SleepPreventionDurationExtensions
{
    public static int? Hours(this SleepPreventionDuration duration)
    {
        return duration switch
        {
            SleepPreventionDuration.OneHour => 1,
            SleepPreventionDuration.TwoHours => 2,
            SleepPreventionDuration.FourHours => 4,
            SleepPreventionDuration.SixHours => 6,
            SleepPreventionDuration.EightHours => 8,
            _ => null
        };
    }

    public static bool IsTimed(this SleepPreventionDuration duration) => duration.Hours() is not null;

    public static string TitleKey(this SleepPreventionDuration duration)
    {
        return duration switch
        {
            SleepPreventionDuration.Disabled => "sleep.doNotDisable",
            SleepPreventionDuration.Forever => "sleep.forever",
            SleepPreventionDuration.OneHour => "sleep.oneHour",
            SleepPreventionDuration.TwoHours => "sleep.twoHours",
            SleepPreventionDuration.FourHours => "sleep.fourHours",
            SleepPreventionDuration.SixHours => "sleep.sixHours",
            SleepPreventionDuration.EightHours => "sleep.eightHours",
            SleepPreventionDuration.TimePlan => "sleep.timePlan",
            _ => throw new ArgumentOutOfRangeException(nameof(duration), duration, "Unknown sleep-prevention duration")
        };
    }
}

/// <summary>
/// Owns the Windows execution-state request on the UI thread that created it. SetThreadExecutionState
/// is thread-scoped, so every acquire and release is guarded against accidental cross-thread use.
/// A low battery pauses the request without changing the selected duration or its absolute deadline.
/// </summary>
internal sealed class SleepPreventionController : IDisposable
{
    [Flags]
    private enum ExecutionState : uint
    {
        SystemRequired = 0x00000001,
        DisplayRequired = 0x00000002,
        Continuous = 0x80000000
    }

    private readonly record struct BatteryState(bool HasBattery, bool IsOnBatteryPower, double ChargePercent);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern ExecutionState SetThreadExecutionState(ExecutionState executionState);

    private readonly int ownerThreadId = Environment.CurrentManagedThreadId;
    private readonly SynchronizationContext uiContext;
    private readonly System.Windows.Forms.Timer expirationTimer = new();
    private readonly System.Windows.Forms.Timer batteryPollTimer = new() { Interval = 30_000 };
    // Polls instead of firing once per hour boundary so a clock change, a time-zone change, or a
    // sleep/wake cycle that skips the boundary still converges within one interval.
    private readonly System.Windows.Forms.Timer timePlanTimer = new() { Interval = 30_000 };
    private bool requestActive;
    private bool powerEventsSubscribed;
    private bool disposed;
    private BatteryState? batteryState;
    private Exception? batteryStatusError;
    private string? lastReportedBatteryError;

    public SleepPreventionDuration Selection { get; private set; } = SleepPreventionDuration.Disabled;
    public DateTimeOffset? ExpiresAt { get; private set; }
    public bool LowBatteryGuardEnabled { get; private set; }
    public SleepPreventionSuspensionReason? SuspensionReason { get; private set; }
    public SleepTimePlan TimePlan { get; private set; } = new();
    /// <summary>
    /// Whether the current wall-clock hour is inside the time plan. Meaningful only while
    /// <see cref="SleepPreventionDuration.TimePlan"/> is selected; the tray menu reads it to
    /// distinguish "on" from "off for now".
    /// </summary>
    public bool IsInsideTimePlan { get; private set; }

    public event Action? Expired;
    public event Action<Exception>? Failure;
    public event Action? StateChanged;

    public SleepPreventionController(SynchronizationContext uiContext)
    {
        this.uiContext = uiContext ?? throw new ArgumentNullException(nameof(uiContext));
        expirationTimer.Tick += (_, _) => ExpireIfDue();
        batteryPollTimer.Tick += (_, _) => RefreshBatteryStatusAndReconcile();
        timePlanTimer.Tick += (_, _) => ReconcileTimePlan();
    }

    internal static bool ShouldSuspendForLowBattery(
        bool hasBattery,
        bool isOnBatteryPower,
        double chargePercent)
    {
        return hasBattery && isOnBatteryPower && chargePercent < 20;
    }

    public void SetLowBatteryGuardEnabled(bool enabled)
    {
        EnsureOwnerThread();
        EnsureNotDisposed();
        if (enabled == LowBatteryGuardEnabled)
        {
            return;
        }

        if (enabled)
        {
            StartBatteryMonitoring();
            StoreCurrentBatteryStatus();
            var nextReason = DesiredSuspensionReason(Selection, guardEnabled: true);
            try
            {
                EnforceRequest(Selection, nextReason, CurrentlyInsideTimePlan(Selection));
            }
            catch
            {
                StopBatteryMonitoring();
                batteryState = null;
                batteryStatusError = null;
                throw;
            }
            LowBatteryGuardEnabled = true;
            UpdateSuspensionReason(nextReason);
            ReportStoredBatteryFailureIfNeeded();
            Trace.WriteLine("Low-battery sleep-prevention guard enabled.");
            return;
        }

        EnforceRequest(Selection, suspensionReason: null, CurrentlyInsideTimePlan(Selection));
        LowBatteryGuardEnabled = false;
        StopBatteryMonitoring();
        batteryState = null;
        batteryStatusError = null;
        lastReportedBatteryError = null;
        UpdateSuspensionReason(null);
        Trace.WriteLine("Low-battery sleep-prevention guard disabled.");
    }

    /// <summary>
    /// Restores persisted state. Returns true when a timed selection expired while the app was not
    /// running and the caller must clear it from persistent configuration.
    /// </summary>
    public bool Restore(SleepPreventionDuration selection, DateTimeOffset? expiresAt, SleepTimePlan timePlan)
    {
        EnsureOwnerThread();
        EnsureNotDisposed();
        ArgumentNullException.ThrowIfNull(timePlan);
        TimePlan = timePlan.Clone();
        if (!Enum.IsDefined(selection))
        {
            throw new InvalidDataException($"Unknown sleep-prevention duration: {(int)selection}");
        }
        if (selection == SleepPreventionDuration.Disabled)
        {
            ApplySelection(SleepPreventionDuration.Disabled, null);
            return false;
        }
        if (selection.IsTimed())
        {
            if (expiresAt is null)
            {
                throw new InvalidDataException("The saved timed sleep-prevention setting has no expiration.");
            }
            if (expiresAt <= DateTimeOffset.UtcNow)
            {
                ApplySelection(SleepPreventionDuration.Disabled, null);
                Trace.WriteLine("Sleep prevention selection expired while Clipboard Sync was not running.");
                return true;
            }
        }

        RefreshBatteryStatusBeforeUserChange();
        ApplySelection(selection, selection.IsTimed() ? expiresAt : null);
        ReportStoredBatteryFailureIfNeeded();
        Trace.WriteLine($"Restored sleep prevention: {selection}.");
        return false;
    }

    /// <summary>
    /// Replaces the weekly schedule. Reconciles the request immediately so an edit that covers (or
    /// uncovers) the current hour takes effect without waiting for the next poll.
    /// </summary>
    public void SetTimePlan(SleepTimePlan plan)
    {
        EnsureOwnerThread();
        EnsureNotDisposed();
        ArgumentNullException.ThrowIfNull(plan);
        if (TimePlan.Matches(plan))
        {
            return;
        }
        TimePlan = plan.Clone();
        Trace.WriteLine($"Sleep prevention time plan updated: {TimePlan.StorageValue}");
        if (Selection == SleepPreventionDuration.TimePlan)
        {
            ApplySelection(SleepPreventionDuration.TimePlan, null);
        }
    }

    public DateTimeOffset? Select(SleepPreventionDuration duration)
    {
        EnsureOwnerThread();
        EnsureNotDisposed();
        if (!Enum.IsDefined(duration))
        {
            throw new ArgumentOutOfRangeException(nameof(duration), duration, "Unknown sleep-prevention duration");
        }
        if (duration == SleepPreventionDuration.Disabled)
        {
            ApplySelection(SleepPreventionDuration.Disabled, null);
            Trace.WriteLine("Sleep prevention disabled.");
            return null;
        }

        RefreshBatteryStatusBeforeUserChange();
        var expiration = duration.Hours() is int hours
            ? DateTimeOffset.UtcNow.AddHours(hours)
            : (DateTimeOffset?)null;
        ApplySelection(duration, expiration);
        ReportStoredBatteryFailureIfNeeded();
        Trace.WriteLine($"Sleep prevention selected: {duration}.");
        return expiration;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        EnsureOwnerThread();
        expirationTimer.Stop();
        batteryPollTimer.Stop();
        timePlanTimer.Stop();
        StopBatteryMonitoring();
        expirationTimer.Dispose();
        batteryPollTimer.Dispose();
        timePlanTimer.Dispose();
        ReleaseRequestIfNeeded();
        disposed = true;
    }

    private void ApplySelection(SleepPreventionDuration duration, DateTimeOffset? expiresAt)
    {
        var nextReason = DesiredSuspensionReason(duration, LowBatteryGuardEnabled);
        var nextInsideTimePlan = CurrentlyInsideTimePlan(duration);
        EnforceRequest(duration, nextReason, nextInsideTimePlan);
        Selection = duration;
        ExpiresAt = expiresAt;
        UpdateInsideTimePlan(nextInsideTimePlan);
        UpdateSuspensionReason(nextReason);
        ScheduleExpirationTimer();
        ScheduleTimePlanTimer();
    }

    private SleepPreventionSuspensionReason? DesiredSuspensionReason(
        SleepPreventionDuration duration,
        bool guardEnabled)
    {
        if (duration == SleepPreventionDuration.Disabled || !guardEnabled)
        {
            return null;
        }
        if (batteryState is not BatteryState state)
        {
            return SleepPreventionSuspensionReason.BatteryStatusUnavailable;
        }
        return ShouldSuspendForLowBattery(state.HasBattery, state.IsOnBatteryPower, state.ChargePercent)
            ? SleepPreventionSuspensionReason.LowBattery
            : null;
    }

    private void EnforceRequest(
        SleepPreventionDuration duration,
        SleepPreventionSuspensionReason? suspensionReason,
        bool insideTimePlan)
    {
        if (duration == SleepPreventionDuration.Disabled
            || suspensionReason is not null
            || (duration == SleepPreventionDuration.TimePlan && !insideTimePlan))
        {
            ReleaseRequestIfNeeded();
        }
        else
        {
            AcquireRequestIfNeeded();
        }
    }

    private bool CurrentlyInsideTimePlan(SleepPreventionDuration duration)
    {
        return duration == SleepPreventionDuration.TimePlan && TimePlan.IsPreventing(DateTime.Now);
    }

    private void UpdateInsideTimePlan(bool next)
    {
        if (IsInsideTimePlan == next)
        {
            return;
        }
        IsInsideTimePlan = next;
        Trace.WriteLine($"Sleep prevention time plan is now {(next ? "inside a planned hour" : "outside every planned hour")}.");
    }

    private void ScheduleTimePlanTimer()
    {
        timePlanTimer.Stop();
        if (Selection == SleepPreventionDuration.TimePlan)
        {
            timePlanTimer.Start();
        }
    }

    private void ReconcileTimePlan()
    {
        if (Selection != SleepPreventionDuration.TimePlan)
        {
            timePlanTimer.Stop();
            return;
        }

        var nextInsideTimePlan = CurrentlyInsideTimePlan(SleepPreventionDuration.TimePlan);
        var nextReason = DesiredSuspensionReason(SleepPreventionDuration.TimePlan, LowBatteryGuardEnabled);
        if (nextInsideTimePlan == IsInsideTimePlan && nextReason == SuspensionReason)
        {
            return;
        }

        try
        {
            EnforceRequest(SleepPreventionDuration.TimePlan, nextReason, nextInsideTimePlan);
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Failed to reconcile the sleep-prevention time plan: {ex}");
            Failure?.Invoke(ex);
            return;
        }

        if (nextInsideTimePlan != IsInsideTimePlan)
        {
            UpdateInsideTimePlan(nextInsideTimePlan);
            StateChanged?.Invoke();
        }
        UpdateSuspensionReason(nextReason);
    }

    private void StartBatteryMonitoring()
    {
        try
        {
            if (!powerEventsSubscribed)
            {
                SystemEvents.PowerModeChanged += HandlePowerModeChanged;
                powerEventsSubscribed = true;
            }
            batteryPollTimer.Start();
        }
        catch
        {
            if (powerEventsSubscribed)
            {
                SystemEvents.PowerModeChanged -= HandlePowerModeChanged;
                powerEventsSubscribed = false;
            }
            throw;
        }
    }

    private void StopBatteryMonitoring()
    {
        batteryPollTimer.Stop();
        if (!powerEventsSubscribed)
        {
            return;
        }
        SystemEvents.PowerModeChanged -= HandlePowerModeChanged;
        powerEventsSubscribed = false;
    }

    private void HandlePowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        uiContext.Post(_ =>
        {
            if (!disposed && LowBatteryGuardEnabled)
            {
                RefreshBatteryStatusAndReconcile();
            }
        }, null);
    }

    private void RefreshBatteryStatusBeforeUserChange()
    {
        if (LowBatteryGuardEnabled)
        {
            StoreCurrentBatteryStatus();
        }
    }

    private void RefreshBatteryStatusAndReconcile()
    {
        EnsureOwnerThread();
        if (!LowBatteryGuardEnabled)
        {
            return;
        }
        StoreCurrentBatteryStatus();
        var nextReason = DesiredSuspensionReason(Selection, guardEnabled: true);
        try
        {
            EnforceRequest(Selection, nextReason, CurrentlyInsideTimePlan(Selection));
            UpdateSuspensionReason(nextReason);
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Failed to reconcile sleep prevention after a battery update: {ex}");
            Failure?.Invoke(ex);
            return;
        }
        ReportStoredBatteryFailureIfNeeded();
    }

    private void StoreCurrentBatteryStatus()
    {
        try
        {
            var nextState = ReadCurrentBatteryState();
            if (batteryState != nextState)
            {
                Trace.WriteLine(
                    $"Battery status: present={nextState.HasBattery}, onBattery={nextState.IsOnBatteryPower}, charge={nextState.ChargePercent:F1}%.");
            }
            batteryState = nextState;
            batteryStatusError = null;
            lastReportedBatteryError = null;
        }
        catch (Exception ex)
        {
            if (batteryStatusError?.Message != ex.Message)
            {
                Trace.WriteLine($"Failed to read battery status: {ex}");
            }
            batteryState = null;
            batteryStatusError = ex;
        }
    }

    private static BatteryState ReadCurrentBatteryState()
    {
        var status = SystemInformation.PowerStatus;
        if (status.BatteryChargeStatus == BatteryChargeStatus.Unknown)
        {
            throw new InvalidOperationException("Windows reported an unknown battery charge status. Sleep prevention is paused for battery safety.");
        }
        if ((status.BatteryChargeStatus & BatteryChargeStatus.NoSystemBattery) != 0)
        {
            return new BatteryState(HasBattery: false, IsOnBatteryPower: false, ChargePercent: 100);
        }
        if (status.PowerLineStatus == PowerLineStatus.Unknown)
        {
            throw new InvalidOperationException("Windows reported an unknown power-line status. Sleep prevention is paused for battery safety.");
        }
        var chargePercent = status.BatteryLifePercent * 100.0;
        if (double.IsNaN(chargePercent) || double.IsInfinity(chargePercent)
            || chargePercent < 0 || chargePercent > 100)
        {
            throw new InvalidOperationException(
                $"Windows reported an invalid battery percentage ({chargePercent}). Sleep prevention is paused for battery safety.");
        }
        return new BatteryState(
            HasBattery: true,
            IsOnBatteryPower: status.PowerLineStatus == PowerLineStatus.Offline,
            ChargePercent: chargePercent);
    }

    private void ReportStoredBatteryFailureIfNeeded()
    {
        if (batteryStatusError is not Exception error || error.Message == lastReportedBatteryError)
        {
            return;
        }
        lastReportedBatteryError = error.Message;
        Failure?.Invoke(error);
    }

    private void UpdateSuspensionReason(SleepPreventionSuspensionReason? nextReason)
    {
        if (SuspensionReason == nextReason)
        {
            return;
        }
        SuspensionReason = nextReason;
        Trace.WriteLine(nextReason switch
        {
            SleepPreventionSuspensionReason.LowBattery => "Sleep prevention paused because battery power is below 20%.",
            SleepPreventionSuspensionReason.BatteryStatusUnavailable => "Sleep prevention paused because battery status is unavailable.",
            null => "Sleep prevention is not battery-suspended.",
            _ => throw new InvalidOperationException("Unknown sleep-prevention suspension reason.")
        });
        StateChanged?.Invoke();
    }

    private void AcquireRequestIfNeeded()
    {
        if (requestActive)
        {
            return;
        }
        var previousState = SetThreadExecutionState(
            ExecutionState.Continuous | ExecutionState.SystemRequired | ExecutionState.DisplayRequired);
        if (previousState == 0)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows rejected the system sleep and display-idle prevention request.");
        }
        requestActive = true;
        Trace.WriteLine("Acquired Windows ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED execution-state request.");
    }

    private void ReleaseRequestIfNeeded()
    {
        if (!requestActive)
        {
            return;
        }
        var previousState = SetThreadExecutionState(ExecutionState.Continuous);
        if (previousState == 0)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not release the system sleep and display-idle prevention request.");
        }
        requestActive = false;
        Trace.WriteLine("Released Windows system and display execution-state request.");
    }

    private void ScheduleExpirationTimer()
    {
        expirationTimer.Stop();
        if (ExpiresAt is not DateTimeOffset expiresAt)
        {
            return;
        }
        var remainingMilliseconds = Math.Max(1, (expiresAt - DateTimeOffset.UtcNow).TotalMilliseconds);
        expirationTimer.Interval = checked((int)Math.Min(int.MaxValue, remainingMilliseconds));
        expirationTimer.Start();
    }

    private void ExpireIfDue()
    {
        if (ExpiresAt is not DateTimeOffset expiresAt)
        {
            expirationTimer.Stop();
            return;
        }
        if (expiresAt > DateTimeOffset.UtcNow)
        {
            ScheduleExpirationTimer();
            return;
        }

        expirationTimer.Stop();
        try
        {
            ApplySelection(SleepPreventionDuration.Disabled, null);
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Failed to end timed sleep prevention: {ex}");
            Failure?.Invoke(ex);
            return;
        }
        Trace.WriteLine("Timed sleep prevention expired.");
        Expired?.Invoke();
    }

    private void EnsureOwnerThread()
    {
        if (Environment.CurrentManagedThreadId != ownerThreadId)
        {
            throw new InvalidOperationException("Sleep prevention must be changed on its owning UI thread.");
        }
    }

    private void EnsureNotDisposed()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
    }
}
