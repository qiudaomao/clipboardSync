stage1:
- Native macOS client in Swift, running from the menu bar only.
- Native Windows client in C#, running from the system tray only.
- Each app can run in server mode or client mode.
- WebSocket is the sync transport.
- Text clipboard changes are captured locally and sent to the peer.
- Received text overwrites the local system clipboard.
- Configurable mode, server host, and port.
- Visible connection/status text in the tray/menu.
- Scope is text only.

stage2:
clipboard history for latest 10 items, accept image and file

stage3:
shows a different icon when receive a clipboard updates

current implementation focus:
- Shared JSON protocol documented in docs/protocol.md.
- macOS Xcode app project under mac/.
- Windows .NET WinForms project under win/ClipboardSyncWin/.
