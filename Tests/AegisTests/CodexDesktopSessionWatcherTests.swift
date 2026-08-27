import Foundation
import XCTest
@testable import Aegis
import AegisBridgeSupport
import SQLite3

final class CodexDesktopSessionWatcherTests: XCTestCase {
    func testPropagatesLatestResolvedTitleOnEachEmittedEvent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-titled.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"titled","cwd":"/tmp/project"}}"#,
        ], to: transcript)
        let resolver = SequenceCodexTitleResolver(["First task name", "Renamed task"])
        let watcher = CodexDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil,
            titleResolver: resolver
        )
        let started = expectation(description: "watcher started")
        let received = expectation(description: "titled events")
        received.expectedFulfillmentCount = 2
        var titles: [String?] = []
        watcher.onMessage = { message in
            titles.append(message.sessionTitle)
            received.fulfill()
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try appendLines([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-1"}}"#,
        ], to: transcript)
        watcher.reconcileNow()

        wait(for: [received], timeout: 3)
        XCTAssertEqual(titles.compactMap { $0 }, ["First task name", "Renamed task"])
        XCTAssertEqual(resolver.callCount, 2)
    }

    func testExistingTranscriptStartsAtEndThenEmitsAppendedEvent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-session-1.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/project"}}"#,
            #"{"type":"turn_context","payload":{"cwd":"/tmp/project","model":"gpt-5.6-sol"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"old prompt"}}"#,
        ], to: transcript)

        let watcher = CodexDesktopSessionWatcher(root: root)
        let started = expectation(description: "watcher started")
        let appended = expectation(description: "appended event")
        var messages: [BridgeMessage] = []
        watcher.onMessage = { message in
            messages.append(message)
            if message.userMessage == "new prompt" { appended.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try appendLine(
            #"{"type":"event_msg","payload":{"type":"user_message","message":"new prompt"}}"#,
            to: transcript
        )

        wait(for: [appended], timeout: 3)
        XCTAssertEqual(messages.map(\.userMessage), ["new prompt"])
        XCTAssertEqual(messages.first?.sessionId, "session-1")
        XCTAssertEqual(messages.first?.model, "gpt-5.6-sol")
    }

    func testNewTranscriptIsDiscoveredWithoutHistoryReplay() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = CodexDesktopSessionWatcher(root: root)
        let started = expectation(description: "watcher started")
        let received = expectation(description: "new transcript event")
        watcher.onMessage = { message in
            if message.userMessage == "first prompt" { received.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try writeLines([
            #"{"type":"session_meta","payload":{"id":"session-2","cwd":"/tmp/project"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"first prompt"}}"#,
        ], to: root.appendingPathComponent("rollout-session-2.jsonl"))

        wait(for: [received], timeout: 3)
    }

    func testReconciliationCatchesCompletionWithoutFileEvent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-session-3.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"session-3","cwd":"/tmp/project"}}"#,
        ], to: transcript)

        let watcher = CodexDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let working = expectation(description: "working event")
        let completed = expectation(description: "completion event")
        watcher.onMessage = { message in
            if message.hookEvent == "UserPromptSubmit" { working.fulfill() }
            if message.hookEvent == "Stop" { completed.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try appendLine(
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: transcript
        )
        watcher.reconcileNow()
        wait(for: [working], timeout: 3)

        try appendLine(
            #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}"#,
            to: transcript
        )
        watcher.reconcileNow()
        wait(for: [completed], timeout: 3)
    }

    func testNewTurnClearsPriorAssistantFallback() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-session-4.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"session-4","cwd":"/tmp/project"}}"#,
        ], to: transcript)

        let watcher = CodexDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let completed = expectation(description: "two completions")
        completed.expectedFulfillmentCount = 2
        var completionMessages: [String?] = []
        watcher.onMessage = { message in
            guard message.hookEvent == "Stop" else { return }
            completionMessages.append(message.assistantMessage)
            completed.fulfill()
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try appendLines([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"old answer"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#,
        ], to: transcript)
        watcher.reconcileNow()

        wait(for: [completed], timeout: 3)
        XCTAssertEqual(completionMessages.count, 2)
        XCTAssertEqual(completionMessages[0], "old answer")
        XCTAssertNil(completionMessages[1])
    }

    func testTranscriptToolOutputEmitsStructuredFailureOutcome() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-tool-outcome.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"tool-outcome","cwd":"/tmp/project"}}"#,
        ], to: transcript)

        let watcher = CodexDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let received = expectation(description: "structured tool failure")
        var outcome: ToolOutcome?
        watcher.onMessage = { message in
            guard message.hookEvent == "PostToolUse" else { return }
            outcome = message.toolOutcome
            XCTAssertEqual(message.toolName, "exec_command")
            received.fulfill()
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try appendLines([
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec_command","call_id":"call-1"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1","output":[{"type":"input_text","text":"{\"exit_code\":1,\"output\":\"failed\"}"}]}}"#,
        ], to: transcript)
        watcher.reconcileNow()

        wait(for: [received], timeout: 3)
        XCTAssertEqual(outcome, .failure)
    }

    func testEmitsPublicAgentAndReasoningActivityWhileTurnIsActive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-live-activity.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"live-activity","cwd":"/tmp/project"}}"#,
        ], to: transcript)

        let watcher = CodexDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let received = expectation(description: "activity updates")
        received.expectedFulfillmentCount = 2
        var summaries: [String] = []
        watcher.onMessage = { message in
            guard message.hookEvent == "ActivityUpdate", let summary = message.activitySummary else { return }
            summaries.append(summary)
            received.fulfill()
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try appendLines([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Checking the existing API contract."}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Reading the affected session code."}]}}"#,
        ], to: transcript)
        watcher.reconcileNow()

        wait(for: [received], timeout: 3)
        XCTAssertEqual(summaries, [
            "Checking the existing API contract.",
            "Reading the affected session code.",
        ])
    }

    func testDoesNotEmitReasoningWithoutPublicSummaryText() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-private-reasoning.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"private-reasoning","cwd":"/tmp/project"}}"#,
        ], to: transcript)

        let watcher = CodexDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        var activityCount = 0
        watcher.onMessage = { message in
            if message.hookEvent == "ActivityUpdate" { activityCount += 1 }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try appendLines([
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
        ], to: transcript)
        watcher.reconcileNow()

        XCTAssertEqual(activityCount, 0)
    }

    func testPolicyUsesOneSecondOnlyWhileActive() {
        let schedule = CodexReconciliationSchedule(
            activeInterval: 1,
            recentDiscoveryInterval: 10,
            fullAuditInterval: 300
        )
        var policy = CodexReconciliationPolicy(schedule: schedule, startTime: 0)

        XCTAssertEqual(policy.nextDelay(at: 0, hasActiveTranscripts: true), 1)
        XCTAssertEqual(policy.nextDelay(at: 0, hasActiveTranscripts: false), 10)
        XCTAssertEqual(policy.dueScopes(at: 9, hasActiveTranscripts: false), [])
        XCTAssertEqual(policy.dueScopes(at: 10, hasActiveTranscripts: false), [.recentDiscovery])
        XCTAssertEqual(policy.dueScopes(at: 299, hasActiveTranscripts: true), [.active, .recentDiscovery])
        XCTAssertEqual(policy.dueScopes(at: 300, hasActiveTranscripts: false), [.fullAudit])
        XCTAssertGreaterThanOrEqual(policy.nextFullAudit, 600)
    }

    func testRecentDiscoveryReturnsOnlyNewestTwoDateLeaves() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeDateDirectory(root: root, path: "2026/07/01")
        let secondNewest = try makeDateDirectory(root: root, path: "2026/08/09")
        let newest = try makeDateDirectory(root: root, path: "2026/08/11")

        let directories = CodexRecentDirectoryDiscovery.dateLeafDirectories(under: root, limit: 2)

        XCTAssertEqual(directories.map(datePath), [datePath(newest), datePath(secondNewest)])
        XCTAssertFalse(directories.map(datePath).contains(datePath(old)))
    }

    func testRecentReconciliationFindsNewestTwoButFullAuditRecoversOldDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeDateDirectory(root: root, path: "2026/07/01")
        let secondNewest = try makeDateDirectory(root: root, path: "2026/08/09")
        let newest = try makeDateDirectory(root: root, path: "2026/08/11")
        let watcher = CodexDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let recentMessages = expectation(description: "two recent sessions discovered")
        recentMessages.expectedFulfillmentCount = 2
        let oldMessage = expectation(description: "old session recovered by full audit")
        var received = Set<String>()
        watcher.onMessage = { message in
            received.insert(message.sessionId)
            if message.sessionId == "old" {
                oldMessage.fulfill()
            } else {
                recentMessages.fulfill()
            }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try writeNewSession(id: "old", in: old)
        try writeNewSession(id: "second", in: secondNewest)
        try writeNewSession(id: "newest", in: newest)

        watcher.reconcileNow(scope: .recentDiscovery)
        wait(for: [recentMessages], timeout: 3)
        XCTAssertEqual(received, ["second", "newest"])

        watcher.reconcileNow(scope: .fullAudit)
        wait(for: [oldMessage], timeout: 3)
        XCTAssertEqual(received, ["old", "second", "newest"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDateDirectory(root: URL, path: String) throws -> URL {
        let directory = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func datePath(_ url: URL) -> String {
        let day = url.lastPathComponent
        let month = url.deletingLastPathComponent().lastPathComponent
        let year = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return "\(year)/\(month)/\(day)"
    }

    private func writeNewSession(id: String, in directory: URL) throws {
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/project"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#,
        ], to: directory.appendingPathComponent("rollout-\(id).jsonl"))
    }

    private func writeLines(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func appendLine(_ line: String, to url: URL) throws {
        try appendLines([line], to: url)
    }

    private func appendLines(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }
}

private final class SequenceCodexTitleResolver: CodexSessionTitleResolving {
    private let titles: [String?]
    private(set) var callCount = 0

    init(_ titles: [String?]) {
        self.titles = titles
    }

    func title(for _: String) -> String? {
        defer { callCount += 1 }
        return callCount < titles.count ? titles[callCount] : titles.last ?? nil
    }
}

final class SQLiteCodexSessionTitleResolverTests: XCTestCase {
    func testPrefersTrimmedNameThenFallsBackToTrimmedTitle() throws {
        let databaseURL = try makeDatabase(
            schema: "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT NOT NULL)",
            inserts: [
                "INSERT INTO threads VALUES ('named', '  Product session  ', 'Transcript title')",
                "INSERT INTO threads VALUES ('untitled', '  ', '  Fallback title  ')",
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let resolver = SQLiteCodexSessionTitleResolver(databaseURL: databaseURL)

        XCTAssertEqual(resolver.title(for: "named"), "Product session")
        XCTAssertEqual(resolver.title(for: "untitled"), "Fallback title")
    }

    func testSupportsLegacySchemaAndMissingStateGracefully() throws {
        let databaseURL = try makeDatabase(
            schema: "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL)",
            inserts: ["INSERT INTO threads VALUES ('legacy', '  Legacy title  ')"]
        )
        let directory = databaseURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = SQLiteCodexSessionTitleResolver(databaseURL: databaseURL)

        XCTAssertEqual(resolver.title(for: "legacy"), "Legacy title")
        XCTAssertNil(resolver.title(for: "missing"))
        XCTAssertNil(
            SQLiteCodexSessionTitleResolver(
                databaseURL: directory.appendingPathComponent("missing.sqlite")
            ).title(for: "legacy")
        )
    }

    private func makeDatabase(schema: String, inserts: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-codex-title-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLiteCodexSessionTitleResolverTests", code: 1)
        }
        defer { sqlite3_close(database) }

        for statement in [schema] + inserts {
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteCodexSessionTitleResolverTests", code: 2)
            }
        }
        return url
    }
}
