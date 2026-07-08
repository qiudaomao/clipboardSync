import AppKit

/// The "Port Forward" panel: a table of forward rules, each mapping In (a device + listen port)
/// to Out (another device + host + port), with an optional note. Each row shows a live status
/// light (green listening / red failed with the reason on hover / gray disabled or offline) and an
/// enable/disable toggle. Structural edits are drafts committed on Save; the enable toggle applies
/// immediately (via `onSave`) so its status light updates without closing the panel.
final class PortForwardWindowController: NSWindowController, NSWindowDelegate {
    var onSave: (([PortForwardRule]) -> Void)?
    var onWindowClosed: (() -> Void)?

    struct DeviceOption {
        let id: String
        let title: String
    }

    /// A rule's display status, computed by the app from local + peer-reported listen state and
    /// handed to the panel to render. The panel itself holds no status logic.
    struct RuleStatus: Equatable {
        enum Light {
            case green
            case red
            case gray
        }

        let light: Light
        let tooltip: String
    }

    private var devices: [DeviceOption] = []
    private var rowViews: [RuleRowView] = []
    private var statuses: [String: RuleStatus] = [:]

    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: AppText.text("forward.empty"))
    private let validationLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()

    fileprivate static let deviceColumnWidth: CGFloat = 190
    fileprivate static let portFieldWidth: CGFloat = 60
    fileprivate static let lanColumnWidth: CGFloat = 52
    fileprivate static let hostFieldWidth: CGFloat = 116
    fileprivate static let noteColumnWidth: CGFloat = 150

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppText.text("forward.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1040, height: 320)

        super.init(window: window)

        window.delegate = self
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(rules: [PortForwardRule], devices: [DeviceOption], statuses: [String: RuleStatus]) {
        self.devices = devices
        self.statuses = statuses
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        for rule in rules {
            addRow(for: rule)
        }
        validationLabel.stringValue = ""
        validationLabel.isHidden = true
        updateEmptyState()

        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Live-refreshes the per-row status lights without disturbing in-progress edits.
    func updateStatuses(_ statuses: [String: RuleStatus]) {
        self.statuses = statuses
        for row in rowViews {
            row.applyStatus(statuses[row.ruleId])
        }
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    private func setupContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let titleLabel = NSTextField(labelWithString: AppText.text("forward.title"))
        titleLabel.font = .boldSystemFont(ofSize: 17)

        let subtitleLabel = NSTextField(wrappingLabelWithString: AppText.text("forward.subtitle"))
        subtitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.setHuggingPriority(.required, for: .vertical)

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .secondaryLabelColor

        let documentView = FlippedStackView(views: [columnHeaderRow(), rowsStack, emptyLabel])
        documentView.orientation = .vertical
        documentView.alignment = .leading
        documentView.spacing = 8
        documentView.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 8, right: 2)
        documentView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clipView = scrollView.contentView
        documentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor).isActive = true
        documentView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor).isActive = true
        documentView.topAnchor.constraint(equalTo: clipView.topAnchor).isActive = true

        let addButton = NSButton(title: AppText.text("forward.add"), target: self, action: #selector(addRule))
        addButton.bezelStyle = .rounded
        addButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading

        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        let saveButton = NSButton(title: AppText.text("settings.save"), target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large

        let cancelButton = NSButton(title: AppText.text("settings.cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large

        let buttonStack = NSStackView(views: [addButton, NSView(), validationLabel, cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        let rootStack = NSStackView(views: [headerStack, scrollView, buttonStack])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    /// Fixed-width column captions kept in sync with the row layout, so the stacked rows read as
    /// one aligned table: [enabled] In device + port + LAN → Out device + host + port, note, remove.
    private func columnHeaderRow() -> NSView {
        func caption(_ key: String, width: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: AppText.text(key))
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            return label
        }

        let arrowSpacer = NSView()
        arrowSpacer.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let row = NSStackView(views: [
            caption("forward.status", width: RuleRowView.statusDotWidth),
            caption("forward.enabled", width: RuleRowView.toggleWidth),
            caption("forward.in", width: Self.deviceColumnWidth + 8 + Self.portFieldWidth),
            caption("forward.lan", width: Self.lanColumnWidth),
            arrowSpacer,
            caption("forward.out", width: Self.deviceColumnWidth + 8 + Self.hostFieldWidth + 8 + Self.portFieldWidth),
            caption("forward.note", width: Self.noteColumnWidth)
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return row
    }

    private func addRow(for rule: PortForwardRule) {
        let row = RuleRowView(rule: rule, devices: devices)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else {
                return
            }
            row.removeFromSuperview()
            self.rowViews.removeAll { $0 === row }
            self.updateEmptyState()
        }
        // The enable/disable toggle applies immediately (so its status light updates) instead of
        // waiting for Save; a failed apply (some row invalid) rolls the toggle back.
        row.onToggle = { [weak self, weak row] in
            guard let self, let row else {
                return
            }
            if !self.applyRules(close: false) {
                row.revertToggle()
            }
        }
        row.applyStatus(statuses[rule.id])
        rowViews.append(row)
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !rowViews.isEmpty
    }

    @objc private func addRule() {
        let localId = devices.first?.id ?? ""
        let peerId = devices.dropFirst().first?.id ?? localId
        addRow(for: PortForwardRule(
            id: UUID().uuidString,
            inDeviceId: localId,
            inPort: 0,
            outDeviceId: peerId,
            outPort: 0,
            note: "",
            enabled: true
        ))
        updateEmptyState()
        window?.makeFirstResponder(rowViews.last?.inPortField)
    }

    /// Validates every row and, if all pass, hands the rule table to `onSave`. Returns whether the
    /// rules were applied; on failure it shows the reason and leaves the panel untouched.
    @discardableResult
    private func applyRules(close closeWindow: Bool) -> Bool {
        var rules: [PortForwardRule] = []
        var listenKeys = Set<String>()

        for row in rowViews {
            guard let rule = row.currentRule() else {
                showValidation(AppText.text("forward.validationPort"))
                window?.makeFirstResponder(row.inPortField)
                return false
            }
            if rule.inDeviceId == rule.outDeviceId && rule.inPort == rule.outPort {
                showValidation(AppText.text("forward.validationSame"))
                window?.makeFirstResponder(row.outPortField)
                return false
            }
            let listenKey = "\(rule.inDeviceId)#\(rule.inPort)"
            if !listenKeys.insert(listenKey).inserted {
                showValidation(AppText.text("forward.validationDuplicate"))
                window?.makeFirstResponder(row.inPortField)
                return false
            }
            rules.append(rule)
        }

        validationLabel.isHidden = true
        onSave?(rules)
        if closeWindow {
            close()
        }
        return true
    }

    @objc private func save() {
        applyRules(close: true)
    }

    @objc private func cancel() {
        close()
    }

    private func showValidation(_ message: String) {
        validationLabel.stringValue = message
        validationLabel.isHidden = false
    }
}

/// Keeps the rule list pinned to the top of the scroll area instead of AppKit's default
/// bottom-anchored document placement.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool {
        true
    }
}

/// One editable rule row: [status] [enable toggle] In device popup + port + LAN → Out device popup
/// + host + port, note, remove. An NSBox so the rounded card background tracks light/dark changes.
private final class RuleRowView: NSBox {
    static let statusDotWidth: CGFloat = 16
    static let toggleWidth: CGFloat = 38

    var onRemove: (() -> Void)?
    /// Fired when the enable/disable toggle is flipped, so the panel can apply the change live.
    var onToggle: (() -> Void)?

    let ruleId: String
    let inPortField = NSTextField()
    let outPortField = NSTextField()

    private let statusDot = NSImageView()
    private let enabledSwitch = NSSwitch()
    private let inDevicePopup = NSPopUpButton()
    private let lanCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let outDevicePopup = NSPopUpButton()
    private let outHostField = NSTextField()
    private let noteField = NSTextField()

    init(rule: PortForwardRule, devices: [PortForwardWindowController.DeviceOption]) {
        ruleId = rule.id
        super.init(frame: .zero)

        boxType = .custom
        titlePosition = .noTitle
        borderWidth = 0
        cornerRadius = 8
        fillColor = .quaternaryLabelColor
        contentViewMargins = .zero

        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.imageScaling = .scaleProportionallyDown
        statusDot.contentTintColor = .tertiaryLabelColor

        enabledSwitch.state = rule.enabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleTapped)
        enabledSwitch.controlSize = .mini
        enabledSwitch.toolTip = AppText.text("forward.enabledTooltip")

        configureDevicePopup(inDevicePopup, devices: devices, selectedId: rule.inDeviceId)
        configureDevicePopup(outDevicePopup, devices: devices, selectedId: rule.outDeviceId)

        configurePortField(inPortField, port: rule.inPort)
        configurePortField(outPortField, port: rule.outPort)

        lanCheckbox.state = rule.inAllowLan ? .on : .off
        lanCheckbox.toolTip = AppText.text("forward.lanTooltip")

        outHostField.stringValue = rule.outHost
        outHostField.placeholderString = "127.0.0.1"
        outHostField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        outHostField.toolTip = AppText.text("forward.hostTooltip")
        outHostField.lineBreakMode = .byTruncatingTail

        noteField.stringValue = rule.note
        noteField.placeholderString = AppText.text("forward.notePlaceholder")
        noteField.font = .systemFont(ofSize: NSFont.systemFontSize)
        noteField.lineBreakMode = .byTruncatingTail

        let arrowLabel = NSTextField(labelWithString: "→")
        arrowLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        arrowLabel.textColor = .secondaryLabelColor

        let removeButton = NSButton(title: "", target: self, action: #selector(removeTapped))
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: AppText.text("forward.remove"))
        removeButton.bezelStyle = .regularSquare
        removeButton.isBordered = false
        removeButton.toolTip = AppText.text("forward.remove")

        let stack = NSStackView(views: [
            statusDot,
            enabledSwitch,
            inDevicePopup,
            inPortField,
            lanCheckbox,
            arrowLabel,
            outDevicePopup,
            outHostField,
            outPortField,
            noteField,
            removeButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = contentView ?? self
        host.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: Self.statusDotWidth),
            statusDot.heightAnchor.constraint(equalToConstant: Self.statusDotWidth),
            enabledSwitch.widthAnchor.constraint(equalToConstant: Self.toggleWidth),
            inDevicePopup.widthAnchor.constraint(equalToConstant: PortForwardWindowController.deviceColumnWidth),
            outDevicePopup.widthAnchor.constraint(equalToConstant: PortForwardWindowController.deviceColumnWidth),
            inPortField.widthAnchor.constraint(equalToConstant: PortForwardWindowController.portFieldWidth),
            outPortField.widthAnchor.constraint(equalToConstant: PortForwardWindowController.portFieldWidth),
            lanCheckbox.widthAnchor.constraint(equalToConstant: PortForwardWindowController.lanColumnWidth),
            outHostField.widthAnchor.constraint(equalToConstant: PortForwardWindowController.hostFieldWidth),
            arrowLabel.widthAnchor.constraint(equalToConstant: 20),
            noteField.widthAnchor.constraint(greaterThanOrEqualToConstant: PortForwardWindowController.noteColumnWidth)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Recolors the status light and updates its hover tooltip. A nil status (rule not applied yet)
    /// reads as a neutral gray.
    func applyStatus(_ status: PortForwardWindowController.RuleStatus?) {
        guard let status else {
            statusDot.contentTintColor = .tertiaryLabelColor
            statusDot.toolTip = nil
            return
        }
        switch status.light {
        case .green:
            statusDot.contentTintColor = .systemGreen
        case .red:
            statusDot.contentTintColor = .systemRed
        case .gray:
            statusDot.contentTintColor = .tertiaryLabelColor
        }
        statusDot.toolTip = status.tooltip
    }

    /// Flips the enable toggle back after an apply that failed validation.
    func revertToggle() {
        enabledSwitch.state = enabledSwitch.state == .on ? .off : .on
    }

    @objc private func toggleTapped() {
        onToggle?()
    }

    /// Reads the row back into a rule; nil when either port is not a valid TCP port number.
    func currentRule() -> PortForwardRule? {
        guard
            let inPort = Int(inPortField.stringValue.trimmingCharacters(in: .whitespaces)),
            let outPort = Int(outPortField.stringValue.trimmingCharacters(in: .whitespaces)),
            (1...65_535).contains(inPort),
            (1...65_535).contains(outPort),
            let inDeviceId = inDevicePopup.selectedItem?.representedObject as? String,
            let outDeviceId = outDevicePopup.selectedItem?.representedObject as? String
        else {
            return nil
        }
        let host = outHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return PortForwardRule(
            id: ruleId,
            inDeviceId: inDeviceId,
            inPort: inPort,
            inAllowLan: lanCheckbox.state == .on,
            outDeviceId: outDeviceId,
            outHost: host.isEmpty ? "127.0.0.1" : host,
            outPort: outPort,
            note: noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabledSwitch.state == .on
        )
    }

    private func configureDevicePopup(_ popup: NSPopUpButton, devices: [PortForwardWindowController.DeviceOption], selectedId: String) {
        popup.removeAllItems()
        for device in devices {
            popup.addItem(withTitle: device.title)
            popup.lastItem?.representedObject = device.id
        }
        if let index = devices.firstIndex(where: { $0.id == selectedId }) {
            popup.selectItem(at: index)
        }
    }

    private func configurePortField(_ field: NSTextField, port: Int) {
        field.stringValue = port > 0 ? String(port) : ""
        field.placeholderString = "8080"
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.alignment = .center
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}
