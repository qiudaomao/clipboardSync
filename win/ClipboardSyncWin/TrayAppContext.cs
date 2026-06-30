using System;
using System.Threading;
using System.Text.Json;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class TrayAppContext : ApplicationContext
{
    private static readonly JsonSerializerOptions MessageJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly NotifyIcon notifyIcon;
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem clientModeItem;
    private readonly ToolStripMenuItem serverModeItem;
    private readonly ClipboardMonitor clipboardMonitor;
    private readonly SynchronizationContext uiContext;

    private AppConfig config;
    private ISyncTransport? transport;
    private string status = "stopped";

    public TrayAppContext()
    {
        uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        config = ConfigStore.Load();

        statusItem = new ToolStripMenuItem("Status: stopped") { Enabled = false };
        clientModeItem = new ToolStripMenuItem("Client mode", null, (_, _) => SetMode(SyncMode.Client));
        serverModeItem = new ToolStripMenuItem("Server mode", null, (_, _) => SetMode(SyncMode.Server));

        notifyIcon = new NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Text = "Clipboard Sync",
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };

        clipboardMonitor = new ClipboardMonitor();
        clipboardMonitor.LocalTextChanged += Publish;
        clipboardMonitor.Start();

        RestartTransport();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            transport?.Dispose();
            clipboardMonitor.Dispose();
            notifyIcon.Dispose();
        }

        base.Dispose(disposing);
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(clientModeItem);
        menu.Items.Add(serverModeItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Configure...", null, (_, _) => ShowConfiguration()));
        menu.Items.Add(new ToolStripMenuItem("Start", null, (_, _) => RestartTransport()));
        menu.Items.Add(new ToolStripMenuItem("Stop", null, (_, _) => StopTransport()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Exit", null, (_, _) => ExitThread()));
        return menu;
    }

    private void UpdateMenu()
    {
        statusItem.Text = $"Status: {status}";
        clientModeItem.Checked = config.Mode == SyncMode.Client;
        serverModeItem.Checked = config.Mode == SyncMode.Server;
    }

    private void SetMode(SyncMode mode)
    {
        config.Mode = mode;
        ConfigStore.Save(config);
        RestartTransport();
    }

    private void ShowConfiguration()
    {
        using var form = new ConfigForm(config);
        if (form.ShowDialog() != DialogResult.OK)
        {
            return;
        }

        var nextConfig = form.Config;
        nextConfig.DeviceId = config.DeviceId;
        config = nextConfig;
        ConfigStore.Save(config);
        RestartTransport();
    }

    private void RestartTransport()
    {
        transport?.Dispose();

        if (config.Mode == SyncMode.Client && string.IsNullOrWhiteSpace(config.Host))
        {
            transport = null;
            status = "set server LAN IP";
            UpdateMenu();
            return;
        }

        if (config.Mode == SyncMode.Client && NetworkAddress.IsLoopbackHost(config.Host))
        {
            transport = null;
            status = "use LAN IP, not 127.0.0.1";
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
        transport.MessageReceived += payload => OnUi(() => HandleMessage(payload));
        transport.Start();
        UpdateMenu();
    }

    private void StopTransport()
    {
        transport?.Dispose();
        transport = null;
        status = "stopped";
        UpdateMenu();
    }

    private void Publish(string text)
    {
        var message = new SyncMessage
        {
            Type = "clipboard",
            Origin = config.DeviceId,
            Text = text,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        };

        var payload = JsonSerializer.Serialize(message, MessageJsonOptions);
        _ = transport?.SendAsync(payload);
    }

    private void HandleMessage(string payload)
    {
        SyncMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<SyncMessage>(payload, MessageJsonOptions);
        }
        catch
        {
            return;
        }

        if (message?.Type != "clipboard" || message.Origin == config.DeviceId)
        {
            return;
        }

        clipboardMonitor.ApplyRemoteText(message.Text);
    }

    private void OnUi(Action action)
    {
        if (SynchronizationContext.Current == uiContext)
        {
            action();
        }
        else
        {
            uiContext.Post(_ => action(), null);
        }
    }
}
