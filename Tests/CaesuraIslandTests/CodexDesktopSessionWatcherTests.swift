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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caesura-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeLines(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }
}
