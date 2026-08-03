using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class InputSharingCoordinator : IDisposable
{
    private const int WH_MOUSE_LL = 14;
    private const int WH_KEYBOARD_LL = 13;
    private const int HC_ACTION = 0;
    private const int WM_MOUSEMOVE = 0x0200;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MBUTTONUP = 0x0208;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_XBUTTONDOWN = 0x020B;
    private const int WM_XBUTTONUP = 0x020C;
    private const int WM_MOUSEHWHEEL = 0x020E;
    /// Which X button an XBUTTON message refers to, in mouseData's high word.
    private const int XBUTTON1 = 0x0001;
    private const int XBUTTON2 = 0x0002;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const uint LLMHF_INJECTED = 0x00000001;
    private const uint LLKHF_INJECTED = 0x00000010;

    /// Stamped as dwExtraInfo on every keyboard event this app (and the elevated input
    /// service — keep WindowsInputInjector's copy in sync) injects, so the keyboard hook
    /// can tell its own injections apart from other software's and never re-capture them
    /// even if the two components are at different versions.
    internal static readonly IntPtr SelfInjectionTag = (IntPtr)0x43530A11;
    private const uint SPI_SETCURSORS = 0x0057;
    private const uint WM_QUIT = 0x0012;
    private const uint PM_NOREMOVE = 0x0000;
    private const int SM_CXCURSOR = 13;
    private const int SM_CYCURSOR = 14;
    private static readonly int[] SystemCursorIds =
    [
        32512, // OCR_NORMAL
        32513, // OCR_IBEAM
        32514, // OCR_WAIT
        32515, // OCR_CROSS
        32516, // OCR_UP
        32642, // OCR_SIZENWSE
        32643, // OCR_SIZENESW
        32644, // OCR_SIZEWE
        32645, // OCR_SIZENS
        32646, // OCR_SIZEALL
        32648, // OCR_NO
        32649, // OCR_HAND
        32650  // OCR_APPSTARTING
    ];
    private static readonly string[] ModifierKeyOrder = ["Shift", "Control", "Alt", "Meta"];
    private static readonly TimeSpan RemoteMouseMoveInterval = TimeSpan.FromMilliseconds(8);
    private static readonly TimeSpan MouseMoveSendInterval = TimeSpan.FromMilliseconds(1000.0 / 60);

    private readonly string deviceId;
    private readonly ScreenLayoutStore layoutStore;
    private readonly LowLevelProc mouseProc;
    private readonly LowLevelProc keyboardProc;
    private readonly object remoteMouseMoveLock = new();
    private readonly object inputServiceLock = new();
    private WindowsInputServiceClient? inputServiceClient;
    private volatile bool disposed;
    private AppConfig config = new();
    private SyncMode role = SyncMode.Client;
    private int peerCount;
    private Dictionary<string, bool> deviceEnabled = [];
    private Dictionary<string, string> deviceNames = [];
    private string? activeScreenId;
    private string? activeTargetDeviceId;
    private ScreenEdge lastCrossedEdge = ScreenEdge.Right;
    private PointF virtualCursor;
    private bool receivingRemote;
    private string? receivingScreenId;
    private readonly HashSet<string> pressedModifierKeys = [];
    private readonly HashSet<string> remotePressedSourceModifierKeys = [];
    private readonly HashSet<string> remotePressedModifierKeys = [];
    private (double X, double Y)? pendingRemoteMouseMove;
    private System.Threading.Timer? pendingRemoteMouseMoveTimer;
    private DateTimeOffset lastRemoteMouseMoveAt = DateTimeOffset.MinValue;
    private readonly object mouseMoveSendLock = new();
    private System.Threading.Timer? pendingMouseMoveSendTimer;
    private DateTimeOffset lastMouseMoveSentAt = DateTimeOffset.MinValue;
    private IntPtr mouseHook;
    private IntPtr keyboardHook;
    private Thread? hookThread;
    private uint hookThreadId;
    private Point localAnchor;
    private bool localCursorHidden;

    public event Action<InputMessage>? MessageReady;
    public event Action<string>? StatusChanged;

    public InputSharingCoordinator(string deviceId, ScreenLayoutStore layoutStore)
    {
        this.deviceId = deviceId;
        this.layoutStore = layoutStore;
        mouseProc = MouseHookCallback;
        keyboardProc = KeyboardHookCallback;
    }

    public void Start()
    {
        UpdateInputState();
    }

    public void Update(AppConfig nextConfig, SyncMode nextRole, int nextPeerCount, Dictionary<string, bool> nextDeviceEnabled, Dictionary<string, string> nextDeviceNames)
    {
        var shouldReleaseRemoteModifiers = !ModifierMapsEqual(config.KeyboardModifierMap, nextConfig.KeyboardModifierMap);
        config = nextConfig.Clone();
        role = nextRole;
        peerCount = nextPeerCount;
        deviceEnabled = nextDeviceEnabled;
        deviceNames = nextDeviceNames;
        if (shouldReleaseRemoteModifiers)
        {
            ReleaseRemoteModifiers();
        }
        UpdateInputState();
    }

    public InputMessage MakeHello(string deviceName, string? deviceAddress)
    {
        return InputMessage.Hello(
            deviceId,
            role,
            deviceName,
            deviceAddress,
            CurrentScreens(),
            config.InputSharingEnabled && peerCount > 0,
            EffectiveControlDeviceId);
    }

    public void Handle(InputMessage message)
    {
        if (message.Origin == deviceId || (message.Target is not null && message.Target != deviceId))
        {
            return;
        }

        if (message.Kind == "hello")
        {
            UpdateStatus();
            return;
        }

        if (!CanReceiveRemoteInput)
        {
            return;
        }

        switch (message.Kind)
        {
            case "capture":
                HandleCapture(message.Capture);
                break;
            case "mouseMove":
                HandleRemoteMouseMove(message.Mouse);
                break;
            case "mouseButton":
                HandleRemoteMouseButton(message.Mouse);
                break;
            case "mouseWheel":
                HandleRemoteMouseWheel(message.Mouse);
                break;
            case "key":
                HandleRemoteKey(message.Key);
                break;
        }
    }

    public void Dispose()
    {
        disposed = true;
        ReleaseRemoteModifiers();
        SendPressedModifierKeyUps();
        ShowLocalCursor();
        activeScreenId = null;
        activeTargetDeviceId = null;
        receivingRemote = false;
        receivingScreenId = null;
        CancelPendingMouseMoveSend();
        ClearPendingRemoteMouseMove();
        RemoveHooks();

        WindowsInputServiceClient? client;
        lock (inputServiceLock)
        {
            client = inputServiceClient;
            inputServiceClient = null;
        }
        // Disposing disconnects the pipe, which makes the secure-desktop agent release any keys or
        // buttons it still had pressed for us.
        client?.Dispose();
    }

    private string EffectiveControlDeviceId => string.IsNullOrWhiteSpace(config.ControlDeviceId)
        ? deviceId
        : config.ControlDeviceId!;

    private bool IsController
    {
        get
        {
            return config.InputSharingEnabled && peerCount > 0 && EffectiveControlDeviceId == deviceId;
        }
    }

    private bool CanReceiveRemoteInput
    {
        get
        {
            if (!config.InputSharingEnabled || peerCount == 0)
            {
                return false;
            }

            return EffectiveControlDeviceId != deviceId;
        }
    }

    private bool HasKnownRemotePeer => layoutStore.Entries.Values.Any(entry =>
        entry.DeviceId != deviceId && deviceEnabled.TryGetValue(entry.DeviceId, out var enabled) && enabled);

    private void UpdateInputState()
    {
        if (IsController)
        {
            EnsureHooks();
        }
        else
        {
            if (activeScreenId is not null)
            {
                EndRemoteCapture(null);
            }
            RemoveHooks();
        }
        if (!CanReceiveRemoteInput)
        {
            ReleaseRemoteModifiers();
            receivingRemote = false;
            receivingScreenId = null;
            ClearPendingRemoteMouseMove();
        }
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        var status = !config.InputSharingEnabled
            ? AppText.Text("input.off")
            : peerCount == 0
                ? AppText.Text("input.waitingPeer")
                : IsController && !HasKnownRemotePeer
                    ? AppText.Text("input.waitingPeerScreen")
                    : IsController && activeTargetDeviceId is not null
                        ? AppText.Format("input.controllingPeer", deviceNames.TryGetValue(activeTargetDeviceId, out var name) ? name : activeTargetDeviceId)
                        : IsController
                            ? AppText.Text("input.ready")
                            : AppText.Text("input.receiving");
        StatusChanged?.Invoke(status);
    }

    /// The low-level hooks live on their own dedicated message-loop thread rather than the UI
    /// thread. LL hook callbacks are dispatched through the message queue of the thread that
    /// installed them, so every mouse event in the SYSTEM waits on that thread's responsiveness.
    /// The UI thread periodically blocks for long stretches (OLE clipboard polling, network
    /// interface enumeration for hello broadcasts, tray menu rebuilds) which showed up as
    /// system-wide cursor stalls whenever this machine was the controller.
    private void EnsureHooks()
    {
        if (hookThread is not null)
        {
            return;
        }
        using var ready = new ManualResetEventSlim(false);
        var thread = new Thread(() => HookThreadProc(ready))
        {
            IsBackground = true,
            Name = "InputSharingHooks",
            Priority = ThreadPriority.Highest
        };
        hookThread = thread;
        thread.Start();
        ready.Wait();
    }

    private void RemoveHooks()
    {
        if (hookThread is null)
        {
            return;
        }
        PostThreadMessage(hookThreadId, WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
        hookThread.Join(TimeSpan.FromSeconds(2));
        hookThread = null;
        hookThreadId = 0;
    }

    private void HookThreadProc(ManualResetEventSlim ready)
    {
        hookThreadId = GetCurrentThreadId();
        // Force the thread's message queue into existence so PostThreadMessage(WM_QUIT) from
        // RemoveHooks can never race its creation and get lost.
        PeekMessage(out _, IntPtr.Zero, 0, 0, PM_NOREMOVE);
        mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, IntPtr.Zero, 0);
        keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, IntPtr.Zero, 0);
        ready.Set();

        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        if (mouseHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(mouseHook);
            mouseHook = IntPtr.Zero;
        }
        if (keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(keyboardHook);
            keyboardHook = IntPtr.Zero;
        }
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < HC_ACTION || !IsController)
        {
            return CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }

        var data = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
        if ((data.flags & LLMHF_INJECTED) != 0)
        {
            return CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }

        var message = wParam.ToInt32();
        if (message == WM_MOUSEMOVE)
        {
            return HandleLocalMouseMove(data.pt) ? (IntPtr)1 : CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }

        if (activeScreenId is null)
        {
            return CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }

        switch (message)
        {
            case WM_LBUTTONDOWN:
            case WM_LBUTTONUP:
            case WM_RBUTTONDOWN:
            case WM_RBUTTONUP:
            case WM_MBUTTONDOWN:
            case WM_MBUTTONUP:
                SendMouseButton(message);
                return (IntPtr)1;
            case WM_XBUTTONDOWN:
            case WM_XBUTTONUP:
                // The thumb buttons (back/forward). mouseData's high word says which one; without
                // this case they were never forwarded and the peer saw nothing at all.
                SendMouseButton(message, SignedHighWord(data.mouseData) == XBUTTON1 ? "back" : "forward");
                return (IntPtr)1;
            case WM_MOUSEWHEEL:
                SendMouseWheel(0, SignedHighWord(data.mouseData) / 120.0);
                return (IntPtr)1;
            case WM_MOUSEHWHEEL:
                SendMouseWheel(SignedHighWord(data.mouseData) / 120.0, 0);
                return (IntPtr)1;
            default:
                return CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < HC_ACTION || !IsController || activeScreenId is null)
        {
            return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
        }

        var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        var message = wParam.ToInt32();
        if (message != WM_KEYDOWN && message != WM_KEYUP && message != WM_SYSKEYDOWN && message != WM_SYSKEYUP)
        {
            return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
        }
        var action = message == WM_KEYUP || message == WM_SYSKEYUP ? "up" : "down";

        if ((data.flags & LLKHF_INJECTED) != 0)
        {
            // Keystrokes injected by other software are deliberately neither captured nor
            // suppressed: they belong to that software (password-manager auto-type, on-screen
            // keyboards), and intercepting them is both a privacy problem and behavior that
            // endpoint protection flags. The one exception is MODIFIER state. A key remapper
            // that expands one key into a chord (CapsLock -> Ctrl+Alt+Win+Shift) injects those
            // modifiers, and without them the peer receives the chord's real key unmodified.
            // Relaying a modifier press types nothing anywhere; it only keeps the peer's
            // modifier state truthful. Our own injections carry SelfInjectionTag and are
            // skipped outright so a stale service build can't echo input back to itself.
            if (data.dwExtraInfo != SelfInjectionTag &&
                WindowsKeyToCanonical.TryGetValue((Keys)data.vkCode, out var injectedKey) &&
                IsModifierKey(injectedKey))
            {
                SendKey((Keys)data.vkCode, action);
            }
            return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
        }

        SendKey((Keys)data.vkCode, action);
        return (IntPtr)1;
    }

    private bool HandleLocalMouseMove(POINT point)
    {
        if (activeScreenId is null)
        {
            var current = CurrentLocalScreen(point);
            if (current is null)
            {
                // The LL hook fires before the system applies (and clamps) the move, so a fast
                // flick toward a peer reports a proposed position already past the physical edge,
                // outside every local screen. Detect the crossing from the nearest screen's edge
                // instead of dropping the event, which would pin the cursor at the edge until a
                // slow move happens to land inside CrossingNeighbor's threshold band.
                current = NearestLocalScreen(point);
                if (current is null)
                {
                    return false;
                }
                point = ClampToScreen(point, current.Value.RealRect);
            }
            if (!layoutStore.Entries.TryGetValue(current.Value.ScreenId, out var currentEntry))
            {
                return false;
            }

            var match = CrossingNeighbor(point, currentEntry, current.Value.RealRect);
            if (match is null)
            {
                return false;
            }

            localAnchor = CenterOfScreenContaining(point);
            StartRemoteCapture(match.Value.Neighbor, match.Value.CanvasPoint, match.Value.Edge);
            SetCursorPos(localAnchor.X, localAnchor.Y);
            return true;
        }

        var dx = point.X - localAnchor.X;
        var dy = point.Y - localAnchor.Y;
        if (dx != 0 || dy != 0)
        {
            virtualCursor.X += dx;
            virtualCursor.Y += dy;
            AdvanceRemoteCursor();
            // AdvanceRemoteCursor may have ended capture and warped the cursor to its return
            // point on one of our own screens; re-anchoring then would yank it back to the
            // screen-center anchor and leave it stranded there.
            if (activeScreenId is not null)
            {
                SetCursorPos(localAnchor.X, localAnchor.Y);
            }
        }
        return true;
    }

    /// Which of this machine's own monitors currently contains the cursor, alongside that
    /// monitor's real screen-coordinate bounds.
    private (string ScreenId, RectangleF RealRect)? CurrentLocalScreen(POINT point)
    {
        var screens = OrderedScreens();
        for (var index = 0; index < screens.Length; index++)
        {
            var bounds = screens[index].Bounds;
            if (bounds.Contains(point.X, point.Y))
            {
                return ($"{deviceId}#{index}", bounds);
            }
        }
        return null;
    }

    /// The local monitor closest to an out-of-bounds proposed cursor position (Screen.FromPoint
    /// resolves to the nearest screen when the point lies outside all of them), identified the
    /// same way as CurrentLocalScreen so its screenId matches the layout entries.
    private (string ScreenId, RectangleF RealRect)? NearestLocalScreen(POINT point)
    {
        var nearest = Screen.FromPoint(new Point(point.X, point.Y)).Bounds;
        var screens = OrderedScreens();
        for (var index = 0; index < screens.Length; index++)
        {
            if (screens[index].Bounds == nearest)
            {
                return ($"{deviceId}#{index}", nearest);
            }
        }
        return null;
    }

    private static POINT ClampToScreen(POINT point, RectangleF rect)
    {
        return new POINT
        {
            X = (int)Math.Min(Math.Max(point.X, rect.Left), rect.Right - 1),
            Y = (int)Math.Min(Math.Max(point.Y, rect.Top), rect.Bottom - 1)
        };
    }

    /// Local cursor is in real screen coordinates, relative to the current monitor's bounds. The
    /// shared layout canvas uses the same top-left-origin, y-down convention, so translating is
    /// just an offset by that monitor's own layout entry origin. The four-edge check is against
    /// the CURRENT monitor's own real bounds, not the union of all this machine's monitors - for
    /// an irregular layout (e.g. one monitor taller than the other) the union's top edge only
    /// coincides with the taller monitor, so a cursor over the shorter one could never reach it.
    /// Checking the current monitor's own edges instead still can't wrongly trigger at an internal
    /// seam between two of this machine's own screens: the neighbor search below always excludes
    /// this device's own screens on this first hop, so it naturally finds nothing there and lets
    /// the OS carry the cursor across the seam on its own.
    private (ScreenEdge Edge, ScreenLayoutEntry Neighbor, PointF CanvasPoint)? CrossingNeighbor(
        POINT location,
        ScreenLayoutEntry currentEntry,
        RectangleF currentRealRect)
    {
        const int threshold = 2;
        var canvasPoint = new PointF(
            (float)(currentEntry.X + (location.X - currentRealRect.Left)),
            (float)(currentEntry.Y + (location.Y - currentRealRect.Top)));

        var candidateEdges = new List<ScreenEdge>();
        if (location.X >= currentRealRect.Right - threshold) candidateEdges.Add(ScreenEdge.Right);
        if (location.X <= currentRealRect.Left + threshold) candidateEdges.Add(ScreenEdge.Left);
        if (location.Y <= currentRealRect.Top + threshold) candidateEdges.Add(ScreenEdge.Top);
        if (location.Y >= currentRealRect.Bottom - threshold) candidateEdges.Add(ScreenEdge.Bottom);

        var ownScreenIds = layoutStore.Entries.Values.Where(e => e.DeviceId == deviceId).Select(e => e.ScreenId).ToHashSet();

        foreach (var edge in candidateEdges)
        {
            var crossAxis = edge is ScreenEdge.Left or ScreenEdge.Right ? canvasPoint.Y : canvasPoint.X;
            var match = Neighbor(edge, currentEntry.Rect, ownScreenIds, crossAxis);
            if (match is not null)
            {
                return (edge, match, canvasPoint);
            }
        }
        return null;
    }

    /// Finds the closest enabled screen positioned beyond `edge` of `rect` whose span across the
    /// perpendicular axis covers `crossAxis`. Tolerates a small gap so screens dragged in the
    /// layout window don't need to touch pixel-perfectly. A candidate belonging to this device
    /// itself is always eligible (used to detect "back to my own screen" hand-offs).
    private ScreenLayoutEntry? Neighbor(ScreenEdge edge, RectangleF rect, HashSet<string> excludingScreenIds, float crossAxis)
    {
        const float epsilon = 48f;
        ScreenLayoutEntry? best = null;
        var bestGap = float.MaxValue;

        foreach (var entry in layoutStore.Entries.Values)
        {
            if (excludingScreenIds.Contains(entry.ScreenId))
            {
                continue;
            }
            if (entry.DeviceId != deviceId && !(deviceEnabled.TryGetValue(entry.DeviceId, out var enabled) && enabled))
            {
                continue;
            }

            var candidate = entry.Rect;
            float gap;
            switch (edge)
            {
                case ScreenEdge.Right:
                    if (!(candidate.Top < crossAxis && candidate.Bottom > crossAxis)) continue;
                    gap = candidate.Left - rect.Right;
                    break;
                case ScreenEdge.Left:
                    if (!(candidate.Top < crossAxis && candidate.Bottom > crossAxis)) continue;
                    gap = rect.Left - candidate.Right;
                    break;
                case ScreenEdge.Bottom:
                    if (!(candidate.Left < crossAxis && candidate.Right > crossAxis)) continue;
                    gap = candidate.Top - rect.Bottom;
                    break;
                default:
                    if (!(candidate.Left < crossAxis && candidate.Right > crossAxis)) continue;
                    gap = rect.Top - candidate.Bottom;
                    break;
            }

            if (gap < -epsilon || gap >= bestGap)
            {
                continue;
            }
            bestGap = gap;
            best = entry;
        }
        return best;
    }

    private static ScreenEdge? ExitedEdge(PointF point, RectangleF rect)
    {
        var left = rect.Left - point.X;
        var right = point.X - rect.Right;
        var top = rect.Top - point.Y;
        var bottom = point.Y - rect.Bottom;
        var maxOverflow = Math.Max(Math.Max(left, right), Math.Max(top, bottom));
        if (maxOverflow <= 0)
        {
            return null;
        }
        if (maxOverflow == left) return ScreenEdge.Left;
        if (maxOverflow == right) return ScreenEdge.Right;
        if (maxOverflow == top) return ScreenEdge.Top;
        return ScreenEdge.Bottom;
    }

    private static PointF Clamp(PointF point, RectangleF rect)
    {
        return new PointF(
            Math.Min(Math.Max(point.X, rect.Left), rect.Right),
            Math.Min(Math.Max(point.Y, rect.Top), rect.Bottom));
    }

    private void StartRemoteCapture(ScreenLayoutEntry target, PointF canvasPoint, ScreenEdge edge)
    {
        virtualCursor = Clamp(canvasPoint, target.Rect);
        activeScreenId = target.ScreenId;
        activeTargetDeviceId = target.DeviceId;
        lastCrossedEdge = edge;
        HideLocalCursor();
        SendCapture("start", target.DeviceId, target.ScreenId, edge, target);
        SendMouseMoveNow();
        UpdateStatus();
    }

    /// Walks the shared layout each time the virtual cursor leaves the currently active screen's
    /// rect, handing capture off to whichever neighbor covers that boundary (which may be another
    /// screen on the same remote machine, or one of this controller's own screens, ending remote
    /// capture) and sticking at the edge when there's none.
    private void AdvanceRemoteCursor()
    {
        if (activeScreenId is null || activeTargetDeviceId is null || !layoutStore.Entries.TryGetValue(activeScreenId, out var activeEntry))
        {
            EndRemoteCapture(null);
            return;
        }

        var rect = activeEntry.Rect;
        var edge = ExitedEdge(virtualCursor, rect);
        if (edge is null)
        {
            QueueMouseMove();
            return;
        }

        var crossAxis = edge is ScreenEdge.Left or ScreenEdge.Right ? virtualCursor.Y : virtualCursor.X;
        var match = Neighbor(edge.Value, rect, [activeScreenId], crossAxis);
        if (match is null)
        {
            virtualCursor = Clamp(virtualCursor, rect);
            QueueMouseMove();
            return;
        }

        lastCrossedEdge = edge.Value;

        if (match.DeviceId == deviceId)
        {
            virtualCursor = Clamp(virtualCursor, match.Rect);
            EndRemoteCapture(match.ScreenId);
            return;
        }

        CancelPendingMouseMoveSend();
        // Moving between two monitors of the SAME peer is a hand-off, not a hand-back: sending
        // "end" there made the receiver tear down its capture state mid-gesture, which dropped
        // any drag crossing the boundary and released held modifiers. Send only the "start" that
        // tells it which monitor the normalized coordinates now refer to.
        if (match.DeviceId != activeTargetDeviceId)
        {
            SendPressedModifierKeyUps();
            SendCapture("end", activeTargetDeviceId, activeScreenId, edge.Value, activeEntry);
        }
        virtualCursor = Clamp(virtualCursor, match.Rect);
        activeScreenId = match.ScreenId;
        activeTargetDeviceId = match.DeviceId;
        SendCapture("start", match.DeviceId, match.ScreenId, edge.Value, match);
        SendMouseMoveNow();
        UpdateStatus();
    }

    private void EndRemoteCapture(string? returnToScreenId)
    {
        if (activeScreenId is null || activeTargetDeviceId is null)
        {
            return;
        }
        ShowLocalCursor();
        CancelPendingMouseMoveSend();
        var endingScreenId = activeScreenId;
        var endingTargetDeviceId = activeTargetDeviceId;
        SendPressedModifierKeyUps();
        pressedModifierKeys.Clear();
        layoutStore.Entries.TryGetValue(endingScreenId, out var entry);
        SendCapture("end", endingTargetDeviceId, endingScreenId, lastCrossedEdge, entry);
        activeScreenId = null;
        activeTargetDeviceId = null;
        if (returnToScreenId is not null)
        {
            WarpLocalCursorToReturnPoint(returnToScreenId);
        }
        UpdateStatus();
    }

    private void WarpLocalCursorToReturnPoint(string screenId)
    {
        if (!layoutStore.Entries.TryGetValue(screenId, out var localEntry))
        {
            return;
        }
        var realRect = LocalScreenRealRect(screenId) ?? DesktopBounds();
        var rawX = realRect.Left + (virtualCursor.X - localEntry.X);
        var rawY = realRect.Top + (virtualCursor.Y - localEntry.Y);
        var clampedX = (int)Math.Min(Math.Max(rawX, realRect.Left), Math.Max(realRect.Right - 2, realRect.Left));
        var clampedY = (int)Math.Min(Math.Max(rawY, realRect.Top), Math.Max(realRect.Bottom - 2, realRect.Top));
        SetCursorPos(clampedX, clampedY);
    }

    private void SendCapture(string action, string targetDeviceId, string screenId, ScreenEdge edge, ScreenLayoutEntry? entry)
    {
        var normalized = entry is not null ? NormalizedPoint(entry) : (X: 0.0, Y: 0.0);
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = targetDeviceId,
            Kind = "capture",
            Capture = new InputCapturePayload
            {
                Action = action,
                Edge = InputSharingWire.EdgeValue(edge),
                ScreenId = screenId,
                NormalizedX = normalized.X,
                NormalizedY = normalized.Y
            },
            SentAt = Now()
        });
    }

    private (double X, double Y) NormalizedPoint(ScreenLayoutEntry entry)
    {
        var x = Math.Clamp((virtualCursor.X - entry.X) / Math.Max(entry.Width, 1), 0, 1);
        var y = Math.Clamp((virtualCursor.Y - entry.Y) / Math.Max(entry.Height, 1), 0, 1);
        return (x, y);
    }

    private void SendMouseMove()
    {
        if (activeTargetDeviceId is null || activeScreenId is null || !layoutStore.Entries.TryGetValue(activeScreenId, out var entry))
        {
            return;
        }
        var normalized = NormalizedPoint(entry);
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = activeTargetDeviceId,
            Kind = "mouseMove",
            Mouse = new InputMousePayload
            {
                Action = "move",
                NormalizedX = normalized.X,
                NormalizedY = normalized.Y
            },
            SentAt = Now()
        });
    }

    /// Throttles controller-side mouseMove sends to 60Hz. The low-level mouse hook fires at the
    /// mouse's polling rate (125-1000Hz) on the UI thread, and each send serializes + encrypts +
    /// ships a websocket frame inline; doing that per event starves the hook past the system's
    /// LowLevelHooksTimeout and the cursor visibly stalls. Only the newest position matters, so
    /// coalesce: send immediately when the interval has elapsed, otherwise arm a one-shot timer
    /// that flushes the latest `virtualCursor` when it does.
    private void QueueMouseMove()
    {
        var sendNow = false;
        lock (mouseMoveSendLock)
        {
            var elapsed = DateTimeOffset.UtcNow - lastMouseMoveSentAt;
            if (elapsed >= MouseMoveSendInterval)
            {
                if (pendingMouseMoveSendTimer is null)
                {
                    lastMouseMoveSentAt = DateTimeOffset.UtcNow;
                    sendNow = true;
                }
            }
            else if (pendingMouseMoveSendTimer is null)
            {
                var delay = MouseMoveSendInterval - elapsed;
                if (delay < TimeSpan.Zero)
                {
                    delay = TimeSpan.Zero;
                }
                pendingMouseMoveSendTimer = new System.Threading.Timer(
                    _ => FlushPendingMouseMoveSend(),
                    null,
                    delay,
                    Timeout.InfiniteTimeSpan);
            }
        }
        if (sendNow)
        {
            SendMouseMove();
        }
    }

    private void FlushPendingMouseMoveSend()
    {
        lock (mouseMoveSendLock)
        {
            pendingMouseMoveSendTimer?.Dispose();
            pendingMouseMoveSendTimer = null;
            if (activeScreenId is null)
            {
                return;
            }
            lastMouseMoveSentAt = DateTimeOffset.UtcNow;
        }
        SendMouseMove();
    }

    /// Immediate send for capture starts and screen hand-offs, where the receiver needs the
    /// position before any subsequent event.
    private void SendMouseMoveNow()
    {
        lock (mouseMoveSendLock)
        {
            pendingMouseMoveSendTimer?.Dispose();
            pendingMouseMoveSendTimer = null;
            lastMouseMoveSentAt = DateTimeOffset.UtcNow;
        }
        SendMouseMove();
    }

    private void CancelPendingMouseMoveSend()
    {
        lock (mouseMoveSendLock)
        {
            pendingMouseMoveSendTimer?.Dispose();
            pendingMouseMoveSendTimer = null;
        }
    }

    private void SendMouseButton(int message, string? xButton = null)
    {
        if (activeTargetDeviceId is null || activeScreenId is null || !layoutStore.Entries.TryGetValue(activeScreenId, out var entry))
        {
            return;
        }
        var button = xButton
            ?? (message == WM_RBUTTONDOWN || message == WM_RBUTTONUP ? "right" :
                message == WM_MBUTTONDOWN || message == WM_MBUTTONUP ? "middle" : "left");
        var action = message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN ||
            message == WM_MBUTTONDOWN || message == WM_XBUTTONDOWN ? "down" : "up";
        var normalized = NormalizedPoint(entry);
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = activeTargetDeviceId,
            Kind = "mouseButton",
            Mouse = new InputMousePayload
            {
                Action = action,
                Button = button,
                NormalizedX = normalized.X,
                NormalizedY = normalized.Y,
                Modifiers = CurrentPressedModifiers()
            },
            SentAt = Now()
        });
    }

    private void SendMouseWheel(double deltaX, double deltaY)
    {
        if (activeTargetDeviceId is null || activeScreenId is null || !layoutStore.Entries.TryGetValue(activeScreenId, out var entry))
        {
            return;
        }
        var normalized = NormalizedPoint(entry);
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = activeTargetDeviceId,
            Kind = "mouseWheel",
            Mouse = new InputMousePayload
            {
                Action = "wheel",
                NormalizedX = normalized.X,
                NormalizedY = normalized.Y,
                DeltaX = deltaX,
                DeltaY = deltaY
            },
            SentAt = Now()
        });
    }

    private void SendKey(Keys keyCode, string action)
    {
        if (activeTargetDeviceId is null)
        {
            return;
        }
        if (!WindowsKeyToCanonical.TryGetValue(keyCode, out var key))
        {
            return;
        }
        UpdatePressedModifiers(key, action);

        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = activeTargetDeviceId,
            Kind = "key",
            Key = new InputKeyPayload
            {
                Action = action,
                Key = key,
                Modifiers = CurrentPressedModifiers()
            },
            SentAt = Now()
        });
    }

    private void SendPressedModifierKeyUps()
    {
        if (activeTargetDeviceId is null)
        {
            return;
        }
        foreach (var modifier in ModifierKeyOrder)
        {
            if (pressedModifierKeys.Contains(modifier))
            {
                MessageReady?.Invoke(new InputMessage
                {
                    Type = "input",
                    Origin = deviceId,
                    Target = activeTargetDeviceId,
                    Kind = "key",
                    Key = new InputKeyPayload
                    {
                        Action = "up",
                        Key = modifier,
                        Modifiers = []
                    },
                    SentAt = Now()
                });
            }
        }
    }

    private void HandleCapture(InputCapturePayload? capture)
    {
        if (capture is null)
        {
            return;
        }

        if (capture.Action == "start")
        {
            // Already receiving means this is a hand-off between two of our own monitors rather
            // than a fresh capture, so a held modifier belongs to a gesture still in progress
            // (Shift-drag, Ctrl-drag) and must survive the crossing.
            var isScreenHandoff = receivingRemote;
            receivingRemote = true;
            receivingScreenId = capture.ScreenId;
            ClearPendingRemoteMouseMove();
            if (!isScreenHandoff)
            {
                ReleaseRemoteModifiers();
            }
            WarpTo(capture.NormalizedX, capture.NormalizedY);
        }
        else if (capture.Action == "end")
        {
            ClearPendingRemoteMouseMove();
            ReleaseRemoteModifiers();
            receivingRemote = false;
            receivingScreenId = null;
        }
    }

    private void HandleRemoteMouseMove(InputMousePayload? mouse)
    {
        if (!receivingRemote || mouse?.NormalizedX is null || mouse.NormalizedY is null)
        {
            return;
        }
        QueueRemoteMouseMove(mouse.NormalizedX.Value, mouse.NormalizedY.Value);
    }

    private void HandleRemoteMouseButton(InputMousePayload? mouse)
    {
        if (!receivingRemote || mouse is null)
        {
            return;
        }
        ClearPendingRemoteMouseMove();
        // Button events stamped with the controller's modifier snapshot reconcile just
        // like key events, so a stale held modifier can't turn a plain click into a
        // Ctrl/Alt-click (and a real modifier-click re-asserts any lost modifier).
        if (mouse.Modifiers is not null)
        {
            SyncRemoteSourceModifiers(mouse.Modifiers);
        }
        if (mouse.NormalizedX is not null && mouse.NormalizedY is not null)
        {
            WarpTo(mouse.NormalizedX.Value, mouse.NormalizedY.Value);
        }

        var down = mouse.Action == "down";
        // The thumb buttons share one pair of flags and are told apart by mouseData, unlike
        // every other button.
        if (mouse.Button == "back" || mouse.Button == "forward")
        {
            SendMouseInput(
                down ? MouseFlags.XDown : MouseFlags.XUp,
                mouse.Button == "back" ? XBUTTON1 : XBUTTON2);
            return;
        }

        var flags = mouse.Button == "right"
            ? down ? MouseFlags.RightDown : MouseFlags.RightUp
            : mouse.Button == "middle"
                ? down ? MouseFlags.MiddleDown : MouseFlags.MiddleUp
                : down ? MouseFlags.LeftDown : MouseFlags.LeftUp;
        SendMouseInput(flags, 0);
    }

    private void HandleRemoteMouseWheel(InputMousePayload? mouse)
    {
        if (!receivingRemote || mouse is null)
        {
            return;
        }
        ClearPendingRemoteMouseMove();
        if (mouse.NormalizedX is not null && mouse.NormalizedY is not null)
        {
            WarpTo(mouse.NormalizedX.Value, mouse.NormalizedY.Value);
        }
        if (mouse.DeltaY is not null)
        {
            var deltaY = config.ReverseMouseVerticalScroll ? -mouse.DeltaY.Value : mouse.DeltaY.Value;
            SendMouseInput(MouseFlags.Wheel, (int)(deltaY * 120));
        }
        if (mouse.DeltaX is not null)
        {
            SendMouseInput(MouseFlags.HWheel, (int)(mouse.DeltaX.Value * 120));
        }
    }

    private void HandleRemoteKey(InputKeyPayload? key)
    {
        if (!receivingRemote || key is null)
        {
            return;
        }
        if (IsModifierKey(key.Key))
        {
            // The stamped snapshot already includes this event's own change and is
            // authoritative, so a modifier keyup lost to a hook miss or dropped
            // message heals on the next modifier event instead of sticking until
            // the next regular keystroke.
            SyncRemoteSourceModifiers(key.Modifiers);
            return;
        }

        if (!CanonicalToWindowsKey.TryGetValue(key.Key, out var virtualKey))
        {
            return;
        }

        SyncRemoteSourceModifiers(key.Modifiers);
        SendKeyboardInput((ushort)virtualKey, key.Action == "up");
    }

    private void QueueRemoteMouseMove(double normalizedX, double normalizedY)
    {
        (double X, double Y)? moveToApply = null;
        lock (remoteMouseMoveLock)
        {
            pendingRemoteMouseMove = (normalizedX, normalizedY);
            var now = DateTimeOffset.UtcNow;
            var elapsed = now - lastRemoteMouseMoveAt;
            if (elapsed >= RemoteMouseMoveInterval && pendingRemoteMouseMoveTimer is null)
            {
                moveToApply = pendingRemoteMouseMove;
                pendingRemoteMouseMove = null;
                lastRemoteMouseMoveAt = now;
            }
            else if (pendingRemoteMouseMoveTimer is null)
            {
                var delay = RemoteMouseMoveInterval - elapsed;
                if (delay < TimeSpan.Zero)
                {
                    delay = TimeSpan.Zero;
                }
                pendingRemoteMouseMoveTimer = new System.Threading.Timer(
                    _ => FlushPendingRemoteMouseMove(),
                    null,
                    delay,
                    Timeout.InfiniteTimeSpan);
            }
        }

        if (moveToApply is { } move)
        {
            WarpTo(move.X, move.Y);
        }
    }

    private void FlushPendingRemoteMouseMove()
    {
        (double X, double Y)? moveToApply = null;
        lock (remoteMouseMoveLock)
        {
            pendingRemoteMouseMoveTimer?.Dispose();
            pendingRemoteMouseMoveTimer = null;
            if (!receivingRemote)
            {
                pendingRemoteMouseMove = null;
                return;
            }

            if (pendingRemoteMouseMove is { } move)
            {
                moveToApply = move;
                pendingRemoteMouseMove = null;
                lastRemoteMouseMoveAt = DateTimeOffset.UtcNow;
            }
        }

        if (moveToApply is { } point)
        {
            WarpTo(point.X, point.Y);
        }
    }

    private void ClearPendingRemoteMouseMove()
    {
        lock (remoteMouseMoveLock)
        {
            pendingRemoteMouseMoveTimer?.Dispose();
            pendingRemoteMouseMoveTimer = null;
            pendingRemoteMouseMove = null;
        }
    }

    /// Maps a normalized 0...1 point onto the monitor we're currently receiving remote input for
    /// (`receivingScreenId`), falling back to the whole local desktop union if that screen can't be
    /// resolved (e.g. it was unplugged mid-session), then injects it as an absolute move across the
    /// full virtual desktop (Windows' SendInput absolute coordinates are always virtual-desktop
    /// relative, regardless of which monitor rect the target pixel point came from).
    private void WarpTo(double normalizedX, double normalizedY)
    {
        var targetRect = (receivingScreenId is not null ? LocalScreenRealRect(receivingScreenId) : null) ?? DesktopBounds();
        var point = PointFor(normalizedX, normalizedY, targetRect);
        var bounds = DesktopBounds();
        SendMouseInput(
            MouseFlags.Move | MouseFlags.Absolute | MouseFlags.VirtualDesk,
            0,
            ToAbsoluteMouseCoordinate(point.X, bounds.Left, bounds.Width),
            ToAbsoluteMouseCoordinate(point.Y, bounds.Top, bounds.Height));
    }

    private static Point PointFor(double normalizedX, double normalizedY, Rectangle rect)
    {
        return new Point(
            rect.Left + (int)(Math.Clamp(normalizedX, 0, 1) * Math.Max(rect.Width - 1, 0)),
            rect.Top + (int)(Math.Clamp(normalizedY, 0, 1) * Math.Max(rect.Height - 1, 0)));
    }

    internal static List<ScreenMetrics> CurrentScreens()
    {
        return OrderedScreens().Select(screen => new ScreenMetrics
        {
            Width = screen.Bounds.Width,
            Height = screen.Bounds.Height,
            Scale = 1,
            LocalX = screen.Bounds.X,
            LocalY = screen.Bounds.Y
        }).ToList();
    }

    /// This machine's actual cursor position, described as a normalized point on whichever of its
    /// own screens currently contains it, plus that screen's id. Used both to show a local "you are
    /// here" dot in the Screen Layout window and to report live position to peers watching it.
    /// Returns null if the monitor the cursor is currently on hasn't been registered in
    /// `entries` yet.
    internal static (string ScreenId, double NormalizedX, double NormalizedY)? CurrentLocalCursorReport(string deviceId, List<ScreenLayoutEntry> entries)
    {
        if (string.IsNullOrEmpty(deviceId))
        {
            return null;
        }
        var location = Cursor.Position;
        var screens = OrderedScreens();
        for (var index = 0; index < screens.Length; index++)
        {
            var bounds = screens[index].Bounds;
            if (!bounds.Contains(location))
            {
                continue;
            }
            var screenId = $"{deviceId}#{index}";
            if (!entries.Any(item => item.ScreenId == screenId))
            {
                return null;
            }
            var normalizedX = Math.Min(Math.Max((double)(location.X - bounds.Left) / Math.Max(bounds.Width, 1), 0), 1);
            var normalizedY = Math.Min(Math.Max((double)(location.Y - bounds.Top) / Math.Max(bounds.Height, 1), 0), 1);
            return (screenId, normalizedX, normalizedY);
        }
        return null;
    }

    /// The system's active screens, ordered by physical position (left-to-right, then top-to-
    /// bottom) rather than raw `Screen.AllScreens` enumeration order. Raw order isn't guaranteed
    /// stable across relaunches or sleep/wake, which would otherwise make a monitor's index-based
    /// screenId (and therefore its saved layout position/size) drift or swap with another
    /// monitor's between sessions.
    private static Screen[] OrderedScreens()
    {
        return Screen.AllScreens
            .OrderBy(screen => screen.Bounds.X)
            .ThenBy(screen => screen.Bounds.Y)
            .ToArray();
    }

    private static Rectangle DesktopBounds()
    {
        return SystemInformation.VirtualScreen;
    }

    /// This machine's own monitor for `screenId` (parsed as `"<deviceId>#<index>"`), resolved
    /// against the current live display list. Used both to warp the local cursor back onto the
    /// right monitor when returning from remote capture, and to warp a remote peer's input onto the
    /// right one of our own monitors when receiving.
    private Rectangle? LocalScreenRealRect(string screenId)
    {
        var prefix = $"{deviceId}#";
        if (!screenId.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }
        if (!int.TryParse(screenId.AsSpan(prefix.Length), out var index))
        {
            return null;
        }
        var screens = OrderedScreens();
        if (index < 0 || index >= screens.Length)
        {
            return null;
        }
        return screens[index].Bounds;
    }

    private static Point CenterOfScreenContaining(POINT point)
    {
        var bounds = Screen.FromPoint(new Point(point.X, point.Y)).Bounds;
        return new Point(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
    }

    /// Hides this machine's own cursor while the mouse is being relayed onto a peer's screen, so the
    /// controller doesn't show a stray arrow parked in the middle of the screen. Windows has no
    /// per-process cursor hide that covers other apps' windows, so we swap every system cursor for a
    /// transparent one and reload the defaults on `ShowLocalCursor`. Guarded by `localCursorHidden`
    /// so the swap/restore stays balanced.
    private void HideLocalCursor()
    {
        if (localCursorHidden)
        {
            return;
        }
        localCursorHidden = true;
        foreach (var id in SystemCursorIds)
        {
            var blank = CreateBlankCursor();
            if (blank != IntPtr.Zero)
            {
                // SetSystemCursor takes ownership of and destroys the handle, so each id needs its own.
                SetSystemCursor(blank, id);
            }
        }
    }

    private void ShowLocalCursor()
    {
        if (!localCursorHidden)
        {
            return;
        }
        localCursorHidden = false;
        SystemParametersInfo(SPI_SETCURSORS, 0, IntPtr.Zero, 0);
    }

    /// 1bpp masks with AND=0xFF, XOR=0x00 leave the screen untouched → fully transparent.
    /// CreateCursor only accepts the dimensions the display driver reports via
    /// GetSystemMetrics(SM_CXCURSOR/SM_CYCURSOR); with a hardcoded 32x32 it fails on machines
    /// whose pointer size isn't 32 (accessibility pointer-size slider, some DPI setups), the
    /// swap was skipped, and the local cursor stayed visible while controlling a peer.
    private static IntPtr CreateBlankCursor()
    {
        var width = Math.Max(GetSystemMetrics(SM_CXCURSOR), 32);
        var height = Math.Max(GetSystemMetrics(SM_CYCURSOR), 32);
        var stride = (width + 15) / 16 * 2; // 1bpp scanlines are WORD-aligned
        var andMask = new byte[stride * height];
        var xorMask = new byte[stride * height];
        for (var i = 0; i < andMask.Length; i++)
        {
            andMask[i] = 0xFF;
        }
        return CreateCursor(IntPtr.Zero, 0, 0, width, height, andMask, xorMask);
    }

    private static double Now()
    {
        return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    }

    private static short SignedHighWord(uint value)
    {
        return unchecked((short)((value >> 16) & 0xffff));
    }

    private void UpdatePressedModifiers(string key, string action)
    {
        if (!IsModifierKey(key))
        {
            return;
        }
        if (action == "down")
        {
            pressedModifierKeys.Add(key);
        }
        else
        {
            pressedModifierKeys.Remove(key);
        }
    }

    private List<string> CurrentPressedModifiers()
    {
        var modifiers = new List<string>();
        foreach (var modifier in ModifierKeyOrder)
        {
            if (pressedModifierKeys.Contains(modifier))
            {
                modifiers.Add(modifier);
            }
        }
        return modifiers;
    }

    /// Replaces the tracked controller-side modifier set with the snapshot stamped on an
    /// incoming message and injects whatever transitions that implies. Keeping the set in
    /// lockstep with every snapshot (rather than applying snapshots transiently) means one
    /// lost or missed message can't leave a modifier held here indefinitely.
    private void SyncRemoteSourceModifiers(IEnumerable<string>? modifiers)
    {
        remotePressedSourceModifierKeys.Clear();
        if (modifiers is not null)
        {
            remotePressedSourceModifierKeys.UnionWith(modifiers);
        }
        ApplyMappedRemoteModifierState(remotePressedSourceModifierKeys);
    }

    private void ApplyMappedRemoteModifierState(IEnumerable<string>? modifiers)
    {
        var desired = MapModifiers(modifiers);
        foreach (var modifier in ModifierKeyOrder)
        {
            SetRemoteModifierState(modifier, desired.Contains(modifier));
        }
    }

    private void SetRemoteModifierState(string modifier, bool down)
    {
        var key = WindowsModifierKey(modifier);
        if (key is null)
        {
            return;
        }

        if (down)
        {
            if (remotePressedModifierKeys.Add(modifier))
            {
                SendKeyboardInput((ushort)key.Value, keyUp: false);
            }
        }
        else if (remotePressedModifierKeys.Remove(modifier))
        {
            SendKeyboardInput((ushort)key.Value, keyUp: true);
        }
    }

    private void ReleaseRemoteModifiers()
    {
        foreach (var modifier in ModifierKeyOrder)
        {
            SetRemoteModifierState(modifier, down: false);
        }
        remotePressedSourceModifierKeys.Clear();
        remotePressedModifierKeys.Clear();
    }

    private HashSet<string> MapModifiers(IEnumerable<string>? modifiers)
    {
        var result = new HashSet<string>();
        if (modifiers is null)
        {
            return result;
        }
        foreach (var modifier in modifiers)
        {
            result.Add(config.KeyboardModifierMap.TargetFor(modifier));
        }
        return result;
    }

    private static bool ModifierMapsEqual(KeyboardModifierMap left, KeyboardModifierMap right)
    {
        return left.Shift == right.Shift &&
            left.Control == right.Control &&
            left.Alt == right.Alt &&
            left.Meta == right.Meta;
    }

    private void SendMouseInput(MouseFlags flags, int data, int dx = 0, int dy = 0)
    {
        if (TryInjectViaService(client => client.TryInjectMouse((uint)flags, data, dx, dy)))
        {
            return;
        }
        SendMouseInputLocal(flags, data, dx, dy);
    }

    private static void SendMouseInputLocal(MouseFlags flags, int data, int dx = 0, int dy = 0)
    {
        var input = new INPUT
        {
            type = InputType.Mouse,
            U = new InputUnion
            {
                mi = new MOUSEINPUT { dx = dx, dy = dy, dwFlags = flags, mouseData = data }
            }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    private static int ToAbsoluteMouseCoordinate(int value, int origin, int length)
    {
        return (int)Math.Round((value - origin) * 65535.0 / Math.Max(length - 1, 1));
    }

    private static bool IsModifierKey(string key)
    {
        return WindowsModifierKey(key) is not null;
    }

    private static Keys? WindowsModifierKey(string key)
    {
        return key switch
        {
            "Shift" => Keys.ShiftKey,
            "Control" => Keys.ControlKey,
            "Alt" => Keys.Menu,
            "Meta" => Keys.LWin,
            _ => null
        };
    }

    /// Keys whose hardware scan codes carry the E0 prefix. Injecting them without
    /// KEYEVENTF_EXTENDEDKEY makes Windows treat e.g. VK_LEFT as the numpad arrow, and with
    /// NumLock on the system wraps it in fake Shift events that terminals can't tell from a real
    /// Shift — an arrow key then reaches a console as Shift+Arrow (VT "ESC[1;2D"), which shells
    /// like adb's print as stray "2D"/"2C" instead of moving the cursor.
    private static readonly HashSet<Keys> ExtendedKeys =
    [
        Keys.Left, Keys.Right, Keys.Up, Keys.Down,
        Keys.Home, Keys.End, Keys.PageUp, Keys.PageDown,
        Keys.Insert, Keys.Delete, Keys.LWin, Keys.RWin,
        // Keypad divide and NumLock are the two keypad keys with E0-prefixed scan codes.
        Keys.Divide, Keys.NumLock
    ];

    private void SendKeyboardInput(ushort virtualKey, bool keyUp)
    {
        var extended = ExtendedKeys.Contains((Keys)virtualKey);
        if (TryInjectViaService(client => client.TryInjectKeyboard(virtualKey, keyUp, extended)))
        {
            return;
        }
        SendKeyboardInputLocal(virtualKey, keyUp);
    }

    /// Routes an injection through the secure-desktop input service when it is connected, so the
    /// event can reach the lock screen / UAC desktop that an in-process SendInput cannot touch.
    /// Returns false (and the caller falls back to in-process injection) whenever the service is
    /// not installed, still connecting, or faulted — i.e. the ordinary unlocked-desktop case.
    private bool TryInjectViaService(Func<WindowsInputServiceClient, bool> inject)
    {
        if (disposed)
        {
            return false;
        }

        WindowsInputServiceClient client;
        lock (inputServiceLock)
        {
            if (disposed)
            {
                return false;
            }
            client = inputServiceClient ??= new WindowsInputServiceClient();
        }

        try
        {
            return client.IsReady && inject(client);
        }
        catch (InvalidOperationException)
        {
            // The client was disposed concurrently; fall back to in-process injection.
            return false;
        }
    }

    private static void SendKeyboardInputLocal(ushort virtualKey, bool keyUp)
    {
        // Include the layout's scan code alongside the virtual key so injected presses look like
        // physical ones to consumers that read scan codes (consoles, games, RDP).
        var flags = keyUp ? KeyboardFlags.KeyUp : 0;
        if (ExtendedKeys.Contains((Keys)virtualKey))
        {
            flags |= KeyboardFlags.ExtendedKey;
        }
        var input = new INPUT
        {
            type = InputType.Keyboard,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = virtualKey,
                    wScan = (ushort)MapVirtualKey(virtualKey, MAPVK_VK_TO_VSC),
                    dwFlags = flags,
                    dwExtraInfo = SelfInjectionTag
                }
            }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    private static readonly Dictionary<Keys, string> WindowsKeyToCanonical = new()
    {
        [Keys.A] = "KeyA", [Keys.B] = "KeyB", [Keys.C] = "KeyC", [Keys.D] = "KeyD",
        [Keys.E] = "KeyE", [Keys.F] = "KeyF", [Keys.G] = "KeyG", [Keys.H] = "KeyH",
        [Keys.I] = "KeyI", [Keys.J] = "KeyJ", [Keys.K] = "KeyK", [Keys.L] = "KeyL",
        [Keys.M] = "KeyM", [Keys.N] = "KeyN", [Keys.O] = "KeyO", [Keys.P] = "KeyP",
        [Keys.Q] = "KeyQ", [Keys.R] = "KeyR", [Keys.S] = "KeyS", [Keys.T] = "KeyT",
        [Keys.U] = "KeyU", [Keys.V] = "KeyV", [Keys.W] = "KeyW", [Keys.X] = "KeyX",
        [Keys.Y] = "KeyY", [Keys.Z] = "KeyZ", [Keys.D0] = "Digit0", [Keys.D1] = "Digit1",
        [Keys.D2] = "Digit2", [Keys.D3] = "Digit3", [Keys.D4] = "Digit4", [Keys.D5] = "Digit5",
        [Keys.D6] = "Digit6", [Keys.D7] = "Digit7", [Keys.D8] = "Digit8", [Keys.D9] = "Digit9",
        [Keys.Space] = "Space", [Keys.Enter] = "Enter", [Keys.CapsLock] = "CapsLock",
        [Keys.Tab] = "Tab", [Keys.Escape] = "Escape", [Keys.Back] = "Backspace",
        [Keys.Delete] = "Delete", [Keys.Left] = "ArrowLeft", [Keys.Right] = "ArrowRight",
        [Keys.Up] = "ArrowUp", [Keys.Down] = "ArrowDown", [Keys.Home] = "Home",
        [Keys.End] = "End", [Keys.PageUp] = "PageUp", [Keys.PageDown] = "PageDown",
        [Keys.ShiftKey] = "Shift", [Keys.LShiftKey] = "Shift", [Keys.RShiftKey] = "Shift",
        [Keys.ControlKey] = "Control", [Keys.LControlKey] = "Control", [Keys.RControlKey] = "Control",
        [Keys.Menu] = "Alt", [Keys.LMenu] = "Alt", [Keys.RMenu] = "Alt",
        [Keys.LWin] = "Meta", [Keys.RWin] = "Meta", [Keys.OemMinus] = "Minus",
        [Keys.Oemplus] = "Equal", [Keys.OemOpenBrackets] = "BracketLeft",
        [Keys.OemCloseBrackets] = "BracketRight", [Keys.OemPipe] = "Backslash",
        [Keys.OemSemicolon] = "Semicolon", [Keys.OemQuotes] = "Quote",
        [Keys.Oemcomma] = "Comma", [Keys.OemPeriod] = "Period", [Keys.OemQuestion] = "Slash",
        [Keys.Oemtilde] = "Backquote", [Keys.F1] = "F1", [Keys.F2] = "F2",
        [Keys.F3] = "F3", [Keys.F4] = "F4", [Keys.F5] = "F5", [Keys.F6] = "F6",
        [Keys.F7] = "F7", [Keys.F8] = "F8", [Keys.F9] = "F9", [Keys.F10] = "F10",
        [Keys.F11] = "F11", [Keys.F12] = "F12",
        // Numeric keypad, so a peer's keypad reaches this machine as keypad keys rather than
        // being dropped. NumPad0-9 are the NumLock-on virtual keys; with NumLock off Windows
        // reports the navigation keys instead, which already map above.
        [Keys.NumPad0] = "Numpad0", [Keys.NumPad1] = "Numpad1", [Keys.NumPad2] = "Numpad2",
        [Keys.NumPad3] = "Numpad3", [Keys.NumPad4] = "Numpad4", [Keys.NumPad5] = "Numpad5",
        [Keys.NumPad6] = "Numpad6", [Keys.NumPad7] = "Numpad7", [Keys.NumPad8] = "Numpad8",
        [Keys.NumPad9] = "Numpad9", [Keys.Decimal] = "NumpadDecimal",
        [Keys.Multiply] = "NumpadMultiply", [Keys.Add] = "NumpadAdd",
        [Keys.Subtract] = "NumpadSubtract", [Keys.Divide] = "NumpadDivide",
        [Keys.NumLock] = "NumLock"
    };

    private static readonly Dictionary<string, Keys> CanonicalToWindowsKey = BuildReverseKeyMap();

    /// Ordered explicitly rather than relying on Dictionary enumeration, whose order is
    /// unspecified: several virtual keys share a canonical name and the winner must be chosen,
    /// not left to chance. Ascending key value picks the generic/left variant (ShiftKey over
    /// L/RShiftKey, LWin over RWin), matching what the enumeration happened to yield before.
    private static Dictionary<string, Keys> BuildReverseKeyMap()
    {
        var result = new Dictionary<string, Keys>();
        foreach (var pair in WindowsKeyToCanonical.OrderBy(pair => (int)pair.Key))
        {
            result.TryAdd(pair.Value, pair.Key);
        }
        return result;
    }

    private delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreateCursor(IntPtr hInst, int xHotSpot, int yHotSpot, int nWidth, int nHeight, byte[] pvANDPlane, byte[] pvXORPlane);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetSystemCursor(IntPtr hcur, int id);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    private const uint MAPVK_VK_TO_VSC = 0;

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostThreadMessage(uint idThread, uint msg, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private enum InputType : uint
    {
        Mouse = 0,
        Keyboard = 1
    }

    [Flags]
    private enum MouseFlags : uint
    {
        Move = 0x0001,
        LeftDown = 0x0002,
        LeftUp = 0x0004,
        RightDown = 0x0008,
        RightUp = 0x0010,
        MiddleDown = 0x0020,
        MiddleUp = 0x0040,
        XDown = 0x0080,
        XUp = 0x0100,
        Wheel = 0x0800,
        HWheel = 0x1000,
        VirtualDesk = 0x4000,
        Absolute = 0x8000
    }

    [Flags]
    private enum KeyboardFlags : uint
    {
        ExtendedKey = 0x0001,
        KeyUp = 0x0002
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public InputType type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public MOUSEINPUT mi;

        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public MouseFlags dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public KeyboardFlags dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
}
