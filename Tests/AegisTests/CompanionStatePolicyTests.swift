import XCTest
@testable import Aegis

final class CompanionStatePolicyTests: XCTestCase {
    func testIdleWhenNoSessionsExist() {
        XCTAssertEqual(
            CompanionStatePolicy.resolve(statuses: [], hasSessions: false, transient: nil),
            .idle
        )
    }

    func testExistingQuietSessionIsObserved() {
        XCTAssertEqual(
            CompanionStatePolicy.resolve(statuses: [.idle], hasSessions: true, transient: nil),
            .observing
        )
    }

    func testWorkingOverridesTransientSuccess() {
        XCTAssertEqual(
            CompanionStatePolicy.resolve(
                statuses: [.thinking, .idle],
                hasSessions: true,
                transient: .success
            ),
            .working
        )
    }

    func testFailureOverridesWorking() {
        XCTAssertEqual(
            CompanionStatePolicy.resolve(
                statuses: [.toolUse, .error],
                hasSessions: true,
                transient: nil
            ),
            .failure
        )
    }

    func testAttentionIsHighestPriority() {
        XCTAssertEqual(
            CompanionStatePolicy.resolve(
                statuses: [.error, .waitingPermission],
                hasSessions: true,
                transient: .success
            ),
            .attention
        )
    }

    func testSuccessAppearsOnlyWhenNoHigherPriorityStateExists() {
        XCTAssertEqual(
            CompanionStatePolicy.resolve(statuses: [.idle], hasSessions: true, transient: .success),
            .success
        )
    }
}
