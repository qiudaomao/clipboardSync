# Clipboard Sync Protocol

The app uses a single WebSocket connection with UTF-8 JSON messages.
Clipboard payloads are encrypted before they are sent.

## Endpoint

The server accepts WebSocket upgrade requests on:

```text
ws://<host>:<port>/
```

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

## Clipboard Plaintext

After decryption, clipboard updates use `type: "clipboard"` and a `kind` discriminator.

The plaintext structure is never sent directly.

### Text

```json
{
  "type": "clipboard",
  "origin": "device-id",
  "kind": "text",
  "text": "clipboard text",
  "sentAt": 1782835200.0
}
```

### Image

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

### Files

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

## Behavior

- Local text and image clipboard changes send one `clipboard` message automatically.
- Local file clipboard changes are ignored by the clipboard poller. The user must click `Send Files from Clipboard` to package and send the current file clipboard.
- A received `clipboard` message overwrites the local clipboard with text, image data, or file-drop URLs.
- Received files are materialized into an app-managed received-files directory before being placed on the clipboard.
- A receiver ignores messages where `origin` matches its own device id.
- A server broadcasts the encrypted envelope from one client to other clients.
- A server applies remote messages locally only when it is configured with the same password.
- Binary WebSocket messages are ignored.
