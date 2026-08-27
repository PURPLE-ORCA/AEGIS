import XCTest
@testable import Aegis

final class SessionListProjectionTests: XCTestCase {
    func testAttentionItemsSortBeforeActiveAndIdleSessions() {
        let now = Date()
        let sessions = [
            makeSession(id: "idle", status: .idle, activity: now.addingTimeInterval(30)),
            makeSession(id: "active", status: .thinking, activity: now.addingTimeInterval(20)),
            makeSession(id: "error", status: .error, activity: now.addingTimeInterval(10)),
            makeSession(id: "permission", status: .waitingPermission, activity: now),
        ]

        let projection = SessionListProjection(sessions: sessions, selectedProvider: nil)

        XCTAssertEqual(
            projection.sessions(for: .codex).map(\.id),
            ["permission", "error", "active", "idle"]
        )
    }

    func testStaleProviderSelectionFallsBackToPresentProviders() {
        let session = makeSession(id: "codex", status: .thinking, activity: Date())

        let projection = SessionListProjection(sessions: [session], selectedProvider: .hermes)

        XCTAssertEqual(projection.visibleProviders.map(\.id), [AIProvider.codex.id])
        XCTAssertEqual(projection.rateLimitProvider, .codex)
    }

    func testExpandedSessionListFitsShortContent() {
        XCTAssertEqual(
            SessionListWindowLayout.viewportHeight(chromeHeight: 44, contentHeight: 66),
            66
        )
        XCTAssertEqual(
            SessionListWindowLayout.fittedHeight(chromeHeight: 44, contentHeight: 66),
            110
        )
    }

    func testExpandedSessionListCapsTallContent() {
        XCTAssertEqual(
            SessionListWindowLayout.viewportHeight(chromeHeight: 76, contentHeight: 500),
            SessionListWindowLayout.maximumHeight - 76
        )
        XCTAssertEqual(
            SessionListWindowLayout.fittedHeight(chromeHeight: 76, contentHeight: 500),
            SessionListWindowLayout.maximumHeight
        )
    }

    func testProviderFilterMetadataIsIconButtonAccessible() {
        let all = SessionProviderFilterMetadata(provider: nil, isSelected: true)
        XCTAssertEqual(all.accessibilityLabel, "Show all sessions")
        XCTAssertEqual(all.accessibilityValue, "Selected")

        let codex = SessionProviderFilterMetadata(provider: .codex, isSelected: false)
        XCTAssertEqual(codex.accessibilityLabel, "Show Codex sessions")
        XCTAssertEqual(codex.accessibilityValue, "Not selected")
    }

    @MainActor
    func testExpandedWindowTracksMeasuredContentHeight() {
        let viewModel = NotchViewModel()
        viewModel.expand()

        XCTAssertEqual(viewModel.currentSize.height, NotchViewModel.collapsedSize.height)

        viewModel.updateExpandedContentHeight(146)
        XCTAssertEqual(viewModel.currentSize.height, 146)

        viewModel.updateExpandedContentHeight(900)
        XCTAssertEqual(viewModel.currentSize.height, SessionListWindowLayout.maximumHeight)
    }

    private func makeSession(
        id: String,
        status: SessionStatus,
        activity: Date
    ) -> Session {
        Session(
            id: id,
            cwd: "/tmp/\(id)",
            startedAt: activity,
            status: status,
            terminalInfo: nil,
            source: "codex",
            lastActivityAt: activity
        )
    }
}
