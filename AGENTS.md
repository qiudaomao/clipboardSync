# Project Working Agreement

## Engineering rules

1. Fail fast. Do not swallow errors or add fallback behavior that hides the real failure.
2. Fix root causes rather than layering narrow patches over symptoms.
3. Keep critical paths observable with useful logs and actionable status messages.
4. Design connection, transfer, input-sharing, and port-forwarding flows for debugging and traceability.
5. Keep this file and the README aligned with material product or architecture changes.

## Product and UX source of truth

- Clipboard Sync is a native macOS menu-bar, Windows system-tray, and Linux Qt 6 application. Linux supports encrypted text/image sync, explicit clipboard-file transfer, port forwarding, and input sharing with the shared screen layout on X11 sessions; on Wayland, input sharing is capability-detected but not available and must not be presented as available.
- The primary user task is copying and pasting text, images, and explicitly selected clipboard files between trusted devices.
- User-facing work modes are **Server** and **Child Device**, with Server shown first. Mode is selected only in Settings and is the single source of truth.
- First launch must open connection setup. Missing configuration and disconnected states must expose an action; they must not exist only as passive status text.
- Do not expose a general Restart action. The main menu may pause/resume sync; recovery-specific reconnect remains attached to connection status.
- **More Features** contains Port Forward, Prevent System Sleep, and Launch at Login. Prevent System Sleep blocks both system idle sleep and display idle blanking, shows its live state and remaining time as the first submenu row, followed by Do not disable, Forever, 1 hour, 2 hour, 4 hour, 6 hour, and 8 hour; timed choices retain an absolute deadline across relaunches and explicit sleep/wake cycles. Its independent low-battery option pauses the native inhibitors only while the machine is on battery power below 20%, then resumes the original selection on AC power or battery recovery without extending a timed deadline. Explicit user sleep and laptop-lid actions remain under operating-system control.
- File sending stays clipboard-based. Do not add a separate file picker without an explicit product decision.
- Received-file notifications must explain that the files are on the clipboard and can be pasted at the desired location.
- Port-forward edits are transactional: all row edits, including enable/disable, apply together on Save. Remote updates must not silently discard a local draft.
- Screen layout changes save as they are applied. The UI must identify the local device, avoid exposing raw device IDs, and confirm permanent forget actions.
- Modifier remapping is labeled **Receive Key Mapping** because it is applied by the device receiving remote keyboard input.
- Windows must expose update history directly from the tray menu; users should not have to wait for an available-update dialog to discover previous releases.
- Preserve platform-native controls and conventions while keeping terminology, information hierarchy, and state semantics consistent across macOS and Windows.
