import XCTest
@testable import Aegis

final class SessionCardPresentationTests: XCTestCase {
    func testCompactTitlePrefersCurrentRunMessage() {
        var session = makeSession(status: .thinking)
        session.lastUserMessage = "  Fix the current run  "
        session.sessionTitle = "  Provider task title  "
        session.firstPrompt = "Fallback prompt"

        XCTAssertEqual(
            SessionCardPresentation.compactTitle(for: session),
            "Fix the current run"
        )
    }

    func testCompactTitleFallsBackToProviderSessionTitle() {
        var session = makeSession(status: .thinking)
        session.sessionTitle = "  Provider task title  "
        session.firstPrompt = "  Make the session cards compact  "

        XCTAssertEqual(
            SessionCardPresentation.compactTitle(for: session),
            "Provider task title"
        )
    }

    func testCompactTitleFallsBackToFirstPrompt() {
        var session = makeSession(status: .thinking)
        session.lastUserMessage = " \n "
        session.sessionTitle = " \n "
        session.firstPrompt = "  Make the session cards compact  "

        XCTAssertEqual(
            SessionCardPresentation.compactTitle(for: session),
            "Make the session cards compact"
        )
    }

    func testCompactTitleNeverFallsBackToProjectFolder() {
        let session = makeSession(status: .thinking)

        XCTAssertEqual(
            SessionCardPresentation.compactTitle(for: session),
            "Untitled session"
        )
    }

    func testExpandedDetailPrefersCurrentTool() {
        var session = makeSession(status: .toolUse)
        session.currentTool = "Swift compiler"
        session.activitySummary = "Compiling project"
        session.lastAssistantMessage = "An older reply"

        XCTAssertEqual(
            SessionCardPresentation.detail(for: session),
            "Compiling project"
        )
    }

    func testExpandedDetailKeepsLastToolActivityBetweenCalls() {
        var session = makeSession(status: .thinking)
        session.activitySummary = "Reading resource"
        session.lastAssistantMessage = "An older reply"

        XCTAssertEqual(SessionCardPresentation.detail(for: session), "Reading resource")
    }

    func testToolActivityUsesSafeHumanLabels() {
        XCTAssertEqual(SessionActivitySummary.toolLabel("functions.exec"), "Running command")
        XCTAssertEqual(SessionActivitySummary.toolLabel("apply_patch"), "Editing files")
        XCTAssertEqual(SessionActivitySummary.toolLabel("read_mcp_resource"), "Reading resource")
        XCTAssertEqual(SessionActivitySummary.toolLabel("custom_tool"), "Using custom tool")
    }

    func testExpandedDetailUsesLatestAgentMessageWithoutCurrentTool() {
        var session = makeSession(status: .thinking)
        session.lastAssistantMessage = "Checking the panel sizing now."

        XCTAssertEqual(
            SessionCardPresentation.detail(for: session),
            "Checking the panel sizing now."
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
            SessionCardPresentation.detail(for: session),
            "Needs approval to use Terminal"
        )
    }

    func testIdlePreviewUsesLatestAssistantMessage() {
        var session = makeSession(status: .idle)
        session.lastAssistantMessage = "Done.\n\nThe cards now expand on hover."

        XCTAssertEqual(
            SessionCardPresentation.detail(for: session),
            "Done. The cards now expand on hover."
        )
    }

    func testPreviewLengthIsCapped() {
        var session = makeSession(status: .idle)
        session.lastAssistantMessage = "A deliberately long session message"

        let preview = SessionCardPresentation.detail(for: session, maximumLength: 12)

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

    func testThinkingDetailHasNoTimerFallback() {
        let session = makeSession(status: .thinking)

        XCTAssertEqual(SessionCardPresentation.detail(for: session), "Thinking…")
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
