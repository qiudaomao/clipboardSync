import AppKit
import Foundation

final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clipboard = ClipboardCoordinator()
    private let deviceId = DeviceIdentity.current
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    private var config = AppConfig.load()
    private var transport: Transport?
    private var statusText = "stopped" {
        didSet {
            updateMenu()
        }
    }

    private var statusMenuItem = NSMenuItem()
    private var serverModeItem = NSMenuItem()
    private var clientModeItem = NSMenuItem()
    private var historyMenu = NSMenu(title: "History")
    private var historyMenuItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
    private var history: [ClipboardHistoryEntry] = []
    private lazy var settingsWindowController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] nextConfig in
            self?.applyConfig(nextConfig)
        }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        clipboard.onLocalContent = { [weak self] content in
            self?.publish(content)
        }
        clipboard.onLocalSkipped = { [weak self] reason in
            self?.statusText = reason
        }
        clipboard.start()
        restartTransport()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard.stop()
        transport?.stop()
    }

    private func setupMenu() {
        if let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Clipboard Sync") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
        } else if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "Clip"
        }
        statusItem.button?.toolTip = "Clipboard Sync"

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Status: stopped", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        historyMenuItem.submenu = historyMenu
        menu.addItem(historyMenuItem)
        menu.addItem(NSMenuItem.separator())

        let sendFilesItem = NSMenuItem(title: "Send Files from Clipboard", action: #selector(sendFilesFromClipboard), keyEquivalent: "")
        sendFilesItem.target = self
        menu.addItem(sendFilesItem)
        menu.addItem(NSMenuItem.separator())

        clientModeItem = NSMenuItem(title: "Client mode", action: #selector(setClientMode), keyEquivalent: "")
        clientModeItem.target = self
        menu.addItem(clientModeItem)

        serverModeItem = NSMenuItem(title: "Server mode", action: #selector(setServerMode), keyEquivalent: "")
        serverModeItem.target = self
        menu.addItem(serverModeItem)

        menu.addItem(NSMenuItem.separator())

        let configureItem = NSMenuItem(title: "Settings...", action: #selector(showConfiguration), keyEquivalent: ",")
        configureItem.target = self
        menu.addItem(configureItem)

        let startItem = NSMenuItem(title: "Start", action: #selector(startTransport), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop", action: #selector(stopTransport), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenu()
    }

    private func updateMenu() {
        statusMenuItem.title = "Status: \(statusText)"
        clientModeItem.state = config.mode == .client ? .on : .off
        serverModeItem.state = config.mode == .server ? .on : .off
        refreshHistoryMenu()
    }

    @objc private func setClientMode() {
        config.mode = .client
        config.save()
        restartTransport()
    }

    @objc private func setServerMode() {
        config.mode = .server
        config.save()
        restartTransport()
    }

    @objc private func startTransport() {
        restartTransport()
    }

    @objc private func stopTransport() {
        transport?.stop()
        transport = nil
        statusText = "stopped"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showConfiguration() {
        settingsWindowController.show(config: config)
    }

    @objc private func sendFilesFromClipboard() {
        guard let content = clipboard.readFilesForManualSend() else {
            statusText = "copy files first"
            return
        }

        if transport == nil {
            restartTransport()
        }
        guard transport != nil else {
            return
        }

        if publish(content) {
            statusText = "file transfer started"
        }
    }

    private func applyConfig(_ nextConfig: AppConfig) {
        config = nextConfig
        config.save()
        restartTransport()
    }

    private func restartTransport() {
        transport?.stop()

        let nextTransport: Transport
        switch config.mode {
        case .client:
            guard !config.host.isEmpty else {
                statusText = "set server LAN IP"
                return
            }
            guard !NetworkAddress.isLoopbackHost(config.host) else {
                statusText = "use LAN IP, not 127.0.0.1"
                return
            }
            nextTransport = WebSocketClientTransport(host: config.host, port: config.port)
        case .server:
            nextTransport = WebSocketServerTransport(port: config.port)
        }

        nextTransport.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusText = status
            }
        }
        nextTransport.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                self?.handleMessage(message)
            }
        }

        transport = nextTransport
        nextTransport.start()
    }

    @discardableResult
    private func publish(_ content: ClipboardContent, recordHistory: Bool = true) -> Bool {
        let message = content.makeMessage(origin: deviceId)

        guard
            let data = try? jsonEncoder.encode(message),
            let payload = String(data: data, encoding: .utf8)
        else {
            return false
        }

        guard data.count <= ClipboardLimits.maxWebSocketMessageBytes else {
            statusText = "clipboard payload too large"
            return false
        }

        if recordHistory {
            addHistory(content)
        }
        transport?.send(payload)
        return true
    }

    private func handleMessage(_ payload: String) {
        guard
            let data = payload.data(using: .utf8),
            let message = try? jsonDecoder.decode(SyncMessage.self, from: data),
            message.type == "clipboard",
            message.origin != deviceId,
            let content = message.clipboardContent()
        else {
            return
        }

        if clipboard.applyContent(content) {
            addHistory(content)
        }
    }

    private func addHistory(_ content: ClipboardContent) {
        let signature = content.signature
        history.removeAll { $0.content.signature == signature }
        history.insert(ClipboardHistoryEntry(id: UUID(), content: content, createdAt: Date()), at: 0)
        if history.count > ClipboardLimits.historyLimit {
            history.removeLast(history.count - ClipboardLimits.historyLimit)
        }
        refreshHistoryMenu()
    }

    private func refreshHistoryMenu() {
        historyMenu.removeAllItems()
        guard !history.isEmpty else {
            let emptyItem = NSMenuItem(title: "No clipboard history", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            historyMenu.addItem(emptyItem)
            return
        }

        for entry in history {
            let item = NSMenuItem(title: entry.content.historyTitle, action: #selector(useHistoryItem), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id.uuidString
            historyMenu.addItem(item)
        }

        historyMenu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        historyMenu.addItem(clearItem)
    }

    @objc private func useHistoryItem(_ sender: NSMenuItem) {
        guard
            let idString = sender.representedObject as? String,
            let id = UUID(uuidString: idString),
            let entry = history.first(where: { $0.id == id })
        else {
            return
        }

        guard clipboard.applyContent(entry.content) else {
            statusText = "failed to restore history item"
            return
        }

        addHistory(entry.content)
        publish(entry.content, recordHistory: false)
    }

    @objc private func clearHistory() {
        history.removeAll()
        refreshHistoryMenu()
    }
}
