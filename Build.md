# Clipboard Sync

Native clipboard sync over WebSocket.

## Stage 1 Goal

The first milestone is a small native app on each platform:

- macOS: Swift menu bar app.
- Windows: C# system tray app.
- Linux: C++20 Qt 6 tray/window app with X11 and Wayland capability detection.
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
- `linux/`: Qt 6/CMake Linux app, tests, desktop metadata, and Flatpak manifest.

## Run Linux

```sh
cmake -S linux -B linux/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build linux/build
ctest --test-dir linux/build --output-on-failure
./linux/build/clipboard-sync
```

Linux requires Qt 6.7+, OpenSSL 3, CMake 3.24+, Ninja, and the X11 client
libraries (`libX11`, `libXtst`, `libXfixes`). The supported features are
encrypted text/image sync, legacy and chunked clipboard-file receive/transfer,
TCP port forwarding, and keyboard/mouse input sharing with the shared screen
layout on X11 sessions (capability-detected only on Wayland). The Flatpak
packaging and update behavior are documented in `linux/README.md`.

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
Set the same sync password on every device before starting. Clipboard payloads are encrypted with AES-GCM over the existing WebSocket connection; unchecking `Encrypt transport` in Settings keeps HMAC password authentication but skips payload encryption to save CPU on trusted networks.
Input Sharing is off by default. Enable it from Settings or the menu, choose `Server -> Client` or `Client -> Server`, and arrange each machine's screen in the `Screen Layout...` menu window (drag rects to match how they physically sit relative to each other). macOS needs Accessibility/Input Monitoring permission before keyboard and mouse sharing can run.
`More Features -> Prevent System Sleep` can keep the Mac awake forever or for 1, 2, 4, 6, or 8 hours. Its independent low-battery checkbox pauses the IOKit assertion only while the Mac is on battery power below 20%, and resumes on AC power or battery recovery without extending a timed deadline. Timed choices retain their original deadline if the app is relaunched.

The Swift Package in `mac/Package.swift` is kept as a lightweight compiler check, but the Xcode project is the native app bundle build.

### Auto-update (Sparkle 2)

The macOS app checks for updates via [Sparkle 2](https://sparkle-project.org/), added as a Swift Package dependency in the Xcode project (and mirrored in `mac/Package.swift` for the compiler check). It reads `SUFeedURL` from `mac/App/Info.plist`, which points at `appcast.xml` in the separate [clipboardSyncRelease](https://github.com/qiudaomao/clipboardSyncRelease) repo, served via `raw.githubusercontent.com`. Release zips are also uploaded as GitHub release assets on that repo, keeping release artifacts out of the main source repo.

One-time setup, from Xcode after the Sparkle package has resolved (Xcode places its tools under `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/`, or build `generate_keys`/`sign_update` from the Sparkle repo directly):

1. Run `generate_keys` once to create an EdDSA keypair. It stores the private key in the login Keychain and prints the public key.
2. Paste the public key into `SUPublicEDKey` in `mac/App/Info.plist` (replacing `REPLACE_WITH_GENERATED_ED25519_PUBLIC_KEY`).
3. Never commit the private key; only the public key belongs in the repo.

See [release_update.md](release_update.md) for the full per-release procedure.

## Run Windows

```powershell
dotnet run --project win\ClipboardSyncWin\ClipboardSyncWin.csproj
```

The app appears in the system tray. Configure one machine as `Server`, then configure the other as `Client` with the server host and port.
The Windows server also binds to the LAN and shows a `ws://LAN-IP:port/` address in the tray status/config form. Use that LAN IP on clients; loopback hosts such as `127.0.0.1` and `localhost` are rejected for client mode.
Text and image clipboard changes sync automatically. File clipboard contents are only sent from `Send Files from Clipboard` in the tray menu, with a 10 MB limit per file.
The `History` submenu keeps the latest 10 clipboard items and can restore/resend an item.
Set the same sync password on every device before starting. Clipboard payloads are encrypted with AES-GCM over the existing WebSocket connection; unchecking `Encrypt transport` in Settings keeps HMAC password authentication but skips payload encryption to save CPU on trusted networks.
Input Sharing is off by default. Enable it from Configure or the tray menu, choose `Server -> Client` or `Client -> Server`, and arrange each machine's screen in the `Screen Layout...` tray menu window (drag rects to match how they physically sit relative to each other).
`More Features -> Prevent System Sleep` can keep Windows awake forever or for 1, 2, 4, 6, or 8 hours. Its independent low-battery checkbox pauses the Windows execution-state request only while the PC is on battery power below 20%, and resumes on AC power or battery recovery without extending a timed deadline. Timed choices retain their original deadline if the app is relaunched.

### Auto-update (NetSparkle)

The Windows app checks for updates via [NetSparkleUpdater](https://github.com/NetSparkleUpdater/NetSparkle). It points at `win-appcast.xml` in the separate [clipboardSyncRelease](https://github.com/qiudaomao/clipboardSyncRelease) repo and expects installer-only releases named like `ClipboardSyncWinSetup-v0.1.0.exe`.

Use `build-windows-installer.ps1` to publish a small framework-dependent build and package it with Inno Setup 6. Users must have the .NET 8 Desktop Runtime (x64); if it is missing, the .NET app host shows Microsoft's runtime install guidance when the app launches. See [release_windows.md](release_windows.md) for the full per-release procedure.

## Notes

The WebSocket endpoint is still plain `ws://`, but clipboard and input-sharing message bodies are encrypted and authenticated with the configured shared password.
On both macOS and Windows, the Screen Layout window represents every physical monitor of every machine as its own rect (not just one rect per machine) and arranges them in a shared 2D layout with no overlaps and no gaps between adjacent machines; a machine's own monitors are fixed relative to each other (that's the OS's arrangement, not user-adjustable here) and drag together as one group. Input sharing hops across whichever monitor is adjacent as the cursor crosses an edge, including hopping between two monitors on the same machine, whether that machine is macOS or Windows.
