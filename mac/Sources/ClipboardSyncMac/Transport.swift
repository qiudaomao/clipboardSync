import Foundation

/// Names the WebSocket subprotocol that marks a connection as the dedicated low-latency input
/// channel. Both sides speak the same wire format on either connection; the split only exists so
/// small input frames never queue behind multi-megabyte clipboard/file/tunnel frames on one TCP
/// stream (head-of-line blocking felt as mouse stutter). Negotiated per RFC 6455: a client that
/// wants the channel requests this subprotocol, and only a server that understands it echoes it
/// back — an old peer fails the negotiation and everything transparently rides the one data
/// connection as before.
enum TransportChannels {
    static let inputSubprotocol = "clipboardsync-input"
}

/// Reads the routing target out of a binary frame without the password, so a relay can forward it
/// blind. The first wire byte picks the codec — `TunnelFrame` (port-forward data) or `BulkFrame`
/// (clipboard image / file chunk). Returns "" for a broadcast and nil for a frame neither codec
/// recognises (which a relay treats the same as a broadcast).
enum BinaryFrameRouting {
    static func target(of frame: Data) -> String? {
        BulkFrame.isBulkFrame(frame) ? BulkFrame.peekTarget(frame) : TunnelFrame.peekTarget(frame)
    }
}

protocol Transport: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
    /// Delivers a received payload; the flag is true when it arrived on the dedicated input
    /// channel, letting the app process it on a fast path that never waits on bulk decryption.
    var onMessage: ((String, Bool) -> Void)? { get set }
    /// Delivers a received binary frame. Only port-forward `data` frames use this — see
    /// `TunnelFrame` for why they bypass the JSON envelope.
    var onBinaryMessage: ((Data) -> Void)? { get set }
    var onPeerCount: ((Int) -> Void)? { get set }

    func start()
    func stop()
    /// `to` is an optional routing hint naming the intended receiver's device id. A server
    /// transport delivers the message to just that peer's connection when it knows which one that
    /// is (falling back to broadcast); a client transport ignores it — its server relays by the
    /// same hint carried inside the message envelope. `realtime` prefers the dedicated input
    /// channel when one is established, falling back to the data connection when it isn't.
    func send(_ message: String, to deviceId: String?, realtime: Bool)
    /// Binary counterpart of `send`, always on the data connection. Routing works the same way,
    /// except a relay reads the target out of the frame header instead of a JSON envelope.
    func sendBinary(_ frame: Data, to deviceId: String?)
}

extension Transport {
    func send(_ message: String) {
        send(message, to: nil, realtime: false)
    }

    func send(_ message: String, to deviceId: String?) {
        send(message, to: deviceId, realtime: false)
    }
}
