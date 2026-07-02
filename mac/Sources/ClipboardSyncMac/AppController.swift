import AppKit
import Foundation

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clipboard = ClipboardCoordinator()
    private let deviceId = DeviceIdentity.current
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let screenLayoutStore = ScreenLayoutStore()
    private lazy var inputCoordinator = InputSharingCoordinator(deviceId: deviceId, layoutStore: screenLayoutStore)

    private var config = AppConfig.load()
    private var transport: Transport?
    private var peerCount = 0
    private var presenceTimer: Timer?
    private static let presenceHeartbeatInterval: TimeInterval = 5
    private static let presenceStaleTimeout: TimeInterval = 15
    private var isLocalLayoutWindowOpen = false
    private var layoutWatchers: Set<String> = []
    private var cursorReportTimer: Timer?
    private static let cursorReportInterval: TimeInterval = 1.0 / 30.0
    private var pendingInputConfigSync = false
    private var statusText = AppText.text("status.stopped") {
        didSet {
            updateMenu()
        }
    }

    private var statusMenuItem = NSMenuItem()
    private var serverModeItem = NSMenuItem()
    private var clientModeItem = NSMenuItem()
    private var inputStatusMenuItem = NSMenuItem()
    private var inputSharingItem = NSMenuItem()
    private var controlDeviceMenuItem = NSMenuItem(title: AppText.text("menu.controlDevice"), action: nil, keyEquivalent: "")
    private var controlDeviceMenu = NSMenu(title: AppText.text("menu.controlDevice"))
    private var inputDevices: [String: InputDeviceMenuDevice] = [:]
    private var historyMenu = NSMenu(title: AppText.text("menu.clipboardHistory"))
    private var historyMenuItem = NSMenuItem(title: AppText.text("menu.clipboardHistory"), action: nil, keyEquivalent: "")
    private var history: [ClipboardHistoryEntry] = []
    private lazy var settingsWindowController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onSave = { [weak self] nextConfig in
            self?.applyConfig(nextConfig)
        }
        return controller
    }()
    private lazy var screenLayoutWindowController: ScreenLayoutWindowController = {
        let controller = ScreenLayoutWindowController()
        controller.onLayoutChanged = { [weak self] entries in
            self?.applyLocalLayoutChange(entries)
        }
        controller.onWindowClosed = { [weak self] in
            self?.handleScreenLayoutWindowClosed()
        }
        return controller
    }()

    private struct InputDeviceMenuDevice {
        let id: String
        var name: String?
        var address: String?
        var role: String?
        var inputEnabled: Bool?
        var lastSeen: Date

        var baseTitle: String {
            let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName: String
            if let trimmedName, !trimmedName.isEmpty {
                baseName = trimmedName
            } else {
                baseName = AppText.text("device.unknown")
            }
            guard let address, !address.isEmpty else {
                return baseName
            }
            return "\(baseName) (\(address))"
        }

        var title: String {
            let status = inputEnabled.map {
                $0 ? AppText.text("state.enabled") : AppText.text("state.disabled")
            } ?? AppText.text("state.unknown")
            return AppText.format("device.titleStatus", baseTitle, status)
        }
    }

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
        registerLocalScreen()
        inputCoordinator.start()
        updateInputCoordinator()
        restartTransport()
        startPresenceHeartbeat()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clipboard.stop()
        inputCoordinator.stop()
        transport?.stop()
        presenceTimer?.invalidate()
        cursorReportTimer?.invalidate()
    }

    /// Periodically re-broadcasts our own hello (so peers keep our `lastSeen` fresh even when we
    /// have nothing else to send) and prunes any peer we haven't heard from in a while — otherwise
    /// a disconnected device's screens and menu entry would linger forever, since nothing else ever
    /// removes them.
    private func startPresenceHeartbeat() {
        presenceTimer?.invalidate()
        let timer = Timer(timeInterval: Self.presenceHeartbeatInterval, repeats: true) { [weak self] _ in
            self?.sendInputHello()
            self?.pruneStaleDevices()
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
    }

    private func pruneStaleDevices() {
        let cutoff = Date().addingTimeInterval(-Self.presenceStaleTimeout)
        let staleIds = inputDevices.values.filter { $0.lastSeen < cutoff }.map(\.id)
        guard !staleIds.isEmpty else {
            return
        }

        let layoutChanged = staleIds.reduce(false) { removeKnownDevice($1) || $0 }

        updateCursorReporting()
        updateMenu()
        updateInputCoordinator()
        if layoutChanged {
            refreshScreenLayoutWindowIfVisible()
            if config.mode == .server {
                broadcastLayout()
            }
        }
    }

    /// Forgets everything we knew about one peer device (menu entry, layout-watch state, its
    /// screens). Returns whether that changed the shared screen layout.
    @discardableResult
    private func removeKnownDevice(_ staleId: String) -> Bool {
        inputDevices.removeValue(forKey: staleId)
        layoutWatchers.remove(staleId)
        let layoutChanged = screenLayoutStore.remove(deviceId: staleId)
        if config.controlDeviceId == staleId {
            config.controlDeviceId = nil
            config.save()
        }
        return layoutChanged
    }

    /// Called the moment the last remaining peer disconnects. At that point we know with certainty
    /// every other device we'd been tracking is gone, so we can clear them immediately instead of
    /// waiting for the slower staleness sweep (`pruneStaleDevices`) to notice one-by-one, which is
    /// what caused a disconnected peer's screen-layout rect to visibly linger for several seconds
    /// after its menu entry (driven by the transport's near-instant peer count) had already updated.
    private func clearAllKnownPeers() {
        guard !inputDevices.isEmpty else {
            return
        }
        let staleIds = Array(inputDevices.keys)
        let layoutChanged = staleIds.reduce(false) { removeKnownDevice($1) || $0 }

        updateCursorReporting()
        updateMenu()
        updateInputCoordinator()
        if layoutChanged {
            refreshScreenLayoutWindowIfVisible()
        }
    }

    private func setupMenu() {
        if let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: AppText.text("app.name")) {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
        } else if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = AppText.text("app.shortName")
        }
        statusItem.button?.toolTip = AppText.text("app.name")

        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem = NSMenuItem(title: AppText.format("status.prefix", AppText.text("status.stopped")), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        historyMenuItem.submenu = historyMenu
        menu.addItem(historyMenuItem)
        menu.addItem(NSMenuItem.separator())

        let sendFilesItem = NSMenuItem(title: AppText.text("menu.sendFiles"), action: #selector(sendFilesFromClipboard), keyEquivalent: "")
        sendFilesItem.target = self
        menu.addItem(sendFilesItem)
        menu.addItem(NSMenuItem.separator())

        inputStatusMenuItem = NSMenuItem(title: AppText.text("input.off"), action: nil, keyEquivalent: "")
        inputStatusMenuItem.isEnabled = false
        menu.addItem(inputStatusMenuItem)

        inputSharingItem = NSMenuItem(title: AppText.text("menu.enableInputSharing"), action: #selector(toggleInputSharing), keyEquivalent: "")
        inputSharingItem.target = self
        menu.addItem(inputSharingItem)

        controlDeviceMenuItem.submenu = controlDeviceMenu
        menu.addItem(controlDeviceMenuItem)

        let screenLayoutItem = NSMenuItem(title: AppText.text("menu.screenLayout"), action: #selector(showScreenLayout), keyEquivalent: "")
        screenLayoutItem.target = self
        menu.addItem(screenLayoutItem)
        menu.addItem(NSMenuItem.separator())

        clientModeItem = NSMenuItem(title: AppText.text("menu.clientMode"), action: #selector(setClientMode), keyEquivalent: "")
        clientModeItem.target = self
        menu.addItem(clientModeItem)

        serverModeItem = NSMenuItem(title: AppText.text("menu.serverMode"), action: #selector(setServerMode), keyEquivalent: "")
        serverModeItem.target = self
        menu.addItem(serverModeItem)

        menu.addItem(NSMenuItem.separator())

        let configureItem = NSMenuItem(title: AppText.text("menu.settings"), action: #selector(showConfiguration), keyEquivalent: ",")
        configureItem.target = self
        menu.addItem(configureItem)

        let startItem = NSMenuItem(title: AppText.text("menu.start"), action: #selector(startTransport), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        let restartItem = NSMenuItem(title: AppText.text("menu.restart"), action: #selector(restartTransportFromMenu), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        let stopItem = NSMenuItem(title: AppText.text("menu.stop"), action: #selector(stopTransport), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: AppText.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
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
        statusMenuItem.title = AppText.format("status.prefix", statusText)
        clientModeItem.state = config.mode == .client ? .on : .off
        serverModeItem.state = config.mode == .server ? .on : .off
        inputSharingItem.state = config.inputSharingEnabled ? .on : .off
        refreshControlDeviceMenu()
        refreshHistoryMenu()
    }

    private var effectiveControlDeviceId: String {
        guard let controlDeviceId = config.controlDeviceId, !controlDeviceId.isEmpty else {
            return deviceId
        }
        return controlDeviceId
    }

    private var localInputDevice: InputDeviceMenuDevice {
        InputDeviceMenuDevice(
            id: deviceId,
            name: DeviceIdentity.displayName,
            address: DeviceIdentity.address,
            role: config.mode.rawValue,
            inputEnabled: config.inputSharingEnabled,
            lastSeen: Date()
        )
    }

    private func refreshControlDeviceMenu() {
        controlDeviceMenu.removeAllItems()

        let selectedId = effectiveControlDeviceId
        var devices = [localInputDevice]
        devices.append(contentsOf: inputDevices.values
            .filter { $0.id != deviceId }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })

        if !devices.contains(where: { $0.id == selectedId }) {
            devices.append(InputDeviceMenuDevice(
                id: selectedId,
                name: AppText.text("device.unknown"),
                address: nil,
                role: nil,
                inputEnabled: nil,
                lastSeen: Date.distantPast
            ))
        }

        let selectedTitle = devices.first { $0.id == selectedId }?.title ?? AppText.text("device.unknown")
        controlDeviceMenuItem.title = AppText.format("menu.controlDeviceWithTitle", selectedTitle)

        for device in devices {
            let item = NSMenuItem(title: device.title, action: #selector(setControlDevice), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == selectedId ? .on : .off
            controlDeviceMenu.addItem(item)
        }
    }

    private func rememberInputDevice(from message: InputMessage) {
        guard message.origin != deviceId else {
            return
        }

        let existing = inputDevices[message.origin]
        inputDevices[message.origin] = InputDeviceMenuDevice(
            id: message.origin,
            name: message.deviceName ?? existing?.name,
            address: message.deviceAddress ?? existing?.address,
            role: message.role ?? existing?.role,
            inputEnabled: message.enabled ?? existing?.inputEnabled,
            lastSeen: Date()
        )

        if let screens = message.screens, screenLayoutStore.merge(deviceId: message.origin, screens: screens) {
            if config.mode == .server {
                broadcastLayout()
            }
            refreshScreenLayoutWindowIfVisible()
        }

        updateMenu()
    }

    private var deviceEnabledMap: [String: Bool] {
        var map: [String: Bool] = [deviceId: config.inputSharingEnabled]
        for device in inputDevices.values {
            if let inputEnabled = device.inputEnabled {
                map[device.id] = inputEnabled
            }
        }
        return map
    }

    private var deviceDisplayNames: [String: String] {
        var names: [String: String] = [deviceId: DeviceIdentity.displayName]
        for device in inputDevices.values {
            names[device.id] = device.baseTitle
        }
        return names
    }

    private func registerLocalScreen() {
        if screenLayoutStore.merge(deviceId: deviceId, screens: InputSharingCoordinator.currentScreens()) {
            refreshScreenLayoutWindowIfVisible()
        }
    }

    @objc private func showScreenLayout() {
        registerLocalScreen()
        isLocalLayoutWindowOpen = true
        broadcastLayoutWatch(enabled: true)
        updateCursorReporting()
        screenLayoutWindowController.show(
            entries: screenLayoutStore.snapshot(),
            localDeviceId: deviceId,
            deviceNames: deviceDisplayNames
        )
    }

    private func handleScreenLayoutWindowClosed() {
        isLocalLayoutWindowOpen = false
        broadcastLayoutWatch(enabled: false)
        updateCursorReporting()
    }

    /// Lets every peer know whether this device is (or isn't) watching the shared layout, so peers
    /// with their own window closed still start reporting their live cursor position — otherwise
    /// only whichever device already has its window open would ever show up moving.
    private func broadcastLayoutWatch(enabled: Bool) {
        guard transport != nil, !config.password.isEmpty, peerCount > 0 else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: nil,
            kind: "layoutWatch",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: enabled,
            controlDeviceId: nil,
            layout: nil,
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func handleLayoutWatchMessage(_ message: InputMessage) {
        if message.enabled == true {
            layoutWatchers.insert(message.origin)
        } else {
            layoutWatchers.remove(message.origin)
        }
        updateCursorReporting()
    }

    /// Starts or stops the periodic local-cursor report: active whenever this device's own layout
    /// window is open, or at least one peer has told us (via `layoutWatch`) that theirs is.
    private func updateCursorReporting() {
        let shouldReport = isLocalLayoutWindowOpen || !layoutWatchers.isEmpty
        guard shouldReport else {
            cursorReportTimer?.invalidate()
            cursorReportTimer = nil
            return
        }
        guard cursorReportTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: Self.cursorReportInterval, repeats: true) { [weak self] _ in
            self?.reportLocalCursor()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorReportTimer = timer
        reportLocalCursor()
    }

    private func reportLocalCursor() {
        let report = InputSharingCoordinator.currentLocalCursorReport(deviceId: deviceId, entries: screenLayoutStore.snapshot())
        if isLocalLayoutWindowOpen {
            screenLayoutWindowController.setLocalCursor(screenId: report?.screenId, normalizedX: report?.normalizedX, normalizedY: report?.normalizedY)
        }
        guard let report else {
            return
        }
        broadcastCursorPosition(screenId: report.screenId, normalizedX: report.normalizedX, normalizedY: report.normalizedY)
    }

    private func refreshScreenLayoutWindowIfVisible() {
        guard screenLayoutWindowController.window?.isVisible == true else {
            return
        }
        screenLayoutWindowController.show(
            entries: screenLayoutStore.snapshot(),
            localDeviceId: deviceId,
            deviceNames: deviceDisplayNames
        )
    }

    private func applyLocalLayoutChange(_ entries: [ScreenLayoutEntry]) {
        // Apply to our own persisted copy immediately, regardless of role — a client shouldn't
        // depend on the server's round-trip broadcast landing before the app might quit to have
        // its own drag survive a restart. The server request below still propagates the change to
        // the server's canonical table and other peers.
        screenLayoutStore.applyPositionUpdates(entries)
        switch config.mode {
        case .server:
            broadcastLayout()
        case .client:
            sendLayoutRequest(entries)
        }
        updateInputCoordinator()
    }

    private func broadcastLayout() {
        guard transport != nil, !config.password.isEmpty else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: nil,
            kind: "layout",
            role: config.mode.rawValue,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: screenLayoutStore.snapshot(),
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func sendLayoutRequest(_ entries: [ScreenLayoutEntry]) {
        guard transport != nil, !config.password.isEmpty else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: nil,
            kind: "layout",
            role: config.mode.rawValue,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: entries,
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func broadcastCursorPosition(screenId: String, normalizedX: Double, normalizedY: Double) {
        guard transport != nil, !config.password.isEmpty, peerCount > 0 else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: nil,
            kind: "cursor",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: nil,
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970,
            cursor: InputCursorPayload(screenId: screenId, normalizedX: normalizedX, normalizedY: normalizedY)
        ))
    }

    private func handleCursorMessage(_ message: InputMessage) {
        guard let cursor = message.cursor else {
            return
        }
        screenLayoutWindowController.updateRemoteCursor(
            deviceId: message.origin,
            screenId: cursor.screenId,
            normalizedX: cursor.normalizedX,
            normalizedY: cursor.normalizedY
        )
    }

    private func handleLayoutMessage(_ message: InputMessage) {
        guard let layout = message.layout else {
            return
        }
        switch config.mode {
        case .server:
            guard message.role == SyncMode.client.rawValue else {
                return
            }
            screenLayoutStore.applyPositionUpdates(layout)
            broadcastLayout()
        case .client:
            guard message.role == SyncMode.server.rawValue else {
                return
            }
            screenLayoutStore.applySnapshot(layout)
        }
        refreshScreenLayoutWindowIfVisible()
        updateInputCoordinator()
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
        layoutWatchers.removeAll()
        updateCursorReporting()
        updateInputCoordinator()
        statusText = AppText.text("status.stopped")
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
        updateInputCoordinator(sendHello: true)
    }

    @objc private func setControlDevice(_ sender: NSMenuItem) {
        guard let controlDeviceId = sender.representedObject as? String else {
            return
        }
        config.controlDeviceId = controlDeviceId
        config.save()
        updateInputCoordinator()
        syncInputConfig()
    }

    @objc private func sendFilesFromClipboard() {
        guard let content = clipboard.readFilesForManualSend() else {
            statusText = AppText.text("status.copyFilesFirst")
            return
        }

        if transport == nil {
            restartTransport()
        }
        guard transport != nil else {
            return
        }

        if publish(content) {
            statusText = AppText.text("status.fileTransferStarted")
        }
    }

    private func applyConfig(_ nextConfig: AppConfig) {
        let previousConfig = config
        let shouldRestartTransport = requiresTransportRestart(from: previousConfig, to: nextConfig)
        let shouldSendHello = previousConfig.inputSharingEnabled != nextConfig.inputSharingEnabled
        let shouldSyncInputConfig = sharedInputConfigChanged(from: previousConfig, to: nextConfig)

        config = nextConfig
        config.save()
        if shouldRestartTransport {
            pendingInputConfigSync = true
            restartTransport()
            return
        }

        updateInputCoordinator(sendHello: shouldSendHello)
        if shouldSyncInputConfig {
            syncInputConfig()
        }
    }

    private func requiresTransportRestart(from previous: AppConfig, to next: AppConfig) -> Bool {
        if transport == nil, canStartTransport(next) {
            return true
        }
        if canStartTransport(previous) != canStartTransport(next) {
            return true
        }
        if previous.mode != next.mode || previous.port != next.port {
            return true
        }
        if (previous.mode == .client || next.mode == .client) && previous.host != next.host {
            return true
        }
        return false
    }

    private func canStartTransport(_ configuration: AppConfig) -> Bool {
        guard !configuration.password.isEmpty else {
            return false
        }
        if configuration.mode == .client {
            return !configuration.host.isEmpty && !NetworkAddress.isLoopbackHost(configuration.host)
        }
        return true
    }

    private func sharedInputConfigChanged(from previous: AppConfig, to next: AppConfig) -> Bool {
        previous.controlDeviceId != next.controlDeviceId
    }

    private func restartTransport() {
        transport?.stop()
        peerCount = 0
        layoutWatchers.removeAll()
        updateCursorReporting()
        updateInputCoordinator()

        guard !config.password.isEmpty else {
            transport = nil
            statusText = AppText.text("status.setSyncPassword")
            return
        }

        let nextTransport: Transport
        switch config.mode {
        case .client:
            guard !config.host.isEmpty else {
                statusText = AppText.text("status.setServerLanIp")
                return
            }
            guard !NetworkAddress.isLoopbackHost(config.host) else {
                statusText = AppText.text("status.useLanIp")
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
                let previousCount = self.peerCount
                self.peerCount = count
                self.updateInputCoordinator(sendHello: true)
                if self.config.mode == .server || self.pendingInputConfigSync {
                    self.sendInputConfig()
                    self.pendingInputConfigSync = false
                }
                if self.isLocalLayoutWindowOpen {
                    self.broadcastLayoutWatch(enabled: true)
                }
                if count == 0, previousCount > 0 {
                    self.clearAllKnownPeers()
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
        _ = sendEncryptedInput(message)
    }

    @discardableResult
    private func sendEncrypted<T: Encodable>(_ message: T) -> Bool {
        guard
            let data = try? jsonEncoder.encode(message),
            let envelope = try? CryptoBox.encrypt(data, password: config.password),
            let envelopeData = try? jsonEncoder.encode(envelope),
            let payload = String(data: envelopeData, encoding: .utf8)
        else {
            statusText = AppText.text("status.encryptionFailed")
            return false
        }

        guard envelopeData.count <= ClipboardLimits.maxWebSocketMessageBytes else {
            statusText = AppText.text("status.clipboardPayloadTooLarge")
            return false
        }

        transport?.send(payload)
        return true
    }

    @discardableResult
    private func sendEncryptedInput(_ message: InputMessage) -> Bool {
        guard
            let data = try? jsonEncoder.encode(message),
            let envelope = try? CryptoBox.encryptRealtime(data, password: config.password),
            let envelopeData = try? jsonEncoder.encode(envelope),
            let payload = String(data: envelopeData, encoding: .utf8)
        else {
            statusText = AppText.text("status.encryptionFailed")
            return false
        }

        guard envelopeData.count <= ClipboardLimits.maxWebSocketMessageBytes else {
            statusText = AppText.text("status.inputPayloadTooLarge")
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

        rememberInputDevice(from: message)

        if message.kind == "config" {
            handleInputConfig(message)
            return
        }

        if message.kind == "layout" {
            handleLayoutMessage(message)
            return
        }

        if message.kind == "cursor" {
            handleCursorMessage(message)
            return
        }

        if message.kind == "layoutWatch" {
            handleLayoutWatchMessage(message)
            return
        }

        if message.kind == "hello", config.mode == .client, message.role == SyncMode.server.rawValue {
            if let controlDeviceId = message.controlDeviceId, config.controlDeviceId != controlDeviceId {
                config.controlDeviceId = controlDeviceId
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
        guard let controlDeviceId = message.controlDeviceId, config.controlDeviceId != controlDeviceId else {
            return false
        }
        config.controlDeviceId = controlDeviceId
        config.save()
        updateInputCoordinator()
        return true
    }

    private func updateInputCoordinator(sendHello: Bool = false) {
        inputCoordinator.update(
            config: config,
            role: config.mode,
            peerCount: peerCount,
            deviceEnabled: deviceEnabledMap,
            deviceNames: deviceDisplayNames
        )
        updateMenu()
        if sendHello {
            sendInputHello()
        }
    }

    private func sendInputHello() {
        guard transport != nil, !config.password.isEmpty else {
            return
        }
        publishInput(inputCoordinator.makeHello(
            deviceName: DeviceIdentity.displayName,
            deviceAddress: DeviceIdentity.address
        ))
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
            deviceName: DeviceIdentity.displayName,
            deviceAddress: DeviceIdentity.address,
            screens: nil,
            enabled: nil,
            controlDeviceId: effectiveControlDeviceId,
            layout: nil,
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
            let emptyItem = NSMenuItem(title: AppText.text("menu.noClipboardHistory"), action: nil, keyEquivalent: "")
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
        let clearItem = NSMenuItem(title: AppText.text("menu.clearClipboardHistory"), action: #selector(clearHistory), keyEquivalent: "")
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
            statusText = AppText.text("status.restoreHistoryFailed")
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
