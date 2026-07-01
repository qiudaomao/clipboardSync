using System;
using System.Collections.Generic;
using System.Drawing;
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
    private const int WM_MOUSEHWHEEL = 0x020E;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const uint LLMHF_INJECTED = 0x00000001;
    private const uint LLKHF_INJECTED = 0x00000010;
    private static readonly string[] ModifierKeyOrder = ["Shift", "Control", "Alt", "Meta"];
    private static readonly TimeSpan RemoteMouseMoveInterval = TimeSpan.FromMilliseconds(8);

    private readonly string deviceId;
    private readonly LowLevelProc mouseProc;
    private readonly LowLevelProc keyboardProc;
    private readonly object remoteMouseMoveLock = new();
    private AppConfig config = new();
    private SyncMode role = SyncMode.Client;
    private int peerCount;
    private string? remoteDeviceId;
    private ScreenMetrics? remoteScreen;
    private bool? remoteInputEnabled;
    private bool remoteActive;
    private bool receivingRemote;
    private readonly HashSet<string> pressedModifierKeys = [];
    private readonly HashSet<string> remotePressedSourceModifierKeys = [];
    private readonly HashSet<string> remotePressedModifierKeys = [];
    private (double X, double Y)? pendingRemoteMouseMove;
    private System.Threading.Timer? pendingRemoteMouseMoveTimer;
    private DateTimeOffset lastRemoteMouseMoveAt = DateTimeOffset.MinValue;
    private PointF remotePosition;
    private IntPtr mouseHook;
    private IntPtr keyboardHook;
    private Point localAnchor;

    public event Action<InputMessage>? MessageReady;
    public event Action<string>? StatusChanged;

    public InputSharingCoordinator(string deviceId)
    {
        this.deviceId = deviceId;
        mouseProc = MouseHookCallback;
        keyboardProc = KeyboardHookCallback;
    }

    public void Start()
    {
        UpdateInputState();
    }

    public void Update(AppConfig nextConfig, SyncMode nextRole, int nextPeerCount)
    {
        var shouldReleaseRemoteModifiers = !ModifierMapsEqual(config.KeyboardModifierMap, nextConfig.KeyboardModifierMap);
        config = nextConfig.Clone();
        role = nextRole;
        peerCount = nextPeerCount;
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
            CurrentScreenMetrics(),
            config.InputSharingEnabled && peerCount > 0,
            EffectiveControlDeviceId,
            config.PeerEdge);
    }

    public void Handle(InputMessage message)
    {
        if (message.Origin == deviceId || (message.Target is not null && message.Target != deviceId))
        {
            return;
        }

        if (message.Kind == "hello")
        {
            if (ShouldUseAsRemotePeer(message))
            {
                remoteDeviceId = message.Origin;
                remoteScreen = message.Screen;
                remoteInputEnabled = message.Enabled;
            }
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
        ReleaseRemoteModifiers();
        SendPressedModifierKeyUps();
        ClearPendingRemoteMouseMove();
        RemoveHooks();
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

    private bool ShouldUseAsRemotePeer(InputMessage message)
    {
        if (IsController)
        {
            if (role == SyncMode.Client)
            {
                return message.Role == "server";
            }

            return message.Role == "client" &&
                (remoteDeviceId is null || remoteDeviceId == message.Origin || peerCount <= 1);
        }

        return message.Origin == EffectiveControlDeviceId;
    }

    private void UpdateInputState()
    {
        if (IsController)
        {
            EnsureHooks();
        }
        else
        {
            if (remoteActive)
            {
                SendPressedModifierKeyUps();
                SendCapture("end");
            }
            RemoveHooks();
            remoteActive = false;
            pressedModifierKeys.Clear();
        }
        if (!CanReceiveRemoteInput)
        {
            ReleaseRemoteModifiers();
            receivingRemote = false;
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
                : IsController && remoteInputEnabled == false
                    ? AppText.Text("input.peerDisabled")
                    : IsController && (remoteScreen is null || remoteInputEnabled is null)
                    ? AppText.Text("input.waitingPeerScreen")
                    : IsController
                        ? AppText.Format("input.controllingPeer", AppText.EdgeTitle(config.PeerEdge))
                        : AppText.Text("input.receiving");
        StatusChanged?.Invoke(status);
    }

    private void EnsureHooks()
    {
        if (mouseHook == IntPtr.Zero)
        {
            mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, IntPtr.Zero, 0);
        }
        if (keyboardHook == IntPtr.Zero)
        {
            keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, IntPtr.Zero, 0);
        }
    }

    private void RemoveHooks()
    {
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

        if (!remoteActive)
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
        if (nCode < HC_ACTION || !IsController || !remoteActive)
        {
            return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
        }

        var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        if ((data.flags & LLKHF_INJECTED) != 0)
        {
            return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
        }

        var message = wParam.ToInt32();
        var action = message == WM_KEYUP || message == WM_SYSKEYUP ? "up" : "down";
        if (message == WM_KEYDOWN || message == WM_KEYUP || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP)
        {
            SendKey((Keys)data.vkCode, action);
            return (IntPtr)1;
        }

        return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
    }

    private bool HandleLocalMouseMove(POINT point)
    {
        if (!remoteActive)
        {
            if (!ShouldStartCapture(point) || remoteScreen is null)
            {
                return false;
            }

            remoteActive = true;
            pressedModifierKeys.Clear();
            remotePosition = EntryPosition(remoteScreen, config.PeerEdge, point);
            localAnchor = CenterOfScreenContaining(point);
            SendCapture("start");
            SendMouseMove();
            SetCursorPos(localAnchor.X, localAnchor.Y);
            UpdateStatus();
            return true;
        }

        var dx = point.X - localAnchor.X;
        var dy = point.Y - localAnchor.Y;
        remotePosition.X += dx;
        remotePosition.Y += dy;

        if (ShouldEndCapture(dx, dy))
        {
            SendPressedModifierKeyUps();
            SendCapture("end");
            remoteActive = false;
            pressedModifierKeys.Clear();
            var returnPoint = ReturnPoint();
            SetCursorPos(returnPoint.X, returnPoint.Y);
            UpdateStatus();
            return true;
        }

        if (remoteScreen is not null)
        {
            remotePosition.X = (float)Math.Clamp(remotePosition.X, 0, Math.Max(remoteScreen.Width - 1, 0));
            remotePosition.Y = (float)Math.Clamp(remotePosition.Y, 0, Math.Max(remoteScreen.Height - 1, 0));
        }

        if (dx != 0 || dy != 0)
        {
            SendMouseMove();
            SetCursorPos(localAnchor.X, localAnchor.Y);
        }
        return true;
    }

    private bool ShouldStartCapture(POINT point)
    {
        if (remoteScreen is null || remoteInputEnabled != true)
        {
            return false;
        }

        var bounds = DesktopBounds();
        const int threshold = 2;
        return config.PeerEdge switch
        {
            ScreenEdge.Left => point.X <= bounds.Left + threshold,
            ScreenEdge.Top => point.Y <= bounds.Top + threshold,
            ScreenEdge.Bottom => point.Y >= bounds.Bottom - threshold,
            _ => point.X >= bounds.Right - threshold
        };
    }

    private bool ShouldEndCapture(int dx, int dy)
    {
        if (remoteScreen is null)
        {
            return true;
        }

        return config.PeerEdge switch
        {
            ScreenEdge.Left => remotePosition.X >= remoteScreen.Width - 1 && dx > 0,
            ScreenEdge.Top => remotePosition.Y >= remoteScreen.Height - 1 && dy > 0,
            ScreenEdge.Bottom => remotePosition.Y <= 0 && dy < 0,
            _ => remotePosition.X <= 0 && dx < 0
        };
    }

    private PointF EntryPosition(ScreenMetrics screen, ScreenEdge edge, POINT point)
    {
        var bounds = DesktopBounds();
        var normalizedX = (point.X - bounds.Left) / Math.Max((double)bounds.Width, 1);
        var normalizedY = (point.Y - bounds.Top) / Math.Max((double)bounds.Height, 1);
        return edge switch
        {
            ScreenEdge.Left => new PointF((float)Math.Max(screen.Width - 1, 0), (float)(normalizedY * screen.Height)),
            ScreenEdge.Top => new PointF((float)(normalizedX * screen.Width), (float)Math.Max(screen.Height - 1, 0)),
            ScreenEdge.Bottom => new PointF((float)(normalizedX * screen.Width), 0),
            _ => new PointF(0, (float)(normalizedY * screen.Height))
        };
    }

    private Point ReturnPoint()
    {
        var bounds = DesktopBounds();
        return config.PeerEdge switch
        {
            ScreenEdge.Left => new Point(bounds.Left + 2, bounds.Top + (int)(bounds.Height * NormalizedRemoteY())),
            ScreenEdge.Top => new Point(bounds.Left + (int)(bounds.Width * NormalizedRemoteX()), bounds.Top + 2),
            ScreenEdge.Bottom => new Point(bounds.Left + (int)(bounds.Width * NormalizedRemoteX()), bounds.Bottom - 2),
            _ => new Point(bounds.Right - 2, bounds.Top + (int)(bounds.Height * NormalizedRemoteY()))
        };
    }

    private void SendCapture(string action)
    {
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = remoteDeviceId,
            Kind = "capture",
            Capture = new InputCapturePayload
            {
                Action = action,
                Edge = InputSharingWire.EdgeValue(config.PeerEdge),
                NormalizedX = NormalizedRemoteX(),
                NormalizedY = NormalizedRemoteY()
            },
            SentAt = Now()
        });
    }

    private void SendMouseMove()
    {
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = remoteDeviceId,
            Kind = "mouseMove",
            Mouse = new InputMousePayload
            {
                Action = "move",
                NormalizedX = NormalizedRemoteX(),
                NormalizedY = NormalizedRemoteY()
            },
            SentAt = Now()
        });
    }

    private void SendMouseButton(int message)
    {
        var button = message == WM_RBUTTONDOWN || message == WM_RBUTTONUP ? "right" :
            message == WM_MBUTTONDOWN || message == WM_MBUTTONUP ? "middle" : "left";
        var action = message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN || message == WM_MBUTTONDOWN ? "down" : "up";
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = remoteDeviceId,
            Kind = "mouseButton",
            Mouse = new InputMousePayload
            {
                Action = action,
                Button = button,
                NormalizedX = NormalizedRemoteX(),
                NormalizedY = NormalizedRemoteY()
            },
            SentAt = Now()
        });
    }

    private void SendMouseWheel(double deltaX, double deltaY)
    {
        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = remoteDeviceId,
            Kind = "mouseWheel",
            Mouse = new InputMousePayload
            {
                Action = "wheel",
                NormalizedX = NormalizedRemoteX(),
                NormalizedY = NormalizedRemoteY(),
                DeltaX = deltaX,
                DeltaY = deltaY
            },
            SentAt = Now()
        });
    }

    private void SendKey(Keys keyCode, string action)
    {
        if (!WindowsKeyToCanonical.TryGetValue(keyCode, out var key))
        {
            return;
        }
        UpdatePressedModifiers(key, action);

        MessageReady?.Invoke(new InputMessage
        {
            Type = "input",
            Origin = deviceId,
            Target = remoteDeviceId,
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
        foreach (var modifier in ModifierKeyOrder)
        {
            if (pressedModifierKeys.Contains(modifier))
            {
                MessageReady?.Invoke(new InputMessage
                {
                    Type = "input",
                    Origin = deviceId,
                    Target = remoteDeviceId,
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
            receivingRemote = true;
            ClearPendingRemoteMouseMove();
            ReleaseRemoteModifiers();
            WarpTo(capture.NormalizedX, capture.NormalizedY);
        }
        else if (capture.Action == "end")
        {
            ClearPendingRemoteMouseMove();
            ReleaseRemoteModifiers();
            receivingRemote = false;
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
        if (mouse.NormalizedX is not null && mouse.NormalizedY is not null)
        {
            WarpTo(mouse.NormalizedX.Value, mouse.NormalizedY.Value);
        }

        var flags = mouse.Button == "right"
            ? mouse.Action == "down" ? MouseFlags.RightDown : MouseFlags.RightUp
            : mouse.Button == "middle"
                ? mouse.Action == "down" ? MouseFlags.MiddleDown : MouseFlags.MiddleUp
                : mouse.Action == "down" ? MouseFlags.LeftDown : MouseFlags.LeftUp;
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
            if (key.Action == "down")
            {
                remotePressedSourceModifierKeys.Add(key.Key);
            }
            else
            {
                remotePressedSourceModifierKeys.Remove(key.Key);
            }
            ApplyMappedRemoteModifierState(remotePressedSourceModifierKeys);
            return;
        }

        if (!CanonicalToWindowsKey.TryGetValue(key.Key, out var virtualKey))
        {
            return;
        }

        ApplyMappedRemoteModifierState(key.Modifiers);
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

    private static void WarpTo(double normalizedX, double normalizedY)
    {
        var point = PointFor(normalizedX, normalizedY);
        var bounds = DesktopBounds();
        SendMouseInput(
            MouseFlags.Move | MouseFlags.Absolute | MouseFlags.VirtualDesk,
            0,
            ToAbsoluteMouseCoordinate(point.X, bounds.Left, bounds.Width),
            ToAbsoluteMouseCoordinate(point.Y, bounds.Top, bounds.Height));
    }

    private static Point PointFor(double normalizedX, double normalizedY)
    {
        var bounds = DesktopBounds();
        return new Point(
            bounds.Left + (int)(Math.Clamp(normalizedX, 0, 1) * Math.Max(bounds.Width - 1, 0)),
            bounds.Top + (int)(Math.Clamp(normalizedY, 0, 1) * Math.Max(bounds.Height - 1, 0)));
    }

    private double NormalizedRemoteX()
    {
        return remoteScreen is null ? 0 : Math.Clamp(remotePosition.X / Math.Max(remoteScreen.Width, 1), 0, 1);
    }

    private double NormalizedRemoteY()
    {
        return remoteScreen is null ? 0 : Math.Clamp(remotePosition.Y / Math.Max(remoteScreen.Height, 1), 0, 1);
    }

    private static ScreenMetrics CurrentScreenMetrics()
    {
        var bounds = DesktopBounds();
        return new ScreenMetrics { Width = bounds.Width, Height = bounds.Height, Scale = 1 };
    }

    private static Rectangle DesktopBounds()
    {
        return SystemInformation.VirtualScreen;
    }

    private static Point CenterOfScreenContaining(POINT point)
    {
        var bounds = Screen.FromPoint(new Point(point.X, point.Y)).Bounds;
        return new Point(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
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

    private static void SendMouseInput(MouseFlags flags, int data, int dx = 0, int dy = 0)
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

    private static void SendKeyboardInput(ushort virtualKey, bool keyUp)
    {
        var input = new INPUT
        {
            type = InputType.Keyboard,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = virtualKey,
                    dwFlags = keyUp ? KeyboardFlags.KeyUp : 0
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
        [Keys.Space] = "Space", [Keys.Enter] = "Enter",
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
        [Keys.F11] = "F11", [Keys.F12] = "F12"
    };

    private static readonly Dictionary<string, Keys> CanonicalToWindowsKey = BuildReverseKeyMap();

    private static Dictionary<string, Keys> BuildReverseKeyMap()
    {
        var result = new Dictionary<string, Keys>();
        foreach (var pair in WindowsKeyToCanonical)
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
        Wheel = 0x0800,
        HWheel = 0x1000,
        VirtualDesk = 0x4000,
        Absolute = 0x8000
    }

    [Flags]
    private enum KeyboardFlags : uint
    {
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
