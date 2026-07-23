import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Private CoreGraphics SPI. `CGDisplayHideCursor` is a no-op for a background
/// (`.accessory`) app that never owns the foreground — which is exactly our case while
/// relaying input to a peer. Setting the `SetsCursorInBackground` connection property
/// once lets our hide/show calls take effect regardless of which app is frontmost.
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ targetCID: Int32, _ key: CFString, _ value: CFTypeRef) -> CGError

@_silgen_name("_CGSDefaultConnection")
private func CGSDefaultConnection() -> Int32

final class InputSharingCoordinator {
    var onMessage: ((InputMessage) -> Void)?
    var onStatus: ((String) -> Void)?

    private let deviceId: String
    private let layoutStore: ScreenLayoutStore
    private var role: SyncMode = .client
    private var config = AppConfig.defaults
    private var peerCount = 0
    private var deviceEnabled: [String: Bool] = [:]
    private var deviceNames: [String: String] = [:]
    private var activeScreenId: String?
    private var activeTargetDeviceId: String?
    private var lastCrossedEdge: ScreenEdge = .right
    private var virtualCursor = CGPoint.zero
    private var receivingRemote = false
    private var receivingScreenId: String?
    private var remotePressedMouseButtons: Set<String> = []
    // Synthesized CGEvents carry no click count on their own, and macOS only recognises a
    // double-click when the second down/up pair arrives with `mouseEventClickState` >= 2 — the
    // controller's raw hook sends independent clicks, so consecutive-click state is rebuilt here.
    private var remoteClickState: Int64 = 1
    private var lastRemoteClickButton: String?
    private var lastRemoteClickTime = Date.distantPast
    private var lastRemoteClickPoint = CGPoint.zero
    private var remotePressedSourceModifierKeys: Set<String> = []
    private var remotePressedModifierKeys: Set<String> = []
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var lastModifierKeys: Set<String> = []
    private var lastCapsLockOn = false
    private let mouseMoveSendInterval: TimeInterval = 1.0 / 60.0
    private var lastMouseMoveSentAt = Date.distantPast
    private var pendingMouseMoveTimer: DispatchSourceTimer?
    private var suppressUntil = Date.distantPast
    private var didRequestAccessibility = false
    private var didRequestInputMonitoring = false
    private var localCursorHidden = false
    private var didAllowBackgroundCursorHide = false
    private var localCursorDetached = false

    /// Source for repositioning our own cursor at hand-back. `CGWarpMouseCursorPosition` makes
    /// the window server suppress hardware mouse events for ~0.25s afterwards (and
    /// `CGAssociateMouseAndMouseCursorPosition(1)` does not reliably lift it), which left the
    /// cursor dead at the edge every time it crossed back from a peer. Posting a synthetic
    /// mouse-move from a source whose suppression interval is zero moves the cursor through the
    /// normal event path with no suppression at all.
    private let returnMoveEventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    init(deviceId: String, layoutStore: ScreenLayoutStore) {
        self.deviceId = deviceId
        self.layoutStore = layoutStore
    }

    func start() {
        updateInputState()
    }

    func stop() {
        sendPressedModifierKeyUps()
        removeEventTap()
        showLocalCursor()
        reattachLocalMouseToCursor()
        activeScreenId = nil
        activeTargetDeviceId = nil
        receivingRemote = false
        receivingScreenId = nil
        remotePressedMouseButtons.removeAll()
        cancelPendingMouseMove()
        releaseRemoteModifiers()
    }

    func update(config: AppConfig, role: SyncMode, peerCount: Int, deviceEnabled: [String: Bool], deviceNames: [String: String]) {
        let shouldReleaseRemoteModifiers = self.config.keyboardModifierMap != config.keyboardModifierMap
        self.config = config
        self.role = role
        self.peerCount = peerCount
        self.deviceEnabled = deviceEnabled
        self.deviceNames = deviceNames
        if shouldReleaseRemoteModifiers {
            releaseRemoteModifiers()
        }
        updateInputState()
    }

    func makeHello(deviceName: String, deviceAddress: String?) -> InputMessage {
        InputMessage.hello(
            origin: deviceId,
            role: role,
            deviceName: deviceName,
            deviceAddress: deviceAddress,
            screens: Self.currentScreens(),
            enabled: config.inputSharingEnabled && peerCount > 0,
            controlDeviceId: effectiveControlDeviceId
        )
    }

    func handle(_ message: InputMessage) {
        guard message.origin != deviceId, message.target == nil || message.target == deviceId else {
            return
        }

        if message.kind == "hello" {
            updateStatus()
            return
        }

        guard canReceiveRemoteInput else {
            return
        }

        switch message.kind {
        case "capture":
            handleCapture(message.capture)
        case "mouseMove":
            handleRemoteMouseMove(message.mouse)
        case "mouseButton":
            handleRemoteMouseButton(message.mouse)
        case "mouseWheel":
            handleRemoteMouseWheel(message.mouse)
        case "key":
            handleRemoteKey(message.key)
        default:
            break
        }
    }

    private var effectiveControlDeviceId: String {
        guard let controlDeviceId = config.controlDeviceId, !controlDeviceId.isEmpty else {
            return deviceId
        }
        return controlDeviceId
    }

    private var isController: Bool {
        config.inputSharingEnabled && peerCount > 0 && effectiveControlDeviceId == deviceId
    }

    private var canReceiveRemoteInput: Bool {
        guard config.inputSharingEnabled, peerCount > 0, hasAccessibilityPermission else {
            return false
        }
        return effectiveControlDeviceId != deviceId
    }

    private var hasKnownRemotePeer: Bool {
        layoutStore.entries.values.contains { $0.deviceId != deviceId && deviceEnabled[$0.deviceId] == true }
    }

    private func updateInputState() {
        if config.inputSharingEnabled {
            requestMissingPermissionsIfNeeded()
        }

        if isController, hasAccessibilityPermission, hasInputMonitoringPermission {
            ensureEventTap()
        } else {
            if activeScreenId != nil {
                endRemoteCapture(returnToScreenId: nil)
            }
            removeEventTap()
            cancelPendingMouseMove()
        }
        // A controller that vanishes mid-session (app quit, network drop) never sends its
        // capture "end", so any modifiers it left pressed have to be released here when
        // receiving stops being possible — otherwise they stay held system-wide.
        if !canReceiveRemoteInput {
            releaseRemoteModifiers()
            receivingRemote = false
            receivingScreenId = nil
            remotePressedMouseButtons.removeAll()
        }
        updateStatus()
    }

    private func updateStatus() {
        let status: String
        if !config.inputSharingEnabled {
            status = AppText.text("input.off")
        } else if peerCount == 0 {
            status = AppText.text("input.waitingPeer")
        } else if !hasAccessibilityPermission {
            status = AppText.text("input.grantAccessibility")
        } else if isController && !hasInputMonitoringPermission {
            status = AppText.text("input.grantInputMonitoring")
        } else if isController && !hasKnownRemotePeer {
            status = AppText.text("input.waitingPeerScreen")
        } else if isController, let activeTargetDeviceId {
            status = AppText.format("input.controllingPeer", deviceNames[activeTargetDeviceId] ?? activeTargetDeviceId)
        } else if isController {
            status = AppText.text("input.ready")
        } else {
            status = AppText.text("input.receiving")
        }
        onStatus?(status)
    }

    private func ensureEventTap() {
        guard eventTap == nil else {
            return
        }

        guard hasInputMonitoringPermission else {
            onStatus?(AppText.text("input.grantInputMonitoring"))
            requestInputMonitoringPermission()
            return
        }

        let mask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.eventCallback,
            userInfo: userInfo
        ) else {
            onStatus?(AppText.text("input.grantBoth"))
            requestMissingPermissionsIfNeeded()
            return
        }

        eventTap = tap
        eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let eventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        eventSource = nil
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let coordinator = Unmanaged<InputSharingCoordinator>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = coordinator.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        return coordinator.handleLocalEvent(type: type, event: event)
    }

    private func handleLocalEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isController, hasAccessibilityPermission, hasInputMonitoringPermission, Date() >= suppressUntil else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return handleLocalMouseMove(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            guard activeScreenId != nil else {
                return Unmanaged.passUnretained(event)
            }
            flushPendingMouseMove()
            sendMouseButton(type: type)
            return nil
        case .scrollWheel:
            guard activeScreenId != nil else {
                return Unmanaged.passUnretained(event)
            }
            flushPendingMouseMove()
            sendMouseWheel(event)
            return nil
        case .keyDown, .keyUp:
            guard activeScreenId != nil else {
                return Unmanaged.passUnretained(event)
            }
            sendKey(event, action: type == .keyDown ? "down" : "up")
            return nil
        case .flagsChanged:
            guard activeScreenId != nil else {
                return Unmanaged.passUnretained(event)
            }
            sendModifierChanges(event)
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleLocalMouseMove(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if activeScreenId == nil {
            guard
                let current = currentLocalScreen(at: event.location),
                let currentEntry = layoutStore.entries[current.screenId]
            else {
                return Unmanaged.passUnretained(event)
            }
            guard let match = crossingNeighbor(
                at: event.location,
                currentEntry: currentEntry,
                currentRealRect: current.realRect
            ) else {
                return Unmanaged.passUnretained(event)
            }
            startRemoteCapture(target: match.neighbor, canvasPoint: match.canvasPoint, edge: match.edge)
            return nil
        }

        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        virtualCursor.x += dx
        virtualCursor.y += dy

        advanceRemoteCursor()
        return nil
    }

    /// Which of this machine's own monitors currently contains the cursor, alongside that
    /// monitor's real Quartz rect.
    private func currentLocalScreen(at location: CGPoint) -> (screenId: String, realRect: CGRect)? {
        for (index, displayId) in Self.activeDisplayIds().enumerated() {
            let rect = CGDisplayBounds(displayId)
            if rect.contains(location) {
                return ("\(deviceId)#\(index)", rect)
            }
        }
        return nil
    }

    /// Local cursor is in Quartz global coordinates, relative to the current monitor's real rect.
    /// The shared layout canvas uses the same top-left-origin, y-down convention, so translating
    /// is just an offset by that monitor's own layout entry origin. The four-edge check is against
    /// the CURRENT monitor's own real bounds, not the union of all this machine's monitors — for
    /// an irregular layout (e.g. one monitor taller than the other) the union's top edge only
    /// coincides with the taller monitor, so a cursor over the shorter one could never reach it.
    /// Checking the current monitor's own edges instead still can't wrongly trigger at an internal
    /// seam between two of this machine's own screens: the neighbor search below always excludes
    /// this device's own screens on this first hop, so it naturally finds nothing there and lets
    /// the OS carry the cursor across the seam on its own.
    private func crossingNeighbor(
        at location: CGPoint,
        currentEntry: ScreenLayoutEntry,
        currentRealRect: CGRect
    ) -> (edge: ScreenEdge, neighbor: ScreenLayoutEntry, canvasPoint: CGPoint)? {
        let threshold = 2.0
        let canvasPoint = CGPoint(
            x: currentEntry.x + (location.x - currentRealRect.minX),
            y: currentEntry.y + (location.y - currentRealRect.minY)
        )

        var candidateEdges: [ScreenEdge] = []
        if Double(location.x) >= Double(currentRealRect.maxX) - threshold { candidateEdges.append(.right) }
        if Double(location.x) <= Double(currentRealRect.minX) + threshold { candidateEdges.append(.left) }
        if Double(location.y) <= Double(currentRealRect.minY) + threshold { candidateEdges.append(.top) }
        if Double(location.y) >= Double(currentRealRect.maxY) - threshold { candidateEdges.append(.bottom) }

        let ownScreenIds = Set(layoutStore.entries.values.filter { $0.deviceId == deviceId }.map(\.screenId))

        for edge in candidateEdges {
            let crossAxis = (edge == .left || edge == .right) ? canvasPoint.y : canvasPoint.x
            if let match = neighbor(beyond: edge, of: currentEntry.rect, excludingScreenIds: ownScreenIds, crossAxis: crossAxis) {
                return (edge, match, canvasPoint)
            }
        }
        return nil
    }

    /// Finds the closest enabled screen positioned beyond `edge` of `rect` whose span across the
    /// perpendicular axis covers `crossAxis`. Tolerates a small gap so screens dragged in the
    /// layout window don't need to touch pixel-perfectly. A candidate belonging to this device
    /// itself is always eligible (used to detect "back to my own screen" hand-offs).
    private func neighbor(beyond edge: ScreenEdge, of rect: CGRect, excludingScreenIds: Set<String>, crossAxis: Double) -> ScreenLayoutEntry? {
        let epsilon = 48.0
        var best: ScreenLayoutEntry?
        var bestGap = Double.greatestFiniteMagnitude

        for entry in layoutStore.entries.values where !excludingScreenIds.contains(entry.screenId) {
            guard entry.deviceId == deviceId || deviceEnabled[entry.deviceId] == true else {
                continue
            }
            let candidate = entry.rect
            let gap: Double
            switch edge {
            case .right:
                guard candidate.maxY > crossAxis, candidate.minY < crossAxis else { continue }
                gap = candidate.minX - rect.maxX
            case .left:
                guard candidate.maxY > crossAxis, candidate.minY < crossAxis else { continue }
                gap = rect.minX - candidate.maxX
            case .bottom:
                guard candidate.maxX > crossAxis, candidate.minX < crossAxis else { continue }
                gap = candidate.minY - rect.maxY
            case .top:
                guard candidate.maxX > crossAxis, candidate.minX < crossAxis else { continue }
                gap = rect.minY - candidate.maxY
            }
            guard gap >= -epsilon, gap < bestGap else { continue }
            bestGap = gap
            best = entry
        }
        return best
    }

    private func exitedEdge(of point: CGPoint, rect: CGRect) -> ScreenEdge? {
        let left = rect.minX - point.x
        let right = point.x - rect.maxX
        let top = rect.minY - point.y
        let bottom = point.y - rect.maxY
        let maxOverflow = max(max(left, right), max(top, bottom))
        guard maxOverflow > 0 else {
            return nil
        }
        if maxOverflow == left { return .left }
        if maxOverflow == right { return .right }
        if maxOverflow == top { return .top }
        return .bottom
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func startRemoteCapture(target: ScreenLayoutEntry, canvasPoint: CGPoint, edge: ScreenEdge) {
        // Baseline the caps-lock state so a session that starts with caps already on doesn't
        // read the first flagsChanged as a toggle.
        lastCapsLockOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        virtualCursor = clamp(canvasPoint, to: target.rect)
        activeScreenId = target.screenId
        activeTargetDeviceId = target.deviceId
        lastCrossedEdge = edge
        hideLocalCursor()
        detachLocalMouseFromCursor()
        sendCapture(action: "start", targetDeviceId: target.deviceId, screenId: target.screenId, edge: edge, entry: target)
        sendMouseMoveNow()
        updateStatus()
    }

    /// Walks the shared layout each time the virtual cursor leaves the currently active screen's
    /// rect, handing capture off to whichever neighbor covers that boundary (which may be another
    /// screen on the same remote machine, or one of this controller's own screens, ending remote
    /// capture) and sticking at the edge when there's none.
    private func advanceRemoteCursor() {
        guard let activeScreenId, let activeTargetDeviceId, let activeEntry = layoutStore.entries[activeScreenId] else {
            endRemoteCapture(returnToScreenId: nil)
            return
        }

        let rect = activeEntry.rect
        guard let edge = exitedEdge(of: virtualCursor, rect: rect) else {
            queueMouseMove()
            return
        }

        let crossAxis = (edge == .left || edge == .right) ? virtualCursor.y : virtualCursor.x
        guard let match = neighbor(beyond: edge, of: rect, excludingScreenIds: [activeScreenId], crossAxis: crossAxis) else {
            virtualCursor = clamp(virtualCursor, to: rect)
            queueMouseMove()
            return
        }

        lastCrossedEdge = edge

        if match.deviceId == deviceId {
            virtualCursor = clamp(virtualCursor, to: match.rect)
            endRemoteCapture(returnToScreenId: match.screenId)
            return
        }

        cancelPendingMouseMove()
        sendPressedModifierKeyUps()
        sendCapture(action: "end", targetDeviceId: activeTargetDeviceId, screenId: activeScreenId, edge: edge, entry: activeEntry)
        virtualCursor = clamp(virtualCursor, to: match.rect)
        self.activeScreenId = match.screenId
        self.activeTargetDeviceId = match.deviceId
        sendCapture(action: "start", targetDeviceId: match.deviceId, screenId: match.screenId, edge: edge, entry: match)
        sendMouseMoveNow()
        updateStatus()
    }

    private func endRemoteCapture(returnToScreenId: String?) {
        guard let currentScreenId = activeScreenId, let currentTargetDeviceId = activeTargetDeviceId else {
            return
        }
        showLocalCursor()
        cancelPendingMouseMove()
        sendPressedModifierKeyUps()
        sendCapture(action: "end", targetDeviceId: currentTargetDeviceId, screenId: currentScreenId, edge: lastCrossedEdge, entry: layoutStore.entries[currentScreenId])
        activeScreenId = nil
        activeTargetDeviceId = nil
        // Unfreeze BEFORE the warp so the warp runs on an associated cursor; the warp itself
        // then re-calls associate to release the window server's post-warp hardware-event
        // suppression (the SDL/deskflow recipe — the release only works reliably when the call
        // isn't also flipping the association state).
        reattachLocalMouseToCursor()
        if let returnToScreenId {
            warpLocalCursorToReturnPoint(screenId: returnToScreenId)
        }
        updateStatus()
    }

    private func warpLocalCursorToReturnPoint(screenId: String) {
        guard let localEntry = layoutStore.entries[screenId] else {
            return
        }
        let realRect = localScreenRealRect(forScreenId: screenId) ?? Self.desktopBounds()
        let raw = CGPoint(
            x: realRect.minX + (virtualCursor.x - localEntry.x),
            y: realRect.minY + (virtualCursor.y - localEntry.y)
        )
        let clampedX = min(max(raw.x, realRect.minX), max(realRect.maxX - 2, realRect.minX))
        let clampedY = min(max(raw.y, realRect.minY), max(realRect.maxY - 2, realRect.minY))
        let point = CGPoint(x: clampedX, y: clampedY)
        // Set the tap-suppression window BEFORE posting: the return point sits inside the
        // crossing threshold band, so our own injected move would otherwise instantly
        // re-trigger crossingNeighbor and bounce capture straight back to the peer.
        suppressUntil = Date().addingTimeInterval(0.08)
        if let event = CGEvent(mouseEventSource: returnMoveEventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        } else {
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private func sendCapture(action: String, targetDeviceId: String, screenId: String, edge: ScreenEdge, entry: ScreenLayoutEntry?) {
        let normalized = entry.map(normalizedPoint) ?? (x: 0, y: 0)
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: targetDeviceId,
            kind: "capture",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: nil,
            capture: InputCapturePayload(
                action: action,
                edge: edge.rawValue,
                screenId: screenId,
                normalizedX: normalized.x,
                normalizedY: normalized.y
            ),
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func normalizedPoint(in entry: ScreenLayoutEntry) -> (x: Double, y: Double) {
        let x = min(max((virtualCursor.x - entry.x) / max(entry.width, 1), 0), 1)
        let y = min(max((virtualCursor.y - entry.y) / max(entry.height, 1), 0), 1)
        return (x, y)
    }

    private func sendMouseMove() {
        guard let target = activeTargetDeviceId, let screenId = activeScreenId, let entry = layoutStore.entries[screenId] else {
            return
        }
        let normalized = normalizedPoint(in: entry)
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: target,
            kind: "mouseMove",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: nil,
            capture: nil,
            mouse: InputMousePayload(
                action: "move",
                button: nil,
                normalizedX: normalized.x,
                normalizedY: normalized.y,
                deltaX: nil,
                deltaY: nil
            ),
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func queueMouseMove() {
        let elapsed = Date().timeIntervalSince(lastMouseMoveSentAt)
        if elapsed >= mouseMoveSendInterval {
            sendMouseMoveNow()
            return
        }

        guard pendingMouseMoveTimer == nil else {
            return
        }

        let delay = mouseMoveSendInterval - elapsed
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            self.pendingMouseMoveTimer = nil
            guard self.activeScreenId != nil else {
                return
            }
            self.sendMouseMoveNow()
        }
        pendingMouseMoveTimer = timer
        timer.resume()
    }

    private func sendMouseMoveNow() {
        cancelPendingMouseMove()
        lastMouseMoveSentAt = Date()
        sendMouseMove()
    }

    private func flushPendingMouseMove() {
        guard pendingMouseMoveTimer != nil else {
            return
        }
        sendMouseMoveNow()
    }

    private func cancelPendingMouseMove() {
        pendingMouseMoveTimer?.cancel()
        pendingMouseMoveTimer = nil
    }

    private func sendMouseButton(type: CGEventType) {
        guard let target = activeTargetDeviceId, let screenId = activeScreenId, let entry = layoutStore.entries[screenId] else {
            return
        }
        let action = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown ? "down" : "up"
        let button: String
        switch type {
        case .rightMouseDown, .rightMouseUp:
            button = "right"
        case .otherMouseDown, .otherMouseUp:
            button = "middle"
        default:
            button = "left"
        }
        let normalized = normalizedPoint(in: entry)
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: target,
            kind: "mouseButton",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: nil,
            capture: nil,
            mouse: InputMousePayload(
                action: action,
                button: button,
                normalizedX: normalized.x,
                normalizedY: normalized.y,
                deltaX: nil,
                deltaY: nil
            ),
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func sendMouseWheel(_ event: CGEvent) {
        guard let target = activeTargetDeviceId, let screenId = activeScreenId, let entry = layoutStore.entries[screenId] else {
            return
        }
        let normalized = normalizedPoint(in: entry)
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: target,
            kind: "mouseWheel",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: nil,
            capture: nil,
            mouse: InputMousePayload(
                action: "wheel",
                button: nil,
                normalizedX: normalized.x,
                normalizedY: normalized.y,
                deltaX: event.getDoubleValueField(.scrollWheelEventDeltaAxis2),
                deltaY: event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            ),
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func sendKey(_ event: CGEvent, action: String) {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard let key = Self.macKeyToCanonical[code] else {
            return
        }
        sendKeyPayload(key: key, action: action, modifiers: Self.modifiers(from: event.flags))
    }

    private func sendModifierChanges(_ event: CGEvent) {
        // Caps lock never arrives as keyDown/keyUp — only as a flagsChanged with the alphaShift
        // flag reflecting the new LOCK STATE (and a second, identical-flags event on key
        // release). Diffing the flag sends exactly one tap per toggle, and sending it as a
        // down+up pair matters because the receiver's OS toggles its caps state on key-down.
        let capsLockOn = event.flags.contains(.maskAlphaShift)
        if capsLockOn != lastCapsLockOn {
            lastCapsLockOn = capsLockOn
            sendKeyPayload(key: "CapsLock", action: "down", modifiers: [])
            sendKeyPayload(key: "CapsLock", action: "up", modifiers: [])
        }

        let next = Set(Self.modifiers(from: event.flags))
        for key in next.subtracting(lastModifierKeys) {
            sendKeyPayload(key: key, action: "down", modifiers: Array(next).sorted())
        }
        for key in lastModifierKeys.subtracting(next) {
            sendKeyPayload(key: key, action: "up", modifiers: Array(next).sorted())
        }
        lastModifierKeys = next
    }

    private func sendPressedModifierKeyUps() {
        guard !lastModifierKeys.isEmpty else {
            return
        }
        for key in lastModifierKeys.sorted() {
            sendKeyPayload(key: key, action: "up", modifiers: [])
        }
        lastModifierKeys.removeAll()
    }

    private func sendKeyPayload(key: String, action: String, modifiers: [String]) {
        guard let target = activeTargetDeviceId else {
            return
        }
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: target,
            kind: "key",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screens: nil,
            enabled: nil,
            controlDeviceId: nil,
            layout: nil,
            capture: nil,
            mouse: nil,
            key: InputKeyPayload(action: action, key: key, modifiers: modifiers),
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func handleCapture(_ capture: InputCapturePayload?) {
        guard let capture else {
            return
        }
        if capture.action == "start" {
            receivingRemote = true
            receivingScreenId = capture.screenId
            remotePressedMouseButtons.removeAll()
            releaseRemoteModifiers()
            warpTo(normalizedX: capture.normalizedX, normalizedY: capture.normalizedY)
        } else if capture.action == "end" {
            releaseRemoteModifiers()
            receivingRemote = false
            receivingScreenId = nil
            remotePressedMouseButtons.removeAll()
        }
    }

    private func handleRemoteMouseMove(_ mouse: InputMousePayload?) {
        guard receivingRemote, let mouse, let x = mouse.normalizedX, let y = mouse.normalizedY else {
            return
        }
        let point = pointFor(normalizedX: x, normalizedY: y)
        if let eventType = remoteDragEventType {
            // Drags inherit the initiating click's count, matching real events — a double-click-
            // and-drag selects by word only when its drag events also report clickState 2.
            postMouseEvent(type: eventType, button: remoteDragButton, at: point, clickState: remoteClickState)
        } else {
            postMouseEvent(type: .mouseMoved, button: .left, at: point)
        }
    }

    private func handleRemoteMouseButton(_ mouse: InputMousePayload?) {
        guard receivingRemote, let mouse else {
            return
        }
        let buttonName = canonicalMouseButton(mouse.button)
        let button = cgMouseButton(for: buttonName)
        let point = mouse.normalizedX.flatMap { x in
            mouse.normalizedY.map { y in pointFor(normalizedX: x, normalizedY: y) }
        } ?? currentCursorLocation()
        let eventType: CGEventType
        switch (buttonName, mouse.action) {
        case ("right", "down"):
            eventType = .rightMouseDown
        case ("right", "up"):
            eventType = .rightMouseUp
        case ("middle", "down"):
            eventType = .otherMouseDown
        case ("middle", "up"):
            eventType = .otherMouseUp
        case (_, "down"):
            eventType = .leftMouseDown
        default:
            eventType = .leftMouseUp
        }

        if mouse.action == "down" {
            if remotePressedMouseButtons.isEmpty {
                activateWindowUnderRemoteClick(at: point)
            }
            remotePressedMouseButtons.insert(buttonName)
            let now = Date()
            if buttonName == lastRemoteClickButton,
               now.timeIntervalSince(lastRemoteClickTime) <= NSEvent.doubleClickInterval,
               abs(point.x - lastRemoteClickPoint.x) <= 5,
               abs(point.y - lastRemoteClickPoint.y) <= 5 {
                remoteClickState += 1
            } else {
                remoteClickState = 1
            }
            lastRemoteClickButton = buttonName
            lastRemoteClickTime = now
            lastRemoteClickPoint = point
        }
        postMouseEvent(type: eventType, button: button, at: point, clickState: remoteClickState)
        if mouse.action == "up" {
            remotePressedMouseButtons.remove(buttonName)
        }
    }

    private func handleRemoteMouseWheel(_ mouse: InputMousePayload?) {
        guard receivingRemote, let mouse else {
            return
        }
        if let x = mouse.normalizedX, let y = mouse.normalizedY {
            warpTo(normalizedX: x, normalizedY: y)
        }
        let deltaY = config.reverseMouseVerticalScroll ? -(mouse.deltaY ?? 0) : (mouse.deltaY ?? 0)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(mouse.deltaX ?? 0),
            wheel3: 0
        ) else {
            return
        }
        post(event)
    }

    private var remoteDragEventType: CGEventType? {
        if remotePressedMouseButtons.contains("left") {
            return .leftMouseDragged
        }
        if remotePressedMouseButtons.contains("right") {
            return .rightMouseDragged
        }
        if remotePressedMouseButtons.contains("middle") {
            return .otherMouseDragged
        }
        return nil
    }

    private var remoteDragButton: CGMouseButton {
        if remotePressedMouseButtons.contains("left") {
            return .left
        }
        if remotePressedMouseButtons.contains("right") {
            return .right
        }
        if remotePressedMouseButtons.contains("middle") {
            return .center
        }
        return .left
    }

    private func handleRemoteKey(_ key: InputKeyPayload?) {
        guard receivingRemote, let key else {
            return
        }
        if Self.modifierKeys.contains(key.key) {
            if key.action == "down" {
                remotePressedSourceModifierKeys.insert(key.key)
            } else {
                remotePressedSourceModifierKeys.remove(key.key)
            }
            reconcileRemoteModifierState()
            return
        }

        if key.key == "CapsLock" {
            // A synthetic keycode-57 event doesn't flip macOS's caps-lock state; only the
            // IOKit modifier-lock API does. The sender emits a down+up pair per toggle, so
            // act on the down and swallow the up.
            if key.action == "down" {
                toggleLocalCapsLock()
            }
            return
        }

        guard let keyCode = Self.canonicalToMacKey[key.key] else {
            return
        }
        // The controller stamps every key message with its live modifier snapshot, so treat it
        // as authoritative rather than unioning it with our own bookkeeping: a modifier keyup
        // the controller's hook missed (secure desktop, hook timeout) or a message lost to a
        // disconnect would otherwise leave the injected modifier held here until the next
        // capture hand-off.
        remotePressedSourceModifierKeys = Set(key.modifiers)
        reconcileRemoteModifierState()
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: key.action == "down") else {
            return
        }
        // Hardware arrow/nav key events carry implicit maskSecondaryFn (+ maskNumericPad for
        // arrows), and WindowServer's symbolic hotkeys only match when they're present — the
        // Spaces switch is registered as Control+Fn+Arrow, so a bare Control+Arrow never fires
        // it. Keep those implicit bits (whether contributed by the CGEvent constructor or added
        // here) instead of overwriting the flags with just the four plain modifier masks.
        var flags = Self.flags(from: Array(mappedModifiers(remotePressedSourceModifierKeys)))
        flags.formUnion(event.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
        if Self.secondaryFnKeys.contains(key.key) {
            flags.insert(.maskSecondaryFn)
        }
        if Self.arrowKeys.contains(key.key) {
            flags.insert(.maskNumericPad)
        }
        event.flags = flags
        post(event)
    }

    private func toggleLocalCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else {
            return
        }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return
        }
        defer { IOServiceClose(connect) }
        var on = false
        guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS else {
            return
        }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !on)
    }

    private func reconcileRemoteModifierState() {
        let desired = mappedModifiers(remotePressedSourceModifierKeys)
        for modifier in Self.modifierKeyOrder where !desired.contains(modifier) && remotePressedModifierKeys.contains(modifier) {
            remotePressedModifierKeys.remove(modifier)
            postModifierEvent(modifier: modifier, keyDown: false)
        }
        for modifier in Self.modifierKeyOrder where desired.contains(modifier) && !remotePressedModifierKeys.contains(modifier) {
            remotePressedModifierKeys.insert(modifier)
            postModifierEvent(modifier: modifier, keyDown: true)
        }
    }

    private func mappedModifiers(_ modifiers: Set<String>) -> Set<String> {
        Set(modifiers.map { config.keyboardModifierMap.target(for: $0) })
    }

    private func postModifierEvent(modifier: String, keyDown: Bool) {
        guard let keyCode = Self.canonicalToMacKey[modifier] else {
            return
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.type = .flagsChanged
        event.flags = Self.flags(from: Array(remotePressedModifierKeys))
        post(event)
    }

    private func releaseRemoteModifiers() {
        guard !remotePressedModifierKeys.isEmpty else {
            remotePressedSourceModifierKeys.removeAll()
            return
        }
        for key in Self.modifierKeyOrder where remotePressedModifierKeys.contains(key) {
            remotePressedModifierKeys.remove(key)
            postModifierEvent(modifier: key, keyDown: false)
        }
        remotePressedSourceModifierKeys.removeAll()
        remotePressedModifierKeys.removeAll()
    }

    private func warpTo(normalizedX: Double, normalizedY: Double) {
        let point = pointFor(normalizedX: normalizedX, normalizedY: normalizedY)
        CGWarpMouseCursorPosition(point)
        suppressUntil = Date().addingTimeInterval(0.08)
    }

    /// Maps a normalized 0...1 point onto the monitor we're currently receiving remote input for
    /// (`receivingScreenId`), falling back to the whole local desktop union if that screen can't
    /// be resolved (e.g. it was unplugged mid-session).
    private func pointFor(normalizedX: Double, normalizedY: Double) -> CGPoint {
        let rect = receivingScreenId.flatMap(localScreenRealRect) ?? Self.desktopBounds()
        return CGPoint(
            x: rect.minX + CGFloat(min(max(normalizedX, 0), 1)) * rect.width,
            y: rect.minY + CGFloat(min(max(normalizedY, 0), 1)) * rect.height
        )
    }

    /// macOS 27 (Golden Gate) betas stopped activating a window when a synthetic click lands on
    /// its body — only title-bar chrome still activates. Until Apple fixes or documents that,
    /// explicitly focus the window under the click point before posting the mouse-down.
    private static let needsSyntheticClickActivationWorkaround =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    private func activateWindowUnderRemoteClick(at point: CGPoint) {
        guard Self.needsSyntheticClickActivationWorkaround else {
            return
        }
        guard let pid = windowOwnerPid(at: point), pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid), !app.isActive else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hit) == .success,
           let hit {
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &windowRef) == .success,
               let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
                let window = windowRef as! AXUIElement
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }

    /// Topmost normal-layer window containing `point`, so we only activate the app the click
    /// actually lands on (and skip menu bar, Dock, and other shell chrome).
    private func windowOwnerPid(at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.contains(point) else {
                continue
            }
            return window[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    private func postMouseEvent(type: CGEventType, button: CGMouseButton, at point: CGPoint, clickState: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return
        }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        CGWarpMouseCursorPosition(point)
        post(event)
    }

    private func post(_ event: CGEvent) {
        suppressUntil = Date().addingTimeInterval(0.08)
        event.post(tap: .cghidEventTap)
    }

    private func currentCursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Hides this machine's own cursor while the mouse is being relayed onto a peer's screen, so the
    /// controller doesn't show a stray arrow parked at the screen edge. Balanced with
    /// `showLocalCursor()` via `localCursorHidden` because the window server ref-counts hide/show.
    private func hideLocalCursor() {
        guard !localCursorHidden else {
            return
        }
        allowBackgroundCursorHideIfNeeded()
        localCursorHidden = true
        CGDisplayHideCursor(CGMainDisplayID())
    }

    private func showLocalCursor() {
        guard localCursorHidden else {
            return
        }
        localCursorHidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// While relaying input to a peer, freeze the local (hidden) cursor in place instead of
    /// letting it wander and pin against this machine's physical screen edges. A pinned cursor
    /// rubs against macOS edge behaviors — menu-bar/notch barriers, rounded-corner containment,
    /// Dock-reveal pressure — which absorb or distort pointer motion, felt on the peer as
    /// stutter, sticking, and jumps whenever its cursor is near a screen edge. Mouse-moved
    /// events keep delivering delta values while disassociated, so relaying is unaffected.
    private func detachLocalMouseFromCursor() {
        guard !localCursorDetached else {
            return
        }
        localCursorDetached = true
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func reattachLocalMouseToCursor() {
        guard localCursorDetached else {
            return
        }
        localCursorDetached = false
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func allowBackgroundCursorHideIfNeeded() {
        guard !didAllowBackgroundCursorHide else {
            return
        }
        didAllowBackgroundCursorHide = true
        let connection = CGSDefaultConnection()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    static func currentScreens() -> [ScreenMetrics] {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 1)
        return activeDisplayIds().map { displayId in
            let bounds = CGDisplayBounds(displayId)
            return ScreenMetrics(
                width: Double(bounds.width),
                height: Double(bounds.height),
                scale: scale,
                localX: Double(bounds.origin.x),
                localY: Double(bounds.origin.y)
            )
        }
    }

    /// This machine's own monitor for `screenId` (parsed as `"<deviceId>#<index>"`), resolved
    /// against the current live display list. Used both to warp the local cursor back onto the
    /// right monitor when returning from remote capture, and to warp a remote peer's input onto
    /// the right one of our own monitors when receiving.
    private func localScreenRealRect(forScreenId screenId: String) -> CGRect? {
        guard screenId.hasPrefix("\(deviceId)#"), let index = Int(screenId.dropFirst(deviceId.count + 1)) else {
            return nil
        }
        let displays = Self.activeDisplayIds()
        guard displays.indices.contains(index) else {
            return nil
        }
        return CGDisplayBounds(displays[index])
    }

    /// This machine's actual cursor position, described as a normalized point on whichever of its
    /// own screens currently contains it, plus that screen's id. Used both to show a local "you are
    /// here" dot in the Screen Layout window and to report live position to peers watching it.
    /// Returns nil if the monitor the cursor is currently on hasn't been registered in `entries` yet.
    static func currentLocalCursorReport(deviceId: String, entries: [ScreenLayoutEntry]) -> (screenId: String, normalizedX: Double, normalizedY: Double)? {
        guard !deviceId.isEmpty else {
            return nil
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        for (index, displayId) in activeDisplayIds().enumerated() {
            let bounds = CGDisplayBounds(displayId)
            guard bounds.contains(location) else {
                continue
            }
            let screenId = "\(deviceId)#\(index)"
            guard entries.contains(where: { $0.screenId == screenId }) else {
                return nil
            }
            let normalizedX = min(max(Double(location.x - bounds.minX) / max(Double(bounds.width), 1), 0), 1)
            let normalizedY = min(max(Double(location.y - bounds.minY) / max(Double(bounds.height), 1), 0), 1)
            return (screenId, normalizedX, normalizedY)
        }
        return nil
    }

    /// The system's active displays, ordered by physical position (left-to-right, then top-to-
    /// bottom) rather than raw `CGGetActiveDisplayList` enumeration order. Raw order isn't
    /// guaranteed stable across relaunches or sleep/wake, which would otherwise make a monitor's
    /// index-based screenId (and therefore its saved layout position/size) drift or swap with
    /// another monitor's between sessions.
    static func activeDisplayIds() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return [CGMainDisplayID()]
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let error = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }
        guard error == .success else {
            return [CGMainDisplayID()]
        }
        return Array(displays.prefix(Int(displayCount))).sorted { lhs, rhs in
            let lhsBounds = CGDisplayBounds(lhs)
            let rhsBounds = CGDisplayBounds(rhs)
            if lhsBounds.origin.x != rhsBounds.origin.x {
                return lhsBounds.origin.x < rhsBounds.origin.x
            }
            return lhsBounds.origin.y < rhsBounds.origin.y
        }
    }

    private static func desktopBounds() -> CGRect {
        let bounds = activeDisplayIds().reduce(CGRect.null) { result, display in
            let displayBounds = CGDisplayBounds(display)
            return result.isNull ? displayBounds : result.union(displayBounds)
        }
        return bounds.isNull ? CGDisplayBounds(CGMainDisplayID()) : bounds
    }

    private func canonicalMouseButton(_ button: String?) -> String {
        switch button {
        case "right":
            return "right"
        case "middle":
            return "middle"
        default:
            return "left"
        }
    }

    private func cgMouseButton(for button: String) -> CGMouseButton {
        switch button {
        case "right":
            return .right
        case "middle":
            return .center
        default:
            return .left
        }
    }

    private static let modifierKeyOrder = ["Shift", "Control", "Alt", "Meta"]
    private static let modifierKeys = Set(modifierKeyOrder)
    private static let arrowKeys: Set<String> = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]
    private static let secondaryFnKeys: Set<String> = arrowKeys.union(["Home", "End", "PageUp", "PageDown", "Delete"])

    private var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    private var hasInputMonitoringPermission: Bool {
        CGPreflightListenEventAccess()
    }

    private func requestMissingPermissionsIfNeeded() {
        if !hasAccessibilityPermission {
            requestAccessibilityPermission()
        }
        if isController, !hasInputMonitoringPermission {
            requestInputMonitoringPermission()
        }
    }

    private func requestAccessibilityPermission() {
        guard !didRequestAccessibility else {
            return
        }
        didRequestAccessibility = true
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func requestInputMonitoringPermission() {
        guard !didRequestInputMonitoring else {
            return
        }
        didRequestInputMonitoring = true
        DispatchQueue.main.async {
            _ = CGRequestListenEventAccess()
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.maskShift) {
            result.append("Shift")
        }
        if flags.contains(.maskControl) {
            result.append("Control")
        }
        if flags.contains(.maskAlternate) {
            result.append("Alt")
        }
        if flags.contains(.maskCommand) {
            result.append("Meta")
        }
        return result
    }

    private static func flags(from modifiers: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains("Shift") {
            flags.insert(.maskShift)
        }
        if modifiers.contains("Control") {
            flags.insert(.maskControl)
        }
        if modifiers.contains("Alt") {
            flags.insert(.maskAlternate)
        }
        if modifiers.contains("Meta") {
            flags.insert(.maskCommand)
        }
        return flags
    }

    private static let macKeyToCanonical: [CGKeyCode: String] = [
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ", 7: "KeyX",
        8: "KeyC", 9: "KeyV", 11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR",
        16: "KeyY", 17: "KeyT", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4",
        22: "Digit6", 23: "Digit5", 24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus",
        28: "Digit8", 29: "Digit0", 30: "BracketRight", 31: "KeyO", 32: "KeyU", 33: "BracketLeft",
        34: "KeyI", 35: "KeyP", 36: "Enter", 37: "KeyL", 38: "KeyJ", 39: "Quote", 40: "KeyK",
        41: "Semicolon", 42: "Backslash", 43: "Comma", 44: "Slash", 45: "KeyN", 46: "KeyM",
        47: "Period", 48: "Tab", 49: "Space", 50: "Backquote", 51: "Backspace", 53: "Escape",
        55: "Meta", 56: "Shift", 58: "Alt", 59: "Control", 60: "Shift", 61: "Alt", 62: "Control",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 115: "Home", 116: "PageUp", 117: "Delete", 118: "F4",
        119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "ArrowLeft", 124: "ArrowRight",
        125: "ArrowDown", 126: "ArrowUp"
    ]

    private static let canonicalToMacKey: [String: CGKeyCode] = {
        var result: [String: CGKeyCode] = [:]
        for (keyCode, canonical) in macKeyToCanonical where result[canonical] == nil {
            result[canonical] = keyCode
        }
        return result
    }()
}
