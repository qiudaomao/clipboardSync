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
    private readonly ContextMenuStrip trayMenu;
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem historyItem;
    private readonly ToolStripMenuItem inputStatusItem;
    private readonly ToolStripMenuItem inputSharingItem;
    private readonly ToolStripMenuItem controlDeviceItem;
    private readonly ToolStripMenuItem checkForUpdatesItem;
    private readonly Dictionary<string, InputDeviceMenuDevice> inputDevices = [];
    private readonly ToolStripMenuItem clientModeItem;
    private readonly ToolStripMenuItem serverModeItem;
    private readonly ToolStripMenuItem startStopItem;
    private readonly ToolStripMenuItem launchAtLoginItem;
    private readonly ClipboardMonitor clipboardMonitor;
    private readonly ScreenLayoutStore screenLayoutStore = new();
    private readonly PortForwardStore portForwardStore = new();
    private readonly PortForwardCoordinator portForwardCoordinator = new();
    private readonly Dictionary<string, PortForwardStatus> localForwardStatuses = [];
    private readonly Dictionary<string, PortForwardStatus> remoteForwardStatuses = [];
    private PortForwardForm? portForwardForm;
    private readonly InputSharingCoordinator inputCoordinator;
    private readonly WinUpdateController updateController;
    private readonly object inputCoordinatorLock = new();
    private readonly SynchronizationContext uiContext;
    private readonly Icon trayIcon;
    private readonly List<ClipboardHistoryEntry> history = [];
    private ScreenLayoutForm? screenLayoutForm;

    private AppConfig config;
    private ISyncTransport? transport;
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
        config = ConfigStore.Load();

        statusItem = new ToolStripMenuItem(AppText.Format("status.prefix", status)) { Enabled = false };
        historyItem = new ToolStripMenuItem(AppText.Text("menu.clipboardHistory"));
        inputStatusItem = new ToolStripMenuItem(AppText.Text("input.off")) { Enabled = false };
        inputSharingItem = new ToolStripMenuItem(AppText.Text("menu.enableInputSharing"), null, (_, _) => ToggleInputSharing());
        controlDeviceItem = new ToolStripMenuItem(AppText.Text("menu.controlDevice"));
        clientModeItem = new ToolStripMenuItem(AppText.Text("menu.clientMode"), null, (_, _) => SetMode(SyncMode.Client));
        serverModeItem = new ToolStripMenuItem(AppText.Text("menu.serverMode"), null, (_, _) => SetMode(SyncMode.Server));
        startStopItem = new ToolStripMenuItem(AppText.Text("menu.start"), null, (_, _) => ToggleTransport());
        launchAtLoginItem = new ToolStripMenuItem(AppText.Text("menu.launchAtLogin"), null, (_, _) => ToggleLaunchAtLogin());
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
        portForwardCoordinator.StatusChanged += text => OnUi(() =>
        {
            status = text;
            UpdateMenu();
        });
        portForwardCoordinator.StatusesChanged += statuses => OnUi(() => HandleLocalForwardStatuses(statuses));

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
        }
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
            portForwardCoordinator.Dispose();
            portForwardForm?.Dispose();
            inputCoordinator.Dispose();
            clipboardMonitor.Dispose();
            notifyIcon.Dispose();
            trayMenu.Dispose();
            trayIcon.Dispose();
            screenLayoutForm?.Dispose();
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
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(historyItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.sendFiles"), null, (_, _) => SendFilesFromClipboard()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(inputStatusItem);
        menu.Items.Add(inputSharingItem);
        menu.Items.Add(controlDeviceItem);
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.screenLayout"), null, (_, _) => ShowScreenLayout()));
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.portForward"), null, (_, _) => ShowPortForward()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(clientModeItem);
        menu.Items.Add(serverModeItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.configure"), null, (_, _) => ShowConfiguration()));
        menu.Items.Add(checkForUpdatesItem);
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.about"), null, (_, _) => ShowAbout()));
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.homepage"), null, (_, _) => OpenProjectHomepage()));
        menu.Items.Add(startStopItem);
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.restart"), null, (_, _) => RestartTransport()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(launchAtLoginItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.exit"), null, (_, _) => ExitThread()));
        return menu;
    }

    private void OnNotifyIconMouseUp(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Right)
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
        statusItem.Text = AppText.Format("status.prefix", status);
        clientModeItem.Checked = config.Mode == SyncMode.Client;
        serverModeItem.Checked = config.Mode == SyncMode.Server;
        inputSharingItem.Checked = config.InputSharingEnabled;
        startStopItem.Text = AppText.Text(transport is null ? "menu.start" : "menu.stop");
        launchAtLoginItem.Checked = IsLaunchAtLoginEnabled();
        RefreshControlDeviceMenu();
        RefreshHistoryMenu();
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
        inputDevices[message.Origin] = new InputDeviceMenuDevice
        {
            Id = message.Origin,
            Name = message.DeviceName ?? existing?.Name,
            Address = message.DeviceAddress ?? existing?.Address,
            Role = message.Role ?? existing?.Role,
            InputEnabled = newInputEnabled,
            LastSeen = DateTimeOffset.UtcNow
        };

        var layoutChanged = message.Screens is { } screens && screenLayoutStore.Merge(message.Origin, screens);
        if (layoutChanged && config.Mode == SyncMode.Server)
        {
            BroadcastLayout();
        }
        if (layoutChanged || wasOffline || inputEnabledChanged)
        {
            RefreshScreenLayoutFormIfVisible();
            // The coordinator only sees peers through the enabled/name snapshots passed via
            // Update(). Without this, a peer that restarts (dropped from inputDevices, then
            // hellos back in) never re-enters those snapshots and the controller sits in
            // "waiting for peer screen" until some unrelated event refreshes the coordinator.
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
        if (transport is null || string.IsNullOrEmpty(config.Password))
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
        if (transport is null || string.IsNullOrEmpty(config.Password))
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
        if (transport is null || string.IsNullOrEmpty(config.Password))
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
                    options.Add(new PortForwardForm.DeviceOption(referencedId, $"{AppText.Text("device.unknown")} ({shortId})"));
                }
            }
        }
        return options;
    }

    private void ShowPortForward()
    {
        // Modeless (like the screen layout window) so live status can be pushed while it stays open;
        // rebuilt each open so its rows reflect the current rule table and device list.
        portForwardForm?.Dispose();
        portForwardForm = new PortForwardForm(portForwardStore.Snapshot(), PortForwardDeviceOptions());
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
        if (transport is null || string.IsNullOrEmpty(config.Password) || peerCount == 0)
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
        if (rule.InDeviceId != config.DeviceId && !online.Contains(rule.InDeviceId))
        {
            return new PortForwardForm.RuleStatus(PortForwardForm.StatusLight.Gray, AppText.Text("forward.statusOffline"));
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

    private void RefreshPortForwardFormIfVisible()
    {
        if (portForwardForm is { IsDisposed: false, Visible: true })
        {
            portForwardForm.UpdateStatuses(PortForwardDisplayStatuses());
        }
    }

    private void SendForwards()
    {
        if (transport is null || string.IsNullOrEmpty(config.Password))
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

    /// Rebuilds the dialog's rows from the current (possibly peer-updated) rule table, if it's open.
    private void RefreshPortForwardFormRowsIfVisible()
    {
        if (portForwardForm is { IsDisposed: false, Visible: true })
        {
            portForwardForm.SetRules(portForwardStore.Snapshot(), PortForwardDeviceOptions(), PortForwardDisplayStatuses());
        }
    }

    private void UpdatePortForwardCoordinator()
    {
        portForwardCoordinator.Update(
            config.DeviceId,
            portForwardStore.Snapshot(),
            transport is not null && !string.IsNullOrEmpty(config.Password),
            new HashSet<string>(inputDevices.Keys));
        // Presence and transport changes flow through here; refresh the dialog's lights so remote
        // rules flip to "offline"/back live.
        RefreshPortForwardFormIfVisible();
    }

    private void PublishTunnel(TunnelMessage message)
    {
        _ = SendEncrypted(message, realtime: true);
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

    /// Lets every peer know whether this device is (or isn't) watching the shared layout, so peers
    /// with their own window closed still start reporting their live cursor position - otherwise
    /// only whichever device already has its window open would ever show up moving.
    private void BroadcastLayoutWatch(bool enabled)
    {
        if (transport is null || string.IsNullOrEmpty(config.Password) || peerCount == 0)
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
        if (transport is null || string.IsNullOrEmpty(config.Password) || peerCount == 0)
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

    private void SetMode(SyncMode mode)
    {
        config.Mode = mode;
        ConfigStore.Save(config);
        RestartTransport();
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

    private void ShowConfiguration()
    {
        using var form = new ConfigForm(config);
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
        transport?.Dispose();
        peerCount = 0;
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
            ? new ServerTransport(config.Port)
            : new ClientTransport(config.Host, config.Port);

        transport.StatusChanged += text => OnUi(() =>
        {
            status = text;
            UpdateMenu();
        });
        transport.MessageReceived += HandleMessage;
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
        layoutWatchers.Clear();
        UpdateCursorReporting();
        UpdateInputCoordinator();
        status = AppText.Text("status.stopped");
        UpdateMenu();
    }

    private void ToggleTransport()
    {
        if (transport is null)
        {
            RestartTransport();
        }
        else
        {
            StopTransport();
        }
    }

    private const string RunRegistryKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunRegistryValueName = "ClipboardSync";

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

    private void SendFilesFromClipboard()
    {
        var content = clipboardMonitor.ReadFilesForManualSend();
        if (content is null)
        {
            status = AppText.Text("status.copyFilesFirst");
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

        if (Publish(content))
        {
            status = AppText.Text("status.fileTransferStarted");
            UpdateMenu();
        }
    }

    private bool Publish(ClipboardContent content, bool recordHistory = true)
    {
        var message = content.ToMessage(config.DeviceId);
        if (!SendEncrypted(message))
        {
            return false;
        }

        if (recordHistory)
        {
            AddHistory(content);
        }

        return true;
    }

    private void PublishInput(InputMessage message)
    {
        _ = SendEncrypted(message, realtime: true);
    }

    private bool SendEncrypted<T>(T message, bool realtime = false)
    {
        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(message, MessageJsonOptions);
        EncryptedEnvelope envelope;
        byte[] envelopeBytes;
        try
        {
            envelope = realtime
                ? CryptoBox.EncryptRealtime(payloadBytes, config.Password)
                : CryptoBox.Encrypt(payloadBytes, config.Password);
            envelopeBytes = JsonSerializer.SerializeToUtf8Bytes(envelope, MessageJsonOptions);
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
        _ = transport?.SendAsync(payload);
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
            plaintext = CryptoBox.Decrypt(envelope, config.Password);
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
                notifyIcon.ShowBalloonTip(3000, AppText.Text("app.name"), AppText.Text("status.filesReceived"), ToolTipIcon.Info);
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
        if (transport is null || string.IsNullOrEmpty(config.Password))
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
        if (transport is null || string.IsNullOrEmpty(config.Password))
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
        if (transport is not null && !string.IsNullOrEmpty(config.Password))
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
            var item = new ToolStripMenuItem(entry.Content.HistoryTitle)
            {
                Tag = entry.Id
            };
            item.Click += (_, _) => UseHistoryItem(entry.Id);
            historyItem.DropDownItems.Add(item);
        }

        historyItem.DropDownItems.Add(new ToolStripSeparator());
        historyItem.DropDownItems.Add(new ToolStripMenuItem(AppText.Text("menu.clearClipboardHistory"), null, (_, _) =>
        {
            history.Clear();
            RefreshHistoryMenu();
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
