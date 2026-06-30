using System;
using System.Drawing;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class ConfigForm : Form
{
    private readonly ComboBox modeBox = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox hostBox = new();
    private readonly NumericUpDown portBox = new()
    {
        Minimum = 1,
        Maximum = 65_535,
        Value = 8787
    };

    public AppConfig Config { get; private set; }

    public ConfigForm(AppConfig config)
    {
        Config = config.Clone();

        Text = "Clipboard Sync";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(320, 150);

        modeBox.Items.AddRange(new object[] { "Client", "Server" });
        modeBox.SelectedIndex = Config.Mode == SyncMode.Client ? 0 : 1;
        hostBox.Text = Config.Host;
        portBox.Value = Math.Clamp(Config.Port, 1, 65_535);

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 2,
            RowCount = 4
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 70));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        AddRow(layout, 0, "Mode", modeBox);
        AddRow(layout, 1, "Host", hostBox);
        AddRow(layout, 2, "Port", portBox);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft
        };

        var okButton = new Button { Text = "Save", DialogResult = DialogResult.OK };
        var cancelButton = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel };
        okButton.Click += (_, _) => Save();
        buttons.Controls.Add(okButton);
        buttons.Controls.Add(cancelButton);
        layout.Controls.Add(buttons, 0, 3);
        layout.SetColumnSpan(buttons, 2);

        AcceptButton = okButton;
        CancelButton = cancelButton;
        Controls.Add(layout);
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

    private void Save()
    {
        Config.Mode = modeBox.SelectedIndex == 1 ? SyncMode.Server : SyncMode.Client;
        Config.Host = hostBox.Text.Trim();
        Config.Port = (int)portBox.Value;
        Config.Normalize();
    }
}
