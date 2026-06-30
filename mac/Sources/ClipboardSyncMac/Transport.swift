import Foundation

protocol Transport: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
    var onMessage: ((String) -> Void)? { get set }

    func start()
    func stop()
    func send(_ message: String)
}
