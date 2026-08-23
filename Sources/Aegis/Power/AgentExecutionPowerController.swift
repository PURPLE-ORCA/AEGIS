import Foundation
import IOKit.pwr_mgt

enum AgentKeepAwakeMode: String, CaseIterable, Identifiable {
    case off
    case powerAdapter
    case powerAdapterAndBattery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .powerAdapter: return "On Power Adapter"
        case .powerAdapterAndBattery: return "On Power Adapter and Battery"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Your Mac follows its normal sleep settings."
        case .powerAdapter:
            return "Prevents idle sleep only while connected to external power."
        case .powerAdapterAndBattery:
            return "Also keeps work running on battery, with automatic low-power safeguards."
        }
    }
}

enum AegisPowerSource: Equatable {
    case external
    case battery
}

struct SystemPowerConditions: Equatable {
    var source: AegisPowerSource
    var isLowPowerModeEnabled: Bool
    var hasLowBatteryWarning: Bool
}

enum SleepAssertionLease: Equatable {
    case indefinite
    case timed(TimeInterval)
}

protocol SleepAssertionBackend: AnyObject {
    var hasAssertion: Bool { get }

    @discardableResult
    func acquire(lease: SleepAssertionLease) -> Bool

    @discardableResult
    func rearm(lease: SleepAssertionLease) -> Bool

    func release()
}

final class IOKitSleepAssertionBackend: SleepAssertionBackend {
    private(set) var assertionID: IOPMAssertionID?

    var hasAssertion: Bool { assertionID != nil }

    @discardableResult
    func acquire(lease: SleepAssertionLease) -> Bool {
        guard assertionID == nil else { return true }

        var newID = IOPMAssertionID(0)
        let timeout: TimeInterval
        let timeoutAction: CFString?
        switch lease {
        case .indefinite:
            timeout = 0
            timeoutAction = nil
        case .timed(let duration):
            timeout = duration
            timeoutAction = kIOPMAssertionTimeoutActionTurnOff as CFString
        }

        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            "Aegis agent execution" as CFString,
            "A supported agent is actively working" as CFString,
            nil,
            nil,
            timeout,
            timeoutAction,
            &newID
        )
        guard result == kIOReturnSuccess else {
            Log.error("Failed to prevent idle sleep: IOKit error \(result)")
            return false
        }

        assertionID = newID
        Log.info("Idle sleep prevention acquired")
        return true
    }

    @discardableResult
    func rearm(lease: SleepAssertionLease) -> Bool {
        guard let assertionID else { return acquire(lease: lease) }
        guard case .timed(let duration) = lease else { return true }

        let result = IOPMAssertionSetProperty(
            assertionID,
            kIOPMAssertionTimeoutKey as CFString,
            NSNumber(value: duration)
        )
        guard result == kIOReturnSuccess else {
            Log.error("Failed to refresh idle sleep prevention: IOKit error \(result)")
            return false
        }
        return true
    }

    func release() {
        guard let assertionID else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result != kIOReturnSuccess {
            Log.error("Failed to release idle sleep prevention: IOKit error \(result)")
        }
        self.assertionID = nil
        Log.info("Idle sleep prevention released")
    }

    deinit {
        release()
    }
}

@MainActor
final class AgentExecutionPowerController {
    static let batteryInactivityLease: TimeInterval = 2 * 60 * 60
    static let minimumBatteryRearmInterval: TimeInterval = 30 * 60

    private let backend: SleepAssertionBackend
    private let now: () -> Date
    private var mode: AgentKeepAwakeMode = .off
    private var conditions = SystemPowerConditions(
        source: .battery,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false
    )
    private var executingSessionIDs: Set<String> = []
    private var activeLease: SleepAssertionLease?
    private var lastRearmAt: Date?

    init(
        backend: SleepAssertionBackend = IOKitSleepAssertionBackend(),
        now: @escaping () -> Date = Date.init
    ) {
        self.backend = backend
        self.now = now
    }

    func handle(_ event: SessionExecutionEvent) {
        switch event {
        case .began(let sessionID):
            guard executingSessionIDs.insert(sessionID).inserted else { return }
            reconcile(recordedProgress: true)
        case .progressed(let sessionID):
            guard executingSessionIDs.contains(sessionID) else { return }
            reconcile(recordedProgress: true)
        case .ended(let sessionID):
            guard executingSessionIDs.remove(sessionID) != nil else { return }
            reconcile(recordedProgress: false)
        }
    }

    func update(mode: AgentKeepAwakeMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        reconcile(recordedProgress: false)
    }

    func update(conditions: SystemPowerConditions) {
        guard self.conditions != conditions else { return }
        self.conditions = conditions
        reconcile(recordedProgress: false)
    }

    func stop() {
        executingSessionIDs.removeAll()
        mode = .off
        releaseAssertion()
    }

    private var desiredLease: SleepAssertionLease? {
        guard !executingSessionIDs.isEmpty,
              !conditions.isLowPowerModeEnabled,
              !conditions.hasLowBatteryWarning else { return nil }

        switch mode {
        case .off:
            return nil
        case .powerAdapter:
            return conditions.source == .external ? .indefinite : nil
        case .powerAdapterAndBattery:
            return conditions.source == .external
                ? .indefinite
                : .timed(Self.batteryInactivityLease)
        }
    }

    private func reconcile(recordedProgress: Bool) {
        guard let desiredLease else {
            releaseAssertion()
            return
        }

        if activeLease != desiredLease || !backend.hasAssertion {
            releaseAssertion()
            if backend.acquire(lease: desiredLease) {
                activeLease = desiredLease
                lastRearmAt = now()
            }
            return
        }

        guard recordedProgress,
              case .timed = desiredLease,
              let lastRearmAt,
              now().timeIntervalSince(lastRearmAt) >= Self.minimumBatteryRearmInterval else {
            return
        }

        if backend.rearm(lease: desiredLease) {
            self.lastRearmAt = now()
        }
    }

    private func releaseAssertion() {
        backend.release()
        activeLease = nil
        lastRearmAt = nil
    }
}
