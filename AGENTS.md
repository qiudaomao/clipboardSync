# Project Working Agreement

## Engineering rules

1. Fail fast. Do not swallow errors or add fallback behavior that hides the real failure.
2. Fix root causes rather than layering narrow patches over symptoms.
3. Keep critical paths observable with useful logs and actionable status messages.
4. Design connection, transfer, input-sharing, and port-forwarding flows for debugging and traceability.
5. Keep this file and the README aligned with material product or architecture changes.

## Product and UX source of truth

- Clipboard Sync is an MIT-licensed open-source project. New release artifacts and canonical update feeds are published from `qiudaomao/clipboardSync`; `qiudaomao/clipboardSyncRelease` remains online as the legacy update channel and jsDelivr binary mirror. During the two-release migration window that begins with v0.2.2, publish matching releases and feed entries to both repositories so existing installations can transition to the canonical project.
- Clipboard Sync is a native macOS menu-bar, Windows system-tray, and Linux Qt 6 application. Linux supports encrypted text/image sync, explicit clipboard-file transfer, port forwarding, and input sharing with the shared screen layout on X11 sessions. On Wayland, being controlled (remote input injection) works through the wlroots virtual pointer/keyboard protocols where the compositor offers them (Hyprland, Sway, ...); controlling other devices (edge-triggered input capture via hyprland_input_capture_v1 + libei) and Auto-control activity monitoring (Hyprland IPC cursor polling) work on Hyprland. Missing compositor support must fail with an explicit reason, never be presented as available.
- The primary user task is copying and pasting text, images, and explicitly selected clipboard files between trusted devices.
- User-facing work modes are **Server** and **Child Device**, with Server shown first. Mode is selected only in Settings and is the single source of truth.
- First launch must open connection setup. Missing configuration and disconnected states must expose an action; they must not exist only as passive status text.
- Do not expose a general Restart action. The main menu may pause/resume sync; recovery-specific reconnect remains attached to connection status.
- **More Features** contains Port Forward, Prevent System Sleep, and Launch at Login. Prevent System Sleep blocks both system idle sleep and display idle blanking, shows its live state and remaining time as the first submenu row, followed by Do not disable, Forever, 1 hour, 2 hour, 4 hour, 6 hour, 8 hour, and Time Plan, then an Edit Time Plan row; timed choices retain an absolute deadline across relaunches and explicit sleep/wake cycles. The choices are mutually exclusive. Its independent low-battery option pauses the native inhibitors only while the machine is on battery power below 20%, then resumes the original selection on AC power or battery recovery without extending a timed deadline. Explicit user sleep and laptop-lid actions remain under operating-system control.
- **Time Plan** is a weekly schedule of 7 day rows by 24 hour columns, in the device's local time, where a blue block prevents sleep and a gray block allows it. Day 0 is Monday. Clicking a block switches it and dragging switches a rectangle of blocks to the value opposite of the pressed block; edits save as they are applied, like the screen layout. The schedule persists as a 168-character string of "0"/"1" so the stored value is identical on all three platforms. Selecting Time Plan with an empty schedule opens the editor rather than leaving a mode selected that does nothing. While Time Plan is selected the inhibitor is reconciled on a poll, so a clock change, a time-zone change, or a sleep/wake cycle that skips an hour boundary still converges.
- File sending stays clipboard-based. Do not add a separate file picker without an explicit product decision.
- Received-file notifications must explain that the files are on the clipboard and can be pasted at the desired location.
- Port-forward edits are transactional: all row edits, including enable/disable, commit together on Apply or Save. Apply commits the draft and leaves the panel open so rule status can be checked; Save commits and closes. Remote updates must not silently discard a local draft.
- Screen layout changes save as they are applied. The UI must identify the local device, avoid exposing raw device IDs, and confirm permanent forget actions.
- Modifier remapping is labeled **Receive Key Mapping** because it is applied by the device receiving remote keyboard input.
- **Control Device** offers a fixed device or **Auto**. In Auto mode, the server elects the device
  that most recently produced a genuine local physical mouse or touchpad event; injected/relayed
  events must never elect a controller. Keyboard activity must not switch control, so a mouse on
  one device and a keyboard on another remain usable at the same time. The menu shows Auto's
  current elected device, and the server broadcasts every accepted election.
- Windows must expose update history directly from the tray menu; users should not have to wait for an available-update dialog to discover previous releases.
- Preserve platform-native controls and conventions while keeping terminology, information hierarchy, and state semantics consistent across macOS and Windows.
