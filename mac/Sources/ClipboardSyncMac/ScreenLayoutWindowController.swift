import AppKit

final class ScreenLayoutWindowController: NSWindowController, NSWindowDelegate {
    var onLayoutChanged: (([ScreenLayoutEntry]) -> Void)?
    var onWindowClosed: (() -> Void)?

    private let canvasView = ScreenLayoutCanvasView()
    private let doneButton = NSButton(title: AppText.text("layout.done"), target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppText.text("layout.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)

        super.init(window: window)
        window.delegate = self
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(entries: [ScreenLayoutEntry], localDeviceId: String, deviceNames: [String: String]) {
        canvasView.localDeviceId = localDeviceId
        canvasView.deviceNames = deviceNames
        canvasView.entries = entries

        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    /// Called by AppController with this device's own live cursor position, already resolved to a
    /// specific screenId + normalized point — so this canvas can draw the local "you are here" dot
    /// without needing to compute it itself. AppController drives this regardless of whether this
    /// window is visible (it may be polling purely to report to a peer who has ITS window open),
    /// so this is a no-op when hidden.
    func setLocalCursor(screenId: String?, normalizedX: Double?, normalizedY: Double?) {
        guard window?.isVisible == true else {
            return
        }
        canvasView.setLocalCursor(screenId: screenId, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    /// Called when a peer reports where its own real cursor currently sits, so this window can
    /// show a "fake mouse" dot on that peer's screens too. No-op if the window isn't visible or
    /// the peer's screen isn't (yet) known in `entries`.
    func updateRemoteCursor(deviceId: String, screenId: String, normalizedX: Double, normalizedY: Double) {
        guard window?.isVisible == true else {
            return
        }
        canvasView.setRemoteCursor(deviceId: deviceId, screenId: screenId, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    private func setupContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let titleLabel = NSTextField(labelWithString: AppText.text("layout.title"))
        titleLabel.font = .boldSystemFont(ofSize: 17)

        let subtitleLabel = NSTextField(wrappingLabelWithString: AppText.text("layout.subtitle"))
        subtitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        canvasView.wantsLayer = true
        canvasView.layer?.cornerRadius = 8
        canvasView.layer?.borderWidth = 1
        canvasView.layer?.borderColor = NSColor.separatorColor.cgColor
        canvasView.onLayoutChanged = { [weak self] entries in
            self?.onLayoutChanged?(entries)
        }
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .large

        let buttonStack = NSStackView(views: [NSView(), doneButton])
        buttonStack.orientation = .horizontal
        buttonStack.distribution = .fill

        let rootStack = NSStackView(views: [headerStack, canvasView, buttonStack])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            buttonStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            canvasView.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    @objc private func done() {
        close()
    }
}

final class ScreenLayoutCanvasView: NSView {
    var onLayoutChanged: (([ScreenLayoutEntry]) -> Void)?
    var localDeviceId = ""
    var deviceNames: [String: String] = [:]
    var entries: [ScreenLayoutEntry] = [] {
        didSet {
            if draggingDeviceId == nil {
                needsDisplay = true
            }
        }
    }

    private typealias Metrics = (scale: CGFloat, originX: CGFloat, originY: CGFloat, marginX: CGFloat, marginY: CGFloat)

    /// A machine's monitors always move together, so a drag tracks the whole group: each member
    /// screen's canvas origin at drag start, keyed by screenId, plus the canvas point under the
    /// pointer at drag start — the live delta between that anchor and the current pointer position
    /// is applied identically to every group member.
    private var draggingDeviceId: String?
    private var dragGroupOrigins: [String: CGPoint] = [:]
    private var dragGroupSizes: [String: CGSize] = [:]
    private var dragAnchorCanvasPoint = CGPoint.zero
    private var dragMetrics: Metrics?
    private var didDragDuringGesture = false

    private var localCursorPosition: CGPoint?
    private var remoteCursorPositions: [String: (canvasPoint: CGPoint, lastUpdated: Date)] = [:]
    private static let remoteCursorTimeout: TimeInterval = 3.0

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let metrics = dragMetrics ?? computeMetrics()

        if !entries.isEmpty {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            for entry in entries.sorted(by: { $0.screenId < $1.screenId }) {
                let rect = screenRect(for: entry, metrics: metrics)
                let color = Self.color(for: entry.deviceId)

                let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                color.withAlphaComponent(0.35).setFill()
                path.fill()
                color.setStroke()
                path.lineWidth = entry.deviceId == localDeviceId ? 3 : 1.5
                path.stroke()

                guard rect.width > 40, rect.height > 28 else {
                    continue
                }

                let subtitle = "\(Int(entry.width))\u{00D7}\(Int(entry.height))"
                let text = NSAttributedString(string: "\(screenLabel(for: entry))\n\(subtitle)", attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .paragraphStyle: paragraphStyle
                ])
                let textSize = text.size()
                let textRect = CGRect(
                    x: rect.midX - textSize.width / 2,
                    y: rect.midY - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                text.draw(in: textRect)
            }
        }

        drawCursors(metrics: metrics)
    }

    // MARK: - Live cursor position

    private static let cursorDotRadius: CGFloat = 7

    /// Sets this device's own live cursor position, already resolved by AppController to a
    /// specific screenId + normalized point — e.g. the dot sits mid-way down screen #1 when the
    /// real pointer is mid-way down that monitor. Pass nil to hide the local dot.
    func setLocalCursor(screenId: String?, normalizedX: Double?, normalizedY: Double?) {
        guard
            let screenId, let normalizedX, let normalizedY,
            let entry = entries.first(where: { $0.screenId == screenId })
        else {
            localCursorPosition = nil
            pruneStaleRemoteCursors()
            needsDisplay = true
            return
        }
        localCursorPosition = CGPoint(x: entry.x + normalizedX * entry.width, y: entry.y + normalizedY * entry.height)
        pruneStaleRemoteCursors()
        needsDisplay = true
    }

    /// Records a peer's reported cursor position, converting its normalized (screenId, x, y) into a
    /// point on this canvas so it can be drawn alongside the local "fake mouse" dot.
    func setRemoteCursor(deviceId: String, screenId: String, normalizedX: Double, normalizedY: Double) {
        guard let entry = entries.first(where: { $0.screenId == screenId }) else {
            return
        }
        let canvasPoint = CGPoint(x: entry.x + normalizedX * entry.width, y: entry.y + normalizedY * entry.height)
        remoteCursorPositions[deviceId] = (canvasPoint, Date())
        needsDisplay = true
    }

    private func pruneStaleRemoteCursors() {
        let cutoff = Date().addingTimeInterval(-Self.remoteCursorTimeout)
        remoteCursorPositions = remoteCursorPositions.filter { $0.value.lastUpdated >= cutoff }
    }

    private func drawCursors(metrics: Metrics) {
        for (deviceId, remote) in remoteCursorPositions {
            drawCursorDot(canvasPosition: remote.canvasPoint, metrics: metrics, fillColor: Self.color(for: deviceId))
        }
        guard let localCursorPosition else {
            return
        }
        drawCursorDot(canvasPosition: localCursorPosition, metrics: metrics, fillColor: .white)
    }

    private func drawCursorDot(canvasPosition: CGPoint, metrics: Metrics, fillColor: NSColor) {
        let position = CGPoint(
            x: (canvasPosition.x - metrics.originX) * metrics.scale + metrics.marginX,
            y: (canvasPosition.y - metrics.originY) * metrics.scale + metrics.marginY
        )
        let radius = Self.cursorDotRadius
        let rect = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)

        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: rect.offsetBy(dx: 0, dy: 2)).fill()

        fillColor.setFill()
        let dot = NSBezierPath(ovalIn: rect)
        dot.fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        dot.lineWidth = 1.5
        dot.stroke()
    }

    private func screenLabel(for entry: ScreenLayoutEntry) -> String {
        let name = deviceNames[entry.deviceId] ?? entry.deviceId
        let siblingCount = entries.filter { $0.deviceId == entry.deviceId }.count
        guard siblingCount > 1, let index = Self.screenIndex(entry.screenId) else {
            return name
        }
        return "\(name) #\(index + 1)"
    }

    private static func screenIndex(_ screenId: String) -> Int? {
        guard let suffix = screenId.split(separator: "#").last else {
            return nil
        }
        return Int(suffix)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let metrics = computeMetrics()
        dragMetrics = metrics
        didDragDuringGesture = false

        for entry in entries.sorted(by: { $0.screenId < $1.screenId }).reversed() {
            let rect = screenRect(for: entry, metrics: metrics)
            if rect.contains(point) {
                draggingDeviceId = entry.deviceId
                let group = entries.filter { $0.deviceId == entry.deviceId }
                dragGroupOrigins = Dictionary(uniqueKeysWithValues: group.map { ($0.screenId, CGPoint(x: $0.x, y: $0.y)) })
                dragGroupSizes = Dictionary(uniqueKeysWithValues: group.map { ($0.screenId, CGSize(width: $0.width, height: $0.height)) })
                dragAnchorCanvasPoint = CGPoint(
                    x: (point.x - metrics.marginX) / metrics.scale + metrics.originX,
                    y: (point.y - metrics.marginY) / metrics.scale + metrics.originY
                )
                return
            }
        }
        draggingDeviceId = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let draggingDeviceId, let metrics = dragMetrics, !dragGroupOrigins.isEmpty else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let currentCanvasPoint = CGPoint(
            x: (point.x - metrics.marginX) / metrics.scale + metrics.originX,
            y: (point.y - metrics.marginY) / metrics.scale + metrics.originY
        )
        let candidateDelta = CGPoint(
            x: currentCanvasPoint.x - dragAnchorCanvasPoint.x,
            y: currentCanvasPoint.y - dragAnchorCanvasPoint.y
        )
        let resolvedDelta = clampedGroupDelta(candidateDelta, excludingDeviceId: draggingDeviceId)

        for (screenId, origin) in dragGroupOrigins {
            guard let index = entries.firstIndex(where: { $0.screenId == screenId }) else {
                continue
            }
            entries[index].x = Double(origin.x + resolvedDelta.x)
            entries[index].y = Double(origin.y + resolvedDelta.y)
        }
        didDragDuringGesture = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draggingDeviceId = nil
            dragGroupOrigins = [:]
            dragGroupSizes = [:]
            dragMetrics = nil
        }
        guard didDragDuringGesture, let draggingDeviceId else {
            return
        }
        snapGroupToTouch(deviceId: draggingDeviceId)
        needsDisplay = true
        onLayoutChanged?(entries)
    }

    // MARK: - Overlap prevention

    /// A machine's own monitors move together as one rigid group — their relative arrangement is
    /// fixed by the OS, not user-adjustable here. Slides the candidate group move along one axis
    /// at a time (full move, X-only, Y-only, no move) and returns the first delta where none of
    /// the group's screens overlap another machine's screen, so the group "bumps" against its
    /// neighbors instead of passing through them while dragging.
    private func clampedGroupDelta(_ candidateDelta: CGPoint, excludingDeviceId: String) -> CGPoint {
        let others = entries.filter { $0.deviceId != excludingDeviceId }.map(\.rect)

        func groupRects(for delta: CGPoint) -> [CGRect] {
            dragGroupOrigins.map { screenId, origin in
                CGRect(
                    origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y),
                    size: dragGroupSizes[screenId] ?? .zero
                )
            }
        }
        func overlapsOthers(_ delta: CGPoint) -> Bool {
            let rects = groupRects(for: delta)
            return others.contains { other in rects.contains { rectsOverlap($0, other) } }
        }

        if !overlapsOthers(candidateDelta) {
            return candidateDelta
        }
        let xOnly = CGPoint(x: candidateDelta.x, y: 0)
        if !overlapsOthers(xOnly) {
            return xOnly
        }
        let yOnly = CGPoint(x: 0, y: candidateDelta.y)
        if !overlapsOthers(yOnly) {
            return yOnly
        }
        return .zero
    }

    private func rectsOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let epsilon: CGFloat = 0.5
        return a.intersects(b.insetBy(dx: epsilon, dy: epsilon))
    }

    // MARK: - Touch (zero-gap) snapping

    /// After a drag ends, snaps the moved machine's whole group of screens so at least one edge of
    /// its combined footprint touches another machine's screen with no gap — a machine shouldn't
    /// float disconnected from the rest of the layout. Falls back to leaving it where dropped if no
    /// touching position is available without overlapping something else.
    private func snapGroupToTouch(deviceId: String) {
        let memberIndices = entries.indices.filter { entries[$0].deviceId == deviceId }
        guard !memberIndices.isEmpty else {
            return
        }
        let memberRects = memberIndices.map { entries[$0].rect }
        let groupBounds = memberRects.dropFirst().reduce(memberRects[0]) { $0.union($1) }
        let others = entries.filter { $0.deviceId != deviceId }.map(\.rect)
        guard !others.isEmpty else {
            return
        }

        let touchEpsilon: CGFloat = 1.0
        if others.contains(where: { $0.insetBy(dx: -touchEpsilon, dy: -touchEpsilon).intersects(groupBounds) }) {
            return
        }

        var bestDelta: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for other in others {
            for candidateOrigin in touchCandidates(moving: groupBounds, toTouch: other) {
                let delta = CGPoint(x: candidateOrigin.x - groupBounds.origin.x, y: candidateOrigin.y - groupBounds.origin.y)
                let distance = hypot(delta.x, delta.y)
                guard distance < bestDistance else {
                    continue
                }
                let movedMemberRects = memberRects.map { $0.offsetBy(dx: delta.x, dy: delta.y) }
                let hasOverlap = others.contains { other in movedMemberRects.contains { rectsOverlap($0, other) } }
                guard !hasOverlap else {
                    continue
                }
                bestDistance = distance
                bestDelta = delta
            }
        }

        guard let bestDelta else {
            return
        }
        for index in memberIndices {
            entries[index].x += Double(bestDelta.x)
            entries[index].y += Double(bestDelta.y)
        }
    }

    /// Candidate origins placing `rect` flush against one edge of `other`, only offered along an
    /// axis where the two rects already share some span (so screens don't "touch" at a bare corner).
    private func touchCandidates(moving rect: CGRect, toTouch other: CGRect) -> [CGPoint] {
        var candidates: [CGPoint] = []
        let horizontalOverlap = rect.minY < other.maxY && rect.maxY > other.minY
        let verticalOverlap = rect.minX < other.maxX && rect.maxX > other.minX

        if horizontalOverlap {
            candidates.append(CGPoint(x: other.maxX, y: rect.origin.y))
            candidates.append(CGPoint(x: other.minX - rect.width, y: rect.origin.y))
        }
        if verticalOverlap {
            candidates.append(CGPoint(x: rect.origin.x, y: other.maxY))
            candidates.append(CGPoint(x: rect.origin.x, y: other.minY - rect.height))
        }
        return candidates
    }

    // MARK: - Metrics

    private func computeMetrics() -> Metrics {
        guard !entries.isEmpty else {
            return (1, 0, 0, 0, 0)
        }

        let minX = entries.map { CGFloat($0.x) }.min() ?? 0
        let minY = entries.map { CGFloat($0.y) }.min() ?? 0
        let maxX = entries.map { CGFloat($0.x + $0.width) }.max() ?? 1
        let maxY = entries.map { CGFloat($0.y + $0.height) }.max() ?? 1
        let boundingWidth = max(maxX - minX, 1)
        let boundingHeight = max(maxY - minY, 1)

        let padding: CGFloat = 24
        let availableWidth = max(bounds.width - padding * 2, 1)
        let availableHeight = max(bounds.height - padding * 2, 1)
        let scale = min(availableWidth / boundingWidth, availableHeight / boundingHeight)

        let marginX = padding + max(availableWidth - boundingWidth * scale, 0) / 2
        let marginY = padding + max(availableHeight - boundingHeight * scale, 0) / 2
        return (scale, minX, minY, marginX, marginY)
    }

    private func screenRect(for entry: ScreenLayoutEntry, metrics: Metrics) -> CGRect {
        let x = (CGFloat(entry.x) - metrics.originX) * metrics.scale + metrics.marginX
        let y = (CGFloat(entry.y) - metrics.originY) * metrics.scale + metrics.marginY
        return CGRect(x: x, y: y, width: CGFloat(entry.width) * metrics.scale, height: CGFloat(entry.height) * metrics.scale)
    }

    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal,
        .systemPink, .systemYellow, .systemRed, .systemIndigo, .systemBrown
    ]

    /// A simple, deterministic hash over UTF-16 code units — deliberately not Swift's `Hasher`,
    /// which is seeded randomly per process launch and would give the same device a different
    /// color every relaunch (and a different color on the Mac side than on a Windows peer looking
    /// at the same layout). Mirrors the Windows client's `ColorFor` exactly (same algorithm, same
    /// wraparound arithmetic, same palette order) so every viewer agrees on every device's color.
    private static func color(for deviceId: String) -> NSColor {
        var hash: Int32 = 17
        for unit in deviceId.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        let unsignedHash = UInt32(bitPattern: hash)
        return palette[Int(unsignedHash % UInt32(palette.count))]
    }
}
