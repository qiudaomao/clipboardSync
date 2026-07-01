# Clipboard Sync

Native clipboard sync over WebSocket.

## Stage 1 Goal

The first milestone is a small native app on each platform:

- macOS: Swift menu bar app.
- Windows: C# system tray app.
- Either side can run as a WebSocket server or client.
- Local text clipboard changes are sent to connected peers.
- Remote text overwrites the local system clipboard.
- Mode, host, and port are configurable in the tray/menu UI.
- The UI shows a simple status string.

Stage 1 intentionally excludes clipboard history, images, files, encryption, and receive-state icon changes. Those are later stages.

## Project Layout

- `docs/protocol.md`: shared WebSocket message contract.
- `mac/`: Xcode app project and Swift source for the macOS menu bar app.
- `win/ClipboardSyncWin/`: .NET WinForms Windows tray app.

## Run macOS

```sh
xcodebuild \
  -project mac/ClipboardSyncMac.xcodeproj \
  -scheme ClipboardSyncMac \
  -configuration Release \
  -derivedDataPath mac/DerivedData \
  build

open mac/DerivedData/Build/Products/Release/ClipboardSyncMac.app
```

The app appears in the menu bar. Configure one machine as `Server`, then configure the other as `Client` with the server host and port.
In server mode the settings window shows the LAN WebSocket address, such as `ws://192.168.1.20:8787/`. Use that LAN IP on the client; `127.0.0.1` only points to the same machine and is rejected for client mode.
Text and image clipboard changes sync automatically. File clipboard contents are not sent by the poller; copy files in Finder, then click `Send Files from Clipboard` from the menu bar. Each file must be 10 MB or smaller.
The `History` submenu keeps the latest 10 clipboard items and can restore/resend an item.
Set the same sync password on every device before starting. Clipboard payloads are encrypted with AES-GCM over the existing WebSocket connection.
Input Sharing is off by default. Enable it from Settings or the menu, choose `Server -> Client` or `Client -> Server`, and set the peer position edge. macOS needs Accessibility/Input Monitoring permission before keyboard and mouse sharing can run.

The Swift Package in `mac/Package.swift` is kept as a lightweight compiler check, but the Xcode project is the native app bundle build.

## Run Windows

```powershell
dotnet run --project win\ClipboardSyncWin\ClipboardSyncWin.csproj
```

The app appears in the system tray. Configure one machine as `Server`, then configure the other as `Client` with the server host and port.
The Windows server also binds to the LAN and shows a `ws://LAN-IP:port/` address in the tray status/config form. Use that LAN IP on clients; loopback hosts such as `127.0.0.1` and `localhost` are rejected for client mode.
Text and image clipboard changes sync automatically. File clipboard contents are only sent from `Send Files from Clipboard` in the tray menu, with a 10 MB limit per file.
The `History` submenu keeps the latest 10 clipboard items and can restore/resend an item.
Set the same sync password on every device before starting. Clipboard payloads are encrypted with AES-GCM over the existing WebSocket connection.
Input Sharing is off by default. Enable it from Configure or the tray menu, choose `Server -> Client` or `Client -> Server`, and set the peer position edge.

## Notes

The WebSocket endpoint is still plain `ws://`, but clipboard and input-sharing message bodies are encrypted and authenticated with the configured shared password.
Input sharing v1 supports one peer and treats all local monitors as one virtual desktop.
