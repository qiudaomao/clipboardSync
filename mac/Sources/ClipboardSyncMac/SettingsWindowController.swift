import AppKit

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    var onSave: ((AppConfig) -> Void)?

    private let modeControl = NSSegmentedControl(labels: [AppText.text("settings.client"), AppText.text("settings.server")], trackingMode: .selectOne, target: nil, action: nil)
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let inputSharingButton = NSButton(checkboxWithTitle: AppText.text("settings.enableInputSharing"), target: nil, action: nil)
    private let peerEdgePopup = NSPopUpButton()
    private let reverseScrollButton = NSButton(checkboxWithTitle: AppText.text("settings.reverseVerticalScroll"), target: nil, action: nil)
    private let shiftModifierPopup = NSPopUpButton()
    private let controlModifierPopup = NSPopUpButton()
    private let altModifierPopup = NSPopUpButton()
    private let metaModifierPopup = NSPopUpButton()
    private let hostHintLabel = NSTextField(labelWithString: AppText.text("settings.hostDefaultHint"))
    private let validationLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: AppText.text("settings.save"), target: nil, action: nil)
    private let cancelButton = NSButton(title: AppText.text("settings.cancel"), target: nil, action: nil)

    private var currentConfig = AppConfig.defaults
    private var clientHostDraft = ""

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = AppText.text("settings.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 560)

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
        selectPeerEdge(config.peerEdge)
        reverseScrollButton.state = config.reverseMouseVerticalScroll ? .on : .off
        selectModifier(config.keyboardModifierMap.shift, in: shiftModifierPopup)
        selectModifier(config.keyboardModifierMap.control, in: controlModifierPopup)
        selectModifier(config.keyboardModifierMap.alt, in: altModifierPopup)
        selectModifier(config.keyboardModifierMap.meta, in: metaModifierPopup)
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

        passwordField.placeholderString = AppText.text("settings.passwordPlaceholder")
        passwordField.controlSize = .large
        passwordField.font = .systemFont(ofSize: NSFont.systemFontSize)

        inputSharingButton.target = self
        inputSharingButton.action = #selector(inputSharingChanged)

        reverseScrollButton.target = self
        reverseScrollButton.action = #selector(inputSharingChanged)

        for popup in modifierPopups {
            configureModifierPopup(popup)
        }

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

        let titleLabel = NSTextField(labelWithString: AppText.text("settings.header"))
        titleLabel.font = .boldSystemFont(ofSize: 17)

        let subtitleLabel = NSTextField(wrappingLabelWithString: AppText.text("settings.subtitle"))
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

        let modifierMapStack = makeModifierMapStack()

        let formStack = NSStackView(views: [
            formRow(label: AppText.text("settings.mode"), control: modeControl),
            formRow(label: AppText.text("settings.host"), control: hostStack),
            formRow(label: AppText.text("settings.port"), control: portField),
            formRow(label: AppText.text("settings.password"), control: passwordField),
            formRow(label: AppText.text("settings.input"), control: inputSharingButton),
            formRow(label: AppText.text("settings.peer"), control: peerEdgePopup),
            formRow(label: AppText.text("settings.scroll"), control: reverseScrollButton),
            formRow(label: AppText.text("settings.modifierKeys"), control: modifierMapStack)
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
            peerEdgePopup.widthAnchor.constraint(equalTo: hostField.widthAnchor),
            reverseScrollButton.widthAnchor.constraint(equalTo: hostField.widthAnchor),
            modifierMapStack.widthAnchor.constraint(equalTo: hostField.widthAnchor)
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
            hostHintLabel.stringValue = AppText.text("settings.hostClientHint")
        } else {
            if hostField.isEnabled {
                clientHostDraft = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            hostField.isEnabled = true
            hostField.isEditable = false
            hostField.isSelectable = true
            hostField.stringValue = NetworkAddress.serverURL(port: currentPortValue())
            hostHintLabel.stringValue = AppText.text("settings.hostServerHint")
        }
        updateInputSharingState()
    }

    private func updateInputSharingState() {
        let isEnabled = inputSharingButton.state == .on
        peerEdgePopup.isEnabled = isEnabled
        reverseScrollButton.isEnabled = isEnabled
        for popup in modifierPopups {
            popup.isEnabled = isEnabled
        }
    }

    @objc private func save() {
        let mode: SyncMode = modeControl.selectedSegment == 1 ? .server : .client
        let host = mode == .client ? hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : currentConfig.host
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        let inputSharingEnabled = inputSharingButton.state == .on
        let peerEdge = selectedPeerEdge()
        let reverseMouseVerticalScroll = reverseScrollButton.state == .on
        let keyboardModifierMap = KeyboardModifierMap(
            shift: selectedModifier(in: shiftModifierPopup, fallback: .shift),
            control: selectedModifier(in: controlModifierPopup, fallback: .control),
            alt: selectedModifier(in: altModifierPopup, fallback: .alt),
            meta: selectedModifier(in: metaModifierPopup, fallback: .meta)
        )

        if mode == .client && host.isEmpty {
            showValidation(AppText.text("settings.validationHost"))
            window?.makeFirstResponder(hostField)
            return
        }

        if mode == .client && NetworkAddress.isLoopbackHost(host) {
            showValidation(AppText.text("settings.validationLoopback"))
            window?.makeFirstResponder(hostField)
            return
        }

        guard let port = Int(portText), (1...65_535).contains(port) else {
            showValidation(AppText.text("settings.validationPort"))
            window?.makeFirstResponder(portField)
            return
        }

        if password.isEmpty {
            showValidation(AppText.text("settings.validationPassword"))
            window?.makeFirstResponder(passwordField)
            return
        }

        let nextConfig = AppConfig(
            mode: mode,
            host: host.isEmpty ? currentConfig.host : host,
            port: port,
            password: password,
            inputSharingEnabled: inputSharingEnabled,
            controlDeviceId: currentConfig.controlDeviceId,
            peerEdge: peerEdge,
            reverseMouseVerticalScroll: reverseMouseVerticalScroll,
            keyboardModifierMap: keyboardModifierMap
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

    private var modifierPopups: [NSPopUpButton] {
        [shiftModifierPopup, controlModifierPopup, altModifierPopup, metaModifierPopup]
    }

    private func configureModifierPopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for modifier in KeyboardModifier.allCases {
            popup.addItem(withTitle: modifier.title)
            popup.lastItem?.representedObject = modifier.rawValue
        }
        popup.controlSize = .large
    }

    private func makeModifierMapStack() -> NSStackView {
        let rows = [
            modifierMapRow(label: AppText.text("settings.mapShift"), popup: shiftModifierPopup),
            modifierMapRow(label: AppText.text("settings.mapControl"), popup: controlModifierPopup),
            modifierMapRow(label: AppText.text("settings.mapAlt"), popup: altModifierPopup),
            modifierMapRow(label: AppText.text("settings.mapMeta"), popup: metaModifierPopup)
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func modifierMapRow(label: String, popup: NSPopUpButton) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = .secondaryLabelColor
        labelView.widthAnchor.constraint(equalToConstant: 82).isActive = true
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let row = NSStackView(views: [labelView, popup])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func selectModifier(_ modifier: KeyboardModifier, in popup: NSPopUpButton) {
        for item in popup.itemArray {
            if item.representedObject as? String == modifier.rawValue {
                popup.select(item)
                return
            }
        }
    }

    private func selectedModifier(in popup: NSPopUpButton, fallback: KeyboardModifier) -> KeyboardModifier {
        guard
            let rawValue = popup.selectedItem?.representedObject as? String,
            let modifier = KeyboardModifier(rawValue: rawValue)
        else {
            return fallback
        }
        return modifier
    }
}
