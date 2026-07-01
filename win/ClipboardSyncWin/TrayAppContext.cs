using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
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
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem historyItem;
    private readonly ToolStripMenuItem inputStatusItem;
    private readonly ToolStripMenuItem inputSharingItem;
    private readonly ToolStripMenuItem controlDeviceItem;
    private readonly Dictionary<ScreenEdge, ToolStripMenuItem> peerEdgeItems = [];
    private readonly Dictionary<string, InputDeviceMenuDevice> inputDevices = [];
    private readonly ToolStripMenuItem clientModeItem;
    private readonly ToolStripMenuItem serverModeItem;
    private readonly ClipboardMonitor clipboardMonitor;
    private readonly InputSharingCoordinator inputCoordinator;
    private readonly object inputCoordinatorLock = new();
    private readonly SynchronizationContext uiContext;
    private readonly Icon trayIcon;
    private readonly List<ClipboardHistoryEntry> history = [];

    private AppConfig config;
    private ISyncTransport? transport;
    private int peerCount;
    private bool pendingInputConfigSync;
    private string status = AppText.Text("status.stopped");

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
        trayIcon = LoadTrayIcon();
        inputCoordinator = new InputSharingCoordinator(config.DeviceId);

        notifyIcon = new NotifyIcon
        {
            Icon = trayIcon,
            Text = AppText.Text("app.name"),
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };

        clipboardMonitor = new ClipboardMonitor();
        clipboardMonitor.LocalContentChanged += content => Publish(content);
        clipboardMonitor.LocalSkipped += reason => OnUi(() =>
        {
            status = reason;
            UpdateMenu();
        });
        inputCoordinator.MessageReady += message => OnUi(() => PublishInput(message));
        inputCoordinator.StatusChanged += text => OnUi(() => inputStatusItem.Text = text);
        clipboardMonitor.Start();
        inputCoordinator.Start();
        UpdateInputCoordinator();

        RestartTransport();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            transport?.Dispose();
            inputCoordinator.Dispose();
            clipboardMonitor.Dispose();
            notifyIcon.Dispose();
            trayIcon.Dispose();
        }

        base.Dispose(disposing);
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
        menu.Items.Add(BuildPeerEdgeMenu());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(clientModeItem);
        menu.Items.Add(serverModeItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.configure"), null, (_, _) => ShowConfiguration()));
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.start"), null, (_, _) => RestartTransport()));
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.restart"), null, (_, _) => RestartTransport()));
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.stop"), null, (_, _) => StopTransport()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppText.Text("menu.exit"), null, (_, _) => ExitThread()));
        return menu;
    }

    private ToolStripMenuItem BuildPeerEdgeMenu()
    {
        var menu = new ToolStripMenuItem(AppText.Text("menu.peerPosition"));
        AddPeerEdgeItem(menu, ScreenEdge.Right);
        AddPeerEdgeItem(menu, ScreenEdge.Left);
        AddPeerEdgeItem(menu, ScreenEdge.Top);
        AddPeerEdgeItem(menu, ScreenEdge.Bottom);
        return menu;
    }

    private void AddPeerEdgeItem(ToolStripMenuItem menu, ScreenEdge edge)
    {
        var item = new ToolStripMenuItem(AppText.EdgeTitle(edge), null, (_, _) => SetPeerEdge(edge));
        peerEdgeItems[edge] = item;
        menu.DropDownItems.Add(item);
    }

    private static Icon LoadTrayIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "clipboard-sync-icon.ico");
        return File.Exists(iconPath) ? new Icon(iconPath) : SystemIcons.Application;
    }

    private void UpdateMenu()
    {
        statusItem.Text = AppText.Format("status.prefix", status);
        clientModeItem.Checked = config.Mode == SyncMode.Client;
        serverModeItem.Checked = config.Mode == SyncMode.Server;
        inputSharingItem.Checked = config.InputSharingEnabled;
        RefreshControlDeviceMenu();
        foreach (var item in peerEdgeItems)
        {
            item.Value.Checked = config.PeerEdge == item.Key;
        }
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

        inputDevices.TryGetValue(message.Origin, out var existing);
        inputDevices[message.Origin] = new InputDeviceMenuDevice
        {
            Id = message.Origin,
            Name = message.DeviceName ?? existing?.Name,
            Address = message.DeviceAddress ?? existing?.Address,
            Role = message.Role ?? existing?.Role,
            InputEnabled = message.Enabled ?? existing?.InputEnabled,
            LastSeen = DateTimeOffset.UtcNow
        };
        UpdateMenu();
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
    }

    private void SetControlDevice(string controlDeviceId)
    {
        config.ControlDeviceId = controlDeviceId;
        ConfigStore.Save(config);
        UpdateInputCoordinator();
        SyncInputConfig();
    }

    private void SetPeerEdge(ScreenEdge edge)
    {
        config.PeerEdge = edge;
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
        var shouldSyncInputConfig =
            previousConfig.ControlDeviceId != nextConfig.ControlDeviceId ||
            previousConfig.PeerEdge != nextConfig.PeerEdge;

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
            peerCount = count;
            UpdateInputCoordinator(sendHello: true);
            if (config.Mode == SyncMode.Server || pendingInputConfigSync)
            {
                SendInputConfig();
                pendingInputConfigSync = false;
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
        UpdateInputCoordinator();
        status = AppText.Text("status.stopped");
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
            status = AppText.Text("status.encryptionFailed");
            UpdateMenu();
            return false;
        }

        if (envelopeBytes.Length > ClipboardLimits.MaxWebSocketMessageBytes)
        {
            status = AppText.Text(realtime ? "status.inputPayloadTooLarge" : "status.clipboardPayloadTooLarge");
            UpdateMenu();
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
                    HandleInputMessage(plaintext);
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
        RememberInputDevice(message);

        if (message.Kind == "config")
        {
            HandleInputConfig(message);
            return;
        }

        if (message.Kind == "hello" && config.Mode == SyncMode.Client && message.Role == "server")
        {
            var changed = false;
            if (message.PeerEdge is not null)
            {
                var edge = InputSharingWire.ParseEdge(message.PeerEdge);
                if (config.PeerEdge != edge)
                {
                    config.PeerEdge = edge;
                    changed = true;
                }
            }
            if (message.ControlDeviceId is not null && config.ControlDeviceId != message.ControlDeviceId)
            {
                config.ControlDeviceId = message.ControlDeviceId;
                changed = true;
            }

            if (changed)
            {
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
        var changed = false;
        if (message.ControlDeviceId is not null && config.ControlDeviceId != message.ControlDeviceId)
        {
            config.ControlDeviceId = message.ControlDeviceId;
            changed = true;
        }
        if (message.PeerEdge is not null)
        {
            var edge = InputSharingWire.ParseEdge(message.PeerEdge);
            if (config.PeerEdge != edge)
            {
                config.PeerEdge = edge;
                changed = true;
            }
        }
        if (changed)
        {
            ConfigStore.Save(config);
            UpdateInputCoordinator();
        }
        return changed;
    }

    private void UpdateInputCoordinator(bool sendHello = false)
    {
        lock (inputCoordinatorLock)
        {
            inputCoordinator.Update(config, config.Mode, peerCount);
        }
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
            PeerEdge = InputSharingWire.EdgeValue(config.PeerEdge),
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
