import AppKit
import Foundation

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clipboard = ClipboardCoordinator()
    private let deviceId = DeviceIdentity.current
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private lazy var inputCoordinator = InputSharingCoordinator(deviceId: deviceId)

    private var config = AppConfig.load()
    private var transport: Transport?
    private var peerCount = 0
    private var pendingInputConfigSync = false
    private var statusText = "stopped" {
        didSet {
            updateMenu()
        }
    }

    private var statusMenuItem = NSMenuItem()
    private var serverModeItem = NSMenuItem()
    private var clientModeItem = NSMenuItem()
    private var inputStatusMenuItem = NSMenuItem()
    private var inputSharingItem = NSMenuItem()
    private var serverControlsClientItem = NSMenuItem()
    private var clientControlsServerItem = NSMenuItem()
    private var peerEdgeItems: [ScreenEdge: NSMenuItem] = [:]
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        clipboard.onLocalContent = { [weak self] content in
            self?.publish(content)
        }
        clipboard.onLocalSkipped = { [weak self] reason in
            self?.statusText = reason
        }
        inputCoordinator.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                self?.publishInput(message)
            }
        }
        inputCoordinator.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.inputStatusMenuItem.title = status
            }
        }
        clipboard.start()
        inputCoordinator.start()
        updateInputCoordinator()
        restartTransport()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clipboard.stop()
        inputCoordinator.stop()
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
        menu.delegate = self
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

        inputStatusMenuItem = NSMenuItem(title: "Input Sharing: off", action: nil, keyEquivalent: "")
        inputStatusMenuItem.isEnabled = false
        menu.addItem(inputStatusMenuItem)

        inputSharingItem = NSMenuItem(title: "Enable Input Sharing", action: #selector(toggleInputSharing), keyEquivalent: "")
        inputSharingItem.target = self
        menu.addItem(inputSharingItem)

        let directionMenu = NSMenu(title: "Control Direction")
        serverControlsClientItem = NSMenuItem(title: "Server -> Client", action: #selector(setInputDirection), keyEquivalent: "")
        serverControlsClientItem.target = self
        serverControlsClientItem.representedObject = InputSharingDirection.serverControlsClient.rawValue
        directionMenu.addItem(serverControlsClientItem)
        clientControlsServerItem = NSMenuItem(title: "Client -> Server", action: #selector(setInputDirection), keyEquivalent: "")
        clientControlsServerItem.target = self
        clientControlsServerItem.representedObject = InputSharingDirection.clientControlsServer.rawValue
        directionMenu.addItem(clientControlsServerItem)
        let directionItem = NSMenuItem(title: "Control Direction", action: nil, keyEquivalent: "")
        directionItem.submenu = directionMenu
        menu.addItem(directionItem)

        let edgeMenu = NSMenu(title: "Peer Position")
        for edge in ScreenEdge.allCases {
            let item = NSMenuItem(title: edge.title, action: #selector(setPeerEdge), keyEquivalent: "")
            item.target = self
            item.representedObject = edge.rawValue
            edgeMenu.addItem(item)
            peerEdgeItems[edge] = item
        }
        let edgeItem = NSMenuItem(title: "Peer Position", action: nil, keyEquivalent: "")
        edgeItem.submenu = edgeMenu
        menu.addItem(edgeItem)
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

        let restartItem = NSMenuItem(title: "Restart", action: #selector(restartTransportFromMenu), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

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

    func menuWillOpen(_ menu: NSMenu) {
        updateInputCoordinator(sendHello: true)
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        else {
            return
        }
        updateInputCoordinator(sendHello: true)
    }

    private func updateMenu() {
        statusMenuItem.title = "Status: \(statusText)"
        clientModeItem.state = config.mode == .client ? .on : .off
        serverModeItem.state = config.mode == .server ? .on : .off
        inputSharingItem.state = config.inputSharingEnabled ? .on : .off
        serverControlsClientItem.state = config.inputSharingDirection == .serverControlsClient ? .on : .off
        clientControlsServerItem.state = config.inputSharingDirection == .clientControlsServer ? .on : .off
        for (edge, item) in peerEdgeItems {
            item.state = config.peerEdge == edge ? .on : .off
        }
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

    @objc private func restartTransportFromMenu() {
        restartTransport()
    }

    @objc private func stopTransport() {
        transport?.stop()
        transport = nil
        peerCount = 0
        updateInputCoordinator()
        statusText = "stopped"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showConfiguration() {
        settingsWindowController.show(config: config)
    }

    @objc private func toggleInputSharing() {
        config.inputSharingEnabled.toggle()
        config.save()
        updateInputCoordinator()
        syncInputConfig()
    }

    @objc private func setInputDirection(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let direction = InputSharingDirection(rawValue: rawValue)
        else {
            return
        }
        config.inputSharingDirection = direction
        config.save()
        updateInputCoordinator()
        syncInputConfig()
    }

    @objc private func setPeerEdge(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let edge = ScreenEdge(rawValue: rawValue)
        else {
            return
        }
        config.peerEdge = edge
        config.save()
        updateInputCoordinator()
        syncInputConfig()
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
        updateInputCoordinator()
        pendingInputConfigSync = true
        restartTransport()
    }

    private func restartTransport() {
        transport?.stop()
        peerCount = 0
        updateInputCoordinator()

        guard !config.password.isEmpty else {
            transport = nil
            statusText = "set sync password"
            return
        }

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
        nextTransport.onPeerCount = { [weak self] count in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.peerCount = count
                self.updateInputCoordinator(sendHello: true)
                if self.config.mode == .server || self.pendingInputConfigSync {
                    self.sendInputConfig()
                    self.pendingInputConfigSync = false
                }
            }
        }

        transport = nextTransport
        nextTransport.start()
    }

    @discardableResult
    private func publish(_ content: ClipboardContent, recordHistory: Bool = true) -> Bool {
        let message = content.makeMessage(origin: deviceId)

        guard sendEncrypted(message) else {
            return false
        }

        if recordHistory {
            addHistory(content)
        }
        return true
    }

    private func publishInput(_ message: InputMessage) {
        _ = sendEncrypted(message)
    }

    @discardableResult
    private func sendEncrypted<T: Encodable>(_ message: T) -> Bool {
        guard
            let data = try? jsonEncoder.encode(message),
            let envelope = try? CryptoBox.encrypt(data, password: config.password),
            let envelopeData = try? jsonEncoder.encode(envelope),
            let payload = String(data: envelopeData, encoding: .utf8)
        else {
            statusText = "encryption failed"
            return false
        }

        guard envelopeData.count <= ClipboardLimits.maxWebSocketMessageBytes else {
            statusText = "clipboard payload too large"
            return false
        }

        transport?.send(payload)
        return true
    }

    private func handleMessage(_ payload: String) {
        guard
            let envelopeData = payload.data(using: .utf8),
            let envelope = try? jsonDecoder.decode(EncryptedEnvelope.self, from: envelopeData),
            let data = try? CryptoBox.decrypt(envelope, password: config.password),
            let header = try? jsonDecoder.decode(MessageHeader.self, from: data)
        else {
            return
        }

        switch header.type {
        case "clipboard":
            handleClipboardMessage(data)
        case "input":
            handleInputMessage(data)
        default:
            break
        }
    }

    private func handleClipboardMessage(_ data: Data) {
        guard
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

    private func handleInputMessage(_ data: Data) {
        guard
            let message = try? jsonDecoder.decode(InputMessage.self, from: data),
            message.type == "input",
            message.origin != deviceId
        else {
            return
        }

        if message.kind == "config" {
            handleInputConfig(message)
            return
        }

        if message.kind == "hello", config.mode == .client, message.role == SyncMode.server.rawValue {
            var changed = false
            if let direction = message.direction.flatMap(InputSharingDirection.init(rawValue:)), config.inputSharingDirection != direction {
                config.inputSharingDirection = direction
                changed = true
            }
            if let edge = message.peerEdge.flatMap(ScreenEdge.init(rawValue:)), config.peerEdge != edge {
                config.peerEdge = edge
                changed = true
            }
            if changed {
                config.save()
                updateInputCoordinator()
            }
        }

        inputCoordinator.handle(message)
        if message.kind == "hello", config.mode == .server {
            sendInputHello()
        }
    }

    private func handleInputConfig(_ message: InputMessage) {
        switch config.mode {
        case .server:
            guard message.role == SyncMode.client.rawValue else {
                return
            }
            _ = applyInputConfig(message)
            sendInputConfig()
        case .client:
            guard message.role == SyncMode.server.rawValue else {
                return
            }
            _ = applyInputConfig(message)
        }
    }

    @discardableResult
    private func applyInputConfig(_ message: InputMessage) -> Bool {
        var changed = false
        if let enabled = message.enabled, config.inputSharingEnabled != enabled {
            config.inputSharingEnabled = enabled
            changed = true
        }
        if let direction = message.direction.flatMap(InputSharingDirection.init(rawValue:)), config.inputSharingDirection != direction {
            config.inputSharingDirection = direction
            changed = true
        }
        if let edge = message.peerEdge.flatMap(ScreenEdge.init(rawValue:)), config.peerEdge != edge {
            config.peerEdge = edge
            changed = true
        }
        if changed {
            config.save()
            updateInputCoordinator()
        }
        return changed
    }

    private func updateInputCoordinator(sendHello: Bool = false) {
        inputCoordinator.update(config: config, role: config.mode, peerCount: peerCount)
        updateMenu()
        if sendHello {
            sendInputHello()
        }
    }

    private func sendInputHello() {
        guard transport != nil, !config.password.isEmpty else {
            return
        }
        publishInput(inputCoordinator.makeHello())
    }

    private func sendInputConfig() {
        guard transport != nil, !config.password.isEmpty else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: nil,
            kind: "config",
            role: config.mode.rawValue,
            screen: nil,
            enabled: config.inputSharingEnabled,
            direction: config.inputSharingDirection.rawValue,
            peerEdge: config.peerEdge.rawValue,
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func syncInputConfig() {
        pendingInputConfigSync = true
        sendInputConfig()
        if transport != nil, !config.password.isEmpty {
            pendingInputConfigSync = false
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
