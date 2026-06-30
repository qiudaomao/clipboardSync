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
- `mac/`: Swift Package for the macOS menu bar app.
- `win/ClipboardSyncWin/`: .NET WinForms Windows tray app.

## Run macOS

```sh
cd mac
swift run ClipboardSyncMac
```

The app appears as `Clip` in the menu bar. Configure one machine as `Server`, then configure the other as `Client` with the server host and port.

## Run Windows

```powershell
dotnet run --project win\ClipboardSyncWin\ClipboardSyncWin.csproj
```

The app appears in the system tray. Configure one machine as `Server`, then configure the other as `Client` with the server host and port.

## Notes

The Stage 1 transport has no authentication and no TLS. Use it only on a trusted network until a security layer is added.
