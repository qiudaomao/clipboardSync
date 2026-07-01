import CryptoKit
import Foundation
import Network

final class WebSocketServerTransport: Transport {
    var onStatus: ((String) -> Void)?
    var onMessage: ((String) -> Void)?
    var onPeerCount: ((Int) -> Void)?

    private let port: Int
    private let queue = DispatchQueue(label: "ClipboardSyncMac.server")
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: ServerPeer] = [:]

    init(port: Int) {
        self.port = port
    }

    func start() {
        queue.async { [self] in
            do {
                guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                    onStatus?("invalid port")
                    return
                }

                let listener = try NWListener(using: .tcp, on: nwPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.pushStatus()
                    case .failed(let error):
                        self?.onStatus?("server failed: \(error.localizedDescription)")
                    case .cancelled:
                        self?.onStatus?("stopped")
                    default:
                        break
                    }
                }

                self.listener = listener
                listener.start(queue: queue)
                onStatus?("starting server \(NetworkAddress.serverURL(port: port))")
            } catch {
                onStatus?("server error: \(error.localizedDescription)")
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
            self.onStatus?("stopped")
        }
    }

    func send(_ message: String) {
        queue.async {
            self.broadcast(message, excluding: nil)
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = ServerPeer(connection: connection, queue: queue)
        let peerId = ObjectIdentifier(peer)

        peer.onText = { [weak self, weak peer] text in
            guard let self else {
                return
            }
            self.onMessage?(text)
            self.broadcast(text, excluding: peer)
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
        pushStatus()
    }

    private func broadcast(_ message: String, excluding excluded: ServerPeer?) {
        for peer in peers.values where peer !== excluded {
            peer.sendText(message)
        }
    }

    private func pushStatus() {
        onPeerCount?(peers.count)
        onStatus?("server \(NetworkAddress.serverURL(port: port)), \(peers.count) peer(s)")
    }
}

private final class ServerPeer {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var didClose = false
    private var handshakeBuffer = Data()

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
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
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

            let response = [
                "HTTP/1.1 101 Switching Protocols",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Accept: \(Self.acceptKey(for: key))",
                "",
                ""
            ].joined(separator: "\r\n")

            self.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                if error != nil {
                    self.close()
                    return
                }
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
                    self.receivePayload(opcode: opcode, masked: masked, length: length)
                }
            case 127:
                self.receiveExact(8) { [weak self] data in
                    guard let self, let data else {
                        self?.close()
                        return
                    }
                    let length = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    self.receivePayload(opcode: opcode, masked: masked, length: length)
                }
            default:
                self.receivePayload(opcode: opcode, masked: masked, length: firstLength)
            }
        }
    }

    private func receivePayload(opcode: UInt8, masked: Bool, length: UInt64) {
        guard length <= UInt64(ClipboardLimits.maxWebSocketMessageBytes) else {
            close()
            return
        }

        let readPayload: (Data?) -> Void = { [weak self] payloadData in
            guard let self, let payload = payloadData else {
                self?.close()
                return
            }

            if opcode == 0x8 {
                self.close()
                return
            }

            if opcode == 0x9 {
                self.sendFrame(opcode: 0xA, payload: payload)
                self.receiveFrame()
                return
            }

            if opcode == 0x1, let text = String(data: payload, encoding: .utf8) {
                self.onText?(text)
            }

            self.receiveFrame()
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
