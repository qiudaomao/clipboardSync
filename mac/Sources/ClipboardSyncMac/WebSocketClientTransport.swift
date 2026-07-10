import Foundation

final class WebSocketClientTransport: NSObject, Transport, URLSessionWebSocketDelegate {
    var onStatus: ((String) -> Void)?
    var onMessage: ((String, Bool) -> Void)?
    var onPeerCount: ((Int) -> Void)?

    private let host: String
    private let port: Int
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var shouldRun = false
    private var reconnectScheduled = false
    private let keepAliveInterval: TimeInterval = 10
    private var keepAliveTimer: DispatchSourceTimer?
    private var pingInFlight = false

    /// Optional second connection dedicated to input frames, so they never queue behind bulk
    /// clipboard/file/tunnel frames on the data connection's TCP stream. Established only when
    /// the server echoes the input subprotocol; an old server fails the negotiation and
    /// `inputChannelUnsupported` stops further attempts until the next transport start.
    private var inputSession: URLSession?
    private var inputTask: URLSessionWebSocketTask?
    private var inputChannelReady = false
    private var inputChannelUnsupported = false
    private var inputReconnectScheduled = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        super.init()
    }

    func start() {
        shouldRun = true
        inputChannelUnsupported = false
        connect()
    }

    func stop() {
        shouldRun = false
        reconnectScheduled = false
        stopKeepAlive()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        closeInputChannel()
        onPeerCount?(0)
        onStatus?(AppText.text("status.stopped"))
    }

    func send(_ message: String, to deviceId: String?, realtime: Bool) {
        // A client has a single connection per channel to its server; the server relays targeted
        // messages using the routing hint inside the envelope itself.
        let channelTask = realtime && inputChannelReady ? inputTask : task
        channelTask?.send(.string(message)) { [weak self] error in
            if let error {
                self?.onStatus?(AppText.format("status.sendFailed", error.localizedDescription))
            }
        }
    }

    private func connect() {
        guard shouldRun, let url = URL(string: "ws://\(host):\(port)/") else {
            return
        }

        pingInFlight = false
        onStatus?(AppText.format("status.connecting", host, port))
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        // The default receive cap is 1 MiB; a clipboard image or file-transfer chunk envelope can
        // exceed that, and hitting the cap kills the connection instead of delivering the message.
        task.maximumMessageSize = ClipboardLimits.maxWebSocketMessageBytes
        self.session = session
        self.task = task
        task.resume()
        receiveLoop()
    }

    private func connectInputChannel() {
        guard
            shouldRun,
            !inputChannelUnsupported,
            inputTask == nil,
            task != nil,
            let url = URL(string: "ws://\(host):\(port)/")
        else {
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url, protocols: [TransportChannels.inputSubprotocol])
        task.maximumMessageSize = ClipboardLimits.maxWebSocketMessageBytes
        inputSession = session
        inputTask = task
        task.resume()
        inputReceiveLoop()
    }

    private func closeInputChannel() {
        inputChannelReady = false
        inputReconnectScheduled = false
        inputTask?.cancel(with: .goingAway, reason: nil)
        inputSession?.invalidateAndCancel()
        inputTask = nil
        inputSession = nil
    }

    /// The input channel is an optimization, never a requirement: any failure just drops back to
    /// the data connection and retries later (unless the server already told us it doesn't speak
    /// the subprotocol, in which case retrying is pointless spam).
    private func scheduleInputChannelReconnect() {
        closeInputChannel()
        guard shouldRun, !inputChannelUnsupported, !inputReconnectScheduled else {
            return
        }
        inputReconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.shouldRun else {
                return
            }
            self.inputReconnectScheduled = false
            self.connectInputChannel()
        }
    }

    private func receiveLoop() {
        guard let activeTask = task else {
            return
        }

        activeTask.receive { [weak self, weak activeTask] result in
            guard let self, self.task === activeTask else {
                return
            }

            switch result {
            case .success(.string(let text)):
                self.onMessage?(text, false)
                if self.shouldRun {
                    self.receiveLoop()
                }
            case .success(.data):
                if self.shouldRun {
                    self.receiveLoop()
                }
            case .failure(let error):
                if self.shouldRun {
                    self.onPeerCount?(0)
                    self.onStatus?(AppText.format("status.disconnectedError", error.localizedDescription))
                    self.scheduleReconnect()
                }
            @unknown default:
                if self.shouldRun {
                    self.receiveLoop()
                }
            }
        }
    }

    private func inputReceiveLoop() {
        guard let activeTask = inputTask else {
            return
        }

        activeTask.receive { [weak self, weak activeTask] result in
            guard let self, self.inputTask === activeTask else {
                return
            }

            switch result {
            case .success(.string(let text)):
                self.onMessage?(text, true)
                if self.shouldRun {
                    self.inputReceiveLoop()
                }
            case .success(.data):
                if self.shouldRun {
                    self.inputReceiveLoop()
                }
            case .failure:
                if self.shouldRun {
                    self.scheduleInputChannelReconnect()
                }
            @unknown default:
                if self.shouldRun {
                    self.inputReceiveLoop()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldRun, !reconnectScheduled else {
            return
        }

        reconnectScheduled = true
        stopKeepAlive()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        closeInputChannel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.shouldRun else {
                return
            }
            self.reconnectScheduled = false
            self.connect()
        }
    }

    private func startKeepAlive() {
        stopKeepAlive()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + keepAliveInterval, repeating: keepAliveInterval)
        timer.setEventHandler { [weak self] in
            self?.sendKeepAlivePing()
        }
        keepAliveTimer = timer
        timer.resume()
    }

    private func stopKeepAlive() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        pingInFlight = false
    }

    private func sendKeepAlivePing() {
        guard shouldRun, let activeTask = task else {
            return
        }

        if pingInFlight {
            onPeerCount?(0)
            onStatus?(AppText.text("status.disconnectedKeepalive"))
            scheduleReconnect()
            return
        }

        pingInFlight = true
        activeTask.sendPing { [weak self, weak activeTask] error in
            DispatchQueue.main.async {
                guard let self, self.task === activeTask else {
                    return
                }

                if let error {
                    self.onPeerCount?(0)
                    self.onStatus?(AppText.format("status.disconnectedError", error.localizedDescription))
                    self.scheduleReconnect()
                } else {
                    self.pingInFlight = false
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        if inputTask === webSocketTask {
            guard shouldRun else {
                return
            }
            if `protocol` == TransportChannels.inputSubprotocol {
                inputChannelReady = true
            } else {
                // The server accepted the socket but didn't echo the subprotocol: it predates the
                // input channel. Close and don't retry — the data connection carries everything.
                inputChannelUnsupported = true
                closeInputChannel()
            }
            return
        }
        guard shouldRun, task === webSocketTask else {
            return
        }
        onPeerCount?(1)
        onStatus?(AppText.format("status.connected", host, port))
        startKeepAlive()
        connectInputChannel()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if inputTask === webSocketTask {
            if shouldRun {
                scheduleInputChannelReconnect()
            }
            return
        }
        guard task === webSocketTask else {
            return
        }
        if shouldRun {
            onPeerCount?(0)
            onStatus?(AppText.text("status.disconnectedRetrying"))
            scheduleReconnect()
        }
    }
}
