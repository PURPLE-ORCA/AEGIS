import XCTest
@testable import Aegis

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

    @MainActor
    func testStaleHermesThinkingSessionIsCompleted() {
        let store = SessionStore()
        let sessionID = "stale-hermes"
        let now = Date()
        store.sessions[sessionID] = Session(
            id: sessionID,
            cwd: "/tmp/project",
            startedAt: now.addingTimeInterval(-20 * 60),
            status: .thinking,
            terminalInfo: nil,
            source: "hermes",
            lastActivityAt: now.addingTimeInterval(-16 * 60)
        )

        store.sweepClosedAgents(at: now)

        XCTAssertEqual(store.sessions[sessionID]?.status, .completed)
        XCTAssertNil(store.activeSessions[sessionID])
    }

    @MainActor
    func testStaleAntigravityThinkingSessionIsCompleted() {
        let store = SessionStore()
        let sessionID = "stale-antigravity"
        let now = Date()
        store.sessions[sessionID] = Session(
            id: sessionID,
            cwd: "/tmp/project",
            startedAt: now.addingTimeInterval(-45 * 60),
            status: .thinking,
            terminalInfo: nil,
            source: "antigravity",
            lastActivityAt: now.addingTimeInterval(-16 * 60)
        )

        store.sweepClosedAgents(at: now)

        XCTAssertEqual(store.sessions[sessionID]?.status, .completed)
        XCTAssertNil(store.activeSessions[sessionID])
    }

    @MainActor
    func testFreshHermesThinkingSessionStaysActive() {
        let store = SessionStore()
        let sessionID = "fresh-hermes"
        let now = Date()
        store.sessions[sessionID] = Session(
            id: sessionID,
            cwd: "/tmp/project",
            startedAt: now.addingTimeInterval(-10 * 60),
            status: .thinking,
            terminalInfo: nil,
            source: "hermes",
            lastActivityAt: now.addingTimeInterval(-14 * 60)
        )

        store.sweepClosedAgents(at: now)

        XCTAssertEqual(store.sessions[sessionID]?.status, .thinking)
        XCTAssertNotNil(store.activeSessions[sessionID])
    }

    @MainActor
    func testLongHermesToolUseIsNotExpired() {
        let store = SessionStore()
        let sessionID = "long-hermes-tool"
        let now = Date()
        store.sessions[sessionID] = Session(
            id: sessionID,
            cwd: "/tmp/project",
            startedAt: now.addingTimeInterval(-30 * 60),
            status: .toolUse,
            terminalInfo: nil,
            source: "hermes",
            lastActivityAt: now.addingTimeInterval(-20 * 60)
        )

        store.sweepClosedAgents(at: now)

        XCTAssertEqual(store.sessions[sessionID]?.status, .toolUse)
        XCTAssertNotNil(store.activeSessions[sessionID])
    }

    @MainActor
    func testDurablyTrackedHermesThinkingSessionIsNotExpired() {
        let store = SessionStore()
        let sessionID = "durable-hermes"
        let now = Date()
        store.handleMessage(
            BridgeMessage(
                sessionId: sessionID,
                hookEvent: "UserPromptSubmit",
                cwd: "/tmp/project",
                userMessage: "Keep working",
                source: "hermes"
            ),
            respond: nil,
            origin: .durableProviderState
        )
        store.sessions[sessionID]?.lastActivityAt = now.addingTimeInterval(-20 * 60)

        store.sweepClosedAgents(at: now)

        XCTAssertEqual(store.sessions[sessionID]?.status, .thinking)
        XCTAssertNotNil(store.activeSessions[sessionID])
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
