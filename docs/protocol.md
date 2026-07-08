# Clipboard Sync Protocol

The app uses a single WebSocket connection with UTF-8 JSON messages.
Clipboard payloads are encrypted before they are sent.

## Endpoint

The server accepts WebSocket upgrade requests on:

```text
ws://<host>:<port>/
```

Clients send WebSocket keepalive traffic about every 10 seconds. Custom servers
reply to standard ping frames with pong frames; clients that can wait for pong
responses treat a missing pong as a disconnect and reconnect.

## Encrypted Message

Every WebSocket text message is an AES-256-GCM envelope:

```json
{
  "type": "encrypted",
  "version": 1,
  "salt": "base64-random-salt",
  "nonce": "base64-random-nonce",
  "ciphertext": "base64-encrypted-clipboard-json",
  "tag": "base64-authentication-tag"
}
```

Version `1` is used for clipboard messages. Its AES key is derived from the
configured sync password with PBKDF2-HMAC-SHA256, 100,000 rounds, a per-message
16-byte salt, and a 32-byte output key.

Version `2` is used for input-sharing messages. It uses the same password,
PBKDF2 parameters, and AES-GCM format, but derives a cached realtime key from a
fixed input salt so mouse/key packets do not run PBKDF2 for every event.

All encrypted messages use a per-message 12-byte nonce and 16-byte
authentication tag. Devices must use the same password; messages encrypted with
a different password are ignored.

## Plaintext Messages

After decryption, messages use a `type` discriminator. Clipboard updates use
`type: "clipboard"` and input-sharing updates use `type: "input"`.

Plaintext structures are never sent directly.

## Clipboard Message

### Clipboard Text

```json
{
  "type": "clipboard",
  "origin": "device-id",
  "kind": "text",
  "text": "clipboard text",
  "sentAt": 1782835200.0
}
```

### Clipboard Image

```json
{
  "type": "clipboard",
  "origin": "device-id",
  "kind": "image",
  "image": {
    "mimeType": "image/png",
    "fileName": "clipboard.png",
    "dataBase64": "base64-png-bytes",
    "size": 12345
  },
  "sentAt": 1782835200.0
}
```

### Clipboard Files

```json
{
  "type": "clipboard",
  "origin": "device-id",
  "kind": "files",
  "files": [
    {
      "name": "example.txt",
      "dataBase64": "base64-file-bytes",
      "size": 12345
    }
  ],
  "sentAt": 1782835200.0
}
```

## Input Message

Input sharing uses the same encrypted envelope. The selected control device is
identified by device id and synchronized by the server.

### Hello

```json
{
  "type": "input",
  "origin": "device-id",
  "target": null,
  "kind": "hello",
  "role": "server",
  "deviceName": "Win-C",
  "deviceAddress": "192.168.1.30",
  "screens": [
    { "width": 3840, "height": 1080, "scale": 1.0, "localX": 0, "localY": 0 },
    { "width": 1920, "height": 1080, "scale": 2.0, "localX": 3840, "localY": 0 }
  ],
  "enabled": true,
  "controlDeviceId": "controller-device-id",
  "sentAt": 1782835200.0
}
```

`screens` lists every physical monitor this device currently has, one entry per monitor.
`localX`/`localY` are that monitor's origin within this device's own local coordinate space
(its real, OS-configured monitor arrangement) — used only to seed each monitor's initial
relative position when it's first placed into the shared layout.

### Capture

```json
{
  "type": "input",
  "origin": "device-id",
  "target": "peer-device-id",
  "kind": "capture",
  "capture": {
    "action": "start",
    "edge": "right",
    "screenId": "peer-device-id#0",
    "normalizedX": 0.0,
    "normalizedY": 0.42
  },
  "sentAt": 1782835200.0
}
```

### Config

```json
{
  "type": "input",
  "origin": "device-id",
  "target": null,
  "kind": "config",
  "role": "server",
  "deviceName": "Win-C",
  "deviceAddress": "192.168.1.30",
  "controlDeviceId": "controller-device-id",
  "sentAt": 1782835200.0
}
```

`kind: "config"` synchronizes shared input coordination fields. A client may
send it as a change request. The server applies the request and broadcasts the
accepted server config to all peers. Local input-sharing enablement is not
synchronized; each device advertises its current receiver state with `hello`.

### Layout

```json
{
  "type": "input",
  "origin": "device-id",
  "target": null,
  "kind": "layout",
  "role": "server",
  "layout": [
    { "screenId": "mac-device-id#0", "deviceId": "mac-device-id", "x": 0, "y": 0, "width": 1920, "height": 1080 },
    { "screenId": "win-device-id#0", "deviceId": "win-device-id", "x": 1920, "y": 0, "width": 1920, "height": 1080 },
    { "screenId": "win-device-id#1", "deviceId": "win-device-id", "x": 3840, "y": 0, "width": 1920, "height": 1080 }
  ],
  "sentAt": 1782835200.0
}
```

`kind: "layout"` carries the shared screen layout: every known device's monitors, each its
own rect (`screenId`) in one common coordinate space (points), used to decide which screen is
adjacent to which when the cursor crosses an edge. A device with several monitors contributes
one entry per monitor, all sharing the same `deviceId`. Any device may send it to
describe a drag from its Screen Layout window. The server is authoritative: it
merges accepted position (`x`/`y`) changes into its canonical table — a
screen's `width`/`height` stay authoritative from that device's own `hello`,
so a stale client can't corrupt sizes it doesn't know about — and rebroadcasts
the full table to all peers. A client receiving `kind: "layout"` from the
server (`role: "server"`) replaces its local table wholesale.

### Mouse

```json
{
  "type": "input",
  "origin": "device-id",
  "target": "peer-device-id",
  "kind": "mouseMove",
  "mouse": {
    "action": "move",
    "normalizedX": 0.5,
    "normalizedY": 0.5,
    "deltaX": null,
    "deltaY": null
  },
  "sentAt": 1782835200.0
}
```

`kind: "mouseButton"` uses `mouse.action` as `down` or `up` and `mouse.button`
as `left`, `right`, or `middle`. `kind: "mouseWheel"` uses `deltaX` and `deltaY`.

### Keyboard

```json
{
  "type": "input",
  "origin": "device-id",
  "target": "peer-device-id",
  "kind": "key",
  "key": {
    "action": "down",
    "key": "KeyA",
    "modifiers": ["Shift"]
  },
  "sentAt": 1782835200.0
}
```

Keyboard codes are canonical physical-key names such as `KeyA`, `Digit1`,
`Enter`, `Escape`, `ArrowLeft`, `Shift`, `Control`, `Alt`, and `Meta`.

## Port Forward Messages

Port forwarding reuses the encrypted envelope. Two message families are involved: `input`
messages of `kind: "forwards"` synchronize the shared rule table, and top-level `tunnel` messages
carry the actual TCP stream data.

### Forwards (rule table)

```json
{
  "type": "input",
  "origin": "device-id",
  "target": null,
  "kind": "forwards",
  "role": "server",
  "forwards": [
    {
      "id": "rule-uuid",
      "inDeviceId": "mac-device-id",
      "inPort": 8022,
      "inAllowLan": false,
      "outDeviceId": "win-device-id",
      "outHost": "127.0.0.1",
      "outPort": 22,
      "note": "SSH to the Windows box",
      "enabled": true
    }
  ],
  "sentAt": 1782835200.0
}
```

`kind: "forwards"` carries the shared port-forward rule table. Each rule says: TCP connections
accepted on `inDeviceId`:`inPort` are tunneled to `outHost`:`outPort` on `outDeviceId`. The
server is authoritative, exactly like `kind: "layout"`: a client sends its edited table as a
request (`role: "client"`), the server merges it into its canonical copy and rebroadcasts the
accepted table (`role: "server"`), and a client receiving the server's table replaces its own
wholesale. The server also rebroadcasts on peer connect so newly joined devices catch up.

`inAllowLan` chooses the listen interface on the In device: `false` (default) binds `127.0.0.1`
only, so the forwarded port is reachable just from the In device itself; `true` binds `0.0.0.0`,
exposing it to other machines on the In device's LAN. `outHost` is the address the Out device
dials, default `127.0.0.1` (a service on the Out device itself); set it to any address the Out
device can reach to use that device as a gateway to a third host. Both fields are optional on the
wire — a rule missing them decodes with these defaults.

### Forward status

```json
{
  "type": "input",
  "origin": "device-id",
  "target": null,
  "kind": "forwardStatus",
  "role": "client",
  "forwardStatuses": [
    { "id": "rule-uuid", "ok": true, "reason": null },
    { "id": "other-rule-uuid", "ok": false, "reason": "Address already in use" }
  ],
  "sentAt": 1782835200.0
}
```

`kind: "forwardStatus"` reports the live listen state of the rules a device is the In side of —
the only device that actually opens each listening socket. `ok` true means the port is bound and
listening; `ok` false means the bind failed and `reason` says why (e.g. address in use, or a
privileged-port hint). Each device broadcasts only its own rules' statuses; peers merge them by
rule id to render an accurate status light per rule in the Port Forward panel. It is re-sent on
peer connect and whenever a local listen state changes. A rule's disabled and "In device offline"
states are derived locally from the rule table and device presence, so they are not carried here.

### Tunnel (stream data)

```json
{
  "type": "tunnel",
  "origin": "device-id",
  "target": "peer-device-id",
  "kind": "open",
  "connectionId": "connection-uuid",
  "host": "127.0.0.1",
  "port": 22,
  "dataBase64": null,
  "reason": null,
  "sentAt": 1782835200.0
}
```

A `tunnel` message is encrypted with the version `2` (realtime) envelope, like input events.
`connectionId` is allocated by the listening ("In") device when it accepts a local TCP
connection, and identifies that one connection across all three kinds:

- `kind: "open"` — sent by the In device to the Out device; asks it to dial `host:port` (the
  rule's `outHost`/`outPort`; `host` defaults to `127.0.0.1` when absent).
- `kind: "data"` — sent in either direction; `dataBase64` is a chunk of the TCP stream.
- `kind: "close"` — sent in either direction; tears the connection down. `reason` is optional.

Tunnel messages with a `target` other than the receiving device are ignored. The In device only
opens a tunnel when the Out device is currently online; otherwise the incoming TCP connection is
refused immediately.

## Fields

- `type`: always `clipboard`.
- `origin`: stable per-device identifier used to avoid applying self-echoed messages.
- `kind`: `text`, `image`, or `files`.
- `text`: plain text clipboard content for `kind: "text"`.
- `image`: PNG image payload for `kind: "image"`.
- `files`: one or more file payloads for `kind: "files"`.
- `dataBase64`: base64-encoded binary bytes.
- `size`: raw byte count before base64 encoding.
- `sentAt`: sender timestamp in Unix seconds.
Input message fields:

- `type`: always `input`.
- `origin`: sender device id.
- `target`: optional receiver device id. Messages with another target are ignored.
- `kind`: `hello`, `config`, `layout`, `capture`, `mouseMove`, `mouseButton`, `mouseWheel`, or `key`.
- `role`: sender role for `hello`/`config`/`layout`, either `server` or `client`.
- `deviceName`: sender host/device name for UI display.
- `deviceAddress`: sender LAN IP address for UI display.
- `screens`: this device's physical monitors (size, scale, and local arrangement) for `hello`.
- `enabled`: sender input-sharing runtime state for `hello`.
- `controlDeviceId`: device id whose mouse and keyboard control remote input.
- `layout`: the shared screen layout table for `kind: "layout"` — see Layout above.
- `edge`: the screen edge the cursor crossed to trigger a `capture`: `left`, `right`, `top`, or `bottom`. Computed dynamically from the shared layout, not configured.
- `screenId`: which of the target device's monitors (`"<deviceId>#<index>"`) a `capture` is entering.
- `normalizedX` / `normalizedY`: screen coordinates normalized to `0...1`, relative to the active monitor.
Encrypted envelope fields:

- `type`: always `encrypted`.
- `version`: encryption envelope version, `1` for clipboard and `2` for input sharing.
- `salt`: base64-encoded PBKDF2 salt; random for version `1`, fixed input salt for version `2`.
- `nonce`: base64-encoded AES-GCM nonce.
- `ciphertext`: base64-encoded encrypted clipboard JSON.
- `tag`: base64-encoded AES-GCM authentication tag.

## Limits

- Clipboard history keeps the latest 10 unique items in memory.
- Each image or file payload is capped at 10 MB raw bytes.
- WebSocket JSON messages are capped at 16 MB to allow for base64 expansion.

## Behavior

- Local text and image clipboard changes send one `clipboard` message automatically.
- Local file clipboard changes are ignored by the clipboard poller. The user must click `Send Files from Clipboard` to package and send the current file clipboard.
- A received `clipboard` message overwrites the local clipboard with text, image data, or file-drop URLs.
- Received files are materialized into an app-managed received-files directory before being placed on the clipboard.
- A receiver ignores messages where `origin` matches its own device id.
- A server broadcasts the encrypted envelope from one client to other clients.
- A server applies remote messages locally only when it is configured with the same password.
- Input sharing is off by default and must be enabled in settings or the tray/menu.
- Input-sharing enablement is local to each device. It is not synchronized by `kind: "config"`.
- The configured control device is selected by device id. The server is authoritative for shared input config; clients may request changes with `kind: "config"`, and the server rebroadcasts the accepted config.
- The Screen Layout window shows every known device's monitors as separate rects (a device with several monitors gets one rect per monitor), all drawn at one consistent scale and true aspect ratio, color-coded per device, and draggable to describe how the machines physically sit relative to each other. A machine's own monitors are fixed relative to each other (that arrangement belongs to the OS, not this tool) and always move together as one rigid group when dragged. Dragging enforces no overlap between different machines and snaps the moved machine to touch (zero gap) another machine's screen. Dragging sends `kind: "layout"`; the server is authoritative and rebroadcasts the accepted table, mirroring how `kind: "config"` is synchronized.
- Reverse vertical scroll is a local receiver setting. It is not synchronized, flips only injected `deltaY`, and leaves horizontal wheel deltas unchanged.
- The controller starts remote capture when the local pointer reaches an edge of its own screen and a neighboring screen is adjacent to it in the shared layout, and walks that layout as the pointer keeps moving: exiting a remote screen's edge hands capture to whichever screen is adjacent there (another remote screen, or back to the controller's own screen), and sticks at the edge when no neighbor is registered there.
- macOS requires Accessibility/Input Monitoring permission for input capture and injection.
- Windows uses low-level mouse/keyboard hooks and `SendInput` for capture and injection.
- Input sharing covers mouse move, button, wheel, and basic physical keyboard events. IME, media keys, and system-reserved shortcuts are not guaranteed.
- Mouse move packets are send-side throttled and receive-side coalesced; the latest pointer position wins when the receiver is under load.
- Binary WebSocket messages are ignored.
