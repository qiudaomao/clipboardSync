import AppKit
import Foundation
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clipboard = ClipboardCoordinator()
    private let deviceId = DeviceIdentity.current
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let screenLayoutStore = ScreenLayoutStore()
    private lazy var inputCoordinator = InputSharingCoordinator(deviceId: deviceId, layoutStore: screenLayoutStore)
    private let updateController = UpdateController()

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
    private var startStopItem = NSMenuItem()
    private var launchAtLoginItem = NSMenuItem()
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
    private let portForwardStore = PortForwardStore()
    /// This device's own live listen state, keyed by rule id (fed by the coordinator).
    private var localForwardStatuses: [String: PortForwardStatus] = [:]
    /// Listen state reported by peers for the rules they host, keyed by rule id.
    private var remoteForwardStatuses: [String: PortForwardStatus] = [:]
    private var isPortForwardWindowOpen = false
    /// The device-option list the open panel's rows were last built from, so presence changes only
    /// rebuild the rows (which would discard in-progress edits) when the choices actually changed.
    private var portForwardPanelDeviceSignature = ""
    private var sendFilesMenuItem = NSMenuItem(title: AppText.text("menu.sendFiles"), action: nil, keyEquivalent: "")
    private var sendFilesMenu = NSMenu(title: AppText.text("menu.sendFiles"))
    private lazy var fileTransferCoordinator: FileTransferCoordinator = {
        let coordinator = FileTransferCoordinator()
        coordinator.configure(deviceId: deviceId)
        coordinator.onSend = { [weak self] message in
            DispatchQueue.main.async {
                _ = self?.sendEncryptedRealtime(message, routedTo: message.target)
            }
        }
        coordinator.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusText = status
            }
        }
        coordinator.onFilesReceived = { [weak self] urls in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.clipboard.applyReceivedFileURLs(urls)
                self.statusText = AppText.text("status.filesReceived")
                self.postFilesReceivedNotification()
            }
        }
        return coordinator
    }()
    private lazy var portForwardCoordinator: PortForwardCoordinator = {
        let coordinator = PortForwardCoordinator()
        coordinator.onSend = { [weak self] message in
            DispatchQueue.main.async {
                self?.publishTunnel(message)
            }
        }
        coordinator.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusText = status
            }
        }
        coordinator.onStatusesChanged = { [weak self] statuses in
            DispatchQueue.main.async {
                self?.handleLocalForwardStatuses(statuses)
            }
        }
        return coordinator
    }()
    private lazy var portForwardWindowController: PortForwardWindowController = {
        let controller = PortForwardWindowController()
        controller.onSave = { [weak self] rules in
            self?.applyPortForwardRules(rules)
        }
        controller.onWindowClosed = { [weak self] in
            self?.isPortForwardWindowOpen = false
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
        controller.onForgetDevice = { [weak self] id in
            self?.forgetDevice(id)
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

        guard !BetaLicense.isExpired else {
            statusText = AppText.text("status.betaExpired")
            presentBetaExpiredAlert()
            return
        }

        clipboard.start()
        registerLocalScreen()
        inputCoordinator.start()
        updateInputCoordinator()
        restartTransport()
        startPresenceHeartbeat()
    }

    private func presentBetaExpiredAlert() {
        let alert = NSAlert()
        alert.messageText = AppText.text("beta.expiredTitle")
        alert.informativeText = AppText.text("beta.expiredMessage")
        alert.addButton(withTitle: AppText.text("menu.checkForUpdates"))
        alert.addButton(withTitle: AppText.text("menu.quit"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            updateController.checkForUpdates()
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clipboard.stop()
        inputCoordinator.stop()
        portForwardCoordinator.stop()
        transport?.stop()
        presenceTimer?.invalidate()
        cursorReportTimer?.invalidate()
    }

    /// Periodically re-broadcasts our own hello (so peers keep our `lastSeen` fresh even when we
    /// have nothing else to send) and prunes any peer we haven't heard from in a while — otherwise
    /// a disconnected device's menu entry would linger forever, since nothing else ever removes it.
    /// Its screen layout entries are deliberately *not* touched here — see `removeKnownDevice`.
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

        staleIds.forEach { removeKnownDevice($0) }

        updateCursorReporting()
        updateMenu()
        updateInputCoordinator()
        refreshScreenLayoutWindowIfVisible()
    }

    /// Forgets everything we knew about one peer device's *live presence*: its menu entry and
    /// layout-watch state. Deliberately does NOT touch `screenLayoutStore` — a device going offline
    /// (whether it quit, restarted, or just dropped its connection momentarily) shouldn't erase the
    /// position the user dragged it to. Screens for offline devices stay in the layout, drawn as
    /// disconnected, until the user explicitly forgets them (see `forgetDevice`). The user's chosen
    /// `controlDeviceId` is likewise kept: a restarting control device must get control back when
    /// it returns, and (on a server) clearing it here would make hellos broadcast this device as
    /// the controller, permanently reassigning control on every peer. Only `forgetDevice` drops it.
    private func removeKnownDevice(_ staleId: String) {
        inputDevices.removeValue(forKey: staleId)
        layoutWatchers.remove(staleId)
    }

    /// Called the moment the last remaining peer disconnects. At that point we know with certainty
    /// every other device we'd been tracking is gone, so we can mark them offline immediately
    /// instead of waiting for the slower staleness sweep (`pruneStaleDevices`) to notice one-by-one.
    private func clearAllKnownPeers() {
        guard !inputDevices.isEmpty else {
            return
        }
        Array(inputDevices.keys).forEach { removeKnownDevice($0) }

        updateCursorReporting()
        updateMenu()
        updateInputCoordinator()
        refreshScreenLayoutWindowIfVisible()
    }

    /// Explicitly and permanently drops a device's saved screens from the shared layout — the only
    /// path that should ever delete layout entries (offline devices are kept, just drawn as
    /// disconnected). Triggered from the layout window's right-click "Forget This Device" menu.
    private func forgetDevice(_ id: String) {
        guard id != deviceId else {
            return
        }
        removeKnownDevice(id)
        if config.controlDeviceId == id {
            config.controlDeviceId = nil
            config.save()
            updateInputCoordinator()
            syncInputConfig()
        }
        let changed = screenLayoutStore.remove(deviceId: id)
        updateMenu()
        if changed {
            refreshScreenLayoutWindowIfVisible()
        }
        switch config.mode {
        case .server:
            if changed {
                broadcastLayout()
            }
        case .client:
            sendLayoutForgetRequest(deviceId: id)
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

        sendFilesMenuItem.submenu = sendFilesMenu
        menu.addItem(sendFilesMenuItem)
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

        let portForwardItem = NSMenuItem(title: AppText.text("menu.portForward"), action: #selector(showPortForward), keyEquivalent: "")
        portForwardItem.target = self
        menu.addItem(portForwardItem)
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

        let checkForUpdatesItem = NSMenuItem(title: AppText.text("menu.checkForUpdates"), action: #selector(checkForUpdates), keyEquivalent: "")
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        startStopItem = NSMenuItem(title: AppText.text("menu.start"), action: #selector(toggleTransport), keyEquivalent: "")
        startStopItem.target = self
        menu.addItem(startStopItem)

        let restartItem = NSMenuItem(title: AppText.text("menu.restart"), action: #selector(restartTransportFromMenu), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(NSMenuItem.separator())

        launchAtLoginItem = NSMenuItem(title: AppText.text("menu.launchAtLogin"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: AppText.text("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let homepageItem = NSMenuItem(title: AppText.text("menu.homepage"), action: #selector(openProjectHomepage), keyEquivalent: "")
        homepageItem.target = self
        menu.addItem(homepageItem)

        let quitItem = NSMenuItem(title: AppText.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateInputCoordinator(sendHello: true)
        updateMenu()
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
        startStopItem.title = AppText.text(transport == nil ? "menu.start" : "menu.stop")
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshControlDeviceMenu()
        refreshSendFilesMenu()
        refreshHistoryMenu()
    }

    /// One entry per online peer: files go to exactly the device the user picks, never to every
    /// peer at once.
    private func refreshSendFilesMenu() {
        sendFilesMenu.removeAllItems()
        let peers = inputDevices.values
            .filter { $0.id != deviceId }
            .sorted { $0.baseTitle.localizedCaseInsensitiveCompare($1.baseTitle) == .orderedAscending }

        guard !peers.isEmpty else {
            let item = NSMenuItem(title: AppText.text("menu.noPeers"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            sendFilesMenu.addItem(item)
            return
        }

        for peer in peers {
            let item = NSMenuItem(title: peer.baseTitle, action: #selector(sendFilesToDevice), keyEquivalent: "")
            item.target = self
            item.representedObject = peer.id
            sendFilesMenu.addItem(item)
        }
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

        // Whether this device was offline a moment ago — its first message back (of any kind, not
        // necessarily one carrying `screens`) is what should flip its layout rect from "disconnected"
        // back to normal, even when `merge` below finds nothing to actually change.
        let wasOffline = inputDevices[message.origin] == nil
        let existing = inputDevices[message.origin]
        let newInputEnabled = message.enabled ?? existing?.inputEnabled
        let inputEnabledChanged = newInputEnabled != existing?.inputEnabled
        let newName = message.deviceName ?? existing?.name
        let newAddress = message.deviceAddress ?? existing?.address
        // The name/address can resolve on a later message (e.g. a nameless message arrives first,
        // then a hello): the Port Forward panel needs to swap "Offline Device" for the real name.
        let identityChanged = newName != existing?.name || newAddress != existing?.address
        inputDevices[message.origin] = InputDeviceMenuDevice(
            id: message.origin,
            name: newName,
            address: newAddress,
            role: message.role ?? existing?.role,
            inputEnabled: newInputEnabled,
            lastSeen: Date()
        )

        let layoutChanged = message.screens.map { screenLayoutStore.merge(deviceId: message.origin, screens: $0) } ?? false
        if layoutChanged, config.mode == .server {
            broadcastLayout()
        }
        if layoutChanged || wasOffline || inputEnabledChanged || identityChanged {
            refreshScreenLayoutWindowIfVisible()
            // The coordinator only sees peers through the enabled/name snapshots passed via
            // update(). Without this, a peer that restarts (dropped from inputDevices, then
            // hellos back in) never re-enters those snapshots and the controller sits in
            // "waiting for peer screen" until some unrelated event refreshes the coordinator.
            // updateInputCoordinator() also runs the signature-gated Port Forward panel refresh.
            updateInputCoordinator()
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

    /// Devices currently known to be connected — the local machine plus every peer we're actively
    /// hearing from. Anything in the shared screen layout that isn't in this set is a remembered
    /// device that's offline right now (quit, restarted, or just dropped), not one we've forgotten.
    private var onlineDeviceIds: Set<String> {
        Set(inputDevices.keys).union([deviceId])
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
            deviceNames: deviceDisplayNames,
            onlineDeviceIds: onlineDeviceIds,
            deviceEnabledMap: deviceEnabledMap
        )
    }

    /// The device choices offered by the Port Forward panel: this machine first, then every
    /// online peer, then any offline device still referenced by an existing rule (so its rows
    /// stay editable instead of silently losing their selection).
    private var portForwardDeviceOptions: [PortForwardWindowController.DeviceOption] {
        var options = [PortForwardWindowController.DeviceOption(id: deviceId, title: localInputDevice.baseTitle)]
        options.append(contentsOf: inputDevices.values
            .filter { $0.id != deviceId }
            .sorted { $0.baseTitle.localizedCaseInsensitiveCompare($1.baseTitle) == .orderedAscending }
            .map { PortForwardWindowController.DeviceOption(id: $0.id, title: $0.baseTitle) })

        let knownIds = Set(options.map(\.id))
        let referencedIds = portForwardStore.snapshot().flatMap { [$0.inDeviceId, $0.outDeviceId] }
        for referencedId in referencedIds where !knownIds.contains(referencedId) && !options.contains(where: { $0.id == referencedId }) {
            let title = "\(AppText.text("forward.offlineDevice")) (\(referencedId.prefix(8)))"
            options.append(PortForwardWindowController.DeviceOption(id: referencedId, title: title))
        }
        return options
    }

    private func portForwardDeviceSignature(_ options: [PortForwardWindowController.DeviceOption]) -> String {
        options.map { "\($0.id):\($0.title)" }.joined(separator: "|")
    }

    @objc private func showPortForward() {
        isPortForwardWindowOpen = true
        let options = portForwardDeviceOptions
        portForwardPanelDeviceSignature = portForwardDeviceSignature(options)
        portForwardWindowController.show(
            rules: portForwardStore.snapshot(),
            devices: options,
            statuses: portForwardDisplayStatuses()
        )
    }

    private func applyPortForwardRules(_ rules: [PortForwardRule]) {
        // Apply locally right away (mirroring layout edits), then let the server's canonical copy
        // propagate: a server broadcasts the accepted table, a client sends a change request.
        portForwardStore.applySnapshot(rules)
        pruneForwardStatuses()
        sendForwards()
        updatePortForwardCoordinator()
        refreshPortForwardPanelIfVisible()
    }

    private func handleLocalForwardStatuses(_ statuses: [PortForwardStatus]) {
        localForwardStatuses = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sendForwardStatuses()
        refreshPortForwardPanelIfVisible()
    }

    /// Broadcasts this device's own listen state so peers can show accurate status lights for rules
    /// that listen here. Only this device's local statuses are sent; each device reports its own.
    private func sendForwardStatuses() {
        guard transport != nil, !config.password.isEmpty, peerCount > 0 else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: nil,
            kind: "forwardStatus",
            role: config.mode.rawValue,
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
            forwardStatuses: Array(localForwardStatuses.values)
        ))
    }

    private func handleForwardStatusMessage(_ message: InputMessage) {
        guard let statuses = message.forwardStatuses else {
            return
        }
        for status in statuses {
            remoteForwardStatuses[status.id] = status
        }
        refreshPortForwardPanelIfVisible()
    }

    /// Drops status entries for rules no longer in the table, keeping the two status maps bounded.
    private func pruneForwardStatuses() {
        let liveIds = Set(portForwardStore.snapshot().map(\.id))
        localForwardStatuses = localForwardStatuses.filter { liveIds.contains($0.key) }
        remoteForwardStatuses = remoteForwardStatuses.filter { liveIds.contains($0.key) }
    }

    /// Computes the status light + hover tooltip for every rule, merging this device's own listen
    /// state with peer reports and gating by the rule's enabled flag and its In device's presence.
    private func portForwardDisplayStatuses() -> [String: PortForwardWindowController.RuleStatus] {
        var result: [String: PortForwardWindowController.RuleStatus] = [:]
        let online = onlineDeviceIds
        for rule in portForwardStore.snapshot() {
            result[rule.id] = displayStatus(for: rule, online: online)
        }
        return result
    }

    private func displayStatus(for rule: PortForwardRule, online: Set<String>) -> PortForwardWindowController.RuleStatus {
        if !rule.enabled {
            return PortForwardWindowController.RuleStatus(light: .gray, tooltip: AppText.text("forward.statusDisabled"))
        }
        // A forward only works when both ends are reachable: the In device has to be up to listen,
        // and the Out device has to be up to receive. A peer (not us) is offline when it isn't in
        // the online set. Gray out either way so a quit/offline peer stops reading as healthy.
        if rule.inDeviceId != deviceId, !online.contains(rule.inDeviceId) {
            return PortForwardWindowController.RuleStatus(light: .gray, tooltip: AppText.text("forward.statusOffline"))
        }
        if rule.outDeviceId != deviceId, !online.contains(rule.outDeviceId) {
            return PortForwardWindowController.RuleStatus(light: .gray, tooltip: AppText.text("forward.statusOutOffline"))
        }
        let status = rule.inDeviceId == deviceId ? localForwardStatuses[rule.id] : remoteForwardStatuses[rule.id]
        guard let status else {
            return PortForwardWindowController.RuleStatus(light: .gray, tooltip: AppText.text("forward.statusStarting"))
        }
        if status.ok {
            return PortForwardWindowController.RuleStatus(light: .green, tooltip: AppText.format("forward.statusListening", rule.inPort))
        }
        let reason = status.reason ?? ""
        return PortForwardWindowController.RuleStatus(light: .red, tooltip: AppText.format("forward.statusFailed", reason))
    }

    /// Refreshes the open panel after a presence or status change: rebuilds the rows only when the
    /// device options changed (a peer went offline/online, or its name resolved), otherwise just
    /// recolors the status lights so in-progress edits survive.
    private func refreshPortForwardPanelIfVisible() {
        guard isPortForwardWindowOpen else {
            return
        }
        let options = portForwardDeviceOptions
        let signature = portForwardDeviceSignature(options)
        if signature != portForwardPanelDeviceSignature {
            portForwardPanelDeviceSignature = signature
            portForwardWindowController.refresh(
                rules: portForwardStore.snapshot(),
                devices: options,
                statuses: portForwardDisplayStatuses()
            )
        } else {
            portForwardWindowController.updateStatuses(portForwardDisplayStatuses())
        }
    }

    private func sendForwards() {
        guard transport != nil, !config.password.isEmpty else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: nil,
            kind: "forwards",
            role: config.mode.rawValue,
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
            forwards: portForwardStore.snapshot()
        ))
    }

    private func handleForwardsMessage(_ message: InputMessage) {
        guard let forwards = message.forwards else {
            return
        }
        switch config.mode {
        case .server:
            guard message.role == SyncMode.client.rawValue else {
                return
            }
            portForwardStore.applySnapshot(forwards)
            sendForwards()
        case .client:
            guard message.role == SyncMode.server.rawValue else {
                return
            }
            portForwardStore.applySnapshot(forwards)
        }
        pruneForwardStatuses()
        updatePortForwardCoordinator()
        // A peer changed the shared table — force a rows rebuild (a new/removed rule), not just the
        // status lights.
        rebuildPortForwardPanelIfVisible()
    }

    /// Forces a full rows rebuild from the current (possibly peer-updated) rule table, if the panel
    /// is open — used when the rule set itself changed rather than just presence.
    private func rebuildPortForwardPanelIfVisible() {
        guard isPortForwardWindowOpen else {
            return
        }
        let options = portForwardDeviceOptions
        portForwardPanelDeviceSignature = portForwardDeviceSignature(options)
        portForwardWindowController.refresh(
            rules: portForwardStore.snapshot(),
            devices: options,
            statuses: portForwardDisplayStatuses()
        )
    }

    private func updatePortForwardCoordinator() {
        portForwardCoordinator.update(
            deviceId: deviceId,
            rules: portForwardStore.snapshot(),
            transportReady: transport != nil && !config.password.isEmpty,
            onlinePeers: Set(inputDevices.keys)
        )
        // Presence and transport changes flow through here; refresh the panel's lights so remote
        // rules flip to "offline"/back live.
        refreshPortForwardPanelIfVisible()
    }

    private func publishTunnel(_ message: TunnelMessage) {
        _ = sendEncryptedRealtime(message, routedTo: message.target)
    }

    private func handleTunnelMessage(_ data: Data) {
        guard
            let message = try? jsonDecoder.decode(TunnelMessage.self, from: data),
            message.type == "tunnel",
            message.origin != deviceId,
            message.target == deviceId
        else {
            return
        }
        portForwardCoordinator.handle(message)
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
            deviceNames: deviceDisplayNames,
            onlineDeviceIds: onlineDeviceIds,
            deviceEnabledMap: deviceEnabledMap
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

    /// Asks the server (the canonical layout owner) to drop a device's screens. Only meaningful
    /// when we're a client — the server applies it locally and rebroadcasts the resulting layout.
    private func sendLayoutForgetRequest(deviceId forgottenId: String) {
        guard transport != nil, !config.password.isEmpty else {
            return
        }
        publishInput(InputMessage(
            type: "input",
            origin: deviceId,
            target: forgottenId,
            kind: "layoutForget",
            role: config.mode.rawValue,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: nil,
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func handleLayoutForgetMessage(_ message: InputMessage) {
        guard config.mode == .server, let target = message.target else {
            return
        }
        inputDevices.removeValue(forKey: target)
        layoutWatchers.remove(target)
        if screenLayoutStore.remove(deviceId: target) {
            broadcastLayout()
        }
        updateMenu()
        refreshScreenLayoutWindowIfVisible()
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

    @objc private func toggleTransport() {
        if transport == nil {
            restartTransport()
        } else {
            stopTransport()
        }
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

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Failed to toggle launch at login: \(error.localizedDescription)")
        }
        updateMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openProjectHomepage() {
        guard let url = URL(string: "https://clipboardsync.fuzhuo.me") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func showConfiguration() {
        settingsWindowController.show(config: config)
    }

    @objc private func checkForUpdates() {
        updateController.checkForUpdates()
    }

    @objc private func toggleInputSharing() {
        config.inputSharingEnabled.toggle()
        config.save()
        updateInputCoordinator(sendHello: true)
        refreshScreenLayoutWindowIfVisible()
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

    @objc private func sendFilesToDevice(_ sender: NSMenuItem) {
        guard let targetId = sender.representedObject as? String else {
            return
        }
        guard let urls = clipboard.readFileURLsForManualSend() else {
            statusText = AppText.text("status.copyFilesFirst")
            return
        }

        if transport == nil {
            restartTransport()
        }
        guard transport != nil else {
            return
        }

        let targetName = inputDevices[targetId]?.baseTitle ?? AppText.text("device.unknown")
        fileTransferCoordinator.sendFiles(urls, to: targetId, targetName: targetName)
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
        if shouldSendHello {
            refreshScreenLayoutWindowIfVisible()
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
        fileTransferCoordinator.cancelAll()
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
                transport = nil
                statusText = AppText.text("status.setServerLanIp")
                return
            }
            guard !NetworkAddress.isLoopbackHost(config.host) else {
                transport = nil
                statusText = AppText.text("status.useLanIp")
                return
            }
            nextTransport = WebSocketClientTransport(host: config.host, port: config.port)
        case .server:
            let server = WebSocketServerTransport(port: config.port)
            server.localDeviceId = deviceId
            nextTransport = server
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
                // The server's rule table is canonical; push it whenever peers change so a newly
                // connected device starts (or an offline editor catches up) with the shared rules.
                if self.config.mode == .server, count > 0 {
                    self.sendForwards()
                }
                // Re-announce our own listen state so a newly connected peer's status lights are
                // accurate without waiting for the next local change.
                if count > 0 {
                    self.sendForwardStatuses()
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
        updateMenu()
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
    private func sendEncrypted<T: Encodable>(_ message: T, routedTo: String? = nil) -> Bool {
        guard
            let data = try? jsonEncoder.encode(message),
            var envelope = try? CryptoBox.encrypt(data, password: config.password)
        else {
            statusText = AppText.text("status.encryptionFailed")
            return false
        }
        envelope.from = deviceId
        envelope.to = routedTo

        guard
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

        transport?.send(payload, to: routedTo)
        return true
    }

    @discardableResult
    private func sendEncryptedInput(_ message: InputMessage) -> Bool {
        sendEncryptedRealtime(message, routedTo: message.target)
    }

    @discardableResult
    private func sendEncryptedRealtime<T: Encodable>(_ message: T, routedTo: String? = nil) -> Bool {
        guard
            let data = try? jsonEncoder.encode(message),
            var envelope = try? CryptoBox.encryptRealtime(data, password: config.password)
        else {
            statusText = AppText.text("status.encryptionFailed")
            return false
        }
        envelope.from = deviceId
        envelope.to = routedTo

        guard
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

        transport?.send(payload, to: routedTo)
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
        case "tunnel":
            handleTunnelMessage(data)
        case "file":
            handleFileMessage(data)
        default:
            break
        }
    }

    private func handleFileMessage(_ data: Data) {
        guard
            let message = try? jsonDecoder.decode(FileTransferMessage.self, from: data),
            message.type == "file",
            message.origin != deviceId,
            message.target == deviceId
        else {
            return
        }
        fileTransferCoordinator.handle(message)
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
            if content.kind == "files" {
                statusText = AppText.text("status.filesReceived")
                postFilesReceivedNotification()
            }
        }
    }

    private func postFilesReceivedNotification() {
        let notification = NSUserNotification()
        notification.title = AppText.text("app.name")
        notification.informativeText = AppText.text("status.filesReceived")
        NSUserNotificationCenter.default.deliver(notification)
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

        if message.kind == "layoutForget" {
            handleLayoutForgetMessage(message)
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

        if message.kind == "forwards" {
            handleForwardsMessage(message)
            return
        }

        if message.kind == "forwardStatus" {
            handleForwardStatusMessage(message)
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
        // Piggybacks on this catch-all "config/peers changed" hook so forward listeners follow
        // transport state and peer presence without a parallel set of call sites.
        updatePortForwardCoordinator()
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
