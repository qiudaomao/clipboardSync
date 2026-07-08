import Foundation
import Network

/// Runs the port-forward data plane. For every enabled rule whose "In" side is this device it
/// listens on that TCP port, and tunnels each accepted connection to the rule's "Out" device as
/// encrypted `tunnel` messages over the existing sync transport. When a peer opens a tunnel into
/// this device, it dials `127.0.0.1:<outPort>` and streams both directions until either end closes.
final class PortForwardCoordinator {
    var onSend: ((TunnelMessage) -> Void)?
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
            case "data":
                self.handleData(message)
            case "close":
                self.removeTunnel(message.connectionId, notifyPeer: false, reason: nil)
            default:
                break
            }
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
                listener = try NWListener(using: .tcp, on: nwPort)
            } else {
                // Loopback only: pinning the listener's required local endpoint to 127.0.0.1 keeps
                // the forwarded port unreachable from anywhere but this machine.
                let parameters = NWParameters.tcp
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
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let tunnel = Tunnel(connectionId: message.connectionId, peerDeviceId: message.origin, connection: connection)
        tunnels[message.connectionId] = tunnel
        start(tunnel)
    }

    private func handleData(_ message: TunnelMessage) {
        guard
            let tunnel = tunnels[message.connectionId],
            let base64 = message.dataBase64,
            let payload = Data(base64Encoded: base64)
        else {
            return
        }

        guard tunnel.isReady else {
            tunnel.pendingPayloads.append(payload)
            return
        }
        write(payload, to: tunnel)
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
                self.send(kind: "data", tunnel: tunnel, dataBase64: data.base64EncodedString())
            }

            if error != nil || isComplete {
                self.removeTunnel(tunnel.connectionId, notifyPeer: true, reason: nil)
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
