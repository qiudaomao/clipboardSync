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
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        onPeerCount?(0)
        onStatus?("stopped")
    }

    func send(_ message: String) {
        task?.send(.string(message)) { [weak self] error in
            if let error {
                self?.onStatus?("send failed: \(error.localizedDescription)")
            }
        }
    }

    private func connect() {
        guard shouldRun, let url = URL(string: "ws://\(host):\(port)/") else {
            return
        }

        onStatus?("connecting \(host):\(port)")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else {
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
                    self.onStatus?("disconnected: \(error.localizedDescription)")
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

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onPeerCount?(1)
        onStatus?("connected \(host):\(port)")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if shouldRun {
            onPeerCount?(0)
            onStatus?("disconnected; retrying")
            scheduleReconnect()
        }
    }
}
