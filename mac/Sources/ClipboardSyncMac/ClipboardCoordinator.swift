import AppKit

final class ClipboardCoordinator {
    var onLocalText: ((String) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastText: String?

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        lastText = NSPasteboard.general.string(forType: .string)
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func applyRemoteText(_ text: String) {
        guard text != lastText else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastText = text
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text != lastText else {
            return
        }

        lastText = text
        onLocalText?(text)
    }
}
