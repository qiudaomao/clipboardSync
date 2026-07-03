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
    public event Action<string>? ForgetDevice;

    public ScreenLayoutForm()
    {
        Text = AppText.Text("layout.title");
        FormBorderStyle = FormBorderStyle.Sizable;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(700, 540);
        MinimumSize = new Size(620, 480);

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
        canvas.ForgetDevice += id => ForgetDevice?.Invoke(id);

        doneButton = new Button
        {
            Text = AppText.Text("layout.done"),
            AutoSize = false,
            Size = new Size(88, 28)
        };
        doneButton.Click += (_, _) => Close();

        var buttonPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 52,
            Padding = new Padding(0, 8, 0, 0)
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
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        root.Controls.Add(headerPanel, 0, 0);
        root.Controls.Add(canvas, 0, 1);
        root.Controls.Add(buttonPanel, 0, 2);

        Controls.Add(root);
        AcceptButton = doneButton;
    }

    public void UpdateLayout(List<ScreenLayoutEntry> entries, string localDeviceId, Dictionary<string, string> deviceNames, HashSet<string> onlineDeviceIds, Dictionary<string, bool> deviceEnabledMap)
    {
        canvas.LocalDeviceId = localDeviceId;
        canvas.DeviceNames = deviceNames;
        canvas.OnlineDeviceIds = onlineDeviceIds;
        canvas.DeviceEnabledMap = deviceEnabledMap;
        canvas.Entries = entries;
    }

    /// Called by TrayAppContext with this device's own live cursor position, already resolved to a
    /// specific screenId + normalized point - so this window can show the local "you are here" dot
    /// without needing to compute it itself. TrayAppContext drives this regardless of whether this
    /// window is visible (it may be polling purely to report to a peer who has ITS window open).
    public void SetLocalCursor(string? screenId, double? normalizedX, double? normalizedY)
    {
        canvas.SetLocalCursor(screenId, normalizedX, normalizedY);
    }

    /// Called when a peer reports where its own real cursor currently sits, so this window can show
    /// a "fake mouse" dot on that peer's screens too. No-op if the peer's screen isn't (yet) known.
    public void UpdateRemoteCursor(string deviceId, string screenId, double normalizedX, double normalizedY)
    {
        canvas.SetRemoteCursor(deviceId, screenId, normalizedX, normalizedY);
    }
}

internal sealed class ScreenLayoutCanvas : Panel
{
    public event Action<List<ScreenLayoutEntry>>? LayoutChanged;
    public event Action<string>? ForgetDevice;

    public string LocalDeviceId = "";
    public Dictionary<string, string> DeviceNames = [];
    public HashSet<string> OnlineDeviceIds = [];
    /// Whether each device currently has input sharing enabled, keyed by deviceId. A device absent
    /// from this map (e.g. an older peer that never reported its state) is treated as enabled, so
    /// its layout rect renders the same as before this distinction existed.
    public Dictionary<string, bool> DeviceEnabledMap = [];

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
    private const float CursorRedrawMinDelta = 1.5f;
    private PointF? localCursorPosition;
    private DateTime lastRemoteCursorPruneAt = DateTime.MinValue;

    private readonly Dictionary<string, (PointF CanvasPoint, DateTime LastUpdated)> remoteCursorPositions = [];
    private static readonly TimeSpan RemoteCursorTimeout = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan RemoteCursorUpdateInterval = TimeSpan.FromMilliseconds(125);
    private static readonly TimeSpan RemoteCursorPruneInterval = TimeSpan.FromSeconds(1);

    public ScreenLayoutCanvas()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = SystemColors.ControlLightLight;
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
                var isOnline = OnlineDeviceIds.Contains(entry.DeviceId);
                var isInputEnabled = !DeviceEnabledMap.TryGetValue(entry.DeviceId, out var enabled) || enabled;
                var isInputDisabled = isOnline && !isInputEnabled;

                using (var fillBrush = new SolidBrush(Color.FromArgb(isOnline ? (isInputDisabled ? 46 : 90) : 30, color)))
                {
                    g.FillRectangle(fillBrush, rect);
                }
                using (var pen = new Pen(Color.FromArgb(isOnline ? (isInputDisabled ? 178 : 255) : 128, color), entry.DeviceId == LocalDeviceId ? 3f : 1.5f))
                {
                    if (!isOnline || isInputDisabled)
                    {
                        pen.DashStyle = DashStyle.Dash;
                    }
                    g.DrawRectangle(pen, rect.X, rect.Y, rect.Width, rect.Height);
                }

                if (rect.Width <= 40 || rect.Height <= 28)
                {
                    continue;
                }

                string subtitle;
                if (!isOnline)
                {
                    subtitle = AppText.Text("layout.disconnected");
                }
                else if (isInputDisabled)
                {
                    subtitle = AppText.Text("layout.inputDisabled");
                }
                else
                {
                    subtitle = $"{(int)entry.Width}×{(int)entry.Height}";
                }
                var text = $"{ScreenLabel(entry)}\n{subtitle}";
                g.DrawString(text, font, (isOnline && !isInputDisabled) ? Brushes.Black : Brushes.Gray, rect, format);
            }
        }

        DrawCursors(g, metrics);
    }

    /// Sets this device's own live cursor position, already resolved by TrayAppContext to a
    /// specific screenId + normalized point. Pass nulls to hide the local dot.
    public void SetLocalCursor(string? screenId, double? normalizedX, double? normalizedY)
    {
        var entry = screenId is null ? null : entries.FirstOrDefault(item => item.ScreenId == screenId);
        var nextPosition = entry is null || normalizedX is null || normalizedY is null
            ? (PointF?)null
            : new PointF(
                (float)(entry.X + normalizedX.Value * entry.Width),
                (float)(entry.Y + normalizedY.Value * entry.Height));

        var positionChanged = PointsDiffer(localCursorPosition, nextPosition, CursorRedrawMinDelta);
        localCursorPosition = nextPosition;

        if (PruneStaleRemoteCursors() || positionChanged)
        {
            Invalidate();
        }
    }

    /// Records a peer's reported cursor position, converting its normalized (screenId, x, y) into a
    /// point on this canvas so it can be drawn alongside the local "fake mouse" dot.
    public void SetRemoteCursor(string deviceId, string screenId, double normalizedX, double normalizedY)
    {
        var entry = entries.FirstOrDefault(item => item.ScreenId == screenId);
        if (entry is null)
        {
            return;
        }
        var canvasPoint = new PointF(
            (float)(entry.X + normalizedX * entry.Width),
            (float)(entry.Y + normalizedY * entry.Height));

        var now = DateTime.UtcNow;
        if (remoteCursorPositions.TryGetValue(deviceId, out var existing))
        {
            if (now - existing.LastUpdated < RemoteCursorUpdateInterval ||
                !PointsDiffer(existing.CanvasPoint, canvasPoint, CursorRedrawMinDelta))
            {
                return;
            }
        }

        remoteCursorPositions[deviceId] = (canvasPoint, now);
        Invalidate();
    }

    private bool PruneStaleRemoteCursors()
    {
        var now = DateTime.UtcNow;
        if (now - lastRemoteCursorPruneAt < RemoteCursorPruneInterval)
        {
            return false;
        }

        lastRemoteCursorPruneAt = now;
        var cutoff = DateTime.UtcNow - RemoteCursorTimeout;
        var removed = false;
        foreach (var staleId in remoteCursorPositions.Where(pair => pair.Value.LastUpdated < cutoff).Select(pair => pair.Key).ToList())
        {
            remoteCursorPositions.Remove(staleId);
            removed = true;
        }
        return removed;
    }

    private static bool PointsDiffer(PointF? previous, PointF? next, float minDelta)
    {
        if (previous is null || next is null)
        {
            return previous != next;
        }

        return Math.Abs(previous.Value.X - next.Value.X) >= minDelta ||
            Math.Abs(previous.Value.Y - next.Value.Y) >= minDelta;
    }

    private void DrawCursors(Graphics g, Metrics metrics)
    {
        foreach (var (deviceId, remote) in remoteCursorPositions)
        {
            DrawCursorDot(g, remote.CanvasPoint, metrics, ColorFor(deviceId));
        }
        if (localCursorPosition is { } canvasPosition)
        {
            DrawCursorDot(g, canvasPosition, metrics, Color.White);
        }
    }

    private static void DrawCursorDot(Graphics g, PointF canvasPosition, Metrics metrics, Color fillColor)
    {
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
        using (var fillBrush = new SolidBrush(fillColor))
        {
            g.FillEllipse(fillBrush, rect);
        }
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

        if (e.Button == MouseButtons.Right)
        {
            ShowForgetMenu(e.Location);
            return;
        }

        if (e.Button != MouseButtons.Left)
        {
            return;
        }

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

    /// Right-click "Forget This Device" - only offered for a screen belonging to a device that's
    /// currently offline, since forgetting an online device's remembered position makes no sense
    /// and it would just get re-merged back in on its next hello anyway.
    private void ShowForgetMenu(Point location)
    {
        var metrics = dragMetrics ?? ComputeMetrics();
        var entry = entries.OrderBy(item => item.ScreenId, StringComparer.Ordinal).Reverse()
            .FirstOrDefault(item => ScreenRect(item, metrics).Contains(location.X, location.Y));

        if (entry is null || entry.DeviceId == LocalDeviceId || OnlineDeviceIds.Contains(entry.DeviceId))
        {
            return;
        }

        var deviceId = entry.DeviceId;
        var menu = new ContextMenuStrip();
        menu.Items.Add(AppText.Text("layout.forgetDevice"), null, (_, _) => ForgetDevice?.Invoke(deviceId));
        menu.Closed += (_, _) => menu.Dispose();
        menu.Show(this, location);
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
        // How much the two rects already overlap along each axis - a larger Y-overlap means
        // they're better aligned to sit beside each other (left/right); a larger X-overlap means
        // they're better aligned to stack (top/bottom). Restricting to whichever is larger, rather
        // than offering both whenever there's any overlap at all, keeps a drag that's clearly
        // meant to go above/below from snapping back beside the other screen (or vice versa) just
        // because that happens to be marginally closer to the drop point in raw distance.
        var horizontalOverlap = Math.Min(rect.Bottom, other.Bottom) - Math.Max(rect.Top, other.Top);
        var verticalOverlap = Math.Min(rect.Right, other.Right) - Math.Max(rect.Left, other.Left);

        if (horizontalOverlap > 0 && horizontalOverlap >= verticalOverlap)
        {
            yield return new PointF(other.Right, rect.Y);
            yield return new PointF(other.Left - rect.Width, rect.Y);
        }
        else if (verticalOverlap > 0)
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
