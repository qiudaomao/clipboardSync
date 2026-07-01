using System;
using System.Drawing;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class ConfigForm : Form
{
    private readonly ComboBox modeBox = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox hostBox = new();
    private readonly Label hostHint = new()
    {
        AutoSize = true,
        ForeColor = SystemColors.GrayText
    };
    private readonly NumericUpDown portBox = new()
    {
        Minimum = 1,
        Maximum = 65_535,
        Value = 8787
    };
    private readonly TextBox passwordBox = new() { UseSystemPasswordChar = true };
    private readonly CheckBox inputSharingBox = new() { AutoSize = true };
    private readonly ComboBox peerEdgeBox = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox reverseScrollBox = new() { AutoSize = true };
    private string clientHostDraft = "";

    public AppConfig Config { get; private set; }

    public ConfigForm(AppConfig config)
    {
        Config = config.Clone();

        Text = AppText.Text("settings.title");
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(430, 360);

        inputSharingBox.Text = AppText.Text("settings.enableInputSharing");
        reverseScrollBox.Text = AppText.Text("settings.reverseVerticalScroll");

        modeBox.Items.AddRange(new object[] { AppText.Text("settings.client"), AppText.Text("settings.server") });
        modeBox.SelectedIndex = Config.Mode == SyncMode.Client ? 0 : 1;
        clientHostDraft = NetworkAddress.IsLoopbackHost(Config.Host) ? "" : Config.Host;
        hostBox.Text = clientHostDraft;
        portBox.Value = Math.Clamp(Config.Port, 1, 65_535);
        passwordBox.Text = Config.Password;
        inputSharingBox.Checked = Config.InputSharingEnabled;
        reverseScrollBox.Checked = Config.ReverseMouseVerticalScroll;
        peerEdgeBox.Items.AddRange(new object[]
        {
            AppText.EdgeTitle(ScreenEdge.Right),
            AppText.EdgeTitle(ScreenEdge.Left),
            AppText.EdgeTitle(ScreenEdge.Top),
            AppText.EdgeTitle(ScreenEdge.Bottom)
        });
        peerEdgeBox.SelectedIndex = Config.PeerEdge switch
        {
            ScreenEdge.Left => 1,
            ScreenEdge.Top => 2,
            ScreenEdge.Bottom => 3,
            _ => 0
        };
        inputSharingBox.CheckedChanged += (_, _) => UpdateInputSharingState();
        hostBox.TextChanged += (_, _) =>
        {
            if (modeBox.SelectedIndex != 1)
            {
                clientHostDraft = hostBox.Text;
            }
        };
        modeBox.SelectedIndexChanged += (_, _) => UpdateModeState();
        portBox.ValueChanged += (_, _) => UpdateModeState();

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 2,
            RowCount = 9
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 70));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));

        AddRow(layout, 0, AppText.Text("settings.mode"), modeBox);
        AddRow(layout, 1, AppText.Text("settings.host"), BuildHostControl());
        AddRow(layout, 2, AppText.Text("settings.port"), portBox);
        AddRow(layout, 3, AppText.Text("settings.password"), passwordBox);
        AddRow(layout, 4, AppText.Text("settings.input"), inputSharingBox);
        AddRow(layout, 5, AppText.Text("settings.peer"), peerEdgeBox);
        AddRow(layout, 6, AppText.Text("settings.scroll"), reverseScrollBox);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft
        };

        var okButton = new Button { Text = AppText.Text("settings.save") };
        var cancelButton = new Button { Text = AppText.Text("settings.cancel"), DialogResult = DialogResult.Cancel };
        okButton.Click += (_, _) => Save();
        buttons.Controls.Add(okButton);
        buttons.Controls.Add(cancelButton);
        layout.Controls.Add(buttons, 0, 8);
        layout.SetColumnSpan(buttons, 2);

        AcceptButton = okButton;
        CancelButton = cancelButton;
        Controls.Add(layout);
        UpdateModeState();
        UpdateInputSharingState();
    }

    private static void AddRow(TableLayoutPanel layout, int row, string label, Control control)
    {
        var labelControl = new Label
        {
            Text = label,
            AutoSize = true,
            Anchor = AnchorStyles.Left
        };
        control.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        layout.Controls.Add(labelControl, 0, row);
        layout.Controls.Add(control, 1, row);
    }

    private Control BuildHostControl()
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Margin = Padding.Empty
        };
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
        hostBox.Dock = DockStyle.Fill;
        hostHint.Dock = DockStyle.Fill;
        panel.Controls.Add(hostBox, 0, 0);
        panel.Controls.Add(hostHint, 0, 1);
        return panel;
    }

    private void UpdateModeState()
    {
        var isClient = modeBox.SelectedIndex != 1;
        if (isClient)
        {
            hostBox.ReadOnly = false;
            hostBox.Text = clientHostDraft;
        }
        else
        {
            clientHostDraft = hostBox.ReadOnly ? clientHostDraft : hostBox.Text.Trim();
            hostBox.ReadOnly = true;
            hostBox.Text = NetworkAddress.ServerUrl((int)portBox.Value);
        }
        hostHint.Text = isClient
            ? AppText.Text("settings.hostClientHint")
            : AppText.Text("settings.hostServerHint");
    }

    private void UpdateInputSharingState()
    {
        peerEdgeBox.Enabled = inputSharingBox.Checked;
        reverseScrollBox.Enabled = inputSharingBox.Checked;
    }

    private void Save()
    {
        Config.Mode = modeBox.SelectedIndex == 1 ? SyncMode.Server : SyncMode.Client;
        var host = Config.Mode == SyncMode.Client ? hostBox.Text.Trim() : Config.Host;
        var password = passwordBox.Text;

        if (Config.Mode == SyncMode.Client && string.IsNullOrWhiteSpace(host))
        {
            MessageBox.Show(this, AppText.Text("settings.validationHost"), Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            hostBox.Focus();
            return;
        }

        if (Config.Mode == SyncMode.Client && NetworkAddress.IsLoopbackHost(host))
        {
            MessageBox.Show(this, AppText.Text("settings.validationLoopback"), Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            hostBox.Focus();
            return;
        }

        if (string.IsNullOrEmpty(password))
        {
            MessageBox.Show(this, AppText.Text("settings.validationPassword"), Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            passwordBox.Focus();
            return;
        }

        Config.Host = host;
        Config.Port = (int)portBox.Value;
        Config.Password = password;
        Config.InputSharingEnabled = inputSharingBox.Checked;
        Config.ReverseMouseVerticalScroll = reverseScrollBox.Checked;
        Config.PeerEdge = peerEdgeBox.SelectedIndex switch
        {
            1 => ScreenEdge.Left,
            2 => ScreenEdge.Top,
            3 => ScreenEdge.Bottom,
            _ => ScreenEdge.Right
        };
        Config.Normalize();
        DialogResult = DialogResult.OK;
        Close();
    }
}
