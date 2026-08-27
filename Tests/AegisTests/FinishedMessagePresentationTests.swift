import XCTest
@testable import Aegis

final class FinishedMessagePresentationTests: XCTestCase {
    func testPreviewUsesAssistantReplyAndFlattensWhitespace() {
        var session = makeSession()
        session.lastAssistantMessage = "Done.\n\nThe build now passes."

        XCTAssertEqual(
            FinishedMessagePresentation.preview(for: session),
            "Done. The build now passes."
        )
    }

    func testPreviewFallsBackToSessionNameWhenReplyIsEmpty() {
        var session = makeSession()
        session.sessionTitle = "Hermes task"
        session.lastAssistantMessage = "  \n "

        XCTAssertEqual(
            FinishedMessagePresentation.preview(for: session),
            "Hermes task finished"
        )
    }

    func testPreviewTruncatesLongReplies() {
        var session = makeSession()
        session.lastAssistantMessage = "A deliberately long completion message"

        let preview = FinishedMessagePresentation.preview(for: session, maximumLength: 12)

        XCTAssertEqual(preview.count, 12)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testReplyViewportFitsShortContentAndCapsLongContent() {
        XCTAssertEqual(FinishedReplyWindowLayout.replyViewportHeight(contentHeight: 72), 72)
        XCTAssertEqual(
            FinishedReplyWindowLayout.replyViewportHeight(contentHeight: 900),
            FinishedReplyWindowLayout.maximumReplyHeight
        )
    }

    func testFinishedWindowFitsMeasuredContentWithinBounds() {
        XCTAssertEqual(FinishedReplyWindowLayout.fittedHeight(240), 240)
        XCTAssertEqual(
            FinishedReplyWindowLayout.fittedHeight(900),
            FinishedReplyWindowLayout.maximumWindowHeight
        )
    }

    @MainActor
    func testFinishedPopupRetainsSnapshotAfterLiveSessionDisappears() {
        let viewModel = NotchViewModel()
        var session = makeSession()
        session.lastAssistantMessage = "The retained reply"

        viewModel.showFinished(session: session)
        session.lastAssistantMessage = "A later mutation"

        XCTAssertEqual(viewModel.state, .finished(sessionId: session.id))
        XCTAssertEqual(viewModel.finishedSessionSnapshot?.lastAssistantMessage, "The retained reply")
        XCTAssertEqual(viewModel.currentSize.height, NotchViewModel.finishedSize.height)

        viewModel.collapse()

        XCTAssertEqual(viewModel.presentedState, .finished(sessionId: session.id))
        XCTAssertEqual(viewModel.finishedSessionSnapshot?.lastAssistantMessage, "The retained reply")

        viewModel.completeCollapsePresentation()

        XCTAssertNil(viewModel.finishedSessionSnapshot)
    }

    @MainActor
    func testFinishedPopupAdoptsMeasuredContentHeight() {
        let viewModel = NotchViewModel()
        viewModel.showFinished(session: makeSession())

        viewModel.updateFinishedContentHeight(248)

        XCTAssertEqual(viewModel.currentSize.height, 248)
    }

    private func makeSession() -> Session {
        Session(
            id: "finished-session",
            cwd: "/tmp/hermes-project",
            startedAt: Date(),
            status: .idle,
            terminalInfo: nil,
            source: "hermes"
        )
    }
}
