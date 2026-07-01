using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class ScreenLayoutForm : Form
{
    private readonly ScreenLayoutCanvas canvas = new();
    private readonly Button doneButton;

    public event Action<List<ScreenLayoutEntry>>? LayoutChanged;

    public ScreenLayoutForm()
    {
        Text = AppText.Text("layout.title");
        FormBorderStyle = FormBorderStyle.Sizable;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(640, 460);
        MinimumSize = new Size(480, 360);

        var titleLabel = new Label
        {
            Text = AppText.Text("layout.title"),
            AutoSize = true,
            Font = new Font(Font.FontFamily, 13f, FontStyle.Bold)
        };
        var subtitleLabel = new Label
        {
            Text = AppText.Text("layout.subtitle"),
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            MaximumSize = new Size(580, 0),
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

        canvas.Dock = DockStyle.Fill;
        canvas.BorderStyle = BorderStyle.FixedSingle;
        canvas.LayoutChanged += entries => LayoutChanged?.Invoke(entries);

        doneButton = new Button
        {
            Text = AppText.Text("layout.done"),
            AutoSize = true
        };
        doneButton.Click += (_, _) => Close();

        var buttonPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 40,
            Padding = new Padding(0, 6, 0, 0)
        };
        buttonPanel.Controls.Add(doneButton);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 3
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        root.Controls.Add(headerPanel, 0, 0);
        root.Controls.Add(canvas, 0, 1);
        root.Controls.Add(buttonPanel, 0, 2);

        Controls.Add(root);
        AcceptButton = doneButton;
    }

    public void UpdateLayout(List<ScreenLayoutEntry> entries, string localDeviceId, Dictionary<string, string> deviceNames)
    {
        canvas.LocalDeviceId = localDeviceId;
        canvas.DeviceNames = deviceNames;
        canvas.Entries = entries;
    }
}

internal sealed class ScreenLayoutCanvas : Panel
{
    public event Action<List<ScreenLayoutEntry>>? LayoutChanged;

    public string LocalDeviceId = "";
    public Dictionary<string, string> DeviceNames = [];

    private List<ScreenLayoutEntry> entries = [];
    public List<ScreenLayoutEntry> Entries
    {
        get => entries;
        set
        {
            entries = value;
            if (draggingDeviceId is null)
            {
                Invalidate();
            }
        }
    }

    private readonly record struct Metrics(float Scale, float OriginX, float OriginY, float MarginX, float MarginY);

    /// A machine's monitors always move together, so a drag tracks the whole group: each member
    /// screen's canvas origin at drag start, keyed by screenId, plus the canvas point under the
    /// pointer at drag start - the live delta between that anchor and the current pointer position
    /// is applied identically to every group member.
    private string? draggingDeviceId;
    private Dictionary<string, PointF> dragGroupOrigins = [];
    private Dictionary<string, SizeF> dragGroupSizes = [];
    private PointF dragAnchorCanvasPoint;
    private Metrics? dragMetrics;
    private bool didDragDuringGesture;

    private const float CursorDotRadius = 7f;
    private readonly System.Windows.Forms.Timer cursorTrackingTimer;
    private PointF? realCursorPosition;

    public ScreenLayoutCanvas()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = SystemColors.ControlLightLight;

        // Tracks this machine's actual cursor and shows it at the matching spot on whichever of
        // this machine's own screen rects currently contains it.
        cursorTrackingTimer = new System.Windows.Forms.Timer { Interval = 16 };
        cursorTrackingTimer.Tick += (_, _) => UpdateRealCursorPosition();
        cursorTrackingTimer.Start();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            cursorTrackingTimer.Stop();
            cursorTrackingTimer.Dispose();
        }
        base.Dispose(disposing);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        var metrics = dragMetrics ?? ComputeMetrics();

        if (entries.Count > 0)
        {
            using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            using var font = new Font(Font.FontFamily, 9f, FontStyle.Bold);

            foreach (var entry in entries.OrderBy(item => item.ScreenId, StringComparer.Ordinal))
            {
                var rect = ScreenRect(entry, metrics);
                var color = ColorFor(entry.DeviceId);

                using (var fillBrush = new SolidBrush(Color.FromArgb(90, color)))
                {
                    g.FillRectangle(fillBrush, rect);
                }
                using (var pen = new Pen(color, entry.DeviceId == LocalDeviceId ? 3f : 1.5f))
                {
                    g.DrawRectangle(pen, rect.X, rect.Y, rect.Width, rect.Height);
                }

                if (rect.Width <= 40 || rect.Height <= 28)
                {
                    continue;
                }

                var text = $"{ScreenLabel(entry)}\n{(int)entry.Width}×{(int)entry.Height}";
                g.DrawString(text, font, Brushes.Black, rect, format);
            }
        }

        DrawRealCursor(g, metrics);
    }

    /// This machine's actual cursor position, mapped onto the corresponding spot in the shared
    /// layout canvas. Left null (dot hidden) if the monitor the cursor is currently on hasn't been
    /// registered in `entries` yet.
    private void UpdateRealCursorPosition()
    {
        realCursorPosition = ComputeRealCursorCanvasPosition();
        Invalidate();
    }

    private PointF? ComputeRealCursorCanvasPosition()
    {
        if (string.IsNullOrEmpty(LocalDeviceId))
        {
            return null;
        }
        var location = Cursor.Position;
        var screens = Screen.AllScreens;
        for (var index = 0; index < screens.Length; index++)
        {
            var bounds = screens[index].Bounds;
            if (!bounds.Contains(location))
            {
                continue;
            }
            var screenId = $"{LocalDeviceId}#{index}";
            var entry = entries.FirstOrDefault(item => item.ScreenId == screenId);
            if (entry is null)
            {
                return null;
            }
            return new PointF(
                (float)(entry.X + (location.X - bounds.Left)),
                (float)(entry.Y + (location.Y - bounds.Top)));
        }
        return null;
    }

    private void DrawRealCursor(Graphics g, Metrics metrics)
    {
        if (realCursorPosition is not { } canvasPosition)
        {
            return;
        }
        var position = new PointF(
            (canvasPosition.X - metrics.OriginX) * metrics.Scale + metrics.MarginX,
            (canvasPosition.Y - metrics.OriginY) * metrics.Scale + metrics.MarginY);
        var rect = new RectangleF(
            position.X - CursorDotRadius,
            position.Y - CursorDotRadius,
            CursorDotRadius * 2,
            CursorDotRadius * 2);

        using (var shadowBrush = new SolidBrush(Color.FromArgb(60, Color.Black)))
        {
            g.FillEllipse(shadowBrush, new RectangleF(rect.X, rect.Y + 2, rect.Width, rect.Height));
        }
        g.FillEllipse(Brushes.White, rect);
        using var pen = new Pen(Color.FromArgb(150, Color.Black), 1.5f);
        g.DrawEllipse(pen, rect);
    }

    private string ScreenLabel(ScreenLayoutEntry entry)
    {
        var name = DeviceNames.TryGetValue(entry.DeviceId, out var deviceName) ? deviceName : entry.DeviceId;
        if (entries.Count(item => item.DeviceId == entry.DeviceId) <= 1)
        {
            return name;
        }
        var index = ScreenIndex(entry.ScreenId);
        return index is null ? name : $"{name} #{index + 1}";
    }

    private static int? ScreenIndex(string screenId)
    {
        var hashIndex = screenId.LastIndexOf('#');
        if (hashIndex < 0)
        {
            return null;
        }
        return int.TryParse(screenId.AsSpan(hashIndex + 1), out var index) ? index : null;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        var metrics = ComputeMetrics();
        dragMetrics = metrics;
        didDragDuringGesture = false;

        foreach (var entry in entries.OrderBy(item => item.ScreenId, StringComparer.Ordinal).Reverse())
        {
            var rect = ScreenRect(entry, metrics);
            if (!rect.Contains(e.X, e.Y))
            {
                continue;
            }

            draggingDeviceId = entry.DeviceId;
            var group = entries.Where(item => item.DeviceId == entry.DeviceId).ToList();
            dragGroupOrigins = group.ToDictionary(item => item.ScreenId, item => new PointF((float)item.X, (float)item.Y));
            dragGroupSizes = group.ToDictionary(item => item.ScreenId, item => new SizeF((float)item.Width, (float)item.Height));
            dragAnchorCanvasPoint = new PointF(
                (e.X - metrics.MarginX) / metrics.Scale + metrics.OriginX,
                (e.Y - metrics.MarginY) / metrics.Scale + metrics.OriginY);
            Capture = true;
            return;
        }
        draggingDeviceId = null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (draggingDeviceId is not { } deviceId || dragMetrics is not { } metrics || dragGroupOrigins.Count == 0)
        {
            return;
        }

        var currentCanvasPoint = new PointF(
            (e.X - metrics.MarginX) / metrics.Scale + metrics.OriginX,
            (e.Y - metrics.MarginY) / metrics.Scale + metrics.OriginY);
        var candidateDelta = new PointF(
            currentCanvasPoint.X - dragAnchorCanvasPoint.X,
            currentCanvasPoint.Y - dragAnchorCanvasPoint.Y);
        var resolvedDelta = ClampedGroupDelta(candidateDelta, deviceId);

        foreach (var (screenId, origin) in dragGroupOrigins)
        {
            var index = entries.FindIndex(item => item.ScreenId == screenId);
            if (index < 0)
            {
                continue;
            }
            entries[index].X = origin.X + resolvedDelta.X;
            entries[index].Y = origin.Y + resolvedDelta.Y;
        }
        didDragDuringGesture = true;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        var deviceId = draggingDeviceId;
        draggingDeviceId = null;
        dragGroupOrigins = [];
        dragGroupSizes = [];
        dragMetrics = null;
        Capture = false;

        if (!didDragDuringGesture || deviceId is null)
        {
            return;
        }
        SnapGroupToTouch(deviceId);
        Invalidate();
        LayoutChanged?.Invoke(entries.Select(item => item.Clone()).ToList());
    }

    // MARK: Overlap prevention

    /// A machine's own monitors move together as one rigid group - their relative arrangement is
    /// fixed by the OS, not user-adjustable here. Slides the candidate group move along one axis at
    /// a time (full move, X-only, Y-only, no move) and returns the first delta where none of the
    /// group's screens overlap another machine's screen, so the group "bumps" against its neighbors
    /// instead of passing through them while dragging.
    private PointF ClampedGroupDelta(PointF candidateDelta, string excludingDeviceId)
    {
        var others = entries.Where(item => item.DeviceId != excludingDeviceId).Select(item => item.Rect).ToList();

        List<RectangleF> GroupRects(PointF delta)
        {
            return dragGroupOrigins.Select(pair =>
            {
                var size = dragGroupSizes.TryGetValue(pair.Key, out var s) ? s : SizeF.Empty;
                return new RectangleF(pair.Value.X + delta.X, pair.Value.Y + delta.Y, size.Width, size.Height);
            }).ToList();
        }

        bool OverlapsOthers(PointF delta)
        {
            var rects = GroupRects(delta);
            return others.Any(other => rects.Any(rect => RectsOverlap(rect, other)));
        }

        if (!OverlapsOthers(candidateDelta))
        {
            return candidateDelta;
        }
        var xOnly = new PointF(candidateDelta.X, 0);
        if (!OverlapsOthers(xOnly))
        {
            return xOnly;
        }
        var yOnly = new PointF(0, candidateDelta.Y);
        if (!OverlapsOthers(yOnly))
        {
            return yOnly;
        }
        return PointF.Empty;
    }

    private static bool RectsOverlap(RectangleF a, RectangleF b)
    {
        const float epsilon = 0.5f;
        return a.IntersectsWith(RectangleF.Inflate(b, -epsilon, -epsilon));
    }

    // MARK: Touch (zero-gap) snapping

    /// After a drag ends, snaps the moved machine's whole group of screens so at least one edge of
    /// its combined footprint touches another machine's screen with no gap - a machine shouldn't
    /// float disconnected from the rest of the layout. Falls back to leaving it where dropped if no
    /// touching position is available without overlapping something else.
    private void SnapGroupToTouch(string deviceId)
    {
        var memberIndices = Enumerable.Range(0, entries.Count).Where(i => entries[i].DeviceId == deviceId).ToList();
        if (memberIndices.Count == 0)
        {
            return;
        }
        var memberRects = memberIndices.Select(i => entries[i].Rect).ToList();
        var groupBounds = memberRects.Skip(1).Aggregate(memberRects[0], RectangleF.Union);
        var others = entries.Where(item => item.DeviceId != deviceId).Select(item => item.Rect).ToList();
        if (others.Count == 0)
        {
            return;
        }

        const float touchEpsilon = 1f;
        if (others.Any(other => RectangleF.Inflate(other, touchEpsilon, touchEpsilon).IntersectsWith(groupBounds)))
        {
            return;
        }

        PointF? bestDelta = null;
        var bestDistance = float.MaxValue;

        foreach (var other in others)
        {
            foreach (var candidateOrigin in TouchCandidates(groupBounds, other))
            {
                var delta = new PointF(candidateOrigin.X - groupBounds.X, candidateOrigin.Y - groupBounds.Y);
                var distance = (float)Math.Sqrt(delta.X * delta.X + delta.Y * delta.Y);
                if (distance >= bestDistance)
                {
                    continue;
                }
                var movedMemberRects = memberRects
                    .Select(rect => new RectangleF(rect.X + delta.X, rect.Y + delta.Y, rect.Width, rect.Height))
                    .ToList();
                if (others.Any(other2 => movedMemberRects.Any(rect => RectsOverlap(rect, other2))))
                {
                    continue;
                }
                bestDistance = distance;
                bestDelta = delta;
            }
        }

        if (bestDelta is not { } bestDeltaValue)
        {
            return;
        }
        foreach (var index in memberIndices)
        {
            entries[index].X += bestDeltaValue.X;
            entries[index].Y += bestDeltaValue.Y;
        }
    }

    /// Candidate origins placing `rect` flush against one edge of `other`, only offered along an
    /// axis where the two rects already share some span (so screens don't "touch" at a bare corner).
    private static IEnumerable<PointF> TouchCandidates(RectangleF rect, RectangleF other)
    {
        var horizontalOverlap = rect.Top < other.Bottom && rect.Bottom > other.Top;
        var verticalOverlap = rect.Left < other.Right && rect.Right > other.Left;

        if (horizontalOverlap)
        {
            yield return new PointF(other.Right, rect.Y);
            yield return new PointF(other.Left - rect.Width, rect.Y);
        }
        if (verticalOverlap)
        {
            yield return new PointF(rect.X, other.Bottom);
            yield return new PointF(rect.X, other.Top - rect.Height);
        }
    }

    // MARK: Metrics

    private Metrics ComputeMetrics()
    {
        if (entries.Count == 0)
        {
            return new Metrics(1, 0, 0, 0, 0);
        }

        var minX = (float)entries.Min(item => item.X);
        var minY = (float)entries.Min(item => item.Y);
        var maxX = (float)entries.Max(item => item.X + item.Width);
        var maxY = (float)entries.Max(item => item.Y + item.Height);
        var boundingWidth = Math.Max(maxX - minX, 1);
        var boundingHeight = Math.Max(maxY - minY, 1);

        const float padding = 24f;
        var availableWidth = Math.Max(Width - padding * 2, 1);
        var availableHeight = Math.Max(Height - padding * 2, 1);
        var scale = Math.Min(availableWidth / boundingWidth, availableHeight / boundingHeight);

        var marginX = padding + Math.Max(availableWidth - boundingWidth * scale, 0) / 2;
        var marginY = padding + Math.Max(availableHeight - boundingHeight * scale, 0) / 2;
        return new Metrics(scale, minX, minY, marginX, marginY);
    }

    private static RectangleF ScreenRect(ScreenLayoutEntry entry, Metrics metrics)
    {
        var x = ((float)entry.X - metrics.OriginX) * metrics.Scale + metrics.MarginX;
        var y = ((float)entry.Y - metrics.OriginY) * metrics.Scale + metrics.MarginY;
        return new RectangleF(x, y, (float)entry.Width * metrics.Scale, (float)entry.Height * metrics.Scale);
    }

    private static readonly Color[] Palette =
    [
        Color.FromArgb(0, 122, 255), Color.FromArgb(52, 199, 89), Color.FromArgb(255, 149, 0),
        Color.FromArgb(175, 82, 222), Color.FromArgb(90, 200, 250), Color.FromArgb(255, 45, 85),
        Color.FromArgb(255, 204, 0), Color.FromArgb(255, 59, 48), Color.FromArgb(88, 86, 214),
        Color.FromArgb(162, 132, 94)
    ];

    private static Color ColorFor(string deviceId)
    {
        unchecked
        {
            var hash = 17;
            foreach (var ch in deviceId)
            {
                hash = hash * 31 + ch;
            }
            return Palette[(uint)hash % (uint)Palette.Length];
        }
    }
}
