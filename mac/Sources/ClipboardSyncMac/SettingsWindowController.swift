import AppKit

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    var onSave: ((AppConfig) -> Void)?

    private let modeControl = NSSegmentedControl(labels: ["Client", "Server"], trackingMode: .selectOne, target: nil, action: nil)
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let inputSharingButton = NSButton(checkboxWithTitle: "Enable Input Sharing", target: nil, action: nil)
    private let directionControl = NSSegmentedControl(labels: ["Server -> Client", "Client -> Server"], trackingMode: .selectOne, target: nil, action: nil)
    private let peerEdgePopup = NSPopUpButton()
    private let hostHintLabel = NSTextField(labelWithString: "Used only in client mode.")
    private let validationLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var currentConfig = AppConfig.defaults
    private var clientHostDraft = ""

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 438),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Sync Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 420)

        super.init(window: window)

        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(config: AppConfig) {
        currentConfig = config
        clientHostDraft = NetworkAddress.isLoopbackHost(config.host) ? "" : config.host
        modeControl.selectedSegment = config.mode == .client ? 0 : 1
        hostField.stringValue = clientHostDraft
        portField.stringValue = String(config.port)
        passwordField.stringValue = config.password
        inputSharingButton.state = config.inputSharingEnabled ? .on : .off
        directionControl.selectedSegment = config.inputSharingDirection == .serverControlsClient ? 0 : 1
        selectPeerEdge(config.peerEdge)
        validationLabel.stringValue = ""
        validationLabel.isHidden = true
        updateModeState()

        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)

        if config.mode == .client {
            window?.makeFirstResponder(hostField)
        } else {
            window?.makeFirstResponder(portField)
        }
    }

    private func setupContent() {
        guard let contentView = window?.contentView else {
            return
        }

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .rounded

        hostField.placeholderString = "192.168.1.10"
        hostField.controlSize = .large
        hostField.font = .systemFont(ofSize: NSFont.systemFontSize)

        portField.placeholderString = "8787"
        portField.controlSize = .large
        portField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        portField.delegate = self

        passwordField.placeholderString = "Required on every device"
        passwordField.controlSize = .large
        passwordField.font = .systemFont(ofSize: NSFont.systemFontSize)

        inputSharingButton.target = self
        inputSharingButton.action = #selector(inputSharingChanged)

        directionControl.segmentStyle = .rounded

        for edge in ScreenEdge.allCases {
            peerEdgePopup.addItem(withTitle: edge.title)
            peerEdgePopup.lastItem?.representedObject = edge.rawValue
        }
        peerEdgePopup.controlSize = .large

        hostHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hostHintLabel.textColor = .secondaryLabelColor

        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large

        let titleLabel = NSTextField(labelWithString: "Clipboard Sync")
        titleLabel.font = .boldSystemFont(ofSize: 17)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "Configure how this Mac syncs clipboard updates.")
        subtitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        let hostStack = NSStackView(views: [hostField, hostHintLabel])
        hostStack.orientation = .vertical
        hostStack.alignment = .leading
        hostStack.spacing = 4
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        hostHintLabel.widthAnchor.constraint(equalTo: hostField.widthAnchor).isActive = true

        let formStack = NSStackView(views: [
            formRow(label: "Mode", control: modeControl),
            formRow(label: "Host", control: hostStack),
            formRow(label: "Port", control: portField),
            formRow(label: "Password", control: passwordField),
            formRow(label: "Input", control: inputSharingButton),
            formRow(label: "Direction", control: directionControl),
            formRow(label: "Peer", control: peerEdgePopup)
        ])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 12

        let buttonStack = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.distribution = .fill

        let rootStack = NSStackView(views: [headerStack, formStack, validationLabel, buttonStack])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            buttonStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            modeControl.widthAnchor.constraint(equalTo: hostField.widthAnchor),
            portField.widthAnchor.constraint(equalTo: hostField.widthAnchor),
            passwordField.widthAnchor.constraint(equalTo: hostField.widthAnchor),
            inputSharingButton.widthAnchor.constraint(equalTo: hostField.widthAnchor),
            directionControl.widthAnchor.constraint(equalTo: hostField.widthAnchor),
            peerEdgePopup.widthAnchor.constraint(equalTo: hostField.widthAnchor)
        ])
    }

    private func formRow(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = .secondaryLabelColor
        labelView.widthAnchor.constraint(equalToConstant: 86).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    @objc private func modeChanged() {
        updateModeState()
    }

    @objc private func inputSharingChanged() {
        updateInputSharingState()
    }

    private func updateModeState() {
        let isClient = modeControl.selectedSegment == 0
        if isClient {
            hostField.isEnabled = true
            hostField.isEditable = true
            hostField.isSelectable = true
            hostField.stringValue = clientHostDraft
            hostField.placeholderString = "192.168.1.10"
            hostHintLabel.stringValue = "Enter the LAN IP shown on the server Mac."
        } else {
            if hostField.isEnabled {
                clientHostDraft = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            hostField.isEnabled = true
            hostField.isEditable = false
            hostField.isSelectable = true
            hostField.stringValue = NetworkAddress.serverURL(port: currentPortValue())
            hostHintLabel.stringValue = "Share this address with clients on the same LAN."
        }
        updateInputSharingState()
    }

    private func updateInputSharingState() {
        let isEnabled = inputSharingButton.state == .on
        directionControl.isEnabled = isEnabled
        peerEdgePopup.isEnabled = isEnabled
    }

    @objc private func save() {
        let mode: SyncMode = modeControl.selectedSegment == 1 ? .server : .client
        let host = mode == .client ? hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : currentConfig.host
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        let inputSharingEnabled = inputSharingButton.state == .on
        let inputSharingDirection: InputSharingDirection = directionControl.selectedSegment == 1 ? .clientControlsServer : .serverControlsClient
        let peerEdge = selectedPeerEdge()

        if mode == .client && host.isEmpty {
            showValidation("Enter a server host for client mode.")
            window?.makeFirstResponder(hostField)
            return
        }

        if mode == .client && NetworkAddress.isLoopbackHost(host) {
            showValidation("Use the server Mac's LAN IP, not 127.0.0.1.")
            window?.makeFirstResponder(hostField)
            return
        }

        guard let port = Int(portText), (1...65_535).contains(port) else {
            showValidation("Port must be a number from 1 to 65535.")
            window?.makeFirstResponder(portField)
            return
        }

        if password.isEmpty {
            showValidation("Enter the same sync password on every device.")
            window?.makeFirstResponder(passwordField)
            return
        }

        let nextConfig = AppConfig(
            mode: mode,
            host: host.isEmpty ? currentConfig.host : host,
            port: port,
            password: password,
            inputSharingEnabled: inputSharingEnabled,
            inputSharingDirection: inputSharingDirection,
            peerEdge: peerEdge
        )
        onSave?(nextConfig)
        close()
    }

    @objc private func cancel() {
        close()
    }

    private func showValidation(_ message: String) {
        validationLabel.stringValue = message
        validationLabel.isHidden = false
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === portField, modeControl.selectedSegment == 1 {
            hostField.stringValue = NetworkAddress.serverURL(port: currentPortValue())
        }
    }

    private func currentPortValue() -> Int {
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(portText) ?? currentConfig.port
    }

    private func selectPeerEdge(_ edge: ScreenEdge) {
        for item in peerEdgePopup.itemArray {
            if item.representedObject as? String == edge.rawValue {
                peerEdgePopup.select(item)
                return
            }
        }
    }

    private func selectedPeerEdge() -> ScreenEdge {
        guard
            let rawValue = peerEdgePopup.selectedItem?.representedObject as? String,
            let edge = ScreenEdge(rawValue: rawValue)
        else {
            return .right
        }
        return edge
    }
}
