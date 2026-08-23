import XCTest
@testable import Aegis

final class SessionCardPresentationTests: XCTestCase {
    func testCompactTitleUsesSessionNameInsteadOfCurrentTask() {
        var session = makeSession(status: .thinking)
        session.lastUserMessage = "Make the session cards compact"

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "project"
        )
    }

    func testThinkingPreviewUsesSessionTitle() {
        var session = makeSession(status: .thinking)
        session.sessionTitle = "Compact session cards"

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "Compact session cards"
        )
    }

    func testToolPreviewUsesSessionName() {
        var session = makeSession(status: .toolUse)
        session.currentTool = "Swift compiler"

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "project"
        )
    }

    func testPermissionPreviewNamesToolRequiringApproval() {
        var session = makeSession(status: .waitingPermission)
        session.pendingPermission = PendingPermission(
            toolName: "Terminal",
            description: nil,
            filePath: nil,
            content: nil,
            oldString: nil,
            newString: nil,
            respond: { _ in }
        )

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "Needs approval to use Terminal"
        )
    }

    func testIdlePreviewUsesLatestAssistantMessage() {
        var session = makeSession(status: .idle)
        session.lastAssistantMessage = "Done.\n\nThe cards now expand on hover."

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "Done. The cards now expand on hover."
        )
    }

    func testPreviewLengthIsCapped() {
        var session = makeSession(status: .idle)
        session.lastAssistantMessage = "A deliberately long session message"

        let preview = SessionCardPresentation.preview(for: session, maximumLength: 12)

        XCTAssertEqual(preview.count, 12)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testCollapsedDetailPresentationKeepsContentMountedAtZeroHeight() {
        let presentation = SessionCardDetailPresentation.resolve(
            measuredHeight: 96,
            isExpanded: false
        )

        XCTAssertTrue(presentation.keepsContentMounted)
        XCTAssertEqual(presentation.height, 0)
        XCTAssertEqual(presentation.opacity, 0)
    }

    func testRuntimeUsesActiveTurnStartAndWholeSecondFormatting() {
        var session = makeSession(status: .thinking)
        session.activeStartedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            SessionCardPresentation.runtimeText(
                for: session,
                at: Date(timeIntervalSince1970: 1_125)
            ),
            "2m 5s"
        )
    }

    private func makeSession(status: SessionStatus) -> Session {
        Session(
            id: "session",
            cwd: "/tmp/project",
            startedAt: Date(),
            status: status,
            terminalInfo: nil,
            source: "codex"
        )
    }
}
