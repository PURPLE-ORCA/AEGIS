import XCTest
@testable import CaesuraIsland

final class SessionPresenceTests: XCTestCase {
    @MainActor
    func testFinishedTurnStopsCountingAsActiveImmediately() {
        let store = SessionStore()
        let sessionID = "session-lifecycle"

        store.handleMessage(
            BridgeMessage(
                sessionId: sessionID,
                hookEvent: "UserPromptSubmit",
                cwd: "/tmp/project",
                userMessage: "Do the work",
                source: "codex"
            ),
            respond: nil
        )
        XCTAssertNotNil(store.activeSessions[sessionID])

        store.handleMessage(
            BridgeMessage(
                sessionId: sessionID,
                hookEvent: "Stop",
                cwd: "/tmp/project",
                assistantMessage: "Done",
                source: "codex"
            ),
            respond: nil
        )

        XCTAssertEqual(store.sessions[sessionID]?.status, .idle)
        XCTAssertNil(store.activeSessions[sessionID])
        XCTAssertEqual(store.sessions[sessionID]?.lastAssistantMessage, "Done")
    }

    @MainActor
    func testOnlyRunningOrActionableStatusesCountAsActive() {
        let store = SessionStore()
        let activeStatuses: [SessionStatus] = [.thinking, .toolUse, .waitingPermission, .error]
        let inactiveStatuses: [SessionStatus] = [.idle, .completed]

        for (index, status) in (activeStatuses + inactiveStatuses).enumerated() {
            store.sessions["session-\(index)"] = Session(
                id: "session-\(index)",
                cwd: "/tmp/project",
                startedAt: Date(),
                status: status,
                terminalInfo: nil,
                source: "codex"
            )
        }

        XCTAssertEqual(Set(store.activeSessions.values.map(\.status)), Set(activeStatuses))
    }

    func testEmptyNotchPresencePolicy() {
        XCTAssertFalse(NotchPresencePolicy.shouldShow(state: .collapsed, activeSessionCount: 0))
        XCTAssertFalse(NotchPresencePolicy.shouldShow(state: .expanded, activeSessionCount: 0))
        XCTAssertTrue(NotchPresencePolicy.shouldCollapse(state: .expanded, activeSessionCount: 0))
    }

    func testNotchShowsLiveWorkAndTransientResults() {
        XCTAssertTrue(NotchPresencePolicy.shouldShow(state: .collapsed, activeSessionCount: 1))
        XCTAssertTrue(NotchPresencePolicy.shouldShow(state: .finished(sessionId: "done"), activeSessionCount: 0))
        XCTAssertTrue(NotchPresencePolicy.shouldShow(state: .permission(sessionId: "approval"), activeSessionCount: 0))
    }
}
