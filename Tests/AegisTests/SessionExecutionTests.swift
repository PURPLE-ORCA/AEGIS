import Combine
import XCTest
@testable import Aegis
import AegisBridgeSupport

final class SessionExecutionTests: XCTestCase {
    @MainActor
    func testTurnAndToolProgressProduceBalancedExecutionEvents() {
        let store = SessionStore()
        var events: [SessionExecutionEvent] = []
        let cancellable = store.onExecutionEvent.sink { events.append($0) }

        store.handleMessage(message(event: "UserPromptSubmit"), respond: nil)
        store.handleMessage(message(event: "PreToolUse", toolName: "Bash"), respond: nil)
        store.handleMessage(message(event: "PostToolUse", toolName: "Bash"), respond: nil)
        store.handleMessage(message(event: "Stop"), respond: nil)

        XCTAssertEqual(events, [
            .began(Self.sessionId),
            .progressed(Self.sessionId),
            .progressed(Self.sessionId),
            .ended(Self.sessionId),
        ])
        XCTAssertFalse(store.sessions[Self.sessionId]?.executionState.isConfirmedExecuting ?? true)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testPermissionResponseWaitsForProviderProgress() {
        let store = SessionStore()
        var events: [SessionExecutionEvent] = []
        let cancellable = store.onExecutionEvent.sink { events.append($0) }

        store.handleMessage(message(event: "UserPromptSubmit"), respond: nil)
        store.handleMessage(message(event: "PermissionRequest", toolName: "Bash"), respond: { _ in })
        store.respondToPermission(sessionId: Self.sessionId, action: .allowOnce)

        XCTAssertEqual(events, [.began(Self.sessionId), .ended(Self.sessionId)])
        XCTAssertFalse(store.sessions[Self.sessionId]?.executionState.isConfirmedExecuting ?? true)

        store.handleMessage(message(event: "PreToolUse", toolName: "Bash"), respond: nil)

        XCTAssertEqual(events, [.began(Self.sessionId), .ended(Self.sessionId), .began(Self.sessionId)])
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testMirroredQuestionAndDeferralDoNotCountAsExecution() {
        let store = SessionStore()
        var events: [SessionExecutionEvent] = []
        let cancellable = store.onExecutionEvent.sink { events.append($0) }
        let input = #"{"questions":[{"question":"Continue?","options":[{"label":"Yes"}]}]}"#

        store.handleMessage(
            message(event: "PreToolUse", toolName: "request_user_input", toolInput: input),
            respond: nil
        )
        store.deferQuestionToTerminal(sessionId: Self.sessionId)

        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(store.sessions[Self.sessionId]?.executionState.isConfirmedExecuting ?? true)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testSubagentActivityIsTrackedWhenParentIsIdle() {
        let store = SessionStore()
        var events: [SessionExecutionEvent] = []
        let cancellable = store.onExecutionEvent.sink { events.append($0) }

        store.handleMessage(message(event: "SubagentStart"), respond: nil)
        store.handleMessage(message(event: "SubagentStop"), respond: nil)

        XCTAssertEqual(events, [.began(Self.sessionId), .ended(Self.sessionId)])
        XCTAssertEqual(store.sessions[Self.sessionId]?.executionState.activeSubagentCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testLifecycleSweepEndsConfirmedExecution() {
        let store = SessionStore()
        var events: [SessionExecutionEvent] = []
        let cancellable = store.onExecutionEvent.sink { events.append($0) }
        let now = Date()

        store.handleMessage(
            BridgeMessage(
                sessionId: Self.sessionId,
                hookEvent: "UserPromptSubmit",
                cwd: "/tmp/project",
                userMessage: "Keep working",
                source: "hermes"
            ),
            respond: nil
        )
        store.sessions[Self.sessionId]?.lastActivityAt = now.addingTimeInterval(-16 * 60)

        store.sweepClosedAgents(at: now)

        XCTAssertEqual(events, [.began(Self.sessionId), .ended(Self.sessionId)])
        XCTAssertEqual(store.sessions[Self.sessionId]?.status, .completed)
        withExtendedLifetime(cancellable) {}
    }

    private static let sessionId = "execution-session"

    private func message(
        event: String,
        toolName: String? = nil,
        toolInput: String? = nil
    ) -> BridgeMessage {
        BridgeMessage(
            sessionId: Self.sessionId,
            hookEvent: event,
            cwd: "/tmp/project",
            toolName: toolName,
            toolInput: toolInput,
            userMessage: event == "UserPromptSubmit" ? "Keep working" : nil,
            source: "codex"
        )
    }
}
