import XCTest
@testable import Aegis

final class EphemeralSessionTests: XCTestCase {
    @MainActor
    func testEphemeralActivityNeverCreatesCardsEvenWithSubagentsEnabled() {
        let store = SessionStore()
        store.setShowsSubagents(true)
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            store.handleMessage(BridgeMessage(sessionId: "internal", hookEvent: event, source: "codex", isEphemeral: true), respond: nil)
            XCTAssertTrue(store.sessions.isEmpty)
        }
        store.handleMessage(BridgeMessage(sessionId: "user", hookEvent: "UserPromptSubmit", source: "codex"), respond: nil)
        XCTAssertNotNil(store.activeSessions["user"])
    }

    @MainActor
    func testEphemeralPermissionRemainsActionableThenIsRemovedOnProgress() {
        let store = SessionStore()
        var responded = false
        store.handleMessage(BridgeMessage(sessionId: "internal", hookEvent: "PermissionRequest", toolName: "Bash", source: "codex", isEphemeral: true), respond: { _ in responded = true })
        XCTAssertNotNil(store.sessions["internal"]?.pendingPermission)
        store.handleMessage(BridgeMessage(sessionId: "internal", hookEvent: "PostToolUse", source: "codex"), respond: nil)
        XCTAssertTrue(responded)
        XCTAssertNil(store.sessions["internal"])
    }
}
