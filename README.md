# Clipboard Sync

Native text clipboard sync over WebSocket.

## Stage 1 Goal

The first milestone is a small native app on each platform:

- macOS: Swift menu bar app.
- Windows: C# system tray app.
- Either side can run as a WebSocket server or client.
- Local text clipboard changes are sent to connected peers.
- Remote text overwrites the local system clipboard.
- Mode, host, and port are configurable in the tray/menu UI.
- The UI shows a simple status string.

Stage 1 intentionally excludes clipboard history, images, files, and receive-state icon changes. Those are Stage 2 and Stage 3.

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

The Swift Package in `mac/Package.swift` is kept as a lightweight compiler check, but the Xcode project is the native app bundle build.

## Run Windows

```powershell
dotnet run --project win\ClipboardSyncWin\ClipboardSyncWin.csproj
```

The app appears in the system tray. Configure one machine as `Server`, then configure the other as `Client` with the server host and port.
The Windows server also binds to the LAN and shows a `ws://LAN-IP:port/` address in the tray status/config form. Use that LAN IP on clients; loopback hosts such as `127.0.0.1` and `localhost` are rejected for client mode.

## Notes

The Stage 1 transport has no authentication and no TLS. Use it only on a trusted network until a security layer is added.
