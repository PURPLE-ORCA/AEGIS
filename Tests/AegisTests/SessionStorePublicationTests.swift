import Combine
import XCTest
@testable import Aegis
import AegisBridgeSupport

final class SessionStorePublicationTests: XCTestCase {
    @MainActor
    func testCanonicalMessagesPublishOnceAndEventsObserveCommittedState() {
        let store = SessionStore()
        var publications = 0
        var observedStatuses: [SessionStatus] = []
        let publication = store.$sessions.dropFirst().sink { _ in publications += 1 }
        let events = store.onEvent.sink { event in
            switch event {
            case .sessionStarted(let id), .statusChanged(let id, _):
                if let status = store.sessions[id]?.status { observedStatuses.append(status) }
            default:
                break
            }
        }

        store.handleMessage(
            message(event: "UserPromptSubmit", userMessage: "Optimize it"),
            respond: nil
        )

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(observedStatuses, [.thinking, .thinking])
        withExtendedLifetime([publication, events]) {}
    }

    @MainActor
    func testEveryCanonicalEventPathPublishesOnce() {
        let cases: [BridgeMessage] = [
            message(event: "SessionStart"),
            message(event: "UserPromptSubmit", userMessage: "Start"),
            message(event: "PreToolUse", toolName: "Read"),
            message(event: "PostToolUse", toolName: "Read"),
            message(event: "PermissionRequest", toolName: "Bash"),
            message(event: "Notification", assistantMessage: "Notice"),
            message(event: "SubagentStart"),
            message(event: "SubagentStop"),
            message(event: "PreCompact"),
            message(event: "Stop", assistantMessage: "Done"),
            message(event: "SessionEnd"),
        ]

        for (index, bridgeMessage) in cases.enumerated() {
            let store = SessionStore()
            var publications = 0
            let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }

            store.handleMessage(bridgeMessage, respond: nil)

            XCTAssertEqual(publications, 1, "case \(index): \(bridgeMessage.hookEvent)")
            withExtendedLifetime(cancellable) {}
        }
    }

    @MainActor
    func testMirroredQuestionPublishesOnce() {
        let store = SessionStore()
        var publications = 0
        let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }
        let input = #"{"questions":[{"question":"Continue?","header":"Choice","options":[{"label":"Yes"}]}]}"#

        store.handleMessage(
            message(event: "PreToolUse", toolName: "request_user_input", toolInput: input),
            respond: nil
        )

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.sessions["publication-session"]?.status, .waitingPermission)
        XCTAssertNotNil(store.sessions["publication-session"]?.pendingQuestion)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testProgressEventResolvesPendingPermissionWithinOnePublication() {
        let store = SessionStore()
        var response: PermissionAction?
        store.handleMessage(
            message(event: "PermissionRequest", toolName: "Bash"),
            respond: { _ in response = .allowOnce }
        )
        var publications = 0
        var dismissed = false
        let publication = store.$sessions.dropFirst().sink { _ in publications += 1 }
        let events = store.onEvent.sink { event in
            if case .pendingDismissedExternally = event { dismissed = true }
        }

        store.handleMessage(message(event: "PreToolUse", toolName: "Bash"), respond: nil)

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(response, .allowOnce)
        XCTAssertTrue(dismissed)
        XCTAssertNil(store.sessions["publication-session"]?.pendingPermission)
        withExtendedLifetime([publication, events]) {}
    }

    @MainActor
    func testIgnoredMessagesAndDuplicateSuggestionsPublishNothing() {
        let store = SessionStore()
        store.handleMessage(message(event: "UserPromptSubmit", userMessage: "Start"), respond: nil)
        store.handleMessage(message(event: "Stop", assistantMessage: "Done"), respond: nil)
        var publications = 0
        let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }

        store.handleMessage(message(event: "provider_raw_event"), respond: nil)
        store.handleMessage(
            message(event: "Stop", assistantMessage: #"{"suggestions":[{"title":"Next"}]}"#),
            respond: nil
        )

        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.sessions["publication-session"]?.lastAssistantMessage, "Done")
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testThousandToolEventsProduceThousandPublications() {
        let store = SessionStore()
        var publications = 0
        var eventCount = 0
        let publication = store.$sessions.dropFirst().sink { _ in publications += 1 }
        let events = store.onEvent.sink { _ in eventCount += 1 }

        for index in 0..<1_000 {
            let event = index.isMultiple(of: 2) ? "PreToolUse" : "PostToolUse"
            store.handleMessage(message(event: event, toolName: "Read"), respond: nil)
        }

        XCTAssertEqual(publications, 1_000)
        XCTAssertEqual(eventCount, 1_001)
        withExtendedLifetime([publication, events]) {}
    }

    @MainActor
    func testActivityUpdatesAreEphemeralAndIgnoreLateOrDuplicateContent() {
        let store = SessionStore()
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "Too early"), respond: nil)
        XCTAssertNil(store.sessions[Self.sessionId])

        store.handleMessage(message(event: "UserPromptSubmit", userMessage: "Start"), respond: nil)
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "  Checking\nfiles  "), respond: nil)
        XCTAssertEqual(store.sessions[Self.sessionId]?.activitySummary, "Checking files")

        var publications = 0
        let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "Checking files"), respond: nil)
        XCTAssertEqual(publications, 0)

        store.handleMessage(message(event: "Stop", assistantMessage: "Done"), respond: nil)
        XCTAssertNil(store.sessions[Self.sessionId]?.activitySummary)
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "Too late"), respond: nil)
        XCTAssertNil(store.sessions[Self.sessionId]?.activitySummary)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testToolActivityRemainsVisibleBetweenToolCalls() {
        let store = SessionStore()
        store.handleMessage(message(event: "UserPromptSubmit", userMessage: "Start"), respond: nil)
        store.handleMessage(message(event: "PreToolUse", toolName: "functions.exec"), respond: nil)

        XCTAssertEqual(store.sessions[Self.sessionId]?.status, .toolUse)
        XCTAssertEqual(store.sessions[Self.sessionId]?.activitySummary, "Running command")

        store.handleMessage(message(event: "PostToolUse", toolName: "functions.exec"), respond: nil)

        XCTAssertEqual(store.sessions[Self.sessionId]?.status, .thinking)
        XCTAssertEqual(store.sessions[Self.sessionId]?.activitySummary, "Running command")
    }

    @MainActor
    func testThreeExplicitSameToolFailuresEmitOneSkillIssueEvent() {
        let store = SessionStore()
        var detectedTools: [String] = []
        let events = store.onEvent.sink { event in
            if case .skillIssueDetected(_, let toolName) = event {
                detectedTools.append(toolName)
            }
        }

        for _ in 0..<4 {
            store.handleMessage(
                message(event: "PostToolUse", toolName: "Bash", toolOutcome: .failure),
                respond: nil
            )
        }

        XCTAssertEqual(detectedTools, ["Bash"])
        withExtendedLifetime(events) {}
    }

    private static let sessionId = "publication-session"

    private func message(
        event: String,
        userMessage: String? = nil,
        assistantMessage: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        activitySummary: String? = nil,
        toolOutcome: ToolOutcome? = nil
    ) -> BridgeMessage {
        BridgeMessage(
            sessionId: Self.sessionId,
            hookEvent: event,
            cwd: "/tmp/project",
            toolName: toolName,
            toolInput: toolInput,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            activitySummary: activitySummary,
            toolOutcome: toolOutcome,
            source: "codex"
        )
    }
}
