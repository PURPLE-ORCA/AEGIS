import Foundation
import IOKit.ps
import notify

@MainActor
final class SystemPowerConditionMonitor {
    var onChange: ((SystemPowerConditions) -> Void)?

    private var powerSourceToken: Int32 = -1
    private var lowBatteryToken: Int32 = -1
    private var lowPowerModeObserver: NSObjectProtocol?
    private var isRunning = false
    private var lastConditions: SystemPowerConditions?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        registerPowerSourceNotification()
        registerLowBatteryNotification()
        lowPowerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if powerSourceToken >= 0 {
            notify_cancel(powerSourceToken)
            powerSourceToken = -1
        }
        if lowBatteryToken >= 0 {
            notify_cancel(lowBatteryToken)
            lowBatteryToken = -1
        }
        if let lowPowerModeObserver {
            NotificationCenter.default.removeObserver(lowPowerModeObserver)
            self.lowPowerModeObserver = nil
        }
    }

    private func registerPowerSourceNotification() {
        let result = notify_register_dispatch(
            kIOPSNotifyPowerSource,
            &powerSourceToken,
            DispatchQueue.main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        if result != NOTIFY_STATUS_OK {
            powerSourceToken = -1
            Log.error("Failed to observe power source changes: notify error \(result)")
        }
    }

    private func registerLowBatteryNotification() {
        let result = notify_register_dispatch(
            kIOPSNotifyLowBattery,
            &lowBatteryToken,
            DispatchQueue.main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        if result != NOTIFY_STATUS_OK {
            lowBatteryToken = -1
            Log.error("Failed to observe low battery warnings: notify error \(result)")
        }
    }

    private func refresh() {
        guard isRunning else { return }
        let conditions = Self.currentConditions()
        guard conditions != lastConditions else { return }
        lastConditions = conditions
        onChange?(conditions)
    }

    static func currentConditions() -> SystemPowerConditions {
        SystemPowerConditions(
            source: currentPowerSource(),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            hasLowBatteryWarning: IOPSGetBatteryWarningLevel() != kIOPSLowBatteryWarningNone
        )
    }

    private static func currentPowerSource() -> AegisPowerSource {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        return source == kIOPMACPowerKey ? .external : .battery
    }

    deinit {
        if powerSourceToken >= 0 { notify_cancel(powerSourceToken) }
        if lowBatteryToken >= 0 { notify_cancel(lowBatteryToken) }
        if let lowPowerModeObserver { NotificationCenter.default.removeObserver(lowPowerModeObserver) }
    }
}
