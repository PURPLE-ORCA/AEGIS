import XCTest
@testable import CaesuraIsland

@MainActor
final class AutoCollapsePolicyTests: XCTestCase {
    func testHoveredFinishedCardRearmsBeforeDeadline() {
        let now = Date()

        XCTAssertEqual(
            NotchViewModel.autoCollapseDecision(
                state: .finished(sessionId: "session"),
                isHovered: true,
                finishedDeadline: now.addingTimeInterval(10),
                now: now
            ),
            .rearm(0.6)
        )
    }

    func testHoveredFinishedCardCollapsesAtDeadline() {
        let now = Date()

        XCTAssertEqual(
            NotchViewModel.autoCollapseDecision(
                state: .finished(sessionId: "session"),
                isHovered: true,
                finishedDeadline: now,
                now: now
            ),
            .collapse
        )
    }

    func testDecisionViewsNeverAutoCollapse() {
        XCTAssertEqual(
            NotchViewModel.autoCollapseDecision(
                state: .permission(sessionId: "session"),
                isHovered: false,
                finishedDeadline: nil,
                now: Date()
            ),
            .pause
        )
    }

    func testSuppressedQuestionStaysDismissedUntilShownAgain() {
        let viewModel = NotchViewModel()
        viewModel.showQuestion(sessionId: "session")
        viewModel.suppressQuestion(sessionId: "session")

        XCTAssertEqual(viewModel.state, .collapsed)
        XCTAssertTrue(viewModel.suppressedQuestionSessionIDs.contains("session"))

        viewModel.showQuestion(sessionId: "session")

        XCTAssertFalse(viewModel.suppressedQuestionSessionIDs.contains("session"))
    }
}
