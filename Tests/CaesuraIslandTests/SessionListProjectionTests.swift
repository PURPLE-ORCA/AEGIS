import XCTest
@testable import CaesuraIsland

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

    func testSessionListWindowFitsSmallContentAndCapsLargeContent() {
        XCTAssertEqual(
            SessionListWindowLayout.fittedHeight(chromeHeight: 44, contentHeight: 80),
            124
        )
        XCTAssertEqual(
            SessionListWindowLayout.fittedHeight(chromeHeight: 76, contentHeight: 500),
            SessionListWindowLayout.maximumHeight
        )
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
