using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ClipboardSyncInputService;

/// Injects synthesized mouse and keyboard events into whichever desktop is currently
/// receiving input.
///
/// The service launches this agent on winsta0\Default, but SendInput only reaches the
/// desktop the calling thread is attached to. When the workstation is locked (or a UAC
/// prompt is showing) the active input desktop switches to the Winlogon secure desktop,
/// so before every event we follow the current input desktop with SetThreadDesktop. That
/// is what lets an injected keystroke land in the lock-screen password box; running as
/// LocalSystem is what grants the agent access to the secure desktop's DACL.
///
/// All members are called from the single agent connection thread, so no locking is needed.
internal sealed class WindowsInputInjector : IDisposable
{
    private const uint InputMouse = 0;
    private const uint InputKeyboard = 1;

    // Mirrors InputSharingCoordinator.SelfInjectionTag in the tray app: marks our
    // injected keyboard events so its hook skips only clipboardSync's own injections
    // and still forwards keys synthesized by other software (remappers, on-screen
    // keyboards). Keep the two values identical.
    private static readonly UIntPtr SelfInjectionTag = (UIntPtr)0x43530A11;

    private const uint KeyEventExtendedKey = 0x0001;
    private const uint KeyEventKeyUp = 0x0002;

    // MOUSEINPUT flags we need to reason about for releasing held buttons.
    private const uint MouseLeftDown = 0x0002;
    private const uint MouseLeftUp = 0x0004;
    private const uint MouseRightDown = 0x0008;
    private const uint MouseRightUp = 0x0010;
    private const uint MouseMiddleDown = 0x0020;
    private const uint MouseMiddleUp = 0x0040;

    private readonly Dictionary<ushort, bool> heldKeys = new();
    private uint heldMouseButtons;

    private IntPtr currentDesktop = IntPtr.Zero;
    private string? currentDesktopName;
    private int lastSendError;

    internal void InjectMouse(uint flags, int data, int dx, int dy)
    {
        EnsureInputDesktop();
        var input = new NativeMethods.Input
        {
            Type = InputMouse,
            Data = new NativeMethods.InputUnion
            {
                Mouse = new NativeMethods.MouseInput
                {
                    X = dx,
                    Y = dy,
                    MouseData = unchecked((uint)data),
                    Flags = flags
                }
            }
        };
        if (Send(input))
        {
            TrackMouseButtons(flags);
        }
    }

    internal void InjectKeyboard(ushort virtualKey, bool keyUp, bool extendedKey)
    {
        EnsureInputDesktop();
        var flags = 0u;
        if (extendedKey)
        {
            flags |= KeyEventExtendedKey;
        }
        if (keyUp)
        {
            flags |= KeyEventKeyUp;
        }

        var input = new NativeMethods.Input
        {
            Type = InputKeyboard,
            Data = new NativeMethods.InputUnion
            {
                Keyboard = new NativeMethods.KeyboardInput
                {
                    VirtualKey = virtualKey,
                    // Carry the scan code so consumers that read it (consoles, RDP, games) see a
                    // press that looks physical, matching the in-process injection path.
                    ScanCode = (ushort)NativeMethods.MapVirtualKey(virtualKey, NativeMethods.MapvkVkToVsc),
                    Flags = flags,
                    ExtraInfo = SelfInjectionTag
                }
            }
        };
        if (Send(input))
        {
            if (keyUp)
            {
                heldKeys.Remove(virtualKey);
            }
            else
            {
                heldKeys[virtualKey] = extendedKey;
            }
        }
    }

    /// Releases every key and mouse button this injector still has pressed. Called when a
    /// client disconnects so a dropped connection can't leave a modifier stuck down on the
    /// secure desktop, where the user has no way to release it.
    internal void ReleaseAll()
    {
        if (heldKeys.Count > 0)
        {
            foreach (var held in new List<KeyValuePair<ushort, bool>>(heldKeys))
            {
                InjectKeyboard(held.Key, keyUp: true, held.Value);
            }
            heldKeys.Clear();
        }

        if ((heldMouseButtons & MouseLeftDown) != 0)
        {
            InjectMouse(MouseLeftUp, 0, 0, 0);
        }
        if ((heldMouseButtons & MouseRightDown) != 0)
        {
            InjectMouse(MouseRightUp, 0, 0, 0);
        }
        if ((heldMouseButtons & MouseMiddleDown) != 0)
        {
            InjectMouse(MouseMiddleUp, 0, 0, 0);
        }
        heldMouseButtons = 0;
    }

    private void TrackMouseButtons(uint flags)
    {
        if ((flags & MouseLeftDown) != 0)
        {
            heldMouseButtons |= MouseLeftDown;
        }
        if ((flags & MouseLeftUp) != 0)
        {
            heldMouseButtons &= ~MouseLeftDown;
        }
        if ((flags & MouseRightDown) != 0)
        {
            heldMouseButtons |= MouseRightDown;
        }
        if ((flags & MouseRightUp) != 0)
        {
            heldMouseButtons &= ~MouseRightDown;
        }
        if ((flags & MouseMiddleDown) != 0)
        {
            heldMouseButtons |= MouseMiddleDown;
        }
        if ((flags & MouseMiddleUp) != 0)
        {
            heldMouseButtons &= ~MouseMiddleDown;
        }
    }

    private bool Send(NativeMethods.Input input)
    {
        var inputs = new[] { input };
        if (NativeMethods.SendInput(1, inputs, Marshal.SizeOf<NativeMethods.Input>()) == 1)
        {
            if (lastSendError != 0)
            {
                ServiceLog.Write("input injection recovered");
                lastSendError = 0;
            }
            return true;
        }

        // SendInput fails when the thread is not on the current input desktop, or when UIPI
        // blocks the target. Log each distinct failure once instead of per-event so a persistent
        // problem is visible without flooding the log at input rates.
        var error = Marshal.GetLastWin32Error();
        if (error != lastSendError)
        {
            lastSendError = error;
            ServiceLog.Write($"SendInput failed on desktop '{currentDesktopName}'; win32={error}");
        }
        return false;
    }

    private void EnsureInputDesktop()
    {
        var desktop = NativeMethods.OpenInputDesktop(0, false, NativeMethods.MaximumAllowed);
        if (desktop == IntPtr.Zero)
        {
            // Transient during a desktop switch; keep the current attachment and let SendInput try.
            return;
        }

        var name = GetDesktopName(desktop);
        if (currentDesktop != IntPtr.Zero &&
            string.Equals(name, currentDesktopName, StringComparison.OrdinalIgnoreCase))
        {
            NativeMethods.CloseDesktop(desktop);
            return;
        }

        if (!NativeMethods.SetThreadDesktop(desktop))
        {
            var error = Marshal.GetLastWin32Error();
            NativeMethods.CloseDesktop(desktop);
            if (error != lastSendError)
            {
                lastSendError = error;
                ServiceLog.Write($"SetThreadDesktop to '{name}' failed; win32={error}");
            }
            return;
        }

        var previous = currentDesktop;
        currentDesktop = desktop;
        currentDesktopName = name;
        lastSendError = 0;
        if (previous != IntPtr.Zero)
        {
            NativeMethods.CloseDesktop(previous);
        }
        ServiceLog.Write($"input injection following desktop '{name}'");
    }

    private static string GetDesktopName(IntPtr desktop)
    {
        uint needed = 0;
        NativeMethods.GetUserObjectInformation(desktop, NativeMethods.UoiName, IntPtr.Zero, 0, out needed);
        if (needed == 0)
        {
            return string.Empty;
        }

        var buffer = Marshal.AllocHGlobal((int)needed);
        try
        {
            if (!NativeMethods.GetUserObjectInformation(desktop, NativeMethods.UoiName, buffer, needed, out _))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetUserObjectInformation(UOI_NAME) failed.");
            }
            return Marshal.PtrToStringUni(buffer) ?? string.Empty;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public void Dispose()
    {
        if (currentDesktop != IntPtr.Zero)
        {
            NativeMethods.CloseDesktop(currentDesktop);
            currentDesktop = IntPtr.Zero;
        }
    }
}
