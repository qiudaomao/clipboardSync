import CryptoKit
import Foundation
import Network

final class WebSocketServerTransport: Transport {
    var onStatus: ((String) -> Void)?
    var onMessage: ((String, Bool) -> Void)?
    var onBinaryMessage: ((Data) -> Void)?
    var onPeerCount: ((Int) -> Void)?

    private let port: Int
    private let queue = DispatchQueue(label: "ClipboardSyncMac.server")
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: ServerPeer] = [:]
    /// This machine's own device id. Messages routed `to` it are already delivered locally via
    /// `onMessage`, so the relay must not fall back to broadcasting them at other peers.
    var localDeviceId: String?

    init(port: Int) {
        self.port = port
    }

    func start() {
        queue.async { [self] in
            do {
                guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                    onStatus?(AppText.text("status.invalidPort"))
                    return
                }

                // Nagle would hold a small frame back waiting for more bytes while the peer's
                // delayed ACK waits for a response — worth ~40 ms on every interactive round trip
                // through a tunnel or an input event. Frames are already batched by the sender.
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: nwPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.pushStatus()
                    case .failed(let error):
                        self?.onStatus?(AppText.format("status.serverFailed", error.localizedDescription))
                    case .cancelled:
                        self?.onStatus?(AppText.text("status.stopped"))
                    default:
                        break
                    }
                }

                self.listener = listener
                listener.start(queue: queue)
                onStatus?(AppText.format("status.startingServer", NetworkAddress.serverAddress(port: port)))
            } catch {
                onStatus?(AppText.format("status.serverError", error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.sync {
            self.listener?.cancel()
            self.listener = nil
            self.peers.values.forEach { $0.close() }
            self.peers.removeAll()
            self.onPeerCount?(0)
            self.onStatus?(AppText.text("status.stopped"))
        }
    }

    func send(_ message: String, to deviceId: String?, realtime: Bool) {
        queue.async {
            self.deliver(message, to: deviceId, preferInput: realtime, excluding: nil)
        }
    }

    func sendBinary(_ frame: Data, to deviceId: String?) {
        queue.async {
            self.deliverBinary(frame, to: deviceId, excluding: nil)
        }
    }

    /// True when `to` names a device that definitely isn't this one, so the frame is only passing
    /// through. Deliberately conservative: an absent hint, an empty hint, or an unknown local
    /// device id all return false, so the frame is still handled locally.
    private func isRelayOnly(_ to: String?) -> Bool {
        guard
            let to,
            !to.isEmpty,
            let localDeviceId,
            !localDeviceId.isEmpty
        else {
            return false
        }
        return to != localDeviceId
    }

    private func accept(_ connection: NWConnection) {
        let peer = ServerPeer(connection: connection, queue: queue)
        let peerId = ObjectIdentifier(peer)

        peer.onText = { [weak self, weak peer] text in
            guard let self else {
                return
            }
            // Envelope routing hints are plaintext, so the relay can learn which connection
            // belongs to which device (`from`) and deliver targeted traffic (`to`) to just that
            // peer instead of broadcasting file chunks and tunnel data to everyone.
            let routing = EnvelopeRouting.scan(text)
            if let from = routing?.from, !from.isEmpty {
                peer?.deviceId = from
            }
            let viaInputChannel = peer?.isInputChannel == true
            // A message addressed to some other device is pure relay traffic. Handing it to
            // `onMessage` would run a full AES-GCM decrypt of a ~100 KB tunnel or file chunk only
            // for the receiver-side target filter to drop it — on a busy forward that is the
            // relay's single largest cost. Anything unaddressed still goes through, so broadcasts
            // and older peers that omit the hint are unaffected.
            if !self.isRelayOnly(routing?.to) {
                self.onMessage?(text, viaInputChannel)
            }
            // Relay on the same class of channel the message arrived on, so one peer's input
            // frames reach the next peer's input connection instead of its bulk stream.
            self.deliver(text, to: routing?.to, preferInput: viaInputChannel, excluding: peer)
        }
        peer.onBinary = { [weak self, weak peer] frame in
            guard let self else {
                return
            }
            // A binary frame is a port-forward `data` frame or a large clipboard/file payload; its
            // target sits in the plaintext header of either codec, so the relay routes it without
            // reading the payload. A clipboard image carries an empty target and is broadcast. Same
            // early-out as the text path: a frame addressed to another device is never handed to
            // the local app.
            let target = BinaryFrameRouting.target(of: frame)
            if !self.isRelayOnly(target) {
                self.onBinaryMessage?(frame)
            }
            self.deliverBinary(frame, to: target, excluding: peer)
        }
        peer.onReady = { [weak self] in
            self?.pushStatus()
        }
        peer.onClose = { [weak self, weak peer] in
            guard let self, let peer else {
                return
            }
            self.peers.removeValue(forKey: ObjectIdentifier(peer))
            self.pushStatus()
        }

        peers[peerId] = peer
        peer.start()
    }

    /// Sends `message` to the one ready peer registered under the `to` device id, or to every
    /// ready peer (except `excluding`) when the target is absent or not (yet) known — a peer that
    /// hasn't sent anything since connecting has no registered device id, and the receiver-side
    /// target filter makes the broadcast fallback harmless. Targeted delivery prefers the
    /// device's connection matching the message's channel (input vs data), falling back to
    /// whichever it has; broadcasts go to data connections only, since every device has exactly
    /// one and duplicates on the auxiliary input channel would double-deliver.
    private func deliver(_ message: String, to deviceId: String?, preferInput: Bool, excluding excluded: ServerPeer?) {
        if let deviceId, !deviceId.isEmpty {
            if deviceId == localDeviceId {
                return
            }
            let candidates = peers.values.filter { $0.deviceId == deviceId && $0.isReady && $0 !== excluded }
            if let target = candidates.first(where: { $0.isInputChannel == preferInput }) ?? candidates.first {
                target.sendText(message)
                return
            }
            if peers.values.contains(where: { $0.deviceId == deviceId && $0.isReady }) {
                // The only matching connection is the excluded source itself; don't broadcast.
                return
            }
        }
        for peer in peers.values where peer !== excluded && peer.isReady && !peer.isInputChannel {
            peer.sendText(message)
        }
    }

    /// Binary counterpart of `deliver`. Tunnel frames are always addressed, so there is no
    /// input-channel preference to make — they belong on the data connection either way.
    private func deliverBinary(_ frame: Data, to deviceId: String?, excluding excluded: ServerPeer?) {
        if let deviceId, !deviceId.isEmpty {
            if deviceId == localDeviceId {
                return
            }
            let candidates = peers.values.filter { $0.deviceId == deviceId && $0.isReady && $0 !== excluded }
            if let target = candidates.first(where: { !$0.isInputChannel }) ?? candidates.first {
                target.sendBinary(frame)
                return
            }
            if peers.values.contains(where: { $0.deviceId == deviceId && $0.isReady }) {
                // The only matching connection is the excluded source itself; don't broadcast.
                return
            }
        }
        for peer in peers.values where peer !== excluded && peer.isReady && !peer.isInputChannel {
            peer.sendBinary(frame)
        }
    }

    private func pushStatus() {
        // Input-channel connections are auxiliary; a device's presence is its data connection.
        let readyPeerCount = peers.values.filter { $0.isReady && !$0.isInputChannel }.count
        onPeerCount?(readyPeerCount)
        onStatus?(AppText.format("status.serverPeers", NetworkAddress.serverAddress(port: port), readyPeerCount))
    }
}

private final class ServerPeer {
    var onReady: (() -> Void)?
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?
    /// The device id this connection last announced via an envelope's `from` hint, once known.
    var deviceId: String?
    private(set) var isReady = false
    /// True when the client negotiated the dedicated input subprotocol during the handshake.
    private(set) var isInputChannel = false

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var didClose = false
    private var handshakeBuffer = Data()
    /// Reassembly state for a fragmented message (RFC 6455 §5.4): the first frame's opcode and the
    /// fragment payloads accumulated so far. Clients are allowed to split any message into
    /// continuation frames — Apple's own WebSocket client does for large messages.
    private var fragmentOpcode: UInt8?
    private var fragmentBuffer = Data()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHandshake()
    }

    func close() {
        guard !didClose else {
            return
        }
        didClose = true
        connection.cancel()
        onClose?()
    }

    func sendText(_ text: String) {
        guard isReady else {
            return
        }
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func sendBinary(_ frame: Data) {
        guard isReady else {
            return
        }
        sendFrame(opcode: 0x2, payload: frame)
    }

    private func receiveHandshake() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data {
                self.handshakeBuffer.append(data)
            }

            if error != nil || isComplete || self.handshakeBuffer.count > 16_384 {
                self.close()
                return
            }

            guard
                let header = String(data: self.handshakeBuffer, encoding: .utf8),
                header.contains("\r\n\r\n")
            else {
                self.receiveHandshake()
                return
            }

            guard let key = Self.headerValue("Sec-WebSocket-Key", in: header) else {
                self.close()
                return
            }

            // Echo the input subprotocol when the client requests it: that both marks this
            // connection as the low-latency input channel and tells the client the server
            // understands the split (an old server's response omits it, and the client falls
            // back to the single data connection).
            var responseLines = [
                "HTTP/1.1 101 Switching Protocols",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Accept: \(Self.acceptKey(for: key))"
            ]
            if let requested = Self.headerValue("Sec-WebSocket-Protocol", in: header),
               requested.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(TransportChannels.inputSubprotocol) {
                self.isInputChannel = true
                responseLines.append("Sec-WebSocket-Protocol: \(TransportChannels.inputSubprotocol)")
            }
            responseLines.append("")
            responseLines.append("")
            let response = responseLines.joined(separator: "\r\n")

            self.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                if error != nil {
                    self.close()
                    return
                }
                self.isReady = true
                self.onReady?()
                self.receiveFrame()
            })
        }
    }

    private func receiveFrame() {
        receiveExact(2) { [weak self] header in
            guard let self, let header else {
                self?.close()
                return
            }

            let fin = (header[0] & 0x80) != 0
            let opcode = header[0] & 0x0f
            let masked = (header[1] & 0x80) != 0
            let firstLength = UInt64(header[1] & 0x7f)

            switch firstLength {
            case 126:
                self.receiveExact(2) { [weak self] data in
                    guard let self, let data else {
                        self?.close()
                        return
                    }
                    let length = (UInt64(data[0]) << 8) | UInt64(data[1])
                    self.receivePayload(fin: fin, opcode: opcode, masked: masked, length: length)
                }
            case 127:
                self.receiveExact(8) { [weak self] data in
                    guard let self, let data else {
                        self?.close()
                        return
                    }
                    let length = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    self.receivePayload(fin: fin, opcode: opcode, masked: masked, length: length)
                }
            default:
                self.receivePayload(fin: fin, opcode: opcode, masked: masked, length: firstLength)
            }
        }
    }

    private func receivePayload(fin: Bool, opcode: UInt8, masked: Bool, length: UInt64) {
        guard length <= UInt64(ClipboardLimits.maxWebSocketMessageBytes) else {
            close()
            return
        }

        let readPayload: (Data?) -> Void = { [weak self] payloadData in
            guard let self, let payload = payloadData else {
                self?.close()
                return
            }

            // Control frames (close/ping/pong) are never fragmented and may interleave with the
            // fragments of a data message, so handle them before any reassembly bookkeeping.
            if opcode == 0x8 {
                self.close()
                return
            }
            if opcode == 0x9 {
                self.sendFrame(opcode: 0xA, payload: payload)
                self.receiveFrame()
                return
            }
            if opcode == 0xA {
                self.receiveFrame()
                return
            }

            self.handleDataFrame(fin: fin, opcode: opcode, payload: payload)
        }

        if masked {
            receiveExact(4) { [weak self] mask in
                guard let self, let mask else {
                    self?.close()
                    return
                }
                self.receiveExact(Int(length)) { payload in
                    guard var payload else {
                        readPayload(nil)
                        return
                    }
                    for index in 0..<payload.count {
                        payload[index] ^= mask[index % 4]
                    }
                    readPayload(payload)
                }
            }
        } else {
            receiveExact(Int(length), completion: readPayload)
        }
    }

    /// Reassembles data frames into messages: a frame with FIN set and a data opcode is a whole
    /// message; otherwise fragments accumulate until the continuation frame with FIN arrives.
    /// Out-of-order fragments (a continuation with nothing started, or a new data opcode while a
    /// message is still open) and oversized reassembled messages close the connection.
    private func handleDataFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1, 0x2:
            guard fragmentOpcode == nil else {
                close()
                return
            }
            if fin {
                deliver(opcode: opcode, payload: payload)
            } else {
                fragmentOpcode = opcode
                fragmentBuffer = payload
            }
        case 0x0:
            guard let firstOpcode = fragmentOpcode else {
                close()
                return
            }
            fragmentBuffer.append(payload)
            guard fragmentBuffer.count <= ClipboardLimits.maxWebSocketMessageBytes else {
                close()
                return
            }
            if fin {
                let message = fragmentBuffer
                fragmentOpcode = nil
                fragmentBuffer = Data()
                deliver(opcode: firstOpcode, payload: message)
            }
        default:
            close()
            return
        }

        receiveFrame()
    }

    private func deliver(opcode: UInt8, payload: Data) {
        if opcode == 0x1, let text = String(data: payload, encoding: .utf8) {
            onText?(text)
        } else if opcode == 0x2 {
            onBinary?(payload)
        }
    }

    private func receiveExact(_ count: Int, accumulated: Data = Data(), completion: @escaping (Data?) -> Void) {
        guard count > 0 else {
            completion(Data())
            return
        }

        let remaining = count - accumulated.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            var next = accumulated
            if let data {
                next.append(data)
            }

            if next.count >= count {
                completion(Data(next.prefix(count)))
                return
            }

            if error != nil || isComplete {
                completion(nil)
                return
            }

            self.receiveExact(count, accumulated: next, completion: completion)
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode)

        switch payload.count {
        case 0..<126:
            frame.append(UInt8(payload.count))
        case 126...65_535:
            frame.append(126)
            var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        default:
            frame.append(127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }

        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
        })
    }

    private static func headerValue(_ name: String, in header: String) -> String? {
        let lowerName = name.lowercased()
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == lowerName else {
                continue
            }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func acceptKey(for key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }
}
