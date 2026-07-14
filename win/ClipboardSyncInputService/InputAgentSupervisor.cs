using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace ClipboardSyncInputService;

internal sealed class InputAgentSupervisor : IDisposable
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan MaxRestartDelay = TimeSpan.FromSeconds(30);
    private readonly AutoResetEvent wake = new(false);
    private AgentProcess? agent;
    private DateTimeOffset nextStartAt = DateTimeOffset.MinValue;
    private int consecutiveStartFailures;
    private string? lastWaitingReason;
    private bool disposed;

    internal void Pulse() => wake.Set();

    internal void Run(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                Reconcile();
            }
            catch (Exception ex)
            {
                ServiceLog.Write($"agent supervisor reconciliation failed: {ex}");
                StopAgent("reconciliation failure");
                ScheduleRestart();
            }

            WaitHandle.WaitAny(
                new[] { cancellationToken.WaitHandle, wake },
                (int)PollInterval.TotalMilliseconds);
        }

        StopAgent("service stopping");
    }

    private void Reconcile()
    {
        var sessionId = NativeMethods.WTSGetActiveConsoleSessionId();
        if (sessionId == NativeMethods.InvalidSessionId)
        {
            WaitWithoutAgent("no active console session");
            return;
        }

        if (!TryGetSessionUserSid(sessionId, out var userSid, out var error))
        {
            WaitWithoutAgent($"session {sessionId} has no queryable user token; win32={error}");
            return;
        }

        lastWaitingReason = null;
        if (agent is not null && agent.SessionId != sessionId)
        {
            StopAgent($"console session changed from {agent.SessionId} to {sessionId}");
        }

        if (agent is not null && !agent.IsRunning(out var exitCode))
        {
            ServiceLog.Write(
                $"input agent exited; session={agent.SessionId}, pid={agent.ProcessId}, exitCode={exitCode}");
            agent.Dispose();
            agent = null;
            ScheduleRestart();
        }

        if (agent is not null || DateTimeOffset.UtcNow < nextStartAt)
        {
            return;
        }

        try
        {
            agent = StartAgent(sessionId, userSid!);
            consecutiveStartFailures = 0;
            nextStartAt = DateTimeOffset.MinValue;
            ServiceLog.Write(
                $"input agent started; session={sessionId}, pid={agent.ProcessId}, userSid={userSid}");
        }
        catch (Exception ex)
        {
            ServiceLog.Write($"input agent start failed; session={sessionId}: {ex}");
            ScheduleRestart();
        }
    }

    private void WaitWithoutAgent(string reason)
    {
        StopAgent(reason);
        if (!string.Equals(lastWaitingReason, reason, StringComparison.Ordinal))
        {
            lastWaitingReason = reason;
            ServiceLog.Write($"input agent waiting: {reason}");
        }
        consecutiveStartFailures = 0;
        nextStartAt = DateTimeOffset.MinValue;
    }

    private void ScheduleRestart()
    {
        consecutiveStartFailures++;
        var seconds = Math.Min(1 << Math.Min(consecutiveStartFailures - 1, 4), MaxRestartDelay.TotalSeconds);
        var delay = TimeSpan.FromSeconds(seconds);
        nextStartAt = DateTimeOffset.UtcNow + delay;
        ServiceLog.Write(
            $"input agent restart scheduled; failures={consecutiveStartFailures}, delaySeconds={delay.TotalSeconds:0}");
    }

    private static bool TryGetSessionUserSid(uint sessionId, out string? userSid, out int error)
    {
        userSid = null;
        error = 0;
        if (!NativeMethods.WTSQueryUserToken(sessionId, out var token))
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }

        using (token)
        using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
        {
            userSid = identity.User?.Value
                ?? throw new InvalidOperationException($"Session {sessionId} user token has no SID.");
        }
        return true;
    }

    private static AgentProcess StartAgent(uint sessionId, string userSid)
    {
        var eventName = $"Global\\ClipboardSync.InputAgent.Stop.{sessionId}.{Guid.NewGuid():N}";
        var stopEvent = NativeMethods.CreateEvent(IntPtr.Zero, manualReset: true, initialState: false, eventName);
        if (stopEvent.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateEvent for input agent stop failed.");
        }

        try
        {
            using var token = DuplicateWinlogonToken(sessionId);
            var uiAccess = 1u;
            if (!NativeMethods.SetTokenInformation(
                    token,
                    NativeMethods.TokenUiAccess,
                    ref uiAccess,
                    sizeof(uint)))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Setting TokenUIAccess on input agent failed.");
            }

            if (!NativeMethods.CreateEnvironmentBlock(out var environment, token, inherit: false))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateEnvironmentBlock failed.");
            }

            NativeMethods.ProcessInformation processInfo;
            try
            {
                var executable = Environment.ProcessPath
                    ?? throw new InvalidOperationException("Input service executable path is unavailable.");
                var commandLine = new StringBuilder(
                    $"\"{executable}\" --agent --session={sessionId} --user-sid={userSid} --stop-event={eventName}");
                var startupInfo = new NativeMethods.StartupInfo
                {
                    Cb = Marshal.SizeOf<NativeMethods.StartupInfo>(),
                    Desktop = "winsta0\\Default"
                };
                if (!NativeMethods.CreateProcessAsUser(
                        token,
                        executable,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        inheritHandles: false,
                        NativeMethods.CreateNoWindow | NativeMethods.CreateUnicodeEnvironment,
                        environment,
                        AppContext.BaseDirectory,
                        ref startupInfo,
                        out processInfo))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser for input agent failed.");
                }
            }
            finally
            {
                if (!NativeMethods.DestroyEnvironmentBlock(environment))
                {
                    ServiceLog.Write(
                        $"DestroyEnvironmentBlock failed after agent launch attempt; win32={Marshal.GetLastWin32Error()}");
                }
            }

            using var thread = new SafeKernelHandle(processInfo.Thread, ownsHandle: true);
            return new AgentProcess(
                sessionId,
                processInfo.ProcessId,
                new SafeKernelHandle(processInfo.Process, ownsHandle: true),
                stopEvent);
        }
        catch
        {
            stopEvent.Dispose();
            throw;
        }
    }

    private static SafeKernelHandle DuplicateWinlogonToken(uint sessionId)
    {
        uint winlogonProcessId = 0;
        var processes = Process.GetProcessesByName("winlogon");
        try
        {
            var match = processes.FirstOrDefault(process => (uint)process.SessionId == sessionId);
            if (match is null)
            {
                throw new InvalidOperationException($"winlogon.exe was not found in session {sessionId}.");
            }
            winlogonProcessId = (uint)match.Id;
        }
        finally
        {
            foreach (var process in processes)
            {
                process.Dispose();
            }
        }

        using var winlogon = NativeMethods.OpenProcess(
            NativeMethods.ProcessQueryLimitedInformation,
            inheritHandle: false,
            winlogonProcessId);
        if (winlogon.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess(winlogon.exe) failed.");
        }
        if (!NativeMethods.OpenProcessToken(
                winlogon,
                NativeMethods.TokenAssignPrimary | NativeMethods.TokenDuplicate | NativeMethods.TokenQuery,
                out var sourceToken))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken(winlogon.exe) failed.");
        }

        using (sourceToken)
        {
            if (!NativeMethods.DuplicateTokenEx(
                    sourceToken,
                    NativeMethods.TokenAllAccess,
                    IntPtr.Zero,
                    NativeMethods.SecurityImpersonation,
                    NativeMethods.TokenPrimary,
                    out var duplicatedToken))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateTokenEx(winlogon.exe) failed.");
            }
            return duplicatedToken;
        }
    }

    private void StopAgent(string reason)
    {
        if (agent is null)
        {
            return;
        }
        ServiceLog.Write(
            $"stopping input agent; session={agent.SessionId}, pid={agent.ProcessId}, reason={reason}");
        agent.Stop();
        agent.Dispose();
        agent = null;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        StopAgent("supervisor disposed");
        wake.Dispose();
    }

    private sealed class AgentProcess : IDisposable
    {
        private readonly SafeKernelHandle process;
        private readonly SafeKernelHandle stopEvent;
        private bool disposed;

        internal uint SessionId { get; }
        internal uint ProcessId { get; }

        internal AgentProcess(
            uint sessionId,
            uint processId,
            SafeKernelHandle process,
            SafeKernelHandle stopEvent)
        {
            SessionId = sessionId;
            ProcessId = processId;
            this.process = process;
            this.stopEvent = stopEvent;
        }

        internal bool IsRunning(out uint exitCode)
        {
            if (!NativeMethods.GetExitCodeProcess(process, out exitCode))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess(input agent) failed.");
            }
            return exitCode == NativeMethods.StillActive;
        }

        internal void Stop()
        {
            if (!NativeMethods.SetEvent(stopEvent))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Signaling input agent stop event failed.");
            }
            var wait = NativeMethods.WaitForSingleObject(process, 3_000);
            if (wait == NativeMethods.WaitObject0)
            {
                return;
            }
            if (wait != NativeMethods.WaitTimeout)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Waiting for input agent shutdown failed.");
            }

            ServiceLog.Write($"input agent did not stop in three seconds; terminating pid={ProcessId}");
            if (!NativeMethods.TerminateProcess(process, 1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateProcess(input agent) failed.");
            }
            if (NativeMethods.WaitForSingleObject(process, 2_000) != NativeMethods.WaitObject0)
            {
                throw new InvalidOperationException($"Input agent {ProcessId} did not exit after termination.");
            }
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            process.Dispose();
            stopEvent.Dispose();
        }
    }
}
