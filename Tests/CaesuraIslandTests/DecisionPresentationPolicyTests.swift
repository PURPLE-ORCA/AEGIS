import XCTest
@testable import CaesuraIsland

final class DecisionPresentationPolicyTests: XCTestCase {
    func testDisabledAutoExpandKeepsCollapsedPermissionQueued() {
        XCTAssertFalse(
            DecisionPresentationPolicy.shouldPresentPermission(
                state: .collapsed,
                autoExpandEnabled: false
            )
        )
    }

    func testEnabledAutoExpandPresentsCollapsedPermission() {
        XCTAssertTrue(
            DecisionPresentationPolicy.shouldPresentPermission(
                state: .collapsed,
                autoExpandEnabled: true
            )
        )
    }

    func testPermissionCanReplaceNonDecisionExpandedContent() {
        XCTAssertTrue(
            DecisionPresentationPolicy.shouldPresentPermission(
                state: .expanded,
                autoExpandEnabled: false
            )
        )
        XCTAssertFalse(
            DecisionPresentationPolicy.shouldPresentPermission(
                state: .question(sessionId: "question"),
                autoExpandEnabled: true
            )
        )
    }
}
