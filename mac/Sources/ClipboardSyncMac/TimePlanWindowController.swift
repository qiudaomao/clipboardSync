import AppKit

/// The weekly sleep-prevention schedule editor: 7 day rows x 24 hour columns. Edits commit on
/// gesture end, matching the screen-layout window's "saved as applied" behaviour.
final class TimePlanWindowController: NSWindowController, NSWindowDelegate {
    var onPlanChanged: ((SleepTimePlan) -> Void)?
    var onWindowClosed: (() -> Void)?

    private let gridView = TimePlanGridView()
    private let doneButton = NSButton(title: AppText.text("timeplan.done"), target: nil, action: nil)
    private let savedLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppText.text("timeplan.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 380)

        super.init(window: window)
        window.delegate = self
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(plan: SleepTimePlan) {
        gridView.plan = plan
        savedLabel.stringValue = ""
        updateSummary()

        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    private func setupContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let titleLabel = NSTextField(labelWithString: AppText.text("timeplan.title"))
        titleLabel.font = .boldSystemFont(ofSize: 17)

        let subtitleLabel = NSTextField(wrappingLabelWithString: AppText.text("timeplan.subtitle"))
        subtitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        gridView.wantsLayer = true
        gridView.layer?.cornerRadius = 8
        gridView.layer?.borderWidth = 1
        gridView.layer?.borderColor = NSColor.separatorColor.cgColor
        gridView.onPlanChanged = { [weak self] plan in
            guard let self else { return }
            self.savedLabel.stringValue = AppText.text("timeplan.saved")
            self.updateSummary()
            self.onPlanChanged?(plan)
        }
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor

        let legendStack = NSStackView(views: [
            TimePlanLegendView(color: TimePlanGridView.preventColor, title: AppText.text("timeplan.legendPrevent")),
            TimePlanLegendView(color: TimePlanGridView.allowColor, title: AppText.text("timeplan.legendAllow")),
            summaryLabel,
            NSView()
        ])
        legendStack.orientation = .horizontal
        legendStack.distribution = .fill
        legendStack.spacing = 16

        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .large

        let clearButton = NSButton(title: AppText.text("timeplan.clearAll"), target: self, action: #selector(clearAll))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .large

        let selectAllButton = NSButton(title: AppText.text("timeplan.selectAll"), target: self, action: #selector(selectAllBlocks))
        selectAllButton.bezelStyle = .rounded
        selectAllButton.controlSize = .large

        let workHoursButton = NSButton(title: AppText.text("timeplan.workHours"), target: self, action: #selector(applyWorkHours))
        workHoursButton.bezelStyle = .rounded
        workHoursButton.controlSize = .large

        savedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        savedLabel.textColor = .secondaryLabelColor

        let buttonStack = NSStackView(views: [
            clearButton, selectAllButton, workHoursButton, NSView(), savedLabel, doneButton
        ])
        buttonStack.orientation = .horizontal
        buttonStack.distribution = .fill

        let rootStack = NSStackView(views: [headerStack, gridView, legendStack, buttonStack])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            buttonStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            gridView.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    private func updateSummary() {
        var selected = 0
        for day in 0..<SleepTimePlan.dayCount {
            for hour in 0..<SleepTimePlan.hourCount where gridView.plan.isPrevented(day: day, hour: hour) {
                selected += 1
            }
        }
        summaryLabel.stringValue = AppText.format("timeplan.selectedHours", selected)
    }

    @objc private func done() {
        close()
    }

    @objc private func clearAll() {
        gridView.fillAll(prevented: false)
    }

    @objc private func selectAllBlocks() {
        gridView.fillAll(prevented: true)
    }

    @objc private func applyWorkHours() {
        gridView.applyWorkHours()
    }
}

/// A small swatch plus caption, used for the prevent/allow legend under the grid.
private final class TimePlanLegendView: NSView {
    init(color: NSColor, title: String) {
        super.init(frame: .zero)

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = 3
        swatch.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [swatch, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 12),
            swatch.heightAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Draws the 7x24 block grid and turns clicks and rectangular drags into plan edits. A drag paints
/// every block in the rectangle between the press and the current cell to the value opposite of the
/// pressed block, so one gesture can clear or fill a span without hunting individual hours.
final class TimePlanGridView: NSView {
    static let preventColor = NSColor.systemBlue
    static let allowColor = NSColor.quaternaryLabelColor

    var onPlanChanged: ((SleepTimePlan) -> Void)?

    var plan: SleepTimePlan = .empty {
        didSet {
            if anchorCell == nil {
                needsDisplay = true
            }
        }
    }

    private struct Cell: Equatable {
        let day: Int
        let hour: Int
    }

    private struct Metrics {
        let dayLabelWidth: CGFloat
        let hourLabelHeight: CGFloat
        let cellWidth: CGFloat
        let cellHeight: CGFloat
    }

    private var anchorCell: Cell?
    private var currentCell: Cell?
    private var paintValue = false

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    /// Replaces every block. Used by the Clear All / Select All buttons, which commit like a drag.
    func fillAll(prevented: Bool) {
        var next = plan
        for day in 0..<SleepTimePlan.dayCount {
            for hour in 0..<SleepTimePlan.hourCount {
                next.setPrevented(prevented, day: day, hour: hour)
            }
        }
        commit(next)
    }

    /// Monday through Friday, 09:00 up to 18:00 — the schedule most users describe when they ask
    /// for "keep it awake while I work".
    func applyWorkHours() {
        var next = SleepTimePlan()
        for day in 0..<5 {
            for hour in 9..<18 {
                next.setPrevented(true, day: day, hour: hour)
            }
        }
        commit(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let metrics = computeMetrics()
        let previewPlan = planWithPreview()

        let labelStyle = NSMutableParagraphStyle()
        labelStyle.alignment = .center
        let hourAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: labelStyle
        ]
        let dayStyle = NSMutableParagraphStyle()
        dayStyle.alignment = .right
        let dayAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: dayStyle
        ]

        // Hour ruler. Every third hour is labelled so the header stays legible when the window is
        // narrow; the grid itself always has all 24 columns. Each label is centred on its own
        // column so it lines up with the block it names.
        for hour in 0..<SleepTimePlan.hourCount where hour % 3 == 0 {
            let text = String(format: "%02d", hour) as NSString
            text.draw(
                in: NSRect(
                    x: metrics.dayLabelWidth + CGFloat(hour) * metrics.cellWidth - metrics.cellWidth,
                    y: metrics.hourLabelHeight - 14,
                    width: metrics.cellWidth * 3,
                    height: 12
                ),
                withAttributes: hourAttributes
            )
        }

        for day in 0..<SleepTimePlan.dayCount {
            let rowTop = metrics.hourLabelHeight + CGFloat(day) * metrics.cellHeight
            let dayTitle = AppText.text("timeplan.day.\(day)") as NSString
            dayTitle.draw(
                in: NSRect(
                    x: 0,
                    y: rowTop + (metrics.cellHeight - 14) / 2,
                    width: metrics.dayLabelWidth - 8,
                    height: 14
                ),
                withAttributes: dayAttributes
            )

            for hour in 0..<SleepTimePlan.hourCount {
                let rect = NSRect(
                    x: metrics.dayLabelWidth + CGFloat(hour) * metrics.cellWidth + 1,
                    y: rowTop + 1,
                    width: metrics.cellWidth - 2,
                    height: metrics.cellHeight - 2
                )
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                if previewPlan.isPrevented(day: day, hour: hour) {
                    Self.preventColor.setFill()
                } else {
                    Self.allowColor.setFill()
                }
                path.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let cell = cell(at: convert(event.locationInWindow, from: nil)) else {
            anchorCell = nil
            currentCell = nil
            return
        }
        anchorCell = cell
        currentCell = cell
        // Painting the inverse of the pressed block makes a single click a toggle and a drag a
        // uniform fill or clear, rather than a per-block flip that depends on each block's state.
        paintValue = !plan.isPrevented(day: cell.day, hour: cell.hour)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchorCell != nil else { return }
        let next = clampedCell(at: convert(event.locationInWindow, from: nil))
        guard next != currentCell else { return }
        currentCell = next
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchorCell = nil
            currentCell = nil
        }
        guard anchorCell != nil else { return }
        commit(planWithPreview())
    }

    private func commit(_ next: SleepTimePlan) {
        guard next != plan else {
            needsDisplay = true
            return
        }
        plan = next
        needsDisplay = true
        onPlanChanged?(next)
    }

    /// The plan as it should currently be drawn: the committed plan, plus the in-flight rectangle
    /// while a drag is active.
    private func planWithPreview() -> SleepTimePlan {
        guard let anchorCell, let currentCell else { return plan }
        var preview = plan
        for day in min(anchorCell.day, currentCell.day)...max(anchorCell.day, currentCell.day) {
            for hour in min(anchorCell.hour, currentCell.hour)...max(anchorCell.hour, currentCell.hour) {
                preview.setPrevented(paintValue, day: day, hour: hour)
            }
        }
        return preview
    }

    private func computeMetrics() -> Metrics {
        let dayLabelWidth: CGFloat = 44
        let hourLabelHeight: CGFloat = 18
        return Metrics(
            dayLabelWidth: dayLabelWidth,
            hourLabelHeight: hourLabelHeight,
            cellWidth: max(1, (bounds.width - dayLabelWidth) / CGFloat(SleepTimePlan.hourCount)),
            cellHeight: max(1, (bounds.height - hourLabelHeight) / CGFloat(SleepTimePlan.dayCount))
        )
    }

    private func cell(at point: CGPoint) -> Cell? {
        let metrics = computeMetrics()
        guard point.x >= metrics.dayLabelWidth, point.y >= metrics.hourLabelHeight else { return nil }
        let hour = Int((point.x - metrics.dayLabelWidth) / metrics.cellWidth)
        let day = Int((point.y - metrics.hourLabelHeight) / metrics.cellHeight)
        guard (0..<SleepTimePlan.hourCount).contains(hour), (0..<SleepTimePlan.dayCount).contains(day) else {
            return nil
        }
        return Cell(day: day, hour: hour)
    }

    /// Used while dragging so the rectangle keeps tracking when the pointer leaves the grid.
    private func clampedCell(at point: CGPoint) -> Cell {
        let metrics = computeMetrics()
        let hour = Int((point.x - metrics.dayLabelWidth) / metrics.cellWidth)
        let day = Int((point.y - metrics.hourLabelHeight) / metrics.cellHeight)
        return Cell(
            day: min(max(day, 0), SleepTimePlan.dayCount - 1),
            hour: min(max(hour, 0), SleepTimePlan.hourCount - 1)
        )
    }
}
