import Foundation
import IOKit.ps
import IOKit.pwr_mgt

enum SleepPreventionError: LocalizedError {
    case invalidTimedExpiration
    case assertionCreationFailed(IOReturn)
    case assertionReleaseFailed(IOReturn)
    case powerSourceSnapshotUnavailable
    case powerSourceListUnavailable
    case invalidPowerSourceDescription(String)
    case powerSourceNotificationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidTimedExpiration:
            return "The saved timed sleep-prevention setting has no valid expiration."
        case let .assertionCreationFailed(code):
            return "macOS rejected the no-idle-sleep assertion (IOKit error \(code))."
        case let .assertionReleaseFailed(code):
            return "macOS could not release the no-idle-sleep assertion (IOKit error \(code))."
        case .powerSourceSnapshotUnavailable:
            return "macOS did not provide a power-source snapshot. Sleep prevention is paused for battery safety."
        case .powerSourceListUnavailable:
            return "macOS did not provide the power-source list. Sleep prevention is paused for battery safety."
        case let .invalidPowerSourceDescription(details):
            return "macOS returned incomplete battery information (\(details)). Sleep prevention is paused for battery safety."
        case .powerSourceNotificationUnavailable:
            return "macOS could not start battery-change notifications. Battery status will still be checked every 30 seconds."
        }
    }
}

enum SleepPreventionSuspensionReason {
    case lowBattery
    case batteryStatusUnavailable
}

private struct MacBatteryState: Equatable {
    let hasBattery: Bool
    let isOnBatteryPower: Bool
    let chargePercent: Double
}

/// Reads internal-battery state from IOKit. Power-source notifications provide prompt changes;
/// the poll timer also recovers if a notification is missed or the IOKit snapshot briefly fails.
private final class MacBatteryMonitor {
    typealias UpdateHandler = (Result<MacBatteryState, Error>) -> Void

    var onMonitoringFailure: ((Error) -> Void)?

    private var updateHandler: UpdateHandler?
    private var notificationSource: CFRunLoopSource?
    private var pollTimer: Timer?

    func start(onUpdate: @escaping UpdateHandler) -> Result<MacBatteryState, Error> {
        precondition(Thread.isMainThread, "Battery monitoring must run on the main thread")
        stop()
        updateHandler = onUpdate

        let initialResult = readCurrentState()
        let shouldInstallNotifications: Bool
        switch initialResult {
        case let .success(state):
            shouldInstallNotifications = state.hasBattery
        case .failure:
            // A notification may let the controller recover before the next poll.
            shouldInstallNotifications = true
        }

        if shouldInstallNotifications {
            if let sourceHandle = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    Unmanaged<MacBatteryMonitor>.fromOpaque(context)
                        .takeUnretainedValue()
                        .publishCurrentState()
                },
                Unmanaged.passUnretained(self).toOpaque()
            ) {
                let source = sourceHandle.takeRetainedValue()
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                notificationSource = source
            } else {
                onMonitoringFailure?(SleepPreventionError.powerSourceNotificationUnavailable)
            }
        }

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.publishCurrentState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        return initialResult
    }

    func refresh() -> Result<MacBatteryState, Error> {
        precondition(Thread.isMainThread, "Battery status must be read on the main thread")
        return readCurrentState()
    }

    func stop() {
        precondition(Thread.isMainThread, "Battery monitoring must stop on the main thread")
        pollTimer?.invalidate()
        pollTimer = nil
        if let notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
            self.notificationSource = nil
        }
        updateHandler = nil
    }

    private func publishCurrentState() {
        updateHandler?(readCurrentState())
    }

    private func readCurrentState() -> Result<MacBatteryState, Error> {
        do {
            guard let infoHandle = IOPSCopyPowerSourcesInfo() else {
                throw SleepPreventionError.powerSourceSnapshotUnavailable
            }
            let info = infoHandle.takeRetainedValue()
            guard let listHandle = IOPSCopyPowerSourcesList(info) else {
                throw SleepPreventionError.powerSourceListUnavailable
            }
            let sources = listHandle.takeRetainedValue() as NSArray

            var foundInternalBattery = false
            var isOnBatteryPower = false
            var totalCurrentCapacity = 0.0
            var totalMaxCapacity = 0.0

            for source in sources {
                guard
                    let descriptionHandle = IOPSGetPowerSourceDescription(info, source as CFTypeRef),
                    let description = descriptionHandle.takeUnretainedValue() as? [String: Any]
                else {
                    throw SleepPreventionError.invalidPowerSourceDescription("description unavailable")
                }
                guard let type = description[kIOPSTypeKey] as? String else {
                    throw SleepPreventionError.invalidPowerSourceDescription("missing type")
                }
                guard type == kIOPSInternalBatteryType else {
                    continue
                }
                guard let isPresent = description[kIOPSIsPresentKey] as? Bool else {
                    throw SleepPreventionError.invalidPowerSourceDescription("missing presence")
                }
                guard isPresent else {
                    continue
                }
                guard
                    let powerSourceState = description[kIOPSPowerSourceStateKey] as? String,
                    let currentCapacity = description[kIOPSCurrentCapacityKey] as? NSNumber,
                    let maxCapacity = description[kIOPSMaxCapacityKey] as? NSNumber,
                    maxCapacity.doubleValue > 0
                else {
                    throw SleepPreventionError.invalidPowerSourceDescription("missing charge or supply state")
                }

                foundInternalBattery = true
                isOnBatteryPower = isOnBatteryPower || powerSourceState == kIOPSBatteryPowerValue
                totalCurrentCapacity += currentCapacity.doubleValue
                totalMaxCapacity += maxCapacity.doubleValue
            }

            guard foundInternalBattery else {
                return .success(MacBatteryState(
                    hasBattery: false,
                    isOnBatteryPower: false,
                    chargePercent: 100
                ))
            }
            guard totalMaxCapacity > 0 else {
                throw SleepPreventionError.invalidPowerSourceDescription("invalid maximum capacity")
            }
            return .success(MacBatteryState(
                hasBattery: true,
                isOnBatteryPower: isOnBatteryPower,
                chargePercent: totalCurrentCapacity / totalMaxCapacity * 100
            ))
        } catch {
            return .failure(error)
        }
    }
}

/// Owns the macOS power assertion, battery guard, and expiration timer. The selected duration is
/// persisted by AppController. A low battery pauses only the assertion; the selection and absolute
/// timed deadline remain unchanged so reconnecting power resumes only for the original remainder.
final class SleepPreventionController {
    private(set) var selection: SleepPreventionDuration = .disabled
    private(set) var expiresAt: Date?
    private(set) var lowBatteryGuardEnabled = false
    private(set) var suspensionReason: SleepPreventionSuspensionReason?

    var onExpired: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onStateChanged: (() -> Void)?

    private var assertionID: IOPMAssertionID?
    private var expirationTimer: Timer?
    private let batteryMonitor = MacBatteryMonitor()
    private var batteryState: MacBatteryState?
    private var batteryStatusError: Error?
    private var lastReportedBatteryError: String?

    init() {
        batteryMonitor.onMonitoringFailure = { [weak self] error in
            NSLog("Battery monitoring warning: \(error.localizedDescription)")
            self?.onFailure?(error)
        }
    }

    static func shouldSuspendForLowBattery(
        hasBattery: Bool,
        isOnBatteryPower: Bool,
        chargePercent: Double
    ) -> Bool {
        hasBattery && isOnBatteryPower && chargePercent < 20
    }

    /// Configures the independent battery-safety checkbox. When battery status cannot be read,
    /// an active selection is paused and the failure is surfaced instead of silently draining it.
    func setLowBatteryGuardEnabled(_ enabled: Bool) throws {
        precondition(Thread.isMainThread, "Sleep prevention must be changed on the main thread")
        guard enabled != lowBatteryGuardEnabled else { return }

        if enabled {
            let result = batteryMonitor.start { [weak self] result in
                self?.handleBatteryUpdate(result)
            }
            storeBatteryResult(result)
            let nextReason = desiredSuspensionReason(for: selection, guardEnabled: true)
            do {
                try enforceAssertion(for: selection, suspensionReason: nextReason)
            } catch {
                batteryMonitor.stop()
                batteryState = nil
                batteryStatusError = nil
                throw error
            }
            lowBatteryGuardEnabled = true
            updateSuspensionReason(nextReason)
            reportStoredBatteryFailureIfNeeded()
            NSLog("Low-battery sleep-prevention guard enabled")
            return
        }

        try enforceAssertion(for: selection, suspensionReason: nil)
        lowBatteryGuardEnabled = false
        batteryMonitor.stop()
        batteryState = nil
        batteryStatusError = nil
        lastReportedBatteryError = nil
        updateSuspensionReason(nil)
        NSLog("Low-battery sleep-prevention guard disabled")
    }

    /// Restores persisted duration state. Returns true when a previously timed selection already
    /// expired and its persisted state must be cleared by the caller.
    func restore(selection: SleepPreventionDuration, expiresAt: Date?) throws -> Bool {
        guard selection != .disabled else {
            try applySelection(.disabled, expiresAt: nil)
            return false
        }

        if selection.isTimed {
            guard let expiresAt else {
                throw SleepPreventionError.invalidTimedExpiration
            }
            guard expiresAt > Date() else {
                try applySelection(.disabled, expiresAt: nil)
                NSLog("Sleep prevention selection expired while Clipboard Sync was not running")
                return true
            }
        }

        refreshBatteryStateBeforeUserChange()
        try applySelection(selection, expiresAt: selection.isTimed ? expiresAt : nil)
        NSLog("Restored sleep prevention: \(selection.rawValue)")
        return false
    }

    /// Applies a menu choice and returns the absolute expiration to persist, if it is timed.
    @discardableResult
    func select(_ duration: SleepPreventionDuration) throws -> Date? {
        if duration == .disabled {
            try applySelection(.disabled, expiresAt: nil)
            NSLog("Sleep prevention disabled")
            return nil
        }

        refreshBatteryStateBeforeUserChange()
        let expiration = duration.hours.map { Date().addingTimeInterval(TimeInterval($0 * 60 * 60)) }
        try applySelection(duration, expiresAt: expiration)
        reportStoredBatteryFailureIfNeeded()
        NSLog("Sleep prevention selected: \(duration.rawValue)")
        return expiration
    }

    /// Releases process-owned resources without changing persisted policy state.
    func stopForTermination() throws {
        expirationTimer?.invalidate()
        expirationTimer = nil
        batteryMonitor.stop()
        try releaseAssertionIfNeeded()
    }

    private func applySelection(_ duration: SleepPreventionDuration, expiresAt: Date?) throws {
        let nextReason = desiredSuspensionReason(for: duration, guardEnabled: lowBatteryGuardEnabled)
        try enforceAssertion(for: duration, suspensionReason: nextReason)
        selection = duration
        self.expiresAt = expiresAt
        updateSuspensionReason(nextReason)
        scheduleExpirationTimer()
    }

    private func desiredSuspensionReason(
        for duration: SleepPreventionDuration,
        guardEnabled: Bool
    ) -> SleepPreventionSuspensionReason? {
        guard duration != .disabled, guardEnabled else { return nil }
        guard let batteryState else { return .batteryStatusUnavailable }
        return Self.shouldSuspendForLowBattery(
            hasBattery: batteryState.hasBattery,
            isOnBatteryPower: batteryState.isOnBatteryPower,
            chargePercent: batteryState.chargePercent
        ) ? .lowBattery : nil
    }

    private func enforceAssertion(
        for duration: SleepPreventionDuration,
        suspensionReason: SleepPreventionSuspensionReason?
    ) throws {
        if duration == .disabled || suspensionReason != nil {
            try releaseAssertionIfNeeded()
        } else {
            try acquireAssertionIfNeeded()
        }
    }

    private func refreshBatteryStateBeforeUserChange() {
        guard lowBatteryGuardEnabled else { return }
        storeBatteryResult(batteryMonitor.refresh())
    }

    private func handleBatteryUpdate(_ result: Result<MacBatteryState, Error>) {
        guard lowBatteryGuardEnabled else { return }
        storeBatteryResult(result)
        let nextReason = desiredSuspensionReason(for: selection, guardEnabled: true)
        do {
            try enforceAssertion(for: selection, suspensionReason: nextReason)
            updateSuspensionReason(nextReason)
        } catch {
            NSLog("Failed to reconcile sleep prevention after a battery update: \(error.localizedDescription)")
            onFailure?(error)
            return
        }
        reportStoredBatteryFailureIfNeeded()
    }

    private func storeBatteryResult(_ result: Result<MacBatteryState, Error>) {
        switch result {
        case let .success(state):
            if batteryState != state {
                NSLog(
                    "Battery status: present=\(state.hasBattery), onBattery=\(state.isOnBatteryPower), charge=\(String(format: "%.1f", state.chargePercent))%"
                )
            }
            batteryState = state
            batteryStatusError = nil
            lastReportedBatteryError = nil
        case let .failure(error):
            if batteryStatusError?.localizedDescription != error.localizedDescription {
                NSLog("Failed to read battery status: \(error.localizedDescription)")
            }
            batteryState = nil
            batteryStatusError = error
        }
    }

    private func reportStoredBatteryFailureIfNeeded() {
        guard let batteryStatusError else { return }
        let message = batteryStatusError.localizedDescription
        guard message != lastReportedBatteryError else { return }
        lastReportedBatteryError = message
        onFailure?(batteryStatusError)
    }

    private func updateSuspensionReason(_ nextReason: SleepPreventionSuspensionReason?) {
        guard suspensionReason != nextReason else { return }
        suspensionReason = nextReason
        switch nextReason {
        case .lowBattery:
            NSLog("Sleep prevention paused because battery power is below 20%")
        case .batteryStatusUnavailable:
            NSLog("Sleep prevention paused because battery status is unavailable")
        case nil:
            NSLog("Sleep prevention is not battery-suspended")
        }
        onStateChanged?()
    }

    private func acquireAssertionIfNeeded() throws {
        guard assertionID == nil else { return }

        var nextAssertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Clipboard Sync: user requested system sleep prevention" as CFString,
            &nextAssertionID
        )
        guard result == kIOReturnSuccess else {
            throw SleepPreventionError.assertionCreationFailed(result)
        }
        assertionID = nextAssertionID
        NSLog("Acquired macOS no-idle-sleep assertion \(nextAssertionID)")
    }

    private func releaseAssertionIfNeeded() throws {
        guard let assertionID else { return }
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            throw SleepPreventionError.assertionReleaseFailed(result)
        }
        self.assertionID = nil
        NSLog("Released macOS no-idle-sleep assertion \(assertionID)")
    }

    private func scheduleExpirationTimer() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        guard let expiresAt else { return }

        let timer = Timer(fire: expiresAt, interval: 0, repeats: false) { [weak self] _ in
            self?.expireIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationTimer = timer
    }

    private func expireIfDue() {
        guard let expiresAt else { return }
        guard expiresAt <= Date() else {
            scheduleExpirationTimer()
            return
        }

        expirationTimer = nil
        do {
            try applySelection(.disabled, expiresAt: nil)
            NSLog("Timed sleep prevention expired")
            onExpired?()
        } catch {
            NSLog("Failed to end timed sleep prevention: \(error.localizedDescription)")
            onFailure?(error)
        }
    }
}
