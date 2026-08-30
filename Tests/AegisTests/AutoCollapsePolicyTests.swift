import XCTest
@testable import Aegis

@MainActor
final class AutoCollapsePolicyTests: XCTestCase {
    func testPanelSnapsCollapseAndKeepsSmoothExpansion() {
        XCTAssertEqual(NotchMotion.panelResizeDuration, 0.20)
        XCTAssertEqual(
            NotchPanelTransitionPolicy.duration(for: .collapsed),
            0
        )
        XCTAssertEqual(
            NotchPanelTransitionPolicy.duration(for: .expanded),
            NotchMotion.panelResizeDuration
        )
        XCTAssertEqual(
            NotchPanelTransitionPolicy.duration(for: .finished(sessionId: "session")),
            NotchMotion.panelResizeDuration
        )
        XCTAssertEqual(NotchMotion.panelResizeProgress(0), 0)
        XCTAssertEqual(NotchMotion.panelResizeProgress(0.5), 0.5)
        XCTAssertEqual(NotchMotion.panelResizeProgress(1), 1)
    }

    func testInteractionTimingsMatchFinishedAndMouseExitPolicy() {
        XCTAssertEqual(NotchViewModel.finishedCardVisibilityDuration, 10)
        XCTAssertEqual(NotchViewModel.finishedHoverCeiling, 30)
        XCTAssertEqual(
            NotchViewModel.autoCollapseDelayAfterMouseExit(for: .expanded),
            0
        )
        XCTAssertNil(
            NotchViewModel.autoCollapseDelayAfterMouseExit(
                for: .finished(sessionId: "session")
            )
        )
        XCTAssertNil(
            NotchViewModel.autoCollapseDelayAfterMouseExit(
                for: .permission(sessionId: "session")
            )
        )
        XCTAssertNil(
            NotchViewModel.autoCollapseDelayAfterMouseExit(
                for: .question(sessionId: "session")
            )
        )
    }

    func testCollapseKeepsOutgoingContentMountedUntilResizeCompletes() {
        let viewModel = NotchViewModel()
        viewModel.expand()

        XCTAssertFalse(viewModel.hidesOutgoingContentDuringCollapse)

        viewModel.collapse()

        XCTAssertEqual(viewModel.state, .collapsed)
        XCTAssertEqual(viewModel.presentedState, .expanded)
        XCTAssertTrue(viewModel.hidesOutgoingContentDuringCollapse)

        viewModel.completeCollapsePresentation()

        XCTAssertEqual(viewModel.presentedState, .collapsed)
        XCTAssertFalse(viewModel.hidesOutgoingContentDuringCollapse)
    }

    func testNewPresentationInterruptsPendingCollapse() {
        let viewModel = NotchViewModel()
        viewModel.expand()
        viewModel.collapse()

        viewModel.showPermission(sessionId: "permission")

        XCTAssertFalse(viewModel.hidesOutgoingContentDuringCollapse)

        viewModel.completeCollapsePresentation()

        XCTAssertEqual(viewModel.state, .permission(sessionId: "permission"))
        XCTAssertEqual(viewModel.presentedState, .permission(sessionId: "permission"))
    }

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

    func testUnhoveredFinishedCardCollapsesWhenVisibilityLeaseEnds() {
        let now = Date()

        XCTAssertEqual(
            NotchViewModel.autoCollapseDecision(
                state: .finished(sessionId: "session"),
                isHovered: false,
                finishedDeadline: now.addingTimeInterval(20),
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
