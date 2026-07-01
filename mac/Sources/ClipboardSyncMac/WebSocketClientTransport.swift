import Foundation

final class WebSocketClientTransport: NSObject, Transport, URLSessionWebSocketDelegate {
    var onStatus: ((String) -> Void)?
    var onMessage: ((String) -> Void)?
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

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        super.init()
    }

    func start() {
        shouldRun = true
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
        onPeerCount?(0)
        onStatus?(AppText.text("status.stopped"))
    }

    func send(_ message: String) {
        task?.send(.string(message)) { [weak self] error in
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
        self.session = session
        self.task = task
        task.resume()
        receiveLoop()
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
                self.onMessage?(text)
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
        guard shouldRun, task === webSocketTask else {
            return
        }
        onPeerCount?(1)
        onStatus?(AppText.format("status.connected", host, port))
        startKeepAlive()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
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
