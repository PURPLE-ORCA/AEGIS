import XCTest
@testable import Aegis

final class AgentExecutionPowerControllerTests: XCTestCase {
    @MainActor
    func testAdapterModeOwnsOneAssertionAcrossMultipleSessions() {
        let backend = FakeSleepAssertionBackend()
        let controller = AgentExecutionPowerController(backend: backend)
        controller.update(conditions: externalPower)
        controller.update(mode: .powerAdapter)

        controller.handle(.began("one"))
        controller.handle(.began("two"))
        controller.handle(.ended("one"))

        XCTAssertEqual(backend.acquiredLeases, [.indefinite])
        XCTAssertEqual(backend.releaseCount, 0)

        controller.handle(.ended("two"))

        XCTAssertEqual(backend.releaseCount, 1)
        XCTAssertFalse(backend.hasAssertion)
    }

    @MainActor
    func testAdapterOnlyModeReleasesWhenPowerIsDisconnected() {
        let backend = FakeSleepAssertionBackend()
        let controller = AgentExecutionPowerController(backend: backend)
        controller.update(conditions: externalPower)
        controller.update(mode: .powerAdapter)
        controller.handle(.began("one"))

        controller.update(conditions: batteryPower)

        XCTAssertEqual(backend.releaseCount, 1)
        XCTAssertFalse(backend.hasAssertion)

        controller.update(conditions: externalPower)

        XCTAssertEqual(backend.acquiredLeases, [.indefinite, .indefinite])
    }

    @MainActor
    func testBatteryModeUsesTimedLeaseAndProgressRearmsAtMostTwicePerHour() {
        let backend = FakeSleepAssertionBackend()
        var currentDate = Date(timeIntervalSince1970: 10_000)
        let controller = AgentExecutionPowerController(backend: backend, now: { currentDate })
        controller.update(conditions: batteryPower)
        controller.update(mode: .powerAdapterAndBattery)
        controller.handle(.began("one"))

        for _ in 0..<1_000 {
            controller.handle(.progressed("one"))
        }
        XCTAssertEqual(backend.acquiredLeases, [.timed(AgentExecutionPowerController.batteryInactivityLease)])
        XCTAssertTrue(backend.rearmedLeases.isEmpty)

        currentDate.addTimeInterval(AgentExecutionPowerController.minimumBatteryRearmInterval)
        controller.handle(.progressed("one"))

        XCTAssertEqual(backend.rearmedLeases, [.timed(AgentExecutionPowerController.batteryInactivityLease)])
    }

    @MainActor
    func testLowPowerAndLowBatteryConditionsReleaseImmediately() {
        let backend = FakeSleepAssertionBackend()
        let controller = AgentExecutionPowerController(backend: backend)
        controller.update(conditions: externalPower)
        controller.update(mode: .powerAdapterAndBattery)
        controller.handle(.began("one"))

        controller.update(conditions: SystemPowerConditions(
            source: .external,
            isLowPowerModeEnabled: true,
            hasLowBatteryWarning: false
        ))
        XCTAssertEqual(backend.releaseCount, 1)

        controller.update(conditions: batteryPower)
        XCTAssertEqual(backend.acquiredLeases.count, 2)

        controller.update(conditions: SystemPowerConditions(
            source: .battery,
            isLowPowerModeEnabled: false,
            hasLowBatteryWarning: true
        ))
        XCTAssertEqual(backend.releaseCount, 2)
    }

    @MainActor
    func testOffModeAndStopNeverLeaveAnAssertionBehind() {
        let backend = FakeSleepAssertionBackend()
        let controller = AgentExecutionPowerController(backend: backend)
        controller.update(conditions: externalPower)

        controller.handle(.began("one"))
        XCTAssertTrue(backend.acquiredLeases.isEmpty)

        controller.update(mode: .powerAdapter)
        XCTAssertEqual(backend.acquiredLeases, [.indefinite])

        controller.stop()
        XCTAssertEqual(backend.releaseCount, 1)
        XCTAssertFalse(backend.hasAssertion)
    }

    @MainActor
    func testFailedAcquisitionRetriesOnLaterProgress() {
        let backend = FakeSleepAssertionBackend()
        backend.acquisitionResults = [false, true]
        let controller = AgentExecutionPowerController(backend: backend)
        controller.update(conditions: externalPower)
        controller.update(mode: .powerAdapter)

        controller.handle(.began("one"))
        controller.handle(.progressed("one"))

        XCTAssertEqual(backend.acquiredLeases, [.indefinite, .indefinite])
        XCTAssertTrue(backend.hasAssertion)
    }

    private var externalPower: SystemPowerConditions {
        SystemPowerConditions(
            source: .external,
            isLowPowerModeEnabled: false,
            hasLowBatteryWarning: false
        )
    }

    private var batteryPower: SystemPowerConditions {
        SystemPowerConditions(
            source: .battery,
            isLowPowerModeEnabled: false,
            hasLowBatteryWarning: false
        )
    }
}

private final class FakeSleepAssertionBackend: SleepAssertionBackend {
    var hasAssertion = false
    var acquiredLeases: [SleepAssertionLease] = []
    var rearmedLeases: [SleepAssertionLease] = []
    var releaseCount = 0
    var acquisitionResults: [Bool] = []

    func acquire(lease: SleepAssertionLease) -> Bool {
        acquiredLeases.append(lease)
        let result = acquisitionResults.isEmpty ? true : acquisitionResults.removeFirst()
        hasAssertion = result
        return result
    }

    func rearm(lease: SleepAssertionLease) -> Bool {
        rearmedLeases.append(lease)
        return hasAssertion
    }

    func release() {
        guard hasAssertion else { return }
        releaseCount += 1
        hasAssertion = false
    }
}
