import XCTest
@testable import Aegis

final class SessionCardPresentationTests: XCTestCase {
    func testThinkingPreviewDescribesCurrentTask() {
        var session = makeSession(status: .thinking)
        session.lastUserMessage = "Make the session cards compact"

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "Working on Make the session cards compact"
        )
    }

    func testThinkingPreviewFallsBackToSessionTitle() {
        var session = makeSession(status: .thinking)
        session.sessionTitle = "Compact session cards"

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "Working on Compact session cards"
        )
    }

    func testToolPreviewNamesCurrentTool() {
        var session = makeSession(status: .toolUse)
        session.currentTool = "Swift compiler"

        XCTAssertEqual(
            SessionCardPresentation.preview(for: session),
            "Using Swift compiler"
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
