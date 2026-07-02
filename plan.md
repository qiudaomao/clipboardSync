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
- Clipboard history for latest 10 unique items.
- Text and image clipboard changes sync automatically.
- File clipboard changes are explicit: user clicks `Send Files from Clipboard`.
- File and image payloads are capped at 10 MB raw bytes per item.

stage3:
- encryption between server and clients
- a password settings

stage4:
- mouse and keyboard sharing
- works similar to synergy but still use current websocket
- read screen size and maintain layout
- auto mouse cross over server and client

stage5:
- auto update support
- macOS: Sparkle 2 framework, appcast-based
- Windows: NetSparkle (Sparkle-equivalent for .NET), reusing an appcast-style feed to keep update-server logic similar across platforms
- macOS implemented first, Windows to follow
- release artifacts (zipped app builds, appcast.xml) are hosted in a separate repo, clipboardSyncRelease (git@github.com:qiudaomao/clipboardSyncRelease.git), not in this repo

current implementation focus:
- Shared JSON protocol documented in docs/protocol.md.
- macOS Xcode app project under mac/.
- Windows .NET WinForms project under win/ClipboardSyncWin/.
- Sparkle 2 auto-update integration for macOS (stage5).
