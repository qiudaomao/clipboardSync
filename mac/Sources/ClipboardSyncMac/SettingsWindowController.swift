import AppKit

final class SettingsWindowController: NSWindowController {
    var onSave: ((AppConfig) -> Void)?

    private let modeControl = NSSegmentedControl(labels: ["Client", "Server"], trackingMode: .selectOne, target: nil, action: nil)
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let hostHintLabel = NSTextField(labelWithString: "Used only in client mode.")
    private let validationLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var currentConfig = AppConfig.defaults

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 288),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Sync Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 260)

        super.init(window: window)

        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(config: AppConfig) {
        currentConfig = config
        modeControl.selectedSegment = config.mode == .client ? 0 : 1
        hostField.stringValue = config.host
        portField.stringValue = String(config.port)
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

        hostField.placeholderString = "127.0.0.1"
        hostField.controlSize = .large
        hostField.font = .systemFont(ofSize: NSFont.systemFontSize)

        portField.placeholderString = "8787"
        portField.controlSize = .large
        portField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

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

        let subtitleLabel = NSTextField(wrappingLabelWithString: "Configure how this Mac syncs text clipboard updates.")
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
            formRow(label: "Port", control: portField)
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
            portField.widthAnchor.constraint(equalTo: hostField.widthAnchor)
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

    private func updateModeState() {
        let isClient = modeControl.selectedSegment == 0
        hostField.isEnabled = isClient
        hostHintLabel.stringValue = isClient ? "Used only in client mode." : "Server mode listens on all network interfaces."
    }

    @objc private func save() {
        let mode: SyncMode = modeControl.selectedSegment == 1 ? .server : .client
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if mode == .client && host.isEmpty {
            showValidation("Enter a server host for client mode.")
            window?.makeFirstResponder(hostField)
            return
        }

        guard let port = Int(portText), (1...65_535).contains(port) else {
            showValidation("Port must be a number from 1 to 65535.")
            window?.makeFirstResponder(portField)
            return
        }

        let nextConfig = AppConfig(
            mode: mode,
            host: host.isEmpty ? currentConfig.host : host,
            port: port
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
}
