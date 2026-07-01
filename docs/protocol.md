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

The AES key is derived from the configured sync password with PBKDF2-HMAC-SHA256,
100,000 rounds, a per-message 16-byte salt, and a 32-byte output key. AES-GCM
uses a per-message 12-byte nonce and 16-byte authentication tag. Devices must
use the same password; messages encrypted with a different password are ignored.

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

Input sharing uses the same encrypted envelope. Version 1 supports one peer for
mouse and basic keyboard sharing.

### Hello

```json
{
  "type": "input",
  "origin": "device-id",
  "target": null,
  "kind": "hello",
  "role": "server",
  "screen": { "width": 3840, "height": 1080, "scale": 1.0 },
  "enabled": true,
  "direction": "serverControlsClient",
  "peerEdge": "right",
  "sentAt": 1782835200.0
}
```

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
  "enabled": true,
  "direction": "serverControlsClient",
  "peerEdge": "right",
  "sentAt": 1782835200.0
}
```

`kind: "config"` synchronizes the input-sharing setting. A client may send it
as a change request. The server applies the request and broadcasts the accepted
server config to all peers.

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
- `kind`: `hello`, `config`, `capture`, `mouseMove`, `mouseButton`, `mouseWheel`, or `key`.
- `role`: sender role for `hello`, either `server` or `client`.
- `screen`: virtual desktop size and scale for `hello`.
- `enabled`: sender input-sharing runtime state for `hello`; configured input-sharing state for `config`.
- `direction`: `serverControlsClient` or `clientControlsServer`.
- `peerEdge`: peer position relative to the controlling side: `left`, `right`, `top`, or `bottom`.
- `normalizedX` / `normalizedY`: screen coordinates normalized to `0...1`.
Encrypted envelope fields:

- `type`: always `encrypted`.
- `version`: encryption envelope version, currently `1`.
- `salt`: base64-encoded random PBKDF2 salt.
- `nonce`: base64-encoded AES-GCM nonce.
- `ciphertext`: base64-encoded encrypted clipboard JSON.
- `tag`: base64-encoded AES-GCM authentication tag.

## Limits

- Clipboard history keeps the latest 10 unique items in memory.
- Each image or file payload is capped at 10 MB raw bytes.
- WebSocket JSON messages are capped at 16 MB to allow for base64 expansion.
- Input sharing v1 supports one peer. If multiple clients connect, clipboard sync continues and input sharing is disabled.

## Behavior

- Local text and image clipboard changes send one `clipboard` message automatically.
- Local file clipboard changes are ignored by the clipboard poller. The user must click `Send Files from Clipboard` to package and send the current file clipboard.
- A received `clipboard` message overwrites the local clipboard with text, image data, or file-drop URLs.
- Received files are materialized into an app-managed received-files directory before being placed on the clipboard.
- A receiver ignores messages where `origin` matches its own device id.
- A server broadcasts the encrypted envelope from one client to other clients.
- A server applies remote messages locally only when it is configured with the same password.
- Input sharing is off by default and must be enabled in settings or the tray/menu.
- The configured direction is either server controls client or client controls server. The server is authoritative for input-sharing config; clients may request changes with `kind: "config"`, and the server rebroadcasts the accepted config.
- The peer edge defines where the remote virtual desktop sits relative to the controller's virtual desktop.
- The controller starts remote capture when the local pointer reaches the configured edge and ends capture when the remote pointer crosses back over the opposite edge.
- macOS requires Accessibility/Input Monitoring permission for input capture and injection.
- Windows uses low-level mouse/keyboard hooks and `SendInput` for capture and injection.
- Input sharing covers mouse move, button, wheel, and basic physical keyboard events. IME, media keys, and system-reserved shortcuts are not guaranteed.
- Binary WebSocket messages are ignored.
