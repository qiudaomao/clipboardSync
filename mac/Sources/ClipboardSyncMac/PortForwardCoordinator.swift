import Foundation
import Network

/// Runs the port-forward data plane. For every enabled rule whose "In" side is this device it
/// listens on that TCP port, and tunnels each accepted connection to the rule's "Out" device as
/// encrypted `tunnel` messages over the existing sync transport. When a peer opens a tunnel into
/// this device, it dials `127.0.0.1:<outPort>` and streams both directions until either end closes.
final class PortForwardCoordinator {
    var onSend: ((TunnelMessage) -> Void)?
    /// Carries a `data` chunk as raw bytes for the caller to put on the wire as a `TunnelFrame`.
    /// `open` and `close` still go through `onSend` as JSON — they happen once per connection and
    /// carry host/port/reason, whereas this fires for every chunk and is the whole reason the
    /// binary path exists.
    ///
    /// The caller must invoke `completion` once the chunk has been handed to the transport. That
    /// is what paces the reader: without it a fast local socket is drained as fast as the kernel
    /// will yield bytes, regardless of whether the far end can keep up, and the backlog grows in
    /// memory with nothing to bound it.
    var onSendData: ((_ connectionId: String, _ target: String, _ payload: Data, _ completion: @escaping () -> Void) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Fires (on the coordinator's queue) whenever this device's own listen state changes — a rule
    /// starts listening, fails to bind, or leaves the local In set. Carries the full current set of
    /// local rule statuses so the app can refresh the panel and broadcast it to peers.
    var onStatusesChanged: (([PortForwardStatus]) -> Void)?

    private let queue = DispatchQueue(label: "ClipboardSyncMac.portForward")
    private var deviceId = ""
    private var listeners: [Int: RuleListener] = [:]
    private var tunnels: [String: Tunnel] = [:]
    /// Live listen state for rules this device is the In side of, keyed by rule id.
    private var ruleStatuses: [String: PortForwardStatus] = [:]
    private var transportReady = false
    private var onlinePeers: Set<String> = []
    private static let chunkBytes = 60 * 1024
    /// Largest chunk any peer may send. Deliberately above this side's own `chunkBytes`: the Linux
    /// client reads in 64 KiB units, so validating against 60 KiB would reject its traffic and
    /// tear down every Linux-to-macOS tunnel.
    private static let maxInboundChunkBytes = 64 * 1024
    /// Ceiling on bytes read from a tunnel's local socket but not yet handed to the transport.
    /// Reaching it stops reading until the backlog drains, which lets TCP's own window push back
    /// on whatever is writing into the forwarded port instead of buffering it here.
    private static let maxInFlightBytes = 512 * 1024
    /// Ceiling on peer data buffered while the "Out" side is still dialling. A peer that never
    /// completes its connection must not be able to grow this without bound.
    private static let maxPendingBytes = 512 * 1024

    /// TCP parameters for every tunnel socket. Forwarded traffic is overwhelmingly interactive
    /// request/response (SSH, HTTP, RDP), where Nagle's algorithm holds a small write back waiting
    /// for more data while the peer's delayed ACK holds the acknowledgement back waiting for a
    /// response — a mutual stall that shows up as ~40 ms added to every round trip. The tunnel
    /// already batches at the chunk level, so coalescing in the kernel buys nothing.
    private static func tunnelParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private struct RuleListener {
        var rule: PortForwardRule
        let listener: NWListener
    }

    private final class Tunnel {
        let connectionId: String
        let peerDeviceId: String
        let connection: NWConnection
        /// The local socket isn't writable until its NWConnection reaches `.ready`; peer data that
        /// arrives before then (the "Out" dial racing the first "In" chunks) waits here.
        var isReady = false
        var pendingPayloads: [Data] = []
        var pendingBytes = 0
        /// Bytes read from the local socket and passed to `onSendData` but not yet acknowledged.
        var inFlightBytes = 0
        /// Set when `inFlightBytes` hit the ceiling and the read loop stopped re-arming itself; a
        /// send completion that brings the backlog back under the ceiling restarts it.
        var readPaused = false

        init(connectionId: String, peerDeviceId: String, connection: NWConnection) {
            self.connectionId = connectionId
            self.peerDeviceId = peerDeviceId
            self.connection = connection
        }
    }

    /// Reconciles the listener set with the current rule table. Listeners exist only while the
    /// transport is running; each accepted connection additionally requires the rule's "Out"
    /// device to be online right now, otherwise it is refused immediately.
    func update(deviceId: String, rules: [PortForwardRule], transportReady: Bool, onlinePeers: Set<String>) {
        queue.async {
            self.deviceId = deviceId
            self.onlinePeers = onlinePeers
            self.transportReady = transportReady

            guard transportReady else {
                self.teardownAll()
                return
            }

            let desired = Dictionary(
                rules
                    .filter { $0.inDeviceId == deviceId && $0.enabled && (1...65_535).contains($0.inPort) }
                    .map { ($0.inPort, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var statusesChanged = false
            for (port, existing) in self.listeners where desired[port] == nil || desired[port] != existing.rule {
                existing.listener.cancel()
                self.listeners.removeValue(forKey: port)
                // A rule that was edited (port/host/LAN) restarts its listener; drop its stale green
                // so it reads as "starting" until the new listener reports ready or failed.
                if self.ruleStatuses.removeValue(forKey: existing.rule.id) != nil {
                    statusesChanged = true
                }
            }

            // Drop status for rules no longer in the local-enabled-In set (disabled, deleted, or
            // moved to another device).
            let desiredIds = Set(desired.values.map(\.id))
            for staleId in self.ruleStatuses.keys where !desiredIds.contains(staleId) {
                self.ruleStatuses.removeValue(forKey: staleId)
                statusesChanged = true
            }

            for (port, rule) in desired where self.listeners[port] == nil {
                self.startListener(for: rule, on: port)
            }

            if statusesChanged {
                self.notifyStatuses()
            }
        }
    }

    func handle(_ message: TunnelMessage) {
        queue.async {
            switch message.kind {
            case "open":
                self.handleOpen(message)
            case "close":
                self.removeTunnel(message.connectionId, notifyPeer: false, reason: nil)
            default:
                // `data` no longer arrives as JSON; see `handleData(connectionId:payload:)`.
                break
            }
        }
    }

    /// Receives a decoded `TunnelFrame` payload.
    func handleData(connectionId: String, payload: Data) {
        queue.async {
            guard let tunnel = self.tunnels[connectionId], !payload.isEmpty else {
                return
            }
            // Bounds what a buggy or hostile peer can make this side buffer per chunk.
            guard payload.count <= Self.maxInboundChunkBytes else {
                self.removeTunnel(connectionId, notifyPeer: true, reason: "oversized tunnel chunk")
                return
            }
            guard tunnel.isReady else {
                guard tunnel.pendingBytes + payload.count <= Self.maxPendingBytes else {
                    self.removeTunnel(connectionId, notifyPeer: true, reason: "tunnel backlog overflow")
                    return
                }
                tunnel.pendingPayloads.append(payload)
                tunnel.pendingBytes += payload.count
                return
            }
            self.write(payload, to: tunnel)
        }
    }

    func stop() {
        queue.async {
            self.transportReady = false
            self.teardownAll()
        }
    }

    private func teardownAll() {
        for entry in listeners.values {
            entry.listener.cancel()
        }
        listeners.removeAll()
        for tunnel in tunnels.values {
            tunnel.connection.cancel()
        }
        tunnels.removeAll()
        if !ruleStatuses.isEmpty {
            ruleStatuses.removeAll()
            notifyStatuses()
        }
    }

    private func setStatus(_ status: PortForwardStatus) {
        guard ruleStatuses[status.id] != status else {
            return
        }
        ruleStatuses[status.id] = status
        notifyStatuses()
    }

    private func notifyStatuses() {
        onStatusesChanged?(Array(ruleStatuses.values))
    }

    // MARK: - In side (local listener)

    private func startListener(for rule: PortForwardRule, on port: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return
        }
        do {
            let listener: NWListener
            if rule.inAllowLan {
                // All interfaces (0.0.0.0): reachable from other machines on the LAN.
                listener = try NWListener(using: Self.tunnelParameters(), on: nwPort)
            } else {
                // Loopback only: pinning the listener's required local endpoint to 127.0.0.1 keeps
                // the forwarded port unreachable from anywhere but this machine.
                let parameters = Self.tunnelParameters()
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
                listener = try NWListener(using: parameters)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection, rule: rule)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    switch state {
                    case .ready:
                        self?.setStatus(PortForwardStatus(id: rule.id, ok: true, reason: nil))
                    case .waiting(let error):
                        // NWListener parks recoverable bind errors (port in use, privileged port
                        // without root) in `.waiting` and keeps retrying. Surface them as a failure
                        // now — but keep the listener, so it flips to green if the port later frees.
                        self?.reportListenFailure(rule: rule, port: port, error: error, emitStatusLine: false)
                    case .failed(let error):
                        self?.listeners.removeValue(forKey: port)
                        self?.reportListenFailure(rule: rule, port: port, error: error, emitStatusLine: true)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            listeners[port] = RuleListener(rule: rule, listener: listener)
        } catch {
            reportListenFailure(rule: rule, port: port, error: error, emitStatusLine: true)
        }
    }

    /// A privileged port (<1024) can't be bound without root, so single out that case with a
    /// friendlier hint; everything else (port in use, etc.) surfaces the raw OS reason. The reason
    /// is stored as the rule's status (shown red with a tooltip in the panel); `emitStatusLine`
    /// also echoes it to the menu-bar status line (suppressed for the retrying `.waiting` state so
    /// it doesn't flap the global status text).
    private func reportListenFailure(rule: PortForwardRule, port: Int, error: Error, emitStatusLine: Bool) {
        let reason: String
        let statusLine: String
        if case NWError.posix(.EACCES) = error {
            reason = AppText.text("forward.reasonPrivileged")
            statusLine = AppText.format("status.forwardListenPermission", port)
        } else {
            reason = error.localizedDescription
            statusLine = AppText.format("status.forwardListenFailed", port, reason)
        }
        if emitStatusLine {
            onStatus?(statusLine)
        }
        setStatus(PortForwardStatus(id: rule.id, ok: false, reason: reason))
    }

    private func accept(_ connection: NWConnection, rule: PortForwardRule) {
        guard transportReady, onlinePeers.contains(rule.outDeviceId) else {
            connection.cancel()
            return
        }

        let connectionId = UUID().uuidString
        let tunnel = Tunnel(connectionId: connectionId, peerDeviceId: rule.outDeviceId, connection: connection)
        tunnels[connectionId] = tunnel

        send(kind: "open", tunnel: tunnel, host: rule.outHost, port: rule.outPort)
        start(tunnel)
    }

    // MARK: - Out side (local dial)

    private func handleOpen(_ message: TunnelMessage) {
        guard
            let port = message.port,
            (1...65_535).contains(port),
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        else {
            sendClose(connectionId: message.connectionId, to: message.origin, reason: "invalid port")
            return
        }

        let host = message.host.flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: Self.tunnelParameters())
        let tunnel = Tunnel(connectionId: message.connectionId, peerDeviceId: message.origin, connection: connection)
        tunnels[message.connectionId] = tunnel
        start(tunnel)
    }

    // MARK: - Shared stream plumbing

    private func start(_ tunnel: Tunnel) {
        tunnel.connection.stateUpdateHandler = { [weak self, weak tunnel] state in
            self?.queue.async {
                guard let self, let tunnel, self.tunnels[tunnel.connectionId] === tunnel else {
                    return
                }
                switch state {
                case .ready:
                    tunnel.isReady = true
                    let pending = tunnel.pendingPayloads
                    tunnel.pendingPayloads = []
                    tunnel.pendingBytes = 0
                    for payload in pending {
                        self.write(payload, to: tunnel)
                    }
                    self.startReading(tunnel)
                case .failed, .cancelled:
                    self.removeTunnel(tunnel.connectionId, notifyPeer: true, reason: "connection failed")
                default:
                    break
                }
            }
        }
        tunnel.connection.start(queue: queue)
    }

    private func startReading(_ tunnel: Tunnel) {
        tunnel.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkBytes) { [weak self, weak tunnel] data, _, isComplete, error in
            guard let self, let tunnel, self.tunnels[tunnel.connectionId] === tunnel else {
                return
            }

            if let data, !data.isEmpty {
                tunnel.inFlightBytes += data.count
                let sentBytes = data.count
                self.onSendData?(tunnel.connectionId, tunnel.peerDeviceId, data) { [weak self, weak tunnel] in
                    self?.queue.async {
                        guard
                            let self,
                            let tunnel,
                            self.tunnels[tunnel.connectionId] === tunnel
                        else {
                            return
                        }
                        tunnel.inFlightBytes -= sentBytes
                        if tunnel.readPaused, tunnel.inFlightBytes < Self.maxInFlightBytes {
                            tunnel.readPaused = false
                            self.startReading(tunnel)
                        }
                    }
                }
            }

            if error != nil || isComplete {
                self.removeTunnel(tunnel.connectionId, notifyPeer: true, reason: nil)
                return
            }

            // Stop pulling from the socket while the backlog is over the ceiling. Not re-arming
            // the receive is what makes TCP's window close on the far side, so the process writing
            // into the forwarded port slows down instead of this one growing without bound.
            guard tunnel.inFlightBytes < Self.maxInFlightBytes else {
                tunnel.readPaused = true
                return
            }

            self.startReading(tunnel)
        }
    }

    private func write(_ payload: Data, to tunnel: Tunnel) {
        tunnel.connection.send(content: payload, completion: .contentProcessed { [weak self, weak tunnel] error in
            guard let self, let tunnel, error != nil else {
                return
            }
            self.queue.async {
                self.removeTunnel(tunnel.connectionId, notifyPeer: true, reason: "write failed")
            }
        })
    }

    private func removeTunnel(_ connectionId: String, notifyPeer: Bool, reason: String?) {
        guard let tunnel = tunnels.removeValue(forKey: connectionId) else {
            return
        }
        tunnel.connection.cancel()
        if notifyPeer {
            sendClose(connectionId: connectionId, to: tunnel.peerDeviceId, reason: reason)
        }
    }

    private func send(kind: String, tunnel: Tunnel, host: String? = nil, port: Int? = nil, dataBase64: String? = nil) {
        onSend?(TunnelMessage(
            type: "tunnel",
            origin: deviceId,
            target: tunnel.peerDeviceId,
            kind: kind,
            connectionId: tunnel.connectionId,
            host: host,
            port: port,
            dataBase64: dataBase64,
            reason: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func sendClose(connectionId: String, to peerDeviceId: String, reason: String?) {
        onSend?(TunnelMessage(
            type: "tunnel",
            origin: deviceId,
            target: peerDeviceId,
            kind: "close",
            connectionId: connectionId,
            host: nil,
            port: nil,
            dataBase64: nil,
            reason: reason,
            sentAt: Date().timeIntervalSince1970
        ))
    }
}
