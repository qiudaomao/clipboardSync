using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace ClipboardSyncWin;

/// The "Port Forward" dialog: a table of forward rules, each mapping In (a device + listen port) to
/// Out (another device + host + port), with an optional note. Each row shows a live status light
/// (green listening / red failed with the reason on hover / gray disabled or offline) and an
/// enable/disable toggle. Structural edits are drafts committed on Save; the enable toggle applies
/// immediately (via RulesApplied) so its status light updates without closing. Modeless, like
/// ScreenLayoutForm, so the tray context can push live status while it stays open.
internal sealed class PortForwardForm : Form
{
    public sealed record DeviceOption(string Id, string Title);

    public enum StatusLight
    {
        Green,
        Red,
        Gray
    }

    /// A rule's display status, computed by the tray context and handed to the dialog to render.
    public readonly record struct RuleStatus(StatusLight Light, string Tooltip);

    /// Raised when the rule table should be applied. Save also closes; the enable toggle keeps the
    /// dialog open so its status light can update in place.
    public event Action<List<PortForwardRule>>? RulesApplied;

    private List<DeviceOption> devices;
    private readonly FlowLayoutPanel rowsPanel;
    private readonly Label emptyLabel;
    private readonly List<RuleRow> rows = [];
    private Dictionary<string, RuleStatus> statuses = [];

    public PortForwardForm(List<PortForwardRule> rules, List<DeviceOption> devices)
    {
        this.devices = devices;

        Text = AppText.Text("forward.title");
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = true;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;
        // Snug to the fixed-width row content (~996px + rowsPanel padding + scrollbar) so there is
        // no dead space to the right of the note column, which is a fixed width on Windows.
        ClientSize = new Size(1044, 440);
        MinimumSize = new Size(1040, 340);

        var subtitle = new Label
        {
            Text = AppText.Text("forward.subtitle"),
            Dock = DockStyle.Top,
            AutoSize = false,
            Height = 44,
            Padding = new Padding(12, 10, 12, 0),
            ForeColor = SystemColors.GrayText
        };

        var header = BuildColumnHeader();

        rowsPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(12, 4, 12, 8)
        };

        emptyLabel = new Label
        {
            Text = AppText.Text("forward.empty"),
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(4, 8, 0, 0)
        };

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 48,
            Padding = new Padding(12, 8, 12, 8)
        };
        var okButton = new Button { Text = AppText.Text("settings.save"), AutoSize = true };
        var closeButton = new Button { Text = AppText.Text("settings.cancel"), DialogResult = DialogResult.Cancel, AutoSize = true };
        var addButton = new Button { Text = AppText.Text("forward.add"), AutoSize = true };
        okButton.Click += (_, _) => Save();
        closeButton.Click += (_, _) => Close();
        addButton.Click += (_, _) => AddRule();
        buttons.Controls.Add(okButton);
        buttons.Controls.Add(closeButton);
        var addHost = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.LeftToRight,
            Height = 40,
            Padding = new Padding(12, 0, 12, 4)
        };
        addHost.Controls.Add(addButton);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.Controls.Add(header, 0, 0);
        root.Controls.Add(rowsPanel, 0, 1);

        Controls.Add(root);
        Controls.Add(addHost);
        Controls.Add(buttons);
        Controls.Add(subtitle);

        AcceptButton = okButton;

        foreach (var rule in rules)
        {
            AddRow(rule);
        }
        UpdateEmptyState();
    }

    /// Live-refreshes the per-row status lights without disturbing in-progress edits.
    public void UpdateStatuses(Dictionary<string, RuleStatus> next)
    {
        statuses = next;
        foreach (var row in rows)
        {
            row.ApplyStatus(next.TryGetValue(row.RuleId, out var status) ? status : null);
        }
    }

    /// Rebuilds the rule rows from an updated table (e.g. a peer added or removed a rule) while the
    /// dialog stays open. Replaces the shown rows wholesale with the authoritative table, so any
    /// unsaved local edits are discarded in favor of it.
    public void SetRules(List<PortForwardRule> rules, List<DeviceOption> deviceOptions, Dictionary<string, RuleStatus> next)
    {
        devices = deviceOptions;
        statuses = next;
        foreach (var row in rows.ToList())
        {
            rowsPanel.Controls.Remove(row);
            row.Dispose();
        }
        rows.Clear();
        foreach (var rule in rules)
        {
            AddRow(rule);
        }
        UpdateEmptyState();
    }

    /// Fixed-width column captions kept in sync with RuleRow's layout, so the stacked rows read as
    /// one aligned table.
    private static Control BuildColumnHeader()
    {
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            AutoSize = true,
            Padding = new Padding(12, 2, 12, 0)
        };

        Label Caption(string key, int width) => new()
        {
            Text = AppText.Text(key),
            Width = width,
            AutoSize = false,
            Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold),
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, RuleRow.CellSpacing, 0)
        };

        panel.Controls.Add(Caption("forward.status", RuleRow.DotWidth));
        panel.Controls.Add(Caption("forward.enabled", RuleRow.ToggleWidth));
        panel.Controls.Add(Caption("forward.in", RuleRow.DeviceWidth + RuleRow.CellSpacing + RuleRow.PortWidth));
        panel.Controls.Add(Caption("forward.lan", RuleRow.LanWidth));
        panel.Controls.Add(new Label { Text = "", Width = RuleRow.ArrowWidth, AutoSize = false });
        panel.Controls.Add(Caption("forward.out", RuleRow.DeviceWidth + RuleRow.CellSpacing + RuleRow.HostWidth + RuleRow.CellSpacing + RuleRow.PortWidth));
        panel.Controls.Add(Caption("forward.note", RuleRow.NoteWidth));
        return panel;
    }

    private void AddRule()
    {
        var localId = devices.FirstOrDefault()?.Id ?? "";
        var peerId = devices.Skip(1).FirstOrDefault()?.Id ?? localId;
        AddRow(new PortForwardRule
        {
            Id = Guid.NewGuid().ToString(),
            InDeviceId = localId,
            InPort = 0,
            OutDeviceId = peerId,
            OutPort = 0,
            Note = "",
            Enabled = true
        });
        UpdateEmptyState();
    }

    private void AddRow(PortForwardRule rule)
    {
        var row = new RuleRow(rule, devices);
        row.Removed += () =>
        {
            rowsPanel.Controls.Remove(row);
            rows.Remove(row);
            row.Dispose();
            UpdateEmptyState();
        };
        // The enable/disable toggle applies immediately (so its status light updates) instead of
        // waiting for Save; a failed apply (some row invalid) rolls the toggle back.
        row.Toggled += () =>
        {
            if (!ApplyRules(close: false))
            {
                row.RevertToggle();
            }
        };
        row.ApplyStatus(statuses.TryGetValue(rule.Id, out var status) ? status : null);
        rows.Add(row);
        rowsPanel.Controls.Add(row);
    }

    private void UpdateEmptyState()
    {
        if (rows.Count == 0)
        {
            if (!rowsPanel.Controls.Contains(emptyLabel))
            {
                rowsPanel.Controls.Add(emptyLabel);
            }
        }
        else
        {
            rowsPanel.Controls.Remove(emptyLabel);
        }
    }

    private void Save()
    {
        if (ApplyRules(close: true))
        {
            Close();
        }
    }

    /// Validates every row and, if all pass, raises RulesApplied. Returns whether the rules were
    /// applied; on failure it shows the reason and leaves the dialog untouched.
    private bool ApplyRules(bool close)
    {
        var result = new List<PortForwardRule>();
        var listenKeys = new HashSet<string>();

        foreach (var row in rows)
        {
            var rule = row.CurrentRule();
            if (rule is null)
            {
                MessageBox.Show(this, AppText.Text("forward.validationPort"), Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            if (rule.InDeviceId == rule.OutDeviceId && rule.InPort == rule.OutPort)
            {
                MessageBox.Show(this, AppText.Text("forward.validationSame"), Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            if (!listenKeys.Add($"{rule.InDeviceId}#{rule.InPort}"))
            {
                MessageBox.Show(this, AppText.Text("forward.validationDuplicate"), Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            result.Add(rule);
        }

        RulesApplied?.Invoke(result);
        return true;
    }

    /// One editable rule row: [status] [enable toggle] In device combo + port + LAN -> Out device
    /// combo + host + port, note, remove.
    private sealed class RuleRow : Panel
    {
        public const int DotWidth = 16;
        public const int ToggleWidth = 46;
        public const int DeviceWidth = 190;
        public const int PortWidth = 58;
        public const int LanWidth = 54;
        public const int HostWidth = 110;
        public const int ArrowWidth = 24;
        public const int NoteWidth = 150;
        public const int CellSpacing = 6;

        public event Action? Removed;
        public event Action? Toggled;

        public string RuleId { get; }

        private readonly Label statusDot;
        private readonly CheckBox enabledToggle;
        private readonly ComboBox inDeviceBox;
        private readonly NumericUpDown inPortBox;
        private readonly CheckBox lanBox;
        private readonly ComboBox outDeviceBox;
        private readonly TextBox outHostBox;
        private readonly NumericUpDown outPortBox;
        private readonly TextBox noteBox;
        private readonly ToolTip toolTip = new();

        public RuleRow(PortForwardRule rule, List<DeviceOption> devices)
        {
            RuleId = rule.Id;
            Height = 40;
            Margin = new Padding(0, 0, 0, 6);
            AutoSize = false;
            Width = DotWidth + ToggleWidth + DeviceWidth + PortWidth + LanWidth + ArrowWidth + DeviceWidth + HostWidth + PortWidth + NoteWidth + 40 + CellSpacing * 10;

            statusDot = new Label
            {
                Text = "●",
                Width = DotWidth,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font(SystemFonts.DefaultFont.FontFamily, 11),
                ForeColor = SystemColors.ControlDark
            };
            enabledToggle = new CheckBox
            {
                Appearance = Appearance.Button,
                Checked = rule.Enabled,
                Width = ToggleWidth,
                Height = 26,
                TextAlign = ContentAlignment.MiddleCenter
            };
            UpdateToggleText();
            toolTip.SetToolTip(enabledToggle, AppText.Text("forward.enabledTooltip"));
            enabledToggle.CheckedChanged += OnToggleChanged;

            inDeviceBox = BuildDeviceBox(devices, rule.InDeviceId);
            inPortBox = BuildPortBox(rule.InPort);
            lanBox = new CheckBox
            {
                Checked = rule.InAllowLan,
                AutoSize = false,
                Width = LanWidth,
                Padding = new Padding(4, 0, 0, 0)
            };
            toolTip.SetToolTip(lanBox, AppText.Text("forward.lanTooltip"));
            outDeviceBox = BuildDeviceBox(devices, rule.OutDeviceId);
            outHostBox = new TextBox
            {
                Text = rule.OutHost,
                Width = HostWidth,
                PlaceholderText = "127.0.0.1"
            };
            toolTip.SetToolTip(outHostBox, AppText.Text("forward.hostTooltip"));
            outPortBox = BuildPortBox(rule.OutPort);
            noteBox = new TextBox
            {
                Text = rule.Note,
                Width = NoteWidth,
                PlaceholderText = AppText.Text("forward.notePlaceholder")
            };

            var arrow = new Label
            {
                Text = "→",
                Width = ArrowWidth,
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font(SystemFonts.DefaultFont.FontFamily, 12, FontStyle.Bold),
                ForeColor = SystemColors.GrayText
            };
            var removeButton = new Button
            {
                Text = "✕",
                Width = 34,
                Height = 26,
                FlatStyle = FlatStyle.Flat
            };
            removeButton.Click += (_, _) => Removed?.Invoke();

            var flow = new FlowLayoutPanel
            {
                Dock = DockStyle.Fill,
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                Padding = new Padding(0, 6, 0, 0)
            };
            foreach (var control in new Control[] { statusDot, enabledToggle, inDeviceBox, inPortBox, lanBox, arrow, outDeviceBox, outHostBox, outPortBox, noteBox, removeButton })
            {
                control.Margin = new Padding(0, 0, CellSpacing, 0);
                flow.Controls.Add(control);
            }
            Controls.Add(flow);
        }

        /// Recolors the status light and updates its hover tooltip. A null status (rule not applied
        /// yet) reads as a neutral gray.
        public void ApplyStatus(RuleStatus? status)
        {
            if (status is not { } value)
            {
                statusDot.ForeColor = SystemColors.ControlDark;
                toolTip.SetToolTip(statusDot, null);
                return;
            }
            statusDot.ForeColor = value.Light switch
            {
                StatusLight.Green => Color.FromArgb(52, 199, 89),
                StatusLight.Red => Color.FromArgb(215, 58, 73),
                _ => SystemColors.ControlDark
            };
            toolTip.SetToolTip(statusDot, value.Tooltip);
        }

        /// Flips the enable toggle back after an apply that failed validation. Suppresses the
        /// CheckedChanged re-entry so it does not re-trigger an apply.
        public void RevertToggle()
        {
            enabledToggle.CheckedChanged -= OnToggleChanged;
            enabledToggle.Checked = !enabledToggle.Checked;
            UpdateToggleText();
            enabledToggle.CheckedChanged += OnToggleChanged;
        }

        private void OnToggleChanged(object? sender, EventArgs e)
        {
            UpdateToggleText();
            Toggled?.Invoke();
        }

        private void UpdateToggleText()
        {
            enabledToggle.Text = AppText.Text(enabledToggle.Checked ? "forward.toggleOn" : "forward.toggleOff");
        }

        /// Reads the row back into a rule; null when either port is outside 1-65535.
        public PortForwardRule? CurrentRule()
        {
            var inPort = (int)inPortBox.Value;
            var outPort = (int)outPortBox.Value;
            if (inPort is < 1 or > 65_535 || outPort is < 1 or > 65_535)
            {
                return null;
            }
            var host = outHostBox.Text.Trim();
            return new PortForwardRule
            {
                Id = RuleId,
                InDeviceId = (inDeviceBox.SelectedItem as DeviceOption)?.Id ?? "",
                InPort = inPort,
                InAllowLan = lanBox.Checked,
                OutDeviceId = (outDeviceBox.SelectedItem as DeviceOption)?.Id ?? "",
                OutHost = string.IsNullOrEmpty(host) ? "127.0.0.1" : host,
                OutPort = outPort,
                Note = noteBox.Text.Trim(),
                Enabled = enabledToggle.Checked
            };
        }

        private static ComboBox BuildDeviceBox(List<DeviceOption> devices, string selectedId)
        {
            var box = new ComboBox
            {
                DropDownStyle = ComboBoxStyle.DropDownList,
                Width = DeviceWidth,
                DisplayMember = nameof(DeviceOption.Title)
            };
            foreach (var device in devices)
            {
                box.Items.Add(device);
            }
            var index = devices.FindIndex(device => device.Id == selectedId);
            if (index >= 0)
            {
                box.SelectedIndex = index;
            }
            else if (devices.Count > 0)
            {
                box.SelectedIndex = 0;
            }
            return box;
        }

        private static NumericUpDown BuildPortBox(int port)
        {
            return new NumericUpDown
            {
                Minimum = 0,
                Maximum = 65_535,
                Value = Math.Clamp(port, 0, 65_535),
                Width = PortWidth,
                TextAlign = HorizontalAlignment.Center
            };
        }
    }
}
