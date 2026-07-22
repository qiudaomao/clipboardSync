using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class TrayAppContext : ApplicationContext
{
    private static readonly JsonSerializerOptions MessageJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly NotifyIcon notifyIcon;
    private bool initialSetupPending;
    private readonly ContextMenuStrip trayMenu;
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem statusActionItem;
    private readonly ToolStripMenuItem historyItem;
    private readonly ToolStripMenuItem inputStatusItem;
    private readonly ToolStripMenuItem inputSharingItem;
    private readonly ToolStripMenuItem controlDeviceItem;
    private readonly ToolStripMenuItem checkForUpdatesItem;
    private readonly Dictionary<string, InputDeviceMenuDevice> inputDevices = [];
    private readonly ToolStripMenuItem startStopItem;
    private readonly ToolStripMenuItem launchAtLoginItem;
    private readonly ToolStripMenuItem sleepPreventionItem;
    private readonly ToolStripMenuItem sleepPreventionStatusItem;
    private readonly ToolStripMenuItem lowBatterySleepPreventionItem;
    private readonly Dictionary<SleepPreventionDuration, ToolStripMenuItem> sleepPreventionItems = [];
    private readonly SleepPreventionController sleepPreventionController;
    private readonly System.Windows.Forms.Timer sleepPreventionStatusTimer = new() { Interval = 30_000 };
    private readonly ToolStripMenuItem sendFilesItem;
    private readonly FileTransferCoordinator fileTransferCoordinator = new();
    private readonly ClipboardMonitor clipboardMonitor;
    private readonly ScreenLayoutStore screenLayoutStore = new();
    private readonly PortForwardStore portForwardStore = new();
    private readonly PortForwardCoordinator portForwardCoordinator = new();
    private readonly Dictionary<string, PortForwardStatus> localForwardStatuses = [];
    private readonly Dictionary<string, PortForwardStatus> remoteForwardStatuses = [];
    private PortForwardForm? portForwardForm;
    // The device-option list the open dialog's rows were last built from, so presence changes only
    // rebuild the rows (which would discard in-progress edits) when the choices actually changed.
    private string portForwardFormDeviceSignature = "";
    private readonly InputSharingCoordinator inputCoordinator;
    private readonly WinUpdateController updateController;
    private readonly object inputCoordinatorLock = new();
    private readonly SynchronizationContext uiContext;
    private readonly Icon trayIcon;
    private readonly List<ClipboardHistoryEntry> history = [];
    private readonly Dictionary<Guid, Image> historyThumbnails = [];
    private ScreenLayoutForm? screenLayoutForm;

    private AppConfig config;
    private ISyncTransport? transport;
    private bool isSyncPaused;
    private int peerCount;
    private bool pendingInputConfigSync;
    private string status = AppText.Text("status.stopped");
    private readonly System.Windows.Forms.Timer presenceTimer;
    private DateTimeOffset lastCursorBroadcastAt = DateTimeOffset.MinValue;
    private string? lastCursorBroadcastScreenId;
    private double lastCursorBroadcastX;
    private double lastCursorBroadcastY;
    private readonly Dictionary<string, DateTimeOffset> lastCursorMessageAt = [];
    private static readonly TimeSpan PresenceStaleTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan CursorBroadcastInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan CursorReceiveInterval = TimeSpan.FromMilliseconds(125);
    private const double CursorBroadcastMinDelta = 0.0025;
    private bool isLocalLayoutWindowOpen;
    private readonly HashSet<string> layoutWatchers = [];
    private System.Windows.Forms.Timer? cursorReportTimer;
    private const int CursorReportIntervalMs = 33;

    private sealed class InputDeviceMenuDevice
    {
        public string Id { get; init; } = "";
        public string? Name { get; init; }
        public string? Address { get; init; }
        public string? Role { get; init; }
        public bool? InputEnabled { get; init; }
        public DateTimeOffset LastSeen { get; init; } = DateTimeOffset.UtcNow;

        public string BaseTitle
        {
            get
            {
                var name = string.IsNullOrWhiteSpace(Name) ? AppText.Text("device.unknown") : Name!;
                return string.IsNullOrWhiteSpace(Address) ? name : $"{name} ({Address})";
            }
        }

        public string Title
        {
            get
            {
                var status = InputEnabled is null
                    ? AppText.Text("state.unknown")
                    : InputEnabled.Value ? AppText.Text("state.enabled") : AppText.Text("state.disabled");
                return AppText.Format("device.titleStatus", BaseTitle, status);
            }
        }
    }

    public TrayAppContext()
    {
        uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        sleepPreventionController = new SleepPreventionController(uiContext);
        initialSetupPending = !ConfigStore.HasSavedConfiguration;
        config = ConfigStore.Load();
        RepairLaunchAtLoginPath();

        statusItem = new ToolStripMenuItem(AppText.Format("status.prefix", status)) { Enabled = false };
        statusActionItem = new ToolStripMenuItem(AppText.Text("menu.completeSetup"), null, (_, _) => HandleStatusAction());
        historyItem = new ToolStripMenuItem(AppText.Text("menu.clipboardHistory"));
        inputStatusItem = new ToolStripMenuItem(AppText.Text("input.off")) { Enabled = false };
        inputSharingItem = new ToolStripMenuItem(AppText.Text("menu.enableInputSharing"), null, (_, _) => ToggleInputSharing());
        controlDeviceItem = new ToolStripMenuItem(AppText.Text("menu.controlDevice"));
        startStopItem = new ToolStripMenuItem(AppText.Text("menu.resumeSync"), null, (_, _) => ToggleTransport());
        launchAtLoginItem = new ToolStripMenuItem(AppText.Text("menu.launchAtLogin"), null, (_, _) => ToggleLaunchAtLogin());
        sleepPreventionItem = new ToolStripMenuItem(AppText.Text("menu.preventSystemSleep"));
        sleepPreventionStatusItem = new ToolStripMenuItem(AppText.Text("sleep.statusOff")) { Enabled = false };
        lowBatterySleepPreventionItem = new ToolStripMenuItem(
            AppText.Text("sleep.disableBelow20OnBattery"),
            null,
            (_, _) => ToggleLowBatterySleepPreventionGuard());
        sendFilesItem = new ToolStripMenuItem(AppText.Text("menu.sendFiles"));
        trayIcon = LoadTrayIcon();
        inputCoordinator = new InputSharingCoordinator(config.DeviceId, screenLayoutStore);
        updateController = new WinUpdateController(trayIcon, CloseForUpdate);
        checkForUpdatesItem = new ToolStripMenuItem(AppText.Text("menu.checkForUpdates"), null, (_, _) => updateController.CheckForUpdates());
        trayMenu = BuildMenu();

        notifyIcon = new NotifyIcon
        {
            Icon = trayIcon,
            Text = AppText.Text("app.name"),
            Visible = true,
            ContextMenuStrip = trayMenu
        };
        notifyIcon.MouseUp += OnNotifyIconMouseUp;

        clipboardMonitor = new ClipboardMonitor();
        clipboardMonitor.LocalContentChanged += content => Publish(content);
        clipboardMonitor.LocalSkipped += reason => OnUi(() =>
        {
            status = reason;
            UpdateMenu();
        });
        // Deliberately NOT marshaled to the UI thread: input messages originate on the hook
        // thread and its flush timers, and encrypt+send is thread-safe. Hopping through the UI
        // thread would queue realtime mouse moves behind clipboard polls and menu rebuilds.
        inputCoordinator.MessageReady += message => PublishInput(message);
        inputCoordinator.StatusChanged += text => OnUi(() => inputStatusItem.Text = text);
        // Like input, tunnel traffic is sent straight from the coordinator's worker threads;
        // encrypt+send is thread-safe and must not queue behind UI-thread work.
        portForwardCoordinator.MessageReady += message => PublishTunnel(message);
        portForwardCoordinator.DataReady += PublishTunnelDataAsync;
        fileTransferCoordinator.ChunkReady += PublishFileChunk;
        portForwardCoordinator.StatusChanged += text => OnUi(() =>
        {
            status = text;
            UpdateMenu();
        });
        portForwardCoordinator.StatusesChanged += statuses => OnUi(() => HandleLocalForwardStatuses(statuses));

        // File-transfer chunks are sent straight from the coordinator's lock, like tunnel data;
        // encrypt+send is thread-safe. Status/completion touch the UI, so those hop threads.
        fileTransferCoordinator.Configure(config.DeviceId);
        fileTransferCoordinator.MessageReady += message => _ = SendEncrypted(message, realtime: true, routedTo: message.Target);
        fileTransferCoordinator.StatusChanged += text => OnUi(() =>
        {
            status = text;
            UpdateMenu();
        });
        fileTransferCoordinator.FilesReceived += paths => OnUi(() =>
        {
            clipboardMonitor.ApplyReceivedFilePaths(paths);
            status = AppText.Text("status.filesReceived");
            UpdateMenu();
            notifyIcon.ShowBalloonTip(5000, AppText.Text("app.name"), AppText.Text("status.filesReceivedPasteHint"), ToolTipIcon.Info);
        });

        // Periodically re-broadcasts our own hello (so peers keep our LastSeen fresh even when we
        // have nothing else to send) and prunes any peer we haven't heard from in a while -
        // otherwise a disconnected device's menu entry would linger forever, since nothing else
        // ever removes it. Its screen layout entries are deliberately NOT touched here - see
        // RemoveKnownDevice.
        presenceTimer = new System.Windows.Forms.Timer { Interval = 5000 };
        presenceTimer.Tick += (_, _) =>
        {
            SendInputHello();
            PruneStaleDevices();
        };

        sleepPreventionController.Expired += () =>
        {
            config.SleepPreventionDuration = SleepPreventionDuration.Disabled;
            config.SleepPreventionUntil = null;
            ConfigStore.Save(config);
            UpdateMenu();
        };
        sleepPreventionController.Failure += ShowSleepPreventionError;
        sleepPreventionController.StateChanged += UpdateMenu;
        sleepPreventionStatusTimer.Tick += (_, _) => UpdateSleepPreventionStatus();
        sleepPreventionStatusTimer.Start();
        bool savedSleepPreventionExpired;
        try
        {
            sleepPreventionController.SetLowBatteryGuardEnabled(
                config.DisableSleepPreventionBelow20PercentOnBattery);
            savedSleepPreventionExpired = sleepPreventionController.Restore(
                config.SleepPreventionDuration,
                config.SleepPreventionUntil);
        }
        catch (Exception ex)
        {
            ShowSleepPreventionError(ex);
            savedSleepPreventionExpired = false;
        }
        if (savedSleepPreventionExpired)
        {
            config.SleepPreventionDuration = SleepPreventionDuration.Disabled;
            config.SleepPreventionUntil = null;
            ConfigStore.Save(config);
        }
        UpdateMenu();

        if (BetaLicense.IsExpired)
        {
            status = AppText.Text("status.betaExpired");
            UpdateMenu();
            ShowBetaExpiredPrompt();
        }
        else
        {
            clipboardMonitor.Start();
            RegisterLocalScreen();
            inputCoordinator.Start();
            UpdateInputCoordinator();
            RestartTransport();
            presenceTimer.Start();
            if (initialSetupPending)
            {
                Application.Idle += ShowInitialSetupWhenIdle;
            }
        }
    }

    private void ShowInitialSetupWhenIdle(object? sender, EventArgs e)
    {
        Application.Idle -= ShowInitialSetupWhenIdle;
        if (!initialSetupPending)
        {
            return;
        }
        initialSetupPending = false;
        ShowConfiguration(firstRun: true);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            presenceTimer.Stop();
            presenceTimer.Dispose();
            cursorReportTimer?.Stop();
            cursorReportTimer?.Dispose();
            transport?.Dispose();
            updateController.Dispose();
            fileTransferCoordinator.Dispose();
            portForwardCoordinator.Dispose();
            portForwardForm?.Dispose();
            inputCoordinator.Dispose();
            clipboardMonitor.Dispose();
            notifyIcon.Dispose();
            trayMenu.Dispose();
            trayIcon.Dispose();
            screenLayoutForm?.Dispose();
            sleepPreventionStatusTimer.Stop();
            sleepPreventionStatusTimer.Dispose();
            sleepPreventionController.Dispose();
        }

        base.Dispose(disposing);
    }

    private void ShowBetaExpiredPrompt()
    {
        var message = $"{AppText.Text("beta.expiredMessage")}{Environment.NewLine}{Environment.NewLine}{AppText.Text("beta.checkNowQuestion")}";
        var result = MessageBox.Show(
            message,
            AppText.Text("beta.expiredTitle"),
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Information);
        if (result == DialogResult.Yes)
        {
            updateController.CheckForUpdates();
        }
        else
        {
            // Called from the constructor, before Application.Run's message loop has started -
            // Application.Exit() would have nothing to signal yet, so terminate the process directly.
            Environment.Exit(0);
        }
    }

    private void PruneStaleDevices()
    {
        var cutoff = DateTimeOffset.UtcNow - PresenceStaleTimeout;
        var staleIds = inputDevices.Values.Where(d => d.LastSeen < cutoff).Select(d => d.Id).ToList();
        if (staleIds.Count == 0)
        {
            return;
        }

        foreach (var staleId in staleIds)
        {
            RemoveKnownDevice(staleId);
        }

        UpdateCursorReporting();
        UpdateMenu();
        UpdateInputCoordinator();
        RefreshScreenLayoutFormIfVisible();
    }

    /// Forgets everything we knew about one peer device's *live presence*: its menu entry and
    /// layout-watch state. Deliberately does NOT touch screenLayoutStore - a device going offline
    /// (whether it quit, restarted, or just dropped its connection momentarily) shouldn't erase the
    /// position the user dragged it to. Screens for offline devices stay in the layout, drawn as
    /// disconnected, until the user explicitly forgets them (see ForgetDevice). The user's chosen
    /// ControlDeviceId is likewise kept: a restarting control device must get control back when it
    /// returns, and (on a server) clearing it here would make hellos broadcast this device as the
    /// controller, permanently reassigning control on every peer. Only ForgetDevice drops it.
    private void RemoveKnownDevice(string staleId)
    {
        inputDevices.Remove(staleId);
        layoutWatchers.Remove(staleId);
    }

    /// Called the moment the last remaining peer disconnects. At that point we know with certainty
    /// every other device we'd been tracking is gone, so we can mark them offline immediately
    /// instead of waiting for the slower staleness sweep (PruneStaleDevices) to notice one-by-one.
    private void ClearAllKnownPeers()
    {
        if (inputDevices.Count == 0)
        {
            return;
        }
        foreach (var staleId in inputDevices.Keys.ToList())
        {
            RemoveKnownDevice(staleId);
        }

        UpdateCursorReporting();
        UpdateMenu();
        UpdateInputCoordinator();
        RefreshScreenLayoutFormIfVisible();
    }

    /// Explicitly and permanently drops a device's saved screens from the shared layout - the only
    /// path that should ever delete layout entries (offline devices are kept, just drawn as
    /// disconnected). Triggered from the layout window's right-click "Forget This Device" menu, and
    /// only offered there for devices that are currently offline.
    private void ForgetDevice(string id)
    {
        if (id == config.DeviceId)
        {
            return;
        }
        RemoveKnownDevice(id);
        if (config.ControlDeviceId == id)
        {
            config.ControlDeviceId = null;
            ConfigStore.Save(config);
            UpdateInputCoordinator();
            SyncInputConfig();
        }
        var changed = screenLayoutStore.Remove(id);
        UpdateMenu();
        if (changed)
        {
            RefreshScreenLayoutFormIfVisible();
        }
        if (config.Mode == SyncMode.Server)
        {
            if (changed)
            {
                BroadcastLayout();
            }
        }
        else
        {
            SendLayoutForgetRequest(id);
        }
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(statusItem);
        menu.Items.Add(statusActionItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(historyItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(sendFilesItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(inputStatusItem);
        menu.Items.Add(inputSharingItem);
        menu.Items.Add(controlDeviceItem);
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.screenLayout"), null, (_, _) => ShowScreenLayout()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.configure"), null, (_, _) => ShowConfiguration()));

        var moreFeaturesItem = new ToolStripMenuItem(AppText.Text("menu.moreFeatures"));
        moreFeaturesItem.DropDownItems.Add(new ToolStripMenuItem(AppText.Text("menu.portForward"), null, (_, _) => ShowPortForward()));
        sleepPreventionItem.DropDownItems.Add(sleepPreventionStatusItem);
        sleepPreventionItem.DropDownItems.Add(new ToolStripSeparator());
        foreach (var duration in Enum.GetValues<SleepPreventionDuration>())
        {
            var durationItem = new ToolStripMenuItem(AppText.Text(duration.TitleKey()))
            {
                Tag = duration
            };
            durationItem.Click += (_, _) => SetSleepPrevention(duration);
            sleepPreventionItem.DropDownItems.Add(durationItem);
            sleepPreventionItems[duration] = durationItem;
        }
        sleepPreventionItem.DropDownItems.Add(new ToolStripSeparator());
        sleepPreventionItem.DropDownItems.Add(lowBatterySleepPreventionItem);
        moreFeaturesItem.DropDownItems.Add(sleepPreventionItem);
        moreFeaturesItem.DropDownItems.Add(launchAtLoginItem);
        menu.Items.Add(moreFeaturesItem);
        menu.Items.Add(checkForUpdatesItem);
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.updateHistory"), null, (_, _) => updateController.ShowUpdateHistory()));
        menu.Items.Add(startStopItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.about"), null, (_, _) => ShowAbout()));
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.homepage"), null, (_, _) => OpenProjectHomepage()));
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.feedback"), null, (_, _) => OpenFeedbackEmail()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.exit"), null, (_, _) => ExitThread()));
        return menu;
    }

    private void OnNotifyIconMouseUp(object? sender, MouseEventArgs e)
    {
        if (e.Button is not (MouseButtons.Left or MouseButtons.Right))
        {
            return;
        }

        UpdateMenu();
        if (!trayMenu.Visible)
        {
            trayMenu.Show(Cursor.Position);
        }
    }

    private static Icon LoadTrayIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "clipboard-sync-icon.ico");
        return File.Exists(iconPath) ? new Icon(iconPath) : SystemIcons.Application;
    }

    private static void OpenProjectHomepage()
    {
        // UseShellExecute is required to open a URL in the default browser on .NET Core+.
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://clipboardsync.fuzhuo.me")
        {
            UseShellExecute = true
        });
    }

    private static void OpenFeedbackEmail()
    {
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("mailto:qiudaomao@gmail.com?subject=Clipboard%20Sync%20Feedback")
        {
            UseShellExecute = true
        });
    }

    private static void ShowAbout()
    {
        var version = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;

        if (string.IsNullOrWhiteSpace(version))
        {
            version = Application.ProductVersion;
        }

        MessageBox.Show(
            AppText.Format("about.message", AppText.Text("app.name"), version),
            AppText.Format("about.title", AppText.Text("app.name")),
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private void UpdateMenu()
    {
        var needsSetup = !CanStartTransport(config);
        var statusSymbol = needsSetup ? "⚠" : peerCount > 0 ? "●" : transport is null ? "○" : "◌";
        statusItem.Text = $"{statusSymbol} {AppText.Format("status.prefix", status)}";
        var tooltip = $"{AppText.Text("app.name")}: {status}";
        notifyIcon.Text = tooltip.Length <= 63 ? tooltip : tooltip[..63];
        statusActionItem.Visible = !isSyncPaused && (needsSetup || transport is null);
        statusActionItem.Text = AppText.Text(needsSetup ? "menu.completeSetup" : "menu.reconnect");
        inputSharingItem.Checked = config.InputSharingEnabled;
        startStopItem.Text = AppText.Text(isSyncPaused || transport is null ? "menu.resumeSync" : "menu.pauseSync");
        launchAtLoginItem.Checked = IsLaunchAtLoginEnabled();
        foreach (var (duration, item) in sleepPreventionItems)
        {
            item.Checked = sleepPreventionController.Selection == duration;
        }
        lowBatterySleepPreventionItem.Checked = sleepPreventionController.LowBatteryGuardEnabled;
        UpdateSleepPreventionStatus();
        sleepPreventionItem.Text = sleepPreventionController.SuspensionReason switch
        {
            SleepPreventionSuspensionReason.LowBattery => AppText.Text("menu.preventSystemSleepPausedLowBattery"),
            SleepPreventionSuspensionReason.BatteryStatusUnavailable => AppText.Text("menu.preventSystemSleepPausedBatteryUnavailable"),
            null => AppText.Text("menu.preventSystemSleep"),
            _ => throw new InvalidOperationException("Unknown sleep-prevention suspension reason.")
        };
        RefreshControlDeviceMenu();
        RefreshSendFilesMenu();
        RefreshHistoryMenu();
    }

    private void UpdateSleepPreventionStatus()
    {
        var paused = sleepPreventionController.SuspensionReason is not null;
        sleepPreventionStatusItem.Text = sleepPreventionController.Selection switch
        {
            SleepPreventionDuration.Disabled => AppText.Text("sleep.statusOff"),
            SleepPreventionDuration.Forever => AppText.Text(
                paused ? "sleep.statusPausedForever" : "sleep.statusForever"),
            _ => FormatTimedSleepPreventionStatus(paused)
        };
    }

    private string FormatTimedSleepPreventionStatus(bool paused)
    {
        var expiration = sleepPreventionController.ExpiresAt
            ?? throw new InvalidOperationException("A timed sleep-prevention selection has no expiration.");
        var remainingMinutes = Math.Max(0, (int)Math.Ceiling((expiration - DateTimeOffset.UtcNow).TotalMinutes));
        var hours = remainingMinutes / 60;
        var minutes = remainingMinutes % 60;
        if (hours > 0)
        {
            return AppText.Format(
                paused ? "sleep.statusPausedRemainingHoursMinutes" : "sleep.statusRemainingHoursMinutes",
                hours,
                minutes);
        }
        return AppText.Format(
            paused ? "sleep.statusPausedRemainingMinutes" : "sleep.statusRemainingMinutes",
            minutes);
    }

    private void HandleStatusAction()
    {
        if (!CanStartTransport(config))
        {
            ShowConfiguration(firstRun: true);
            return;
        }
        RestartTransport();
    }

    private void SetSleepPrevention(SleepPreventionDuration duration)
    {
        DateTimeOffset? expiration;
        try
        {
            expiration = sleepPreventionController.Select(duration);
        }
        catch (Exception ex)
        {
            ShowSleepPreventionError(ex);
            return;
        }
        config.SleepPreventionDuration = duration;
        config.SleepPreventionUntil = expiration;
        ConfigStore.Save(config);
        UpdateMenu();
    }

    private void ToggleLowBatterySleepPreventionGuard()
    {
        var enabled = !sleepPreventionController.LowBatteryGuardEnabled;
        try
        {
            sleepPreventionController.SetLowBatteryGuardEnabled(enabled);
        }
        catch (Exception ex)
        {
            ShowSleepPreventionError(ex);
            return;
        }
        config.DisableSleepPreventionBelow20PercentOnBattery = enabled;
        ConfigStore.Save(config);
        UpdateMenu();
    }

    private void ShowSleepPreventionError(Exception error)
    {
        System.Diagnostics.Trace.WriteLine($"System sleep prevention failed: {error}");
        MessageBox.Show(
            AppText.Format("sleep.errorMessage", error.Message),
            AppText.Text("sleep.errorTitle"),
            MessageBoxButtons.OK,
            MessageBoxIcon.Error);
        UpdateMenu();
    }

    /// One entry per online peer: files go to exactly the device the user picks, never to every
    /// peer at once. The parent item is grayed out while the clipboard holds no sendable files,
    /// and names the copied file otherwise.
    private void RefreshSendFilesMenu()
    {
        sendFilesItem.DropDownItems.Clear();

        var fileNames = clipboardMonitor.PeekFileNamesForManualSend();
        if (fileNames is null)
        {
            sendFilesItem.Text = AppText.Text("menu.sendFilesNoFile");
            sendFilesItem.Enabled = false;
            return;
        }
        var summary = fileNames.Count > 1
            ? $"{fileNames[0]} +{fileNames.Count - 1}"
            : fileNames[0];
        sendFilesItem.Text = AppText.Format("menu.sendFilesWithName", summary);
        sendFilesItem.Enabled = true;

        var peers = inputDevices.Values
            .Where(item => item.Id != config.DeviceId)
            .OrderBy(item => item.BaseTitle, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        if (peers.Count == 0)
        {
            sendFilesItem.DropDownItems.Add(new ToolStripMenuItem(AppText.Text("menu.noPeers")) { Enabled = false });
            return;
        }

        foreach (var peer in peers)
        {
            var item = new ToolStripMenuItem(peer.BaseTitle) { Tag = peer.Id };
            item.Click += (_, _) => SendFilesToDevice(peer.Id, peer.BaseTitle);
            sendFilesItem.DropDownItems.Add(item);
        }
    }

    private string EffectiveControlDeviceId => string.IsNullOrWhiteSpace(config.ControlDeviceId)
        ? config.DeviceId
        : config.ControlDeviceId!;

    private InputDeviceMenuDevice LocalInputDevice => new()
    {
        Id = config.DeviceId,
        Name = Environment.MachineName,
        Address = NetworkAddress.LocalLanIPv4Address(),
        Role = config.Mode == SyncMode.Server ? "server" : "client",
        InputEnabled = config.InputSharingEnabled,
        LastSeen = DateTimeOffset.UtcNow
    };

    private void RefreshControlDeviceMenu()
    {
        controlDeviceItem.DropDownItems.Clear();

        var selectedId = EffectiveControlDeviceId;
        var devices = new List<InputDeviceMenuDevice> { LocalInputDevice };
        devices.AddRange(inputDevices.Values
            .Where(item => item.Id != config.DeviceId)
            .OrderBy(item => item.Title, StringComparer.CurrentCultureIgnoreCase));

        if (!devices.Any(item => item.Id == selectedId))
        {
            devices.Add(new InputDeviceMenuDevice
            {
                Id = selectedId,
                Name = AppText.Text("device.unknown"),
                InputEnabled = null,
                LastSeen = DateTimeOffset.MinValue
            });
        }

        var selectedTitle = devices.FirstOrDefault(item => item.Id == selectedId)?.Title ?? AppText.Text("device.unknown");
        controlDeviceItem.Text = AppText.Format("menu.controlDeviceWithTitle", selectedTitle);

        foreach (var device in devices)
        {
            var item = new ToolStripMenuItem(device.Title)
            {
                Checked = device.Id == selectedId,
                Tag = device.Id
            };
            item.Click += (_, _) => SetControlDevice(device.Id);
            controlDeviceItem.DropDownItems.Add(item);
        }
    }

    private void RememberInputDevice(InputMessage message)
    {
        if (message.Origin == config.DeviceId)
        {
            return;
        }

        // Whether this device was offline a moment ago - its first message back (of any kind, not
        // necessarily one carrying Screens) is what should flip its layout rect from "disconnected"
        // back to normal, even when Merge below finds nothing to actually change.
        var wasOffline = !inputDevices.TryGetValue(message.Origin, out var existing);
        var newInputEnabled = message.Enabled ?? existing?.InputEnabled;
        var inputEnabledChanged = newInputEnabled != existing?.InputEnabled;
        var newName = message.DeviceName ?? existing?.Name;
        var newAddress = message.DeviceAddress ?? existing?.Address;
        // The name/address can resolve on a later message (e.g. a nameless message arrives first,
        // then a hello): the Port Forward dialog needs to swap "Offline Device" for the real name.
        var identityChanged = newName != existing?.Name || newAddress != existing?.Address;
        inputDevices[message.Origin] = new InputDeviceMenuDevice
        {
            Id = message.Origin,
            Name = newName,
            Address = newAddress,
            Role = message.Role ?? existing?.Role,
            InputEnabled = newInputEnabled,
            LastSeen = DateTimeOffset.UtcNow
        };

        var layoutChanged = message.Screens is { } screens && screenLayoutStore.Merge(message.Origin, screens);
        if (layoutChanged && config.Mode == SyncMode.Server)
        {
            BroadcastLayout();
        }
        if (layoutChanged || wasOffline || inputEnabledChanged || identityChanged)
        {
            RefreshScreenLayoutFormIfVisible();
            // The coordinator only sees peers through the enabled/name snapshots passed via
            // Update(). Without this, a peer that restarts (dropped from inputDevices, then
            // hellos back in) never re-enters those snapshots and the controller sits in
            // "waiting for peer screen" until some unrelated event refreshes the coordinator.
            // UpdateInputCoordinator() also runs the signature-gated Port Forward dialog refresh.
            UpdateInputCoordinator();
        }

        UpdateMenu();
    }

    /// Devices currently known to be connected - the local machine plus every peer we're actively
    /// hearing from. Anything in the shared screen layout that isn't in this set is a remembered
    /// device that's offline right now (quit, restarted, or just dropped), not one we've forgotten.
    private HashSet<string> OnlineDeviceIds()
    {
        var ids = new HashSet<string>(inputDevices.Keys) { config.DeviceId };
        return ids;
    }

    private Dictionary<string, bool> DeviceEnabledMap()
    {
        var map = new Dictionary<string, bool> { [config.DeviceId] = config.InputSharingEnabled };
        foreach (var device in inputDevices.Values)
        {
            if (device.InputEnabled is { } enabled)
            {
                map[device.Id] = enabled;
            }
        }
        return map;
    }

    private Dictionary<string, string> DeviceDisplayNames()
    {
        var names = new Dictionary<string, string> { [config.DeviceId] = Environment.MachineName };
        foreach (var device in inputDevices.Values)
        {
            names[device.Id] = device.BaseTitle;
        }
        return names;
    }

    private void RegisterLocalScreen()
    {
        if (screenLayoutStore.Merge(config.DeviceId, InputSharingCoordinator.CurrentScreens()))
        {
            RefreshScreenLayoutFormIfVisible();
        }
    }

    private void ShowScreenLayout()
    {
        RegisterLocalScreen();
        var form = EnsureScreenLayoutForm();
        form.UpdateLayout(screenLayoutStore.Snapshot(), config.DeviceId, DeviceDisplayNames(), OnlineDeviceIds(), DeviceEnabledMap());
        if (!form.Visible)
        {
            form.Show();
        }
        form.Activate();

        isLocalLayoutWindowOpen = true;
        BroadcastLayoutWatch(enabled: true);
        UpdateCursorReporting();
    }

    private ScreenLayoutForm EnsureScreenLayoutForm()
    {
        if (screenLayoutForm is null || screenLayoutForm.IsDisposed)
        {
            screenLayoutForm = new ScreenLayoutForm();
            screenLayoutForm.LayoutChanged += entries => ApplyLocalLayoutChange(entries);
            screenLayoutForm.FormClosed += (_, _) => HandleScreenLayoutFormClosed();
            screenLayoutForm.ForgetDevice += id => ForgetDevice(id);
        }
        return screenLayoutForm;
    }

    private void CloseForUpdate()
    {
        if (SynchronizationContext.Current == uiContext)
        {
            ExitThread();
            return;
        }

        uiContext.Send(_ => ExitThread(), null);
    }

    private void HandleScreenLayoutFormClosed()
    {
        isLocalLayoutWindowOpen = false;
        BroadcastLayoutWatch(enabled: false);
        UpdateCursorReporting();
    }

    private void RefreshScreenLayoutFormIfVisible()
    {
        if (screenLayoutForm is { IsDisposed: false, Visible: true })
        {
            screenLayoutForm.UpdateLayout(screenLayoutStore.Snapshot(), config.DeviceId, DeviceDisplayNames(), OnlineDeviceIds(), DeviceEnabledMap());
        }
    }

    private void ApplyLocalLayoutChange(List<ScreenLayoutEntry> entries)
    {
        // Apply to our own persisted copy immediately, regardless of role - a client shouldn't
        // depend on the server's round-trip broadcast landing before the app might quit to have
        // its own drag survive a restart. The server request below still propagates the change to
        // the server's canonical table and other peers.
        screenLayoutStore.ApplyPositionUpdates(entries);
        if (config.Mode == SyncMode.Server)
        {
            BroadcastLayout();
        }
        else
        {
            SendLayoutRequest(entries);
        }
        UpdateInputCoordinator();
    }

    private void BroadcastLayout()
    {
        if (transport is null)
        {
            return;
        }
        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Kind = "layout",
            Role = config.Mode == SyncMode.Server ? "server" : "client",
            Layout = screenLayoutStore.Snapshot(),
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void SendLayoutRequest(List<ScreenLayoutEntry> entries)
    {
        if (transport is null)
        {
            return;
        }
        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Kind = "layout",
            Role = config.Mode == SyncMode.Server ? "server" : "client",
            Layout = entries,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    /// Asks the server (the canonical layout owner) to drop a device's screens. Only meaningful
    /// when we're a client - the server applies it locally and rebroadcasts the resulting layout.
    private void SendLayoutForgetRequest(string forgottenId)
    {
        if (transport is null)
        {
            return;
        }
        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Target = forgottenId,
            Kind = "layoutForget",
            Role = config.Mode == SyncMode.Server ? "server" : "client",
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void HandleLayoutForgetMessage(InputMessage message)
    {
        if (config.Mode != SyncMode.Server || message.Target is not { } target)
        {
            return;
        }
        inputDevices.Remove(target);
        layoutWatchers.Remove(target);
        if (screenLayoutStore.Remove(target))
        {
            BroadcastLayout();
        }
        UpdateMenu();
        RefreshScreenLayoutFormIfVisible();
    }

    /// The device choices offered by the Port Forward dialog: this machine first, then every
    /// online peer, then any offline device still referenced by an existing rule (so its rows
    /// stay editable instead of silently losing their selection).
    private List<PortForwardForm.DeviceOption> PortForwardDeviceOptions()
    {
        var options = new List<PortForwardForm.DeviceOption>
        {
            new(config.DeviceId, LocalInputDevice.BaseTitle)
        };
        options.AddRange(inputDevices.Values
            .Where(device => device.Id != config.DeviceId)
            .OrderBy(device => device.BaseTitle, StringComparer.CurrentCultureIgnoreCase)
            .Select(device => new PortForwardForm.DeviceOption(device.Id, device.BaseTitle)));

        var knownIds = options.Select(option => option.Id).ToHashSet();
        foreach (var rule in portForwardStore.Snapshot())
        {
            foreach (var referencedId in new[] { rule.InDeviceId, rule.OutDeviceId })
            {
                if (!string.IsNullOrEmpty(referencedId) && knownIds.Add(referencedId))
                {
                    var shortId = referencedId.Length > 8 ? referencedId[..8] : referencedId;
                    options.Add(new PortForwardForm.DeviceOption(referencedId, $"{AppText.Text("forward.offlineDevice")} ({shortId})"));
                }
            }
        }
        return options;
    }

    private static string PortForwardDeviceSignature(List<PortForwardForm.DeviceOption> options)
    {
        return string.Join("|", options.Select(option => $"{option.Id}:{option.Title}"));
    }

    private void ShowPortForward()
    {
        // Modeless (like the screen layout window) so live status can be pushed while it stays open;
        // rebuilt each open so its rows reflect the current rule table and device list.
        portForwardForm?.Dispose();
        var options = PortForwardDeviceOptions();
        portForwardFormDeviceSignature = PortForwardDeviceSignature(options);
        portForwardForm = new PortForwardForm(portForwardStore.Snapshot(), options);
        portForwardForm.RulesApplied += ApplyPortForwardRules;
        portForwardForm.FormClosed += (_, _) => portForwardForm = null;
        portForwardForm.UpdateStatuses(PortForwardDisplayStatuses());
        portForwardForm.Show();
        portForwardForm.Activate();
    }

    private void ApplyPortForwardRules(List<PortForwardRule> rules)
    {
        // Apply locally right away (mirroring layout edits), then let the server's canonical copy
        // propagate: a server broadcasts the accepted table, a client sends a change request.
        portForwardStore.ApplySnapshot(rules);
        PruneForwardStatuses();
        SendForwards();
        UpdatePortForwardCoordinator();
        RefreshPortForwardFormIfVisible();
    }

    private void HandleLocalForwardStatuses(List<PortForwardStatus> statuses)
    {
        localForwardStatuses.Clear();
        foreach (var s in statuses)
        {
            localForwardStatuses[s.Id] = s;
        }
        SendForwardStatuses();
        RefreshPortForwardFormIfVisible();
    }

    /// Broadcasts this device's own listen state so peers can show accurate status lights for rules
    /// that listen here. Only this device's local statuses are sent; each device reports its own.
    private void SendForwardStatuses()
    {
        if (transport is null || peerCount == 0)
        {
            return;
        }
        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Kind = "forwardStatus",
            Role = config.Mode == SyncMode.Server ? "server" : "client",
            ForwardStatuses = localForwardStatuses.Values.ToList(),
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void HandleForwardStatusMessage(InputMessage message)
    {
        if (message.ForwardStatuses is not { } statuses)
        {
            return;
        }
        foreach (var s in statuses)
        {
            remoteForwardStatuses[s.Id] = s;
        }
        RefreshPortForwardFormIfVisible();
    }

    /// Drops status entries for rules no longer in the table, keeping the two status maps bounded.
    private void PruneForwardStatuses()
    {
        var liveIds = portForwardStore.Snapshot().Select(rule => rule.Id).ToHashSet();
        foreach (var id in localForwardStatuses.Keys.Where(id => !liveIds.Contains(id)).ToList())
        {
            localForwardStatuses.Remove(id);
        }
        foreach (var id in remoteForwardStatuses.Keys.Where(id => !liveIds.Contains(id)).ToList())
        {
            remoteForwardStatuses.Remove(id);
        }
    }

    /// Computes the status light + hover tooltip for every rule, merging this device's own listen
    /// state with peer reports and gating by the rule's enabled flag and its In device's presence.
    private Dictionary<string, PortForwardForm.RuleStatus> PortForwardDisplayStatuses()
    {
        var online = OnlineDeviceIds();
        var result = new Dictionary<string, PortForwardForm.RuleStatus>();
        foreach (var rule in portForwardStore.Snapshot())
        {
            result[rule.Id] = DisplayStatus(rule, online);
        }
        return result;
    }

    private PortForwardForm.RuleStatus DisplayStatus(PortForwardRule rule, HashSet<string> online)
    {
        if (!rule.Enabled)
        {
            return new PortForwardForm.RuleStatus(PortForwardForm.StatusLight.Gray, AppText.Text("forward.statusDisabled"));
        }
        // A forward only works when both ends are reachable: the In device has to be up to listen,
        // and the Out device has to be up to receive. A peer (not us) is offline when it isn't in
        // the online set. Gray out either way so a quit/offline peer stops reading as healthy.
        if (rule.InDeviceId != config.DeviceId && !online.Contains(rule.InDeviceId))
        {
            return new PortForwardForm.RuleStatus(PortForwardForm.StatusLight.Gray, AppText.Text("forward.statusOffline"));
        }
        if (rule.OutDeviceId != config.DeviceId && !online.Contains(rule.OutDeviceId))
        {
            return new PortForwardForm.RuleStatus(PortForwardForm.StatusLight.Gray, AppText.Text("forward.statusOutOffline"));
        }
        var status = rule.InDeviceId == config.DeviceId
            ? localForwardStatuses.GetValueOrDefault(rule.Id)
            : remoteForwardStatuses.GetValueOrDefault(rule.Id);
        if (status is null)
        {
            return new PortForwardForm.RuleStatus(PortForwardForm.StatusLight.Gray, AppText.Text("forward.statusStarting"));
        }
        return status.Ok
            ? new PortForwardForm.RuleStatus(PortForwardForm.StatusLight.Green, AppText.Format("forward.statusListening", rule.InPort))
            : new PortForwardForm.RuleStatus(PortForwardForm.StatusLight.Red, AppText.Format("forward.statusFailed", status.Reason ?? ""));
    }

    /// Refreshes the open dialog after a presence or status change: rebuilds the rows only when the
    /// device options changed (a peer went offline/online, or its name resolved), otherwise just
    /// recolors the status lights so in-progress edits survive.
    private void RefreshPortForwardFormIfVisible()
    {
        if (portForwardForm is not { IsDisposed: false, Visible: true })
        {
            return;
        }
        var options = PortForwardDeviceOptions();
        var signature = PortForwardDeviceSignature(options);
        if (signature != portForwardFormDeviceSignature)
        {
            portForwardFormDeviceSignature = signature;
            portForwardForm.SetRules(portForwardStore.Snapshot(), options, PortForwardDisplayStatuses());
        }
        else
        {
            portForwardForm.UpdateStatuses(PortForwardDisplayStatuses());
        }
    }

    private void SendForwards()
    {
        if (transport is null)
        {
            return;
        }
        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Kind = "forwards",
            Role = config.Mode == SyncMode.Server ? "server" : "client",
            Forwards = portForwardStore.Snapshot(),
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void HandleForwardsMessage(InputMessage message)
    {
        if (message.Forwards is not { } forwards)
        {
            return;
        }
        if (config.Mode == SyncMode.Server)
        {
            if (message.Role != "client")
            {
                return;
            }
            portForwardStore.ApplySnapshot(forwards);
            SendForwards();
        }
        else
        {
            if (message.Role != "server")
            {
                return;
            }
            portForwardStore.ApplySnapshot(forwards);
        }
        PruneForwardStatuses();
        UpdatePortForwardCoordinator();
        // A peer changed the shared table - rebuild the dialog's rows (a new/removed rule), not just
        // the status lights.
        RefreshPortForwardFormRowsIfVisible();
    }

    /// Forces a full rows rebuild from the current (possibly peer-updated) rule table, if the dialog
    /// is open - used when the rule set itself changed rather than just presence.
    private void RefreshPortForwardFormRowsIfVisible()
    {
        if (portForwardForm is { IsDisposed: false, Visible: true })
        {
            var options = PortForwardDeviceOptions();
            portForwardFormDeviceSignature = PortForwardDeviceSignature(options);
            portForwardForm.SetRules(portForwardStore.Snapshot(), options, PortForwardDisplayStatuses());
        }
    }

    private void UpdatePortForwardCoordinator()
    {
        portForwardCoordinator.Update(
            config.DeviceId,
            portForwardStore.Snapshot(),
            transport is not null,
            new HashSet<string>(inputDevices.Keys));
        // Presence and transport changes flow through here; refresh the dialog's lights so remote
        // rules flip to "offline"/back live.
        RefreshPortForwardFormIfVisible();
    }

    private void PublishTunnel(TunnelMessage message)
    {
        _ = SendEncrypted(message, realtime: true, routedTo: message.Target);
    }

    /// Puts one forwarded TCP chunk on the wire as a binary TunnelFrame - no base64, no JSON and
    /// no UTF-8 round trip, unlike the envelope path every other message takes.
    private async Task PublishTunnelDataAsync(string connectionId, string target, byte[] payload)
    {
        byte[] frame;
        try
        {
            frame = TunnelFrame.Encode(connectionId, config.DeviceId, target, payload, config.Password, config.EncryptTransport);
        }
        catch
        {
            OnUi(() =>
            {
                status = AppText.Text("status.encryptionFailed");
                UpdateMenu();
            });
            return;
        }

        if (frame.Length > ClipboardLimits.MaxWebSocketMessageBytes)
        {
            OnUi(() =>
            {
                status = AppText.Text("status.clipboardPayloadTooLarge");
                UpdateMenu();
            });
            return;
        }

        var active = transport;
        if (active is not null)
        {
            // Awaited, not fire-and-forget: completing only once the frame reaches the transport
            // is what paces the tunnel's reader.
            await active.SendBinaryAsync(frame, target).ConfigureAwait(false);
        }
    }

    /// A binary frame is always a port-forward "data" chunk. Awaited by the transport's receive
    /// loop, so blocking on a full tunnel queue back-pressures the connection.
    private async Task HandleBinaryFrameAsync(byte[] frame)
    {
        // A binary frame is either a port-forward "data" chunk (TunnelFrame) or a large
        // clipboard/file payload (BulkFrame); the first wire byte says which.
        if (BulkFrame.IsBulkFrame(frame))
        {
            HandleBulkFrame(frame);
            return;
        }

        TunnelFrame.Decoded decoded;
        try
        {
            decoded = TunnelFrame.Decode(frame, config.Password);
        }
        catch
        {
            // Wrong password, tampering, or a malformed frame: drop it silently, exactly as the
            // envelope path does for a payload it cannot authenticate.
            return;
        }

        if (decoded.Origin == config.DeviceId || decoded.Target != config.DeviceId)
        {
            return;
        }
        await portForwardCoordinator.HandleDataAsync(decoded.ConnectionId, decoded.Payload).ConfigureAwait(false);
    }

    private void HandleBulkFrame(byte[] frame)
    {
        BulkFrame.Decoded decoded;
        try
        {
            decoded = BulkFrame.Decode(frame, config.Password);
        }
        catch
        {
            return;
        }
        // A clipboard image is a broadcast (empty target); a file chunk is addressed to us.
        if (decoded.Origin == config.DeviceId
            || (decoded.Target.Length != 0 && decoded.Target != config.DeviceId))
        {
            return;
        }

        switch (decoded.Kind)
        {
            case BulkFrame.Kind.ClipboardImage:
            {
                if (decoded.Target.Length != 0)
                {
                    return;
                }
                SyncMessage? meta;
                try
                {
                    meta = JsonSerializer.Deserialize<SyncMessage>(decoded.Meta, MessageJsonOptions);
                }
                catch
                {
                    return;
                }
                if (meta?.Image is not { } metaImage)
                {
                    return;
                }
                // Rebuild the payload the existing clipboard path expects: the metadata's image
                // with its emptied DataBase64 refilled from the raw frame bytes.
                metaImage.DataBase64 = Convert.ToBase64String(decoded.Payload);
                OnUi(() =>
                {
                    var content = ClipboardContent.FromMessage(meta);
                    if (content is not null && clipboardMonitor.ApplyContent(content))
                    {
                        AddHistory(content);
                    }
                });
                break;
            }
            case BulkFrame.Kind.FileChunk:
            {
                FileTransferMessage? meta;
                try
                {
                    meta = JsonSerializer.Deserialize<FileTransferMessage>(decoded.Meta, MessageJsonOptions);
                }
                catch
                {
                    return;
                }
                if (meta is not null)
                {
                    fileTransferCoordinator.HandleChunk(meta, decoded.Payload);
                }
                break;
            }
        }
    }

    private void HandleTunnelMessage(byte[] plaintext)
    {
        TunnelMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<TunnelMessage>(plaintext, MessageJsonOptions);
        }
        catch
        {
            return;
        }

        if (message?.Type != "tunnel" || message.Origin == config.DeviceId || message.Target != config.DeviceId)
        {
            return;
        }
        portForwardCoordinator.Handle(message);
    }

    private void HandleFileMessage(byte[] plaintext)
    {
        FileTransferMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<FileTransferMessage>(plaintext, MessageJsonOptions);
        }
        catch
        {
            return;
        }

        if (message?.Type != "file" || message.Origin == config.DeviceId || message.Target != config.DeviceId)
        {
            return;
        }
        fileTransferCoordinator.Handle(message);
    }

    /// Lets every peer know whether this device is (or isn't) watching the shared layout, so peers
    /// with their own window closed still start reporting their live cursor position - otherwise
    /// only whichever device already has its window open would ever show up moving.
    private void BroadcastLayoutWatch(bool enabled)
    {
        if (transport is null || peerCount == 0)
        {
            return;
        }
        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Kind = "layoutWatch",
            Enabled = enabled,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void HandleLayoutWatchMessage(InputMessage message)
    {
        if (message.Enabled == true)
        {
            layoutWatchers.Add(message.Origin);
        }
        else
        {
            layoutWatchers.Remove(message.Origin);
        }
        UpdateCursorReporting();
    }

    /// Starts or stops the periodic local-cursor report: active whenever this device's own layout
    /// window is open, or at least one peer has told us (via `layoutWatch`) that theirs is.
    private void UpdateCursorReporting()
    {
        var shouldReport = isLocalLayoutWindowOpen || layoutWatchers.Count > 0;
        if (!shouldReport)
        {
            cursorReportTimer?.Stop();
            cursorReportTimer?.Dispose();
            cursorReportTimer = null;
            return;
        }

        if (cursorReportTimer is not null)
        {
            return;
        }
        cursorReportTimer = new System.Windows.Forms.Timer { Interval = CursorReportIntervalMs };
        cursorReportTimer.Tick += (_, _) => ReportLocalCursor();
        cursorReportTimer.Start();
        ReportLocalCursor();
    }

    private void ReportLocalCursor()
    {
        var report = InputSharingCoordinator.CurrentLocalCursorReport(config.DeviceId, screenLayoutStore.Snapshot());
        if (isLocalLayoutWindowOpen && screenLayoutForm is { IsDisposed: false } form)
        {
            form.SetLocalCursor(report?.ScreenId, report?.NormalizedX, report?.NormalizedY);
        }
        if (report is { } value)
        {
            BroadcastCursorPosition(value.ScreenId, value.NormalizedX, value.NormalizedY);
        }
    }

    private void BroadcastCursorPosition(string screenId, double normalizedX, double normalizedY)
    {
        if (transport is null || peerCount == 0)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var movedEnough =
            lastCursorBroadcastScreenId != screenId ||
            Math.Abs(normalizedX - lastCursorBroadcastX) >= CursorBroadcastMinDelta ||
            Math.Abs(normalizedY - lastCursorBroadcastY) >= CursorBroadcastMinDelta;

        if (!movedEnough || now - lastCursorBroadcastAt < CursorBroadcastInterval)
        {
            return;
        }

        lastCursorBroadcastAt = now;
        lastCursorBroadcastScreenId = screenId;
        lastCursorBroadcastX = normalizedX;
        lastCursorBroadcastY = normalizedY;

        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Kind = "cursor",
            Cursor = new InputCursorPayload { ScreenId = screenId, NormalizedX = normalizedX, NormalizedY = normalizedY },
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void HandleCursorMessage(InputMessage message)
    {
        if (message.Cursor is not { } cursor || screenLayoutForm is not { IsDisposed: false, Visible: true } form)
        {
            return;
        }
        form.UpdateRemoteCursor(message.Origin, cursor.ScreenId, cursor.NormalizedX, cursor.NormalizedY);
    }

    private void HandleLayoutMessage(InputMessage message)
    {
        if (message.Layout is not { } layout)
        {
            return;
        }

        if (config.Mode == SyncMode.Server)
        {
            if (message.Role != "client")
            {
                return;
            }
            screenLayoutStore.ApplyPositionUpdates(layout);
            BroadcastLayout();
        }
        else
        {
            if (message.Role != "server")
            {
                return;
            }
            screenLayoutStore.ApplySnapshot(layout);
        }

        RefreshScreenLayoutFormIfVisible();
        UpdateInputCoordinator();
    }

    private void ToggleInputSharing()
    {
        config.InputSharingEnabled = !config.InputSharingEnabled;
        ConfigStore.Save(config);
        UpdateInputCoordinator(sendHello: true);
        RefreshScreenLayoutFormIfVisible();
    }

    private void SetControlDevice(string controlDeviceId)
    {
        config.ControlDeviceId = controlDeviceId;
        ConfigStore.Save(config);
        UpdateInputCoordinator();
        SyncInputConfig();
    }

    private void ShowConfiguration(bool firstRun = false)
    {
        using var form = new ConfigForm(config, firstRun);
        if (form.ShowDialog() != DialogResult.OK)
        {
            return;
        }

        var previousConfig = config.Clone();
        var nextConfig = form.Config;
        nextConfig.DeviceId = config.DeviceId;
        nextConfig.Normalize();

        var shouldRestartTransport = RequiresTransportRestart(previousConfig, nextConfig);
        var shouldSendHello = previousConfig.InputSharingEnabled != nextConfig.InputSharingEnabled;
        var shouldSyncInputConfig = previousConfig.ControlDeviceId != nextConfig.ControlDeviceId;

        config = nextConfig;
        ConfigStore.Save(config);
        if (shouldRestartTransport)
        {
            pendingInputConfigSync = true;
            RestartTransport();
            return;
        }

        UpdateInputCoordinator(sendHello: shouldSendHello);
        if (shouldSyncInputConfig)
        {
            SyncInputConfig();
        }
        if (shouldSendHello)
        {
            RefreshScreenLayoutFormIfVisible();
        }
    }

    private bool RequiresTransportRestart(AppConfig previous, AppConfig next)
    {
        if (transport is null && CanStartTransport(next))
        {
            return true;
        }
        if (CanStartTransport(previous) != CanStartTransport(next))
        {
            return true;
        }
        if (previous.Mode != next.Mode || previous.Port != next.Port)
        {
            return true;
        }
        if ((previous.Mode == SyncMode.Client || next.Mode == SyncMode.Client) &&
            previous.Host != next.Host)
        {
            return true;
        }
        return false;
    }

    private static bool CanStartTransport(AppConfig item)
    {
        // The password is always required: it authenticates every message even
        // when transport encryption is turned off.
        if (string.IsNullOrEmpty(item.Password))
        {
            return false;
        }
        if (item.Mode == SyncMode.Client)
        {
            return !string.IsNullOrWhiteSpace(item.Host) && !NetworkAddress.IsLoopbackHost(item.Host);
        }
        return true;
    }

    private void RestartTransport()
    {
        isSyncPaused = false;
        transport?.Dispose();
        peerCount = 0;
        fileTransferCoordinator.CancelAll();
        layoutWatchers.Clear();
        UpdateCursorReporting();
        UpdateInputCoordinator();

        if (string.IsNullOrEmpty(config.Password))
        {
            transport = null;
            status = AppText.Text("status.setSyncPassword");
            UpdateMenu();
            return;
        }

        if (config.Mode == SyncMode.Client && string.IsNullOrWhiteSpace(config.Host))
        {
            transport = null;
            status = AppText.Text("status.setServerLanIp");
            UpdateMenu();
            return;
        }

        if (config.Mode == SyncMode.Client && NetworkAddress.IsLoopbackHost(config.Host))
        {
            transport = null;
            status = AppText.Text("status.useLanIp");
            UpdateMenu();
            return;
        }

        transport = config.Mode == SyncMode.Server
            ? new ServerTransport(config.Port) { LocalDeviceId = config.DeviceId }
            : (ISyncTransport)new ClientTransport(config.Host, config.Port);

        transport.StatusChanged += text => OnUi(() =>
        {
            status = text;
            UpdateMenu();
        });
        // Each connection reads on its own task, so input frames arriving on the dedicated
        // channel are decrypted in parallel with (never behind) bulk clipboard/file frames.
        transport.MessageReceived += (payload, _) => HandleMessage(payload);
        transport.BinaryReceived += HandleBinaryFrameAsync;
        transport.PeerCountChanged += count => OnUi(() =>
        {
            var previousCount = peerCount;
            peerCount = count;
            UpdateInputCoordinator(sendHello: true);
            if (config.Mode == SyncMode.Server || pendingInputConfigSync)
            {
                SendInputConfig();
                pendingInputConfigSync = false;
            }
            if (isLocalLayoutWindowOpen)
            {
                BroadcastLayoutWatch(enabled: true);
            }
            // The server's rule table is canonical; push it whenever peers change so a newly
            // connected device starts (or an offline editor catches up) with the shared rules.
            if (config.Mode == SyncMode.Server && count > 0)
            {
                SendForwards();
            }
            // Re-announce our own listen state so a newly connected peer's status lights are
            // accurate without waiting for the next local change.
            if (count > 0)
            {
                SendForwardStatuses();
            }
            if (count == 0 && previousCount > 0)
            {
                ClearAllKnownPeers();
            }
        });
        transport.Start();
        UpdateMenu();
    }

    private void StopTransport()
    {
        transport?.Dispose();
        transport = null;
        peerCount = 0;
        fileTransferCoordinator.CancelAll();
        layoutWatchers.Clear();
        UpdateCursorReporting();
        UpdateInputCoordinator();
        status = AppText.Text(isSyncPaused ? "status.syncPaused" : "status.stopped");
        UpdateMenu();
    }

    private void ToggleTransport()
    {
        if (transport is null)
        {
            isSyncPaused = false;
            RestartTransport();
        }
        else
        {
            isSyncPaused = true;
            StopTransport();
        }
    }

    private const string RunRegistryKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunRegistryValueName = "ClipboardSync";

    /// An existing launch-at-login entry keeps working across updates only while the executable
    /// path is stable; the rename from ClipboardSyncWin.exe to ClipboardSync.exe broke that once,
    /// so rewrite a stale entry to wherever this process actually runs from.
    private static void RepairLaunchAtLoginPath()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunRegistryKeyPath, writable: true);
            if (key?.GetValue(RunRegistryValueName) is string current)
            {
                var expected = $"\"{Application.ExecutablePath}\"";
                if (!string.Equals(current, expected, StringComparison.OrdinalIgnoreCase))
                {
                    key.SetValue(RunRegistryValueName, expected);
                }
            }
        }
        catch
        {
            // Best effort; the menu toggle can still rewrite the entry.
        }
    }

    private static bool IsLaunchAtLoginEnabled()
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunRegistryKeyPath);
        return key?.GetValue(RunRegistryValueName) is not null;
    }

    private void ToggleLaunchAtLogin()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunRegistryKeyPath);
            if (key.GetValue(RunRegistryValueName) is null)
            {
                key.SetValue(RunRegistryValueName, $"\"{Application.ExecutablePath}\"");
            }
            else
            {
                key.DeleteValue(RunRegistryValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception ex)
        {
            status = ex.Message;
        }
        UpdateMenu();
    }

    private void SendFilesToDevice(string targetId, string targetName)
    {
        var paths = clipboardMonitor.ReadFilePathsForManualSend();
        if (paths is null)
        {
            status = AppText.Text("status.copyFilesFirst");
            UpdateMenu();
            return;
        }

        if (isSyncPaused)
        {
            status = AppText.Text("status.syncPaused");
            UpdateMenu();
            return;
        }

        if (transport is null)
        {
            RestartTransport();
        }

        if (transport is null)
        {
            return;
        }

        fileTransferCoordinator.SendFiles(paths, targetId, targetName);
    }

    private bool Publish(ClipboardContent content, bool recordHistory = true)
    {
        // An image is the one large clipboard payload, so it ships as a binary BulkFrame with the
        // pixels as raw bytes instead of base64 inside JSON. Text and the small inline-files path
        // stay on the JSON envelope, where their size makes the binary framing pointless.
        if (content.Kind == "image" && content.Image is { } image)
        {
            byte[] pixels;
            try
            {
                pixels = Convert.FromBase64String(image.DataBase64);
            }
            catch
            {
                return false;
            }
            PublishClipboardImage(image, pixels);
        }
        else if (!SendEncrypted(content.ToMessage(config.DeviceId)))
        {
            return false;
        }

        if (recordHistory)
        {
            AddHistory(content);
        }

        return true;
    }

    /// Ships a clipboard image as a broadcast BulkFrame: the pixels ride as the binary payload and
    /// the metadata JSON carries an empty DataBase64, so the wire copy is the raw image rather than
    /// a ~1.33x base64 blob wrapped in two JSON layers.
    private void PublishClipboardImage(ClipboardImagePayload image, byte[] pixels)
    {
        var meta = new SyncMessage
        {
            Type = "clipboard",
            Origin = config.DeviceId,
            Kind = "image",
            Image = new ClipboardImagePayload
            {
                MimeType = image.MimeType,
                FileName = image.FileName,
                DataBase64 = "",
                Size = image.Size
            },
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        };
        PublishBulk(BulkFrame.Kind.ClipboardImage, meta, target: null, pixels);
    }

    /// Ships a file-transfer chunk as a targeted BulkFrame: metadata JSON with a null DataBase64,
    /// the chunk bytes as the binary payload.
    private void PublishFileChunk(FileTransferMessage message, byte[] data)
    {
        PublishBulk(BulkFrame.Kind.FileChunk, message, message.Target, data);
    }

    private void PublishBulk<T>(BulkFrame.Kind kind, T meta, string? target, byte[] payload)
    {
        byte[] frame;
        try
        {
            var metaBytes = JsonSerializer.SerializeToUtf8Bytes(meta, MessageJsonOptions);
            frame = BulkFrame.Encode(kind, metaBytes, config.DeviceId, target, payload, config.Password, config.EncryptTransport);
        }
        catch
        {
            OnUi(() =>
            {
                status = AppText.Text("status.encryptionFailed");
                UpdateMenu();
            });
            return;
        }

        if (frame.Length > ClipboardLimits.MaxWebSocketMessageBytes)
        {
            OnUi(() =>
            {
                status = AppText.Text("status.clipboardPayloadTooLarge");
                UpdateMenu();
            });
            return;
        }

        _ = transport?.SendBinaryAsync(frame, target);
    }

    private void PublishInput(InputMessage message)
    {
        _ = SendEncrypted(message, realtime: true, routedTo: message.Target, viaInputChannel: true);
    }

    private bool SendEncrypted<T>(T message, bool realtime = false, string? routedTo = null, bool viaInputChannel = false)
    {
        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(message, MessageJsonOptions);
        byte[] envelopeBytes;
        try
        {
            // The password always authenticates the message; the setting only
            // chooses between AES-GCM encryption and the cheaper HMAC-signed
            // plaintext envelope for trusted networks.
            if (!config.EncryptTransport)
            {
                var envelope = CryptoBox.Sign(payloadBytes, config.Password);
                envelope.From = config.DeviceId;
                envelope.To = routedTo;
                envelopeBytes = JsonSerializer.SerializeToUtf8Bytes(envelope, MessageJsonOptions);
            }
            else
            {
                var envelope = realtime
                    ? CryptoBox.EncryptRealtime(payloadBytes, config.Password)
                    : CryptoBox.Encrypt(payloadBytes, config.Password);
                envelope.From = config.DeviceId;
                envelope.To = routedTo;
                envelopeBytes = JsonSerializer.SerializeToUtf8Bytes(envelope, MessageJsonOptions);
            }
        }
        catch
        {
            OnUi(() =>
            {
                status = AppText.Text("status.encryptionFailed");
                UpdateMenu();
            });
            return false;
        }

        if (envelopeBytes.Length > ClipboardLimits.MaxWebSocketMessageBytes)
        {
            OnUi(() =>
            {
                status = AppText.Text(realtime ? "status.inputPayloadTooLarge" : "status.clipboardPayloadTooLarge");
                UpdateMenu();
            });
            return false;
        }

        var payload = System.Text.Encoding.UTF8.GetString(envelopeBytes);
        _ = transport?.SendAsync(payload, routedTo, viaInputChannel);
        return true;
    }

    private void HandleMessage(string payload)
    {
        try
        {
            byte[] plaintext;
            MessageHeader? header;
            var envelope = JsonSerializer.Deserialize<EncryptedEnvelope>(payload, MessageJsonOptions);
            if (envelope is null)
            {
                return;
            }
            // Both envelope kinds prove knowledge of the sync password, so
            // either is accepted regardless of this device's own transport
            // setting; anything else is unauthenticated and dropped.
            if (envelope.Type == "encrypted")
            {
                plaintext = CryptoBox.Decrypt(envelope, config.Password);
            }
            else if (envelope.Type == "signed")
            {
                var signedEnvelope = JsonSerializer.Deserialize<SignedEnvelope>(payload, MessageJsonOptions);
                if (signedEnvelope is null)
                {
                    return;
                }
                plaintext = CryptoBox.Verify(signedEnvelope, config.Password);
            }
            else
            {
                return;
            }
            header = JsonSerializer.Deserialize<MessageHeader>(plaintext, MessageJsonOptions);

            switch (header?.Type)
            {
                case "clipboard":
                    OnUi(() => HandleClipboardMessage(plaintext));
                    break;
                case "input":
                    if (header.Kind == "cursor" && screenLayoutForm is not { IsDisposed: false, Visible: true })
                    {
                        return;
                    }
                    HandleInputMessage(plaintext);
                    break;
                case "tunnel":
                    HandleTunnelMessage(plaintext);
                    break;
                case "file":
                    HandleFileMessage(plaintext);
                    break;
            }
        }
        catch
        {
            return;
        }
    }

    private void HandleClipboardMessage(byte[] plaintext)
    {
        SyncMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<SyncMessage>(plaintext, MessageJsonOptions);
        }
        catch
        {
            return;
        }

        if (message?.Type != "clipboard" || message.Origin == config.DeviceId)
        {
            return;
        }

        var content = ClipboardContent.FromMessage(message);
        if (content is not null && clipboardMonitor.ApplyContent(content))
        {
            AddHistory(content);
            if (content.Kind == "files")
            {
                status = AppText.Text("status.filesReceived");
                UpdateMenu();
                notifyIcon.ShowBalloonTip(5000, AppText.Text("app.name"), AppText.Text("status.filesReceivedPasteHint"), ToolTipIcon.Info);
            }
        }
    }

    private void HandleInputMessage(byte[] plaintext)
    {
        InputMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<InputMessage>(plaintext, MessageJsonOptions);
        }
        catch
        {
            return;
        }

        if (message?.Type != "input" || message.Origin == config.DeviceId)
        {
            return;
        }

        if (IsRealtimeInputMessage(message))
        {
            HandleRealtimeInputMessage(message);
            return;
        }

        OnUi(() => HandleInputControlMessage(message));
    }

    private static bool IsRealtimeInputMessage(InputMessage message)
    {
        return message.Kind is "capture" or "mouseMove" or "mouseButton" or "mouseWheel" or "key";
    }

    private void HandleRealtimeInputMessage(InputMessage message)
    {
        lock (inputCoordinatorLock)
        {
            inputCoordinator.Handle(message);
        }
    }

    private void HandleInputControlMessage(InputMessage message)
    {
        if (message.Kind == "cursor")
        {
            if (ShouldHandleCursorMessage(message))
            {
                HandleCursorMessage(message);
            }
            return;
        }

        RememberInputDevice(message);

        if (message.Kind == "config")
        {
            HandleInputConfig(message);
            return;
        }

        if (message.Kind == "layout")
        {
            HandleLayoutMessage(message);
            return;
        }

        if (message.Kind == "layoutForget")
        {
            HandleLayoutForgetMessage(message);
            return;
        }

        if (message.Kind == "layoutWatch")
        {
            HandleLayoutWatchMessage(message);
            return;
        }

        if (message.Kind == "forwards")
        {
            HandleForwardsMessage(message);
            return;
        }

        if (message.Kind == "forwardStatus")
        {
            HandleForwardStatusMessage(message);
            return;
        }

        if (message.Kind == "hello" && config.Mode == SyncMode.Client && message.Role == "server")
        {
            if (message.ControlDeviceId is not null && config.ControlDeviceId != message.ControlDeviceId)
            {
                config.ControlDeviceId = message.ControlDeviceId;
                ConfigStore.Save(config);
                UpdateInputCoordinator();
            }
        }

        lock (inputCoordinatorLock)
        {
            inputCoordinator.Handle(message);
        }
        if (message.Kind == "hello" && config.Mode == SyncMode.Server)
        {
            SendInputHello();
        }
    }

    private bool ShouldHandleCursorMessage(InputMessage message)
    {
        if (message.Cursor is null || screenLayoutForm is not { IsDisposed: false, Visible: true })
        {
            return false;
        }

        var key = $"{message.Origin}\0{message.Cursor.ScreenId}";
        var now = DateTimeOffset.UtcNow;
        if (lastCursorMessageAt.TryGetValue(key, out var lastSeen) && now - lastSeen < CursorReceiveInterval)
        {
            return false;
        }

        lastCursorMessageAt[key] = now;
        return true;
    }

    private void HandleInputConfig(InputMessage message)
    {
        if (config.Mode == SyncMode.Server)
        {
            if (message.Role != "client")
            {
                return;
            }
            ApplyInputConfig(message);
            SendInputConfig();
            return;
        }

        if (message.Role == "server")
        {
            ApplyInputConfig(message);
        }
    }

    private bool ApplyInputConfig(InputMessage message)
    {
        if (message.ControlDeviceId is null || config.ControlDeviceId == message.ControlDeviceId)
        {
            return false;
        }
        config.ControlDeviceId = message.ControlDeviceId;
        ConfigStore.Save(config);
        UpdateInputCoordinator();
        return true;
    }

    private void UpdateInputCoordinator(bool sendHello = false)
    {
        lock (inputCoordinatorLock)
        {
            inputCoordinator.Update(config, config.Mode, peerCount, DeviceEnabledMap(), DeviceDisplayNames());
        }
        // Piggybacks on this catch-all "config/peers changed" hook so forward listeners follow
        // transport state and peer presence without a parallel set of call sites.
        UpdatePortForwardCoordinator();
        UpdateMenu();
        if (sendHello)
        {
            SendInputHello();
        }
    }

    private void SendInputHello()
    {
        if (transport is null)
        {
            return;
        }
        InputMessage hello;
        lock (inputCoordinatorLock)
        {
            hello = inputCoordinator.MakeHello(Environment.MachineName, NetworkAddress.LocalLanIPv4Address());
        }
        PublishInput(hello);
    }

    private void SendInputConfig()
    {
        if (transport is null)
        {
            return;
        }

        PublishInput(new InputMessage
        {
            Type = "input",
            Origin = config.DeviceId,
            Kind = "config",
            Role = config.Mode == SyncMode.Server ? "server" : "client",
            DeviceName = Environment.MachineName,
            DeviceAddress = NetworkAddress.LocalLanIPv4Address(),
            ControlDeviceId = EffectiveControlDeviceId,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void SyncInputConfig()
    {
        pendingInputConfigSync = true;
        SendInputConfig();
        if (transport is not null)
        {
            pendingInputConfigSync = false;
        }
    }

    private void AddHistory(ClipboardContent content)
    {
        var signature = content.Signature;
        history.RemoveAll(item => item.Content.Signature == signature);
        history.Insert(0, new ClipboardHistoryEntry { Content = content });
        if (history.Count > ClipboardLimits.HistoryLimit)
        {
            history.RemoveRange(ClipboardLimits.HistoryLimit, history.Count - ClipboardLimits.HistoryLimit);
        }
        RefreshHistoryMenu();
        PruneHistoryThumbnails();
    }

    /// Disposes thumbnails for dropped entries. Call only after RefreshHistoryMenu so no menu
    /// item still references a disposed image.
    private void PruneHistoryThumbnails()
    {
        var liveIds = history.Select(entry => entry.Id).ToHashSet();
        foreach (var staleId in historyThumbnails.Keys.Where(id => !liveIds.Contains(id)).ToList())
        {
            historyThumbnails[staleId].Dispose();
            historyThumbnails.Remove(staleId);
        }
    }

    private Image? HistoryThumbnail(ClipboardHistoryEntry entry)
    {
        if (entry.Content.Kind != "image" || entry.Content.Image is null)
        {
            return null;
        }
        if (historyThumbnails.TryGetValue(entry.Id, out var cached))
        {
            return cached;
        }

        try
        {
            var bytes = Convert.FromBase64String(entry.Content.Image.DataBase64);
            using var stream = new MemoryStream(bytes);
            using var source = Image.FromStream(stream);
            const int maxSide = 40;
            var scale = Math.Min(1.0, Math.Min((double)maxSide / source.Width, (double)maxSide / source.Height));
            var width = Math.Max(1, (int)Math.Round(source.Width * scale));
            var height = Math.Max(1, (int)Math.Round(source.Height * scale));
            var thumbnail = new Bitmap(width, height);
            using (var graphics = Graphics.FromImage(thumbnail))
            {
                graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(source, new Rectangle(0, 0, width, height));
            }
            historyThumbnails[entry.Id] = thumbnail;
            return thumbnail;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private void RefreshHistoryMenu()
    {
        historyItem.DropDownItems.Clear();
        if (history.Count == 0)
        {
            historyItem.DropDownItems.Add(new ToolStripMenuItem(AppText.Text("menu.noClipboardHistory")) { Enabled = false });
            return;
        }

        foreach (var entry in history)
        {
            var time = entry.CreatedAt.ToLocalTime().ToString("t");
            var item = new ToolStripMenuItem($"{entry.Content.HistoryTitle} · {time}")
            {
                Tag = entry.Id
            };
            if (HistoryThumbnail(entry) is { } thumbnail)
            {
                item.Image = thumbnail;
                item.ImageScaling = ToolStripItemImageScaling.None;
            }
            item.Click += (_, _) => UseHistoryItem(entry.Id);
            historyItem.DropDownItems.Add(item);
        }

        historyItem.DropDownItems.Add(new ToolStripSeparator());
        historyItem.DropDownItems.Add(new ToolStripMenuItem(AppText.Text("menu.clearClipboardHistory"), null, (_, _) =>
        {
            history.Clear();
            RefreshHistoryMenu();
            PruneHistoryThumbnails();
        }));
    }

    private void UseHistoryItem(Guid id)
    {
        var entry = history.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return;
        }

        if (!clipboardMonitor.ApplyContent(entry.Content))
        {
            status = AppText.Text("status.restoreHistoryFailed");
            UpdateMenu();
            return;
        }

        AddHistory(entry.Content);
        Publish(entry.Content, recordHistory: false);
    }

    private void OnUi(Action action)
    {
        void Run()
        {
            try
            {
                action();
            }
            catch
            {
                // Ignore stale or malformed network/UI callbacks.
            }
        }

        if (SynchronizationContext.Current == uiContext)
        {
            Run();
        }
        else
        {
            uiContext.Post(_ => Run(), null);
        }
    }
}
