# Clipboard Sync for Linux

The Linux client is a Qt 6 application using the same encrypted WebSocket
protocol as the macOS and Windows clients. The implementation supports Server
and Child Device modes, automatic text and PNG clipboard sync, explicit chunked
clipboard-file transfer, TCP port forwarding, and — on X11 sessions — keyboard
and mouse input sharing with the shared screen layout. `More Features -> Prevent
System Sleep` shows its live state and remaining time in the first submenu row,
and can inhibit suspend and display idle forever, for 1, 2, 4, 6, or 8 hours, or
on a weekly Time Plan, through the desktop Inhibit portal, including inside the
Flatpak sandbox. `Edit Time Plan` opens a 7-day by 24-hour grid in local time
where blue blocks prevent sleep and gray blocks allow it; click a block to switch
it or drag to switch a rectangle of blocks. Its independent
low-battery checkbox reads UPower and pauses that inhibitor only while the system
is on battery power below 20%; AC power or battery recovery resumes the original
selection without extending a timed deadline.

## Build

Dependencies: CMake 3.24+, Qt 6.7+ (`Core`, `DBus`, `Gui`, `Widgets`, `Network`,
and `WebSockets`), OpenSSL 3, X11 client libraries (`libX11`, `libXi`, `libXtst`,
`libXfixes`), `wayland-client` plus `wayland-scanner`, `libxkbcommon`, `libei`,
and a C++20 compiler.

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

To publish single-file bundles without any Linux machine, build them in Docker
from the project root (same container image the CI release workflow uses; on
Apple silicon the aarch64 build is native and x86_64 runs emulated):

```sh
./script/build-linux-flatpak.sh                # both arches → artifacts/linux/
./script/build-linux-flatpak.sh -u v0.1.20     # also upload to this repo's release
```

Or from an existing ostree repo (e.g. on the Steam Deck):

```sh
flatpak build-bundle <ostree-repo> clipboardSyncLinux-x86_64.flatpak \
  io.github.qiudaomao.clipboardsync master
```

Users install the downloaded bundle with
`flatpak install clipboardSyncLinux.flatpak` (the KDE Platform 6.9 runtime is
pulled from Flathub automatically when a Flathub remote is configured).
The manifest grants read access to `org.freedesktop.UPower` on the system bus so
the optional low-battery sleep-prevention guard also works inside the sandbox.

## Input sharing

Input sharing follows the shared protocol: enable it from the tray menu, pick
the Control Device (or `Auto (mouse; current: …)`), and arrange every machine's monitors in `Screen Layout…`.
Auto uses XInput2 raw pointer events to elect the device whose physical mouse or touchpad was
most recently used. Keyboard activity does not switch the controller, so a mouse on one device
and a keyboard on another can be used together; XTest-injected remote input is ignored.
When this device is the controller, crossing a screen edge captures the local
pointer and keyboard (an X11 pointer/keyboard grab; the cursor is hidden via
XFixes) and relays the events to the adjacent peer. When a peer controls this
device, events are injected with XTest. `Receive Key Mapping` in Settings
remaps modifier keys on the receiving side, and `Reverse mouse vertical
scroll` flips injected wheel direction.

On Wayland sessions a separate backend injects remote input through the
wlroots virtual-input protocols (`zwlr_virtual_pointer_v1` and
`zwp_virtual_keyboard_v1`), which Hyprland, Sway, and other wlroots-based
compositors implement. The virtual keyboard carries its own fixed us keymap,
so the position-based canonical key names resolve the same way on every
receiver.

Controlling other devices from Wayland uses `hyprland_input_capture_v1`
(Hyprland only): the app arms compositor pointer barriers on the shared-layout
edges, the compositor grabs input when the cursor crosses one, and the
captured events arrive over an EIS socket consumed with libei. Because the
compositor detects the crossing itself, no global cursor polling is needed.
The Auto control device election monitors local mouse activity by polling the
Hyprland IPC `cursorpos` (movement right after the app's own injections is
ignored so relayed input can never elect this device).

### Wayland input sharing from the Flatpak

Compositors treat the virtual-input protocols as privileged and hide them from
sandboxed clients: Flatpak connects the app through a
`wp_security_context_v1`-tagged socket, and Hyprland (unconditionally, as of
0.56) filters every non-whitelisted global for such clients. The app detects
this and falls back to the X11 backend, which cannot reach the compositor —
so a stock Flatpak install cannot be controlled on Hyprland. To opt out of
the sandbox filtering, hand the app the real session socket under a separate
name (a hardlink, so neither Flatpak's symlink nor the security context
applies):

```sh
ln -f "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/wayland-real"
flatpak override --user \
  --filesystem=xdg-run/wayland-real \
  --env=WAYLAND_DISPLAY=wayland-real \
  io.github.qiudaomao.clipboardsync
```

The hardlink lives in a tmpfs, so recreate it at each session start (e.g. a
user service or `exec-once`). At startup the app logs
`Input backend: Wayland virtual pointer/keyboard` when injection is
available, and `Input backend: X11 XTest` when it is not. Native
(non-sandboxed) builds need none of this.

## Current limitations

- On Wayland, controlling other devices and Auto-control monitoring are
  Hyprland-specific (`hyprland_input_capture_v1` and the Hyprland IPC
  socket). On other wlroots compositors this device can only be controlled;
  on compositors without the wlroots virtual-input protocols (e.g. GNOME)
  input sharing is unavailable entirely. Every missing piece fails with an
  explicit status message.
- Inside the Flatpak sandbox the compositor hides the privileged
  virtual-input protocols; see “Wayland input sharing from the Flatpak”
  above for the opt-out. The Auto-control monitor additionally needs
  `flatpak override --user --filesystem=xdg-run/hypr` for the Hyprland IPC
  socket.
- X11 sessions keep the original XTest/XFixes implementation for both
  directions.
- Wayland compositors may prevent reliable background clipboard observation.
