import Foundation
import XCTest
@testable import CaesuraIsland

final class CodexDesktopSessionWatcherTests: XCTestCase {
    func testExistingTranscriptStartsAtEndThenEmitsAppendedEvent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("rollout-session-1.jsonl")
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/project"}}"#,
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
            .appendingPathComponent("caesura-codex-tests-\(UUID().uuidString)", isDirectory: true)
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
