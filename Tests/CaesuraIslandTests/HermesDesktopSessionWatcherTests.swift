import Foundation
import SQLite3
import XCTest
@testable import CaesuraIsland

final class HermesDesktopSessionWatcherTests: XCTestCase {
    func testRestoresUnfinishedDesktopTurnAtStartupWithoutCompletedTabs() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try openDatabase(at: root)
        defer { sqlite3_close(database) }

        try insertSession(database, id: "active", title: "Active Hermes task")
        try insertMessage(database, sessionId: "active", role: "user", content: "keep working")
        try insertMessage(
            database,
            sessionId: "active",
            role: "assistant",
            toolCalls: #"[{"function":{"name":"browser_click","arguments":"{}"}}]"#,
            finishReason: "tool_calls"
        )

        try insertSession(database, id: "idle", title: "Completed Hermes task")
        try insertMessage(database, sessionId: "idle", role: "user", content: "already done")
        try insertMessage(database, sessionId: "idle", role: "assistant", content: "done", finishReason: "stop")

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let restored = expectation(description: "active turn restored")
        var messages: [BridgeMessage] = []
        watcher.onMessage = { message in
            messages.append(message)
            if message.sessionId == "active", message.hookEvent == "PreToolUse" {
                restored.fulfill()
            }
        }
        watcher.start { started.fulfill() }
        wait(for: [started, restored], timeout: 3)
        watcher.stop()

        XCTAssertEqual(messages.filter { $0.sessionId == "active" }.map(\.hookEvent), ["UserPromptSubmit", "PreToolUse"])
        XCTAssertFalse(messages.contains { $0.sessionId == "idle" })
    }

    func testReconciliationCatchesAppendWithoutFileEvent() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try openDatabase(at: root)
        defer { sqlite3_close(database) }
        try insertSession(database, id: "new-turn", title: "New Hermes turn")

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let received = expectation(description: "append received")
        watcher.onMessage = { message in
            if message.userMessage == "fresh prompt" { received.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try insertMessage(database, sessionId: "new-turn", role: "user", content: "fresh prompt")
        watcher.reconcileNow()
        wait(for: [received], timeout: 3)
    }

    func testAdaptiveReconciliationUsesSlowestCadenceWhenDatabaseIsAbsent() {
        let schedule = HermesReconciliationSchedule(
            afterNewRows: 2,
            afterDatabaseOpened: 3,
            whileIdle: 5,
            whileDatabaseAbsent: 8
        )
        let policy = HermesReconciliationPolicy(schedule: schedule)

        XCTAssertEqual(policy.delay(after: .newRows), 2)
        XCTAssertEqual(policy.delay(after: .databaseOpened), 3)
        XCTAssertEqual(policy.delay(after: .noChanges), 5)
        XCTAssertEqual(policy.delay(after: .databaseUnavailable), 8)
    }

    private func makeDatabaseRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("caesura-hermes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func openDatabase(at root: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let path = root.appendingPathComponent("state.db").path
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "HermesDesktopSessionWatcherTests", code: 1)
        }
        try execute(database, """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                model TEXT,
                ended_at REAL,
                title TEXT,
                cwd TEXT
            )
            """)
        try execute(database, """
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT,
                tool_calls TEXT,
                tool_name TEXT,
                finish_reason TEXT
            )
            """)
        return database
    }

    private func insertSession(_ database: OpaquePointer, id: String, title: String) throws {
        try execute(
            database,
            "INSERT INTO sessions (id, source, title, cwd) VALUES (?, 'desktop', ?, '/tmp/project')",
            bindings: [id, title]
        )
    }

    private func insertMessage(
        _ database: OpaquePointer,
        sessionId: String,
        role: String,
        content: String? = nil,
        toolCalls: String? = nil,
        finishReason: String? = nil
    ) throws {
        try execute(
            database,
            "INSERT INTO messages (session_id, role, content, tool_calls, finish_reason) VALUES (?, ?, ?, ?, ?)",
            bindings: [sessionId, role, content, toolCalls, finishReason]
        )
    }

    private func execute(
        _ database: OpaquePointer,
        _ sql: String,
        bindings: [String?] = []
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "HermesDesktopSessionWatcherTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            if let binding {
                sqlite3_bind_text(statement, Int32(index + 1), binding, -1, transient)
            } else {
                sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "HermesDesktopSessionWatcherTests", code: 3)
        }
    }
}
