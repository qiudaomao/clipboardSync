using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClipboardSyncWin;

/// <summary>
/// The weekly sleep-prevention schedule editor: 7 day rows x 24 hour columns. Edits commit on
/// gesture end, matching the screen-layout window's "saved as applied" behaviour.
/// </summary>
internal sealed class TimePlanForm : Form
{
    private readonly TimePlanGrid grid = new();
    private readonly Button doneButton;
    private readonly Label savedLabel;
    private readonly Label summaryLabel;

    public event Action<SleepTimePlan>? PlanChanged;

    public TimePlanForm()
    {
        Text = AppText.Text("timeplan.title");
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = true;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(940, 460);
        MinimumSize = new Size(780, 420);

        var titleLabel = new Label
        {
            Text = AppText.Text("timeplan.title"),
            AutoSize = true,
            Font = new Font(Font.FontFamily, 13f, FontStyle.Bold)
        };
        var subtitleLabel = new Label
        {
            Text = AppText.Text("timeplan.subtitle"),
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            MaximumSize = new Size(880, 0),
            Margin = new Padding(0, 4, 0, 10)
        };

        var headerPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.TopDown,
            AutoSize = true,
            WrapContents = false
        };
        headerPanel.Controls.Add(titleLabel);
        headerPanel.Controls.Add(subtitleLabel);

        summaryLabel = new Label
        {
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(16, 6, 0, 0)
        };
        savedLabel = new Label
        {
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 10, 12, 0)
        };

        grid.Dock = DockStyle.Fill;
        grid.BorderStyle = BorderStyle.FixedSingle;
        grid.PlanChanged += plan =>
        {
            savedLabel.Text = AppText.Text("timeplan.saved");
            UpdateSummary();
            PlanChanged?.Invoke(plan);
        };

        var legendPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.LeftToRight,
            Height = 28,
            AutoSize = false,
            WrapContents = false
        };
        legendPanel.Controls.Add(new TimePlanLegend(TimePlanGrid.PreventColor, AppText.Text("timeplan.legendPrevent")));
        legendPanel.Controls.Add(new TimePlanLegend(TimePlanGrid.AllowColor, AppText.Text("timeplan.legendAllow")));
        legendPanel.Controls.Add(summaryLabel);

        doneButton = new Button { Text = AppText.Text("timeplan.done"), AutoSize = true };
        doneButton.Click += (_, _) => Close();

        var clearButton = new Button { Text = AppText.Text("timeplan.clearAll"), AutoSize = true };
        clearButton.Click += (_, _) => grid.FillAll(prevented: false);

        var selectAllButton = new Button { Text = AppText.Text("timeplan.selectAll"), AutoSize = true };
        selectAllButton.Click += (_, _) => grid.FillAll(prevented: true);

        var workHoursButton = new Button { Text = AppText.Text("timeplan.workHours"), AutoSize = true };
        workHoursButton.Click += (_, _) => grid.ApplyWorkHours();

        // RightToLeft flow, so controls are added in the order they should appear from the right.
        var buttonPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 52,
            Padding = new Padding(0, 8, 0, 0)
        };
        buttonPanel.Controls.Add(doneButton);
        buttonPanel.Controls.Add(savedLabel);
        buttonPanel.Controls.Add(workHoursButton);
        buttonPanel.Controls.Add(selectAllButton);
        buttonPanel.Controls.Add(clearButton);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 4
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        root.Controls.Add(headerPanel, 0, 0);
        root.Controls.Add(grid, 0, 1);
        root.Controls.Add(legendPanel, 0, 2);
        root.Controls.Add(buttonPanel, 0, 3);

        Controls.Add(root);
        AcceptButton = doneButton;
    }

    public void UpdatePlan(SleepTimePlan plan)
    {
        grid.Plan = plan.Clone();
        savedLabel.Text = "";
        UpdateSummary();
    }

    private void UpdateSummary()
    {
        summaryLabel.Text = AppText.Format("timeplan.selectedHours", grid.Plan.PreventedHourCount);
    }
}

/// <summary>A small swatch plus caption, used for the prevent/allow legend under the grid.</summary>
internal sealed class TimePlanLegend : Panel
{
    private readonly Color swatchColor;
    private readonly string caption;

    public TimePlanLegend(Color swatchColor, string caption)
    {
        this.swatchColor = swatchColor;
        this.caption = caption;
        AutoSize = false;
        Height = 22;
        Width = 150;
        Margin = new Padding(0, 4, 8, 0);
        DoubleBuffered = true;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var brush = new SolidBrush(swatchColor);
        e.Graphics.FillRectangle(brush, new Rectangle(0, 5, 12, 12));
        using var textBrush = new SolidBrush(SystemColors.GrayText);
        e.Graphics.DrawString(caption, Font, textBrush, 18, 3);
    }
}

/// <summary>
/// Draws the 7x24 block grid and turns clicks and rectangular drags into plan edits. A drag paints
/// every block in the rectangle between the press and the current cell to the value opposite of the
/// pressed block, so one gesture can clear or fill a span without hunting individual hours.
/// </summary>
internal sealed class TimePlanGrid : Panel
{
    public static readonly Color PreventColor = Color.FromArgb(0x2D, 0x7D, 0xD2);
    public static readonly Color AllowColor = Color.FromArgb(0xE3, 0xE3, 0xE6);

    private const int DayLabelWidth = 52;
    private const int HourLabelHeight = 20;

    public event Action<SleepTimePlan>? PlanChanged;

    private SleepTimePlan plan = new();
    private (int Day, int Hour)? anchorCell;
    private (int Day, int Hour)? currentCell;
    private bool paintValue;

    public TimePlanGrid()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = SystemColors.Window;
    }

    public SleepTimePlan Plan
    {
        get => plan;
        set
        {
            plan = value;
            if (anchorCell is null)
            {
                Invalidate();
            }
        }
    }

    /// <summary>Replaces every block. Used by Clear All / Select All, which commit like a drag.</summary>
    public void FillAll(bool prevented)
    {
        var next = new SleepTimePlan();
        for (var day = 0; day < SleepTimePlan.DayCount; day++)
        {
            for (var hour = 0; hour < SleepTimePlan.HourCount; hour++)
            {
                next.SetPrevented(prevented, day, hour);
            }
        }
        Commit(next);
    }

    /// <summary>
    /// Monday through Friday, 09:00 up to 18:00 - the schedule most users describe when they ask
    /// for "keep it awake while I work".
    /// </summary>
    public void ApplyWorkHours()
    {
        var next = new SleepTimePlan();
        for (var day = 0; day < 5; day++)
        {
            for (var hour = 9; hour < 18; hour++)
            {
                next.SetPrevented(true, day, hour);
            }
        }
        Commit(next);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        var cellWidth = CellWidth;
        var cellHeight = CellHeight;
        var preview = PlanWithPreview();

        using var hourFont = new Font(Font.FontFamily, 7.5f);
        using var dayFont = new Font(Font.FontFamily, 8.5f);
        using var labelBrush = new SolidBrush(SystemColors.GrayText);
        using var dayBrush = new SolidBrush(SystemColors.ControlText);
        using var centered = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        using var rightAligned = new StringFormat { Alignment = StringAlignment.Far, LineAlignment = StringAlignment.Center };
        using var preventBrush = new SolidBrush(PreventColor);
        using var allowBrush = new SolidBrush(AllowColor);

        // Hour ruler. Every third hour is labelled so the header stays legible when the window is
        // narrow; the grid itself always has all 24 columns.
        for (var hour = 0; hour < SleepTimePlan.HourCount; hour += 3)
        {
            var labelRect = new RectangleF(
                DayLabelWidth + (hour - 1) * cellWidth,
                0,
                cellWidth * 3,
                HourLabelHeight);
            g.DrawString(hour.ToString("00"), hourFont, labelBrush, labelRect, centered);
        }

        for (var day = 0; day < SleepTimePlan.DayCount; day++)
        {
            var rowTop = HourLabelHeight + day * cellHeight;
            g.DrawString(
                AppText.Text($"timeplan.day.{day}"),
                dayFont,
                dayBrush,
                new RectangleF(0, rowTop, DayLabelWidth - 8, cellHeight),
                rightAligned);

            for (var hour = 0; hour < SleepTimePlan.HourCount; hour++)
            {
                var rect = new RectangleF(
                    DayLabelWidth + hour * cellWidth + 1,
                    rowTop + 1,
                    Math.Max(1, cellWidth - 2),
                    Math.Max(1, cellHeight - 2));
                g.FillRectangle(preview.IsPrevented(day, hour) ? preventBrush : allowBrush, rect);
            }
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left)
        {
            return;
        }
        if (CellAt(e.Location) is not (int day, int hour) cell)
        {
            anchorCell = null;
            currentCell = null;
            return;
        }

        anchorCell = cell;
        currentCell = cell;
        // Painting the inverse of the pressed block makes a single click a toggle and a drag a
        // uniform fill or clear, rather than a per-block flip that depends on each block's state.
        paintValue = !plan.IsPrevented(day, hour);
        Capture = true;
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (anchorCell is null)
        {
            return;
        }
        var next = ClampedCellAt(e.Location);
        if (next == currentCell)
        {
            return;
        }
        currentCell = next;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        // Only the button that started the gesture ends it, so a stray right-click mid-drag does
        // not commit a partial rectangle.
        if (e.Button != MouseButtons.Left || anchorCell is null)
        {
            return;
        }
        var next = PlanWithPreview();
        anchorCell = null;
        currentCell = null;
        Capture = false;
        Commit(next);
    }

    private void Commit(SleepTimePlan next)
    {
        if (plan.Matches(next))
        {
            Invalidate();
            return;
        }
        plan = next;
        Invalidate();
        PlanChanged?.Invoke(plan.Clone());
    }

    /// <summary>
    /// The plan as it should currently be drawn: the committed plan, plus the in-flight rectangle
    /// while a drag is active.
    /// </summary>
    private SleepTimePlan PlanWithPreview()
    {
        if (anchorCell is not (int anchorDay, int anchorHour) || currentCell is not (int liveDay, int liveHour))
        {
            return plan;
        }

        var preview = plan.Clone();
        for (var day = Math.Min(anchorDay, liveDay); day <= Math.Max(anchorDay, liveDay); day++)
        {
            for (var hour = Math.Min(anchorHour, liveHour); hour <= Math.Max(anchorHour, liveHour); hour++)
            {
                preview.SetPrevented(paintValue, day, hour);
            }
        }
        return preview;
    }

    private float CellWidth => Math.Max(1f, (ClientSize.Width - DayLabelWidth) / (float)SleepTimePlan.HourCount);

    private float CellHeight => Math.Max(1f, (ClientSize.Height - HourLabelHeight) / (float)SleepTimePlan.DayCount);

    private (int Day, int Hour)? CellAt(Point point)
    {
        if (point.X < DayLabelWidth || point.Y < HourLabelHeight)
        {
            return null;
        }
        var hour = (int)((point.X - DayLabelWidth) / CellWidth);
        var day = (int)((point.Y - HourLabelHeight) / CellHeight);
        if (hour < 0 || hour >= SleepTimePlan.HourCount || day < 0 || day >= SleepTimePlan.DayCount)
        {
            return null;
        }
        return (day, hour);
    }

    /// <summary>Used while dragging so the rectangle keeps tracking when the pointer leaves the grid.</summary>
    private (int Day, int Hour) ClampedCellAt(Point point)
    {
        var hour = (int)Math.Floor((point.X - DayLabelWidth) / CellWidth);
        var day = (int)Math.Floor((point.Y - HourLabelHeight) / CellHeight);
        return (
            Math.Clamp(day, 0, SleepTimePlan.DayCount - 1),
            Math.Clamp(hour, 0, SleepTimePlan.HourCount - 1));
    }
}
