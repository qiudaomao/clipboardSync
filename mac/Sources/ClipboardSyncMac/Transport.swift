import Foundation

protocol Transport: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
    var onMessage: ((String) -> Void)? { get set }
    var onPeerCount: ((Int) -> Void)? { get set }

    func start()
    func stop()
    /// `to` is an optional routing hint naming the intended receiver's device id. A server
    /// transport delivers the message to just that peer's connection when it knows which one that
    /// is (falling back to broadcast); a client transport ignores it — its server relays by the
    /// same hint carried inside the message envelope.
    func send(_ message: String, to deviceId: String?)
}

extension Transport {
    func send(_ message: String) {
        send(message, to: nil)
    }
}
