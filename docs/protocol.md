# Clipboard Sync Protocol

Stage 1 uses a single WebSocket connection with UTF-8 JSON text messages.

## Endpoint

The server accepts WebSocket upgrade requests on:

```text
ws://<host>:<port>/
```

## Clipboard Message

```json
{
  "type": "clipboard",
  "origin": "device-id",
  "text": "clipboard text",
  "sentAt": 1782835200.0
}
```

- `type`: currently always `clipboard`.
- `origin`: stable per-device identifier used to avoid applying self-echoed messages.
- `text`: plain text clipboard content.
- `sentAt`: sender timestamp in Unix seconds.

## Behavior

- A local text clipboard change sends one `clipboard` message.
- A received `clipboard` message overwrites the local text clipboard.
- A receiver ignores messages where `origin` matches its own device id.
- A server applies remote messages locally and broadcasts them to other connected clients.
- Binary messages are ignored in Stage 1.
