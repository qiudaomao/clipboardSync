# Clipboard Sync for Linux

The Linux client is a Qt 6 application using the same encrypted WebSocket
protocol as the macOS and Windows clients. The implementation supports Server
and Child Device modes, automatic text and PNG clipboard sync, explicit chunked
clipboard-file transfer, TCP port forwarding, and — on X11 sessions — keyboard
and mouse input sharing with the shared screen layout.

## Build

Dependencies: CMake 3.24+, Qt 6.7+ (`Core`, `DBus`, `Gui`, `Widgets`, `Network`,
and `WebSockets`), OpenSSL 3, X11 client libraries (`libX11`, `libXtst`,
`libXfixes`), and a C++20 compiler.

```sh
cmake -S linux -B linux/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build linux/build
ctest --test-dir linux/build --output-on-failure
./linux/build/clipboard-sync
```

At startup the app logs the detected display session, desktop, tray availability,
and portal input capabilities. On desktops without a system tray, the main
window remains available as the primary control surface.

## Updates

The app checks the release repository for a newer version and delegates the
installation according to its source:

- Flatpak opens the desktop software manager.
- AppImage starts `AppImageUpdate` when it is installed, otherwise it opens the release page.
- Distribution packages and manual installs open the release page; the app never runs `sudo`,
  `apt`, or `dnf` itself.

The update check reports HTTP and malformed-release errors instead of treating
them as an up-to-date result.

## Flatpak

Build the repository manifest from the project root after installing
`flatpak-builder` and the KDE 6.9 runtime/SDK:

```sh
flatpak-builder --force-clean linux/flatpak-build \
  linux/packaging/io.github.qiudaomao.clipboardsync.yml
```

## Input sharing

Input sharing follows the shared protocol: enable it from the tray menu, pick
the Control Device, and arrange every machine's monitors in `Screen Layout…`.
When this device is the controller, crossing a screen edge captures the local
pointer and keyboard (an X11 pointer/keyboard grab; the cursor is hidden via
XFixes) and relays the events to the adjacent peer. When a peer controls this
device, events are injected with XTest. `Receive Key Mapping` in Settings
remaps modifier keys on the receiving side, and `Reverse mouse vertical
scroll` flips injected wheel direction.

## Current limitations

- Input sharing requires an X11 session (XTest/XFixes grabs and injection). On
  Wayland the InputCapture/RemoteDesktop portals are detected but the feature
  is not offered yet.
- Wayland compositors may prevent reliable background clipboard observation.
