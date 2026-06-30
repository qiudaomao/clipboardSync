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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        clipboard.onLocalText = { [weak self] text in
            self?.publish(text)
        }
        clipboard.start()
        restartTransport()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard.stop()
        transport?.stop()
    }

    private func setupMenu() {
        statusItem.button?.title = "Clip"

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Status: stopped", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        clientModeItem = NSMenuItem(title: "Client mode", action: #selector(setClientMode), keyEquivalent: "")
        clientModeItem.target = self
        menu.addItem(clientModeItem)

        serverModeItem = NSMenuItem(title: "Server mode", action: #selector(setServerMode), keyEquivalent: "")
        serverModeItem.target = self
        menu.addItem(serverModeItem)

        menu.addItem(NSMenuItem.separator())

        let configureItem = NSMenuItem(title: "Configure...", action: #selector(showConfiguration), keyEquivalent: ",")
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
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Clipboard Sync"
        alert.informativeText = "Configure the sync role and endpoint."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let modePopup = NSPopUpButton()
        modePopup.addItems(withTitles: ["Client", "Server"])
        modePopup.selectItem(withTitle: config.mode == .client ? "Client" : "Server")

        let hostField = NSTextField(string: config.host)
        hostField.placeholderString = "127.0.0.1"

        let portField = NSTextField(string: String(config.port))
        portField.placeholderString = "8787"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row(label: "Mode", control: modePopup))
        stack.addArrangedSubview(row(label: "Host", control: hostField))
        stack.addArrangedSubview(row(label: "Port", control: portField))
        stack.widthAnchor.constraint(equalToConstant: 280).isActive = true

        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let selectedMode: SyncMode = modePopup.titleOfSelectedItem == "Server" ? .server : .client
        let selectedPort = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? AppConfig.defaults.port
        config = AppConfig(mode: selectedMode, host: hostField.stringValue, port: selectedPort)
        config.save()
        restartTransport()
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func restartTransport() {
        transport?.stop()

        let nextTransport: Transport
        switch config.mode {
        case .client:
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

    private func publish(_ text: String) {
        let message = SyncMessage(
            type: "clipboard",
            origin: deviceId,
            text: text,
            sentAt: Date().timeIntervalSince1970
        )

        guard
            let data = try? jsonEncoder.encode(message),
            let payload = String(data: data, encoding: .utf8)
        else {
            return
        }

        transport?.send(payload)
    }

    private func handleMessage(_ payload: String) {
        guard
            let data = payload.data(using: .utf8),
            let message = try? jsonDecoder.decode(SyncMessage.self, from: data),
            message.type == "clipboard",
            message.origin != deviceId
        else {
            return
        }

        clipboard.applyRemoteText(message.text)
    }
}
