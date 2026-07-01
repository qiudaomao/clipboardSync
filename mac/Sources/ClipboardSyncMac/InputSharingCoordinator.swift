import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class InputSharingCoordinator {
    var onMessage: ((InputMessage) -> Void)?
    var onStatus: ((String) -> Void)?

    private let deviceId: String
    private var role: SyncMode = .client
    private var config = AppConfig.defaults
    private var peerCount = 0
    private var remoteDeviceId: String?
    private var remoteScreen: ScreenMetrics?
    private var remoteInputEnabled: Bool?
    private var remoteActive = false
    private var receivingRemote = false
    private var remotePosition = CGPoint.zero
    private var remotePressedMouseButtons: Set<String> = []
    private var remotePressedModifierKeys: Set<String> = []
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var lastModifierKeys: Set<String> = []
    private let mouseMoveSendInterval: TimeInterval = 1.0 / 60.0
    private var lastMouseMoveSentAt = Date.distantPast
    private var pendingMouseMoveTimer: DispatchSourceTimer?
    private var suppressUntil = Date.distantPast
    private var didRequestAccessibility = false
    private var didRequestInputMonitoring = false

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    func start() {
        updateInputState()
    }

    func stop() {
        sendPressedModifierKeyUps()
        removeEventTap()
        remoteActive = false
        receivingRemote = false
        remotePressedMouseButtons.removeAll()
        cancelPendingMouseMove()
        releaseRemoteModifiers()
    }

    func update(config: AppConfig, role: SyncMode, peerCount: Int) {
        self.config = config
        self.role = role
        self.peerCount = peerCount
        updateInputState()
    }

    func makeHello(deviceName: String, deviceAddress: String?) -> InputMessage {
        InputMessage.hello(
            origin: deviceId,
            role: role,
            deviceName: deviceName,
            deviceAddress: deviceAddress,
            screen: Self.currentScreenMetrics(),
            enabled: config.inputSharingEnabled && peerCount > 0,
            controlDeviceId: effectiveControlDeviceId,
            peerEdge: config.peerEdge
        )
    }

    func handle(_ message: InputMessage) {
        guard message.origin != deviceId, message.target == nil || message.target == deviceId else {
            return
        }

        if message.kind == "hello" {
            if shouldUseAsRemotePeer(message) {
                remoteDeviceId = message.origin
                remoteScreen = message.screen
                remoteInputEnabled = message.enabled
            }
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

    private func shouldUseAsRemotePeer(_ message: InputMessage) -> Bool {
        if isController {
            if role == .client {
                return message.role == SyncMode.server.rawValue
            }
            return message.role == SyncMode.client.rawValue &&
                (remoteDeviceId == nil || remoteDeviceId == message.origin || peerCount <= 1)
        }
        return message.origin == effectiveControlDeviceId
    }

    private func updateInputState() {
        if config.inputSharingEnabled {
            requestMissingPermissionsIfNeeded()
        }

        if isController, hasAccessibilityPermission, hasInputMonitoringPermission {
            ensureEventTap()
        } else {
            if remoteActive {
                sendPressedModifierKeyUps()
                sendCapture(action: "end")
            }
            removeEventTap()
            remoteActive = false
            cancelPendingMouseMove()
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
        } else if isController && remoteInputEnabled == false {
            status = AppText.text("input.peerDisabled")
        } else if isController && (remoteScreen == nil || remoteInputEnabled == nil) {
            status = AppText.text("input.waitingPeerScreen")
        } else if isController {
            status = AppText.format("input.controllingPeer", config.peerEdge.title)
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
            guard remoteActive else {
                return Unmanaged.passUnretained(event)
            }
            flushPendingMouseMove()
            sendMouseButton(type: type)
            return nil
        case .scrollWheel:
            guard remoteActive else {
                return Unmanaged.passUnretained(event)
            }
            flushPendingMouseMove()
            sendMouseWheel(event)
            return nil
        case .keyDown, .keyUp:
            guard remoteActive else {
                return Unmanaged.passUnretained(event)
            }
            sendKey(event, action: type == .keyDown ? "down" : "up")
            return nil
        case .flagsChanged:
            guard remoteActive else {
                return Unmanaged.passUnretained(event)
            }
            sendModifierChanges(event)
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleLocalMouseMove(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if !remoteActive {
            guard shouldStartCapture(at: event.location), let remoteScreen else {
                return Unmanaged.passUnretained(event)
            }
            remoteActive = true
            remotePosition = entryPosition(on: remoteScreen, edge: config.peerEdge, location: event.location)
            sendCapture(action: "start")
            sendMouseMoveNow()
            updateStatus()
            return nil
        }

        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        remotePosition.x += dx
        remotePosition.y += dy

        if shouldEndCapture(deltaX: dx, deltaY: dy) {
            cancelPendingMouseMove()
            sendPressedModifierKeyUps()
            sendCapture(action: "end")
            remoteActive = false
            warpLocalCursorToReturnPoint()
            updateStatus()
            return nil
        }

        if let remoteScreen {
            remotePosition.x = min(max(remotePosition.x, 0), max(remoteScreen.width - 1, 0))
            remotePosition.y = min(max(remotePosition.y, 0), max(remoteScreen.height - 1, 0))
        }
        queueMouseMove()
        return nil
    }

    private func shouldStartCapture(at location: CGPoint) -> Bool {
        guard remoteScreen != nil, remoteInputEnabled == true else {
            return false
        }
        let bounds = Self.desktopBounds()
        let threshold = 2.0
        switch config.peerEdge {
        case .right:
            return Double(location.x) >= Double(bounds.maxX) - threshold
        case .left:
            return Double(location.x) <= Double(bounds.minX) + threshold
        case .top:
            return Double(location.y) <= Double(bounds.minY) + threshold
        case .bottom:
            return Double(location.y) >= Double(bounds.maxY) - threshold
        }
    }

    private func shouldEndCapture(deltaX: Double, deltaY: Double) -> Bool {
        guard let remoteScreen else {
            return true
        }
        switch config.peerEdge {
        case .right:
            return remotePosition.x <= 0 && deltaX < 0
        case .left:
            return remotePosition.x >= remoteScreen.width - 1 && deltaX > 0
        case .top:
            return remotePosition.y >= remoteScreen.height - 1 && deltaY > 0
        case .bottom:
            return remotePosition.y <= 0 && deltaY < 0
        }
    }

    private func entryPosition(on screen: ScreenMetrics, edge: ScreenEdge, location: CGPoint) -> CGPoint {
        let bounds = Self.desktopBounds()
        let normalizedX = Double(location.x - bounds.minX) / max(Double(bounds.width), 1)
        let normalizedY = Double(location.y - bounds.minY) / max(Double(bounds.height), 1)
        switch edge {
        case .right:
            return CGPoint(x: 0, y: normalizedY * screen.height)
        case .left:
            return CGPoint(x: max(screen.width - 1, 0), y: normalizedY * screen.height)
        case .top:
            return CGPoint(x: normalizedX * screen.width, y: max(screen.height - 1, 0))
        case .bottom:
            return CGPoint(x: normalizedX * screen.width, y: 0)
        }
    }

    private func warpLocalCursorToReturnPoint() {
        let bounds = Self.desktopBounds()
        let localX: CGFloat
        let localY: CGFloat
        switch config.peerEdge {
        case .right:
            localX = bounds.maxX - 2
            localY = bounds.minY + bounds.height * normalizedRemoteY()
        case .left:
            localX = bounds.minX + 2
            localY = bounds.minY + bounds.height * normalizedRemoteY()
        case .top:
            localX = bounds.minX + bounds.width * normalizedRemoteX()
            localY = bounds.minY + 2
        case .bottom:
            localX = bounds.minX + bounds.width * normalizedRemoteX()
            localY = bounds.maxY - 2
        }
        CGWarpMouseCursorPosition(CGPoint(x: localX, y: localY))
        suppressUntil = Date().addingTimeInterval(0.08)
    }

    private func sendCapture(action: String) {
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: remoteDeviceId,
            kind: "capture",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screen: nil,
            enabled: nil,
            controlDeviceId: nil,
            peerEdge: nil,
            capture: InputCapturePayload(
                action: action,
                edge: config.peerEdge.rawValue,
                normalizedX: normalizedRemoteX(),
                normalizedY: normalizedRemoteY()
            ),
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func sendMouseMove() {
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: remoteDeviceId,
            kind: "mouseMove",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screen: nil,
            enabled: nil,
            controlDeviceId: nil,
            peerEdge: nil,
            capture: nil,
            mouse: InputMousePayload(
                action: "move",
                button: nil,
                normalizedX: normalizedRemoteX(),
                normalizedY: normalizedRemoteY(),
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
            guard self.remoteActive else {
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
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: remoteDeviceId,
            kind: "mouseButton",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screen: nil,
            enabled: nil,
            controlDeviceId: nil,
            peerEdge: nil,
            capture: nil,
            mouse: InputMousePayload(
                action: action,
                button: button,
                normalizedX: normalizedRemoteX(),
                normalizedY: normalizedRemoteY(),
                deltaX: nil,
                deltaY: nil
            ),
            key: nil,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private func sendMouseWheel(_ event: CGEvent) {
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: remoteDeviceId,
            kind: "mouseWheel",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screen: nil,
            enabled: nil,
            controlDeviceId: nil,
            peerEdge: nil,
            capture: nil,
            mouse: InputMousePayload(
                action: "wheel",
                button: nil,
                normalizedX: normalizedRemoteX(),
                normalizedY: normalizedRemoteY(),
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
        onMessage?(InputMessage(
            type: "input",
            origin: deviceId,
            target: remoteDeviceId,
            kind: "key",
            role: nil,
            deviceName: nil,
            deviceAddress: nil,
            screen: nil,
            enabled: nil,
            controlDeviceId: nil,
            peerEdge: nil,
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
            remotePressedMouseButtons.removeAll()
            releaseRemoteModifiers()
            warpTo(normalizedX: capture.normalizedX, normalizedY: capture.normalizedY)
        } else if capture.action == "end" {
            releaseRemoteModifiers()
            receivingRemote = false
            remotePressedMouseButtons.removeAll()
        }
    }

    private func handleRemoteMouseMove(_ mouse: InputMousePayload?) {
        guard receivingRemote, let mouse, let x = mouse.normalizedX, let y = mouse.normalizedY else {
            return
        }
        let point = pointFor(normalizedX: x, normalizedY: y)
        if let eventType = remoteDragEventType {
            postMouseEvent(type: eventType, button: remoteDragButton, at: point)
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
            remotePressedMouseButtons.insert(buttonName)
        }
        postMouseEvent(type: eventType, button: button, at: point)
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
        guard receivingRemote, let key, let keyCode = Self.canonicalToMacKey[key.key] else {
            return
        }
        if Self.modifierKeys.contains(key.key) {
            if key.action == "down" {
                remotePressedModifierKeys.insert(key.key)
            } else {
                remotePressedModifierKeys.remove(key.key)
            }
            postModifierEvent(keyCode: keyCode, keyDown: key.action == "down")
            return
        }

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: key.action == "down") else {
            return
        }
        let modifiers = remotePressedModifierKeys.union(key.modifiers)
        event.flags = Self.flags(from: Array(modifiers))
        post(event)
    }

    private func postModifierEvent(keyCode: CGKeyCode, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.type = .flagsChanged
        event.flags = Self.flags(from: Array(remotePressedModifierKeys))
        post(event)
    }

    private func releaseRemoteModifiers() {
        guard !remotePressedModifierKeys.isEmpty else {
            return
        }
        for key in Self.modifierKeyOrder where remotePressedModifierKeys.contains(key) {
            remotePressedModifierKeys.remove(key)
            if let keyCode = Self.canonicalToMacKey[key] {
                postModifierEvent(keyCode: keyCode, keyDown: false)
            }
        }
        remotePressedModifierKeys.removeAll()
    }

    private func warpTo(normalizedX: Double, normalizedY: Double) {
        let point = pointFor(normalizedX: normalizedX, normalizedY: normalizedY)
        CGWarpMouseCursorPosition(point)
        suppressUntil = Date().addingTimeInterval(0.08)
    }

    private func pointFor(normalizedX: Double, normalizedY: Double) -> CGPoint {
        let bounds = Self.desktopBounds()
        return CGPoint(
            x: bounds.minX + CGFloat(min(max(normalizedX, 0), 1)) * bounds.width,
            y: bounds.minY + CGFloat(min(max(normalizedY, 0), 1)) * bounds.height
        )
    }

    private func postMouseEvent(type: CGEventType, button: CGMouseButton, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return
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

    private func normalizedRemoteX() -> Double {
        guard let remoteScreen else {
            return 0
        }
        return min(max(Double(remotePosition.x) / max(remoteScreen.width, 1), 0), 1)
    }

    private func normalizedRemoteY() -> Double {
        guard let remoteScreen else {
            return 0
        }
        return min(max(Double(remotePosition.y) / max(remoteScreen.height, 1), 0), 1)
    }

    static func currentScreenMetrics() -> ScreenMetrics {
        let bounds = desktopBounds()
        return ScreenMetrics(
            width: Double(bounds.width),
            height: Double(bounds.height),
            scale: Double(NSScreen.main?.backingScaleFactor ?? 1)
        )
    }

    private static func desktopBounds() -> CGRect {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let error = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }
        guard error == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }

        let bounds = displays.prefix(Int(displayCount)).reduce(CGRect.null) { result, display in
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
