import Foundation
import SQLite3
import XCTest
@testable import Aegis

final class HermesDesktopSessionWatcherTests: XCTestCase {
    func testRestoresUnfinishedTurnFromNamedProfileAtStartup() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileRoot = root.appendingPathComponent("profiles/orcanee", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let database = try openDatabase(at: profileRoot)
        defer { sqlite3_close(database) }

        try insertSession(database, id: "profile-active", title: "Profile task")
        try insertMessage(database, sessionId: "profile-active", role: "user", content: "profile prompt")

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let restored = expectation(description: "profile turn restored")
        watcher.onMessage = { message in
            if message.sessionId == "profile-active", message.userMessage == "profile prompt" {
                restored.fulfill()
            }
        }
        watcher.start { started.fulfill() }
        wait(for: [started, restored], timeout: 3)
        watcher.stop()
    }

    func testReconciliationDiscoversProfileCreatedAfterStartup() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let discovered = expectation(description: "new profile discovered")
        watcher.onMessage = { message in
            if message.sessionId == "late-profile" { discovered.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        let profileRoot = root.appendingPathComponent("profiles/late", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let database = try openDatabase(at: profileRoot)
        defer { sqlite3_close(database) }
        try insertSession(database, id: "late-profile", title: "Late profile task")
        try insertMessage(database, sessionId: "late-profile", role: "user", content: "discover me")

        watcher.reconcileNow()
        wait(for: [discovered], timeout: 3)
    }

    func testPrefersNamedProfileWhenSessionWasCopiedFromLegacyDatabase() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDatabase = try openDatabase(at: root)
        defer { sqlite3_close(legacyDatabase) }
        try insertSession(legacyDatabase, id: "migrated", title: "Legacy copy")
        try insertMessage(legacyDatabase, sessionId: "migrated", role: "user", content: "legacy prompt")

        let profileRoot = root.appendingPathComponent("profiles/orcanee", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let profileDatabase = try openDatabase(at: profileRoot)
        defer { sqlite3_close(profileDatabase) }
        try insertSession(profileDatabase, id: "migrated", title: "Profile copy")
        try insertMessage(profileDatabase, sessionId: "migrated", role: "user", content: "profile prompt")

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let restored = expectation(description: "preferred profile restored")
        var prompts: [String] = []
        watcher.onMessage = { message in
            if let prompt = message.userMessage {
                prompts.append(prompt)
                if prompt == "profile prompt" { restored.fulfill() }
            }
        }
        watcher.start { started.fulfill() }
        wait(for: [started, restored], timeout: 3)
        watcher.stop()

        XCTAssertEqual(prompts, ["profile prompt"])
    }

    func testFallsBackToLegacyDatabaseWhenPreferredProfileDisappears() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDatabase = try openDatabase(at: root)
        defer { sqlite3_close(legacyDatabase) }
        try insertSession(legacyDatabase, id: "migrated", title: "Legacy copy")
        try insertMessage(legacyDatabase, sessionId: "migrated", role: "user", content: "legacy prompt")

        let profileRoot = root.appendingPathComponent("profiles/orcanee", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let profileDatabase = try openDatabase(at: profileRoot)
        try insertSession(profileDatabase, id: "migrated", title: "Profile copy")
        try insertMessage(profileDatabase, sessionId: "migrated", role: "user", content: "profile prompt")

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let profileRestored = expectation(description: "profile restored")
        let legacyRestored = expectation(description: "legacy fallback restored")
        watcher.onMessage = { message in
            if message.userMessage == "profile prompt" { profileRestored.fulfill() }
            if message.userMessage == "legacy prompt" { legacyRestored.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started, profileRestored], timeout: 3)
        defer { watcher.stop() }

        sqlite3_close(profileDatabase)
        try FileManager.default.removeItem(at: profileRoot.appendingPathComponent("state.db"))
        watcher.reconcileNow()
        wait(for: [legacyRestored], timeout: 3)
    }

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

    func testDoesNotRestoreStaleUnfinishedTurnAtStartup() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try openDatabase(at: root)
        defer { sqlite3_close(database) }
        let now = Date(timeIntervalSince1970: 10_000)

        try insertSession(database, id: "stale", title: "Abandoned turn", lastActivityAt: 9_000)
        try insertMessage(
            database,
            sessionId: "stale",
            role: "user",
            content: "This turn never completed",
            timestamp: 9_000
        )

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil,
            staleTurnInterval: 300,
            now: { now }
        )
        let started = expectation(description: "watcher started")
        let unexpectedMessage = expectation(description: "stale turn was restored")
        unexpectedMessage.isInverted = true
        watcher.onMessage = { _ in unexpectedMessage.fulfill() }
        watcher.start { started.fulfill() }
        defer { watcher.stop() }

        wait(for: [started, unexpectedMessage], timeout: 0.2)
    }

    func testReconciliationEndsTurnWhenHermesActivityBecomesStale() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try openDatabase(at: root)
        defer { sqlite3_close(database) }
        var now = Date(timeIntervalSince1970: 10_000)

        try insertSession(database, id: "active", title: "Active turn", lastActivityAt: 9_900)
        try insertMessage(database, sessionId: "active", role: "user", content: "Keep going", timestamp: 9_900)

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil,
            staleTurnInterval: 300,
            now: { now }
        )
        let started = expectation(description: "watcher started")
        let restored = expectation(description: "fresh turn restored")
        let ended = expectation(description: "stale turn ended")
        watcher.onMessage = { message in
            if message.hookEvent == "UserPromptSubmit" { restored.fulfill() }
            if message.hookEvent == "SessionEnd" { ended.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started, restored], timeout: 3)
        defer { watcher.stop() }

        now = Date(timeIntervalSince1970: 10_301)
        watcher.reconcileNow()
        wait(for: [ended], timeout: 3)
    }

    func testFreshHeartbeatRevivesPreviouslyStaleTurnWithoutNewMessage() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try openDatabase(at: root)
        defer { sqlite3_close(database) }
        let now = Date(timeIntervalSince1970: 10_000)

        try insertSession(database, id: "revived", title: "Revived turn", lastActivityAt: 9_000)
        try insertMessage(database, sessionId: "revived", role: "user", content: "Resume me", timestamp: 9_000)

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil,
            staleTurnInterval: 300,
            now: { now }
        )
        let started = expectation(description: "watcher started")
        let revived = expectation(description: "turn revived")
        watcher.onMessage = { message in
            if message.sessionId == "revived", message.hookEvent == "UserPromptSubmit" {
                revived.fulfill()
            }
        }
        watcher.start { started.fulfill() }
        wait(for: [started], timeout: 3)
        defer { watcher.stop() }

        try updateSessionActivity(database, id: "revived", timestamp: 9_900)
        watcher.reconcileNow()
        wait(for: [revived], timeout: 3)
    }

    func testReconciliationObservesSessionEndWithoutNewMessage() throws {
        let root = try makeDatabaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try openDatabase(at: root)
        defer { sqlite3_close(database) }

        try insertSession(database, id: "closed", title: "Closed turn")
        try insertMessage(database, sessionId: "closed", role: "user", content: "Close me")

        let watcher = HermesDesktopSessionWatcher(
            root: root,
            automaticallyMonitorsChanges: false,
            reconciliationSchedule: nil
        )
        let started = expectation(description: "watcher started")
        let restored = expectation(description: "turn restored")
        let ended = expectation(description: "session end observed")
        watcher.onMessage = { message in
            if message.hookEvent == "UserPromptSubmit" { restored.fulfill() }
            if message.hookEvent == "SessionEnd" { ended.fulfill() }
        }
        watcher.start { started.fulfill() }
        wait(for: [started, restored], timeout: 3)
        defer { watcher.stop() }

        try endSession(database, id: "closed")
        watcher.reconcileNow()
        wait(for: [ended], timeout: 3)
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
            .appendingPathComponent("aegis-hermes-tests-\(UUID().uuidString)", isDirectory: true)
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
                last_activity_at REAL,
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
                finish_reason TEXT,
                timestamp REAL NOT NULL
            )
            """)
        return database
    }

    private func insertSession(
        _ database: OpaquePointer,
        id: String,
        title: String,
        lastActivityAt: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        try execute(
            database,
            "INSERT INTO sessions (id, source, title, cwd, last_activity_at) VALUES (?, 'desktop', ?, '/tmp/project', \(lastActivityAt))",
            bindings: [id, title]
        )
    }

    private func insertMessage(
        _ database: OpaquePointer,
        sessionId: String,
        role: String,
        content: String? = nil,
        toolCalls: String? = nil,
        finishReason: String? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        try execute(
            database,
            "INSERT INTO messages (session_id, role, content, tool_calls, finish_reason, timestamp) VALUES (?, ?, ?, ?, ?, \(timestamp))",
            bindings: [sessionId, role, content, toolCalls, finishReason]
        )
    }

    private func updateSessionActivity(_ database: OpaquePointer, id: String, timestamp: TimeInterval) throws {
        try execute(
            database,
            "UPDATE sessions SET last_activity_at = \(timestamp) WHERE id = ?",
            bindings: [id]
        )
    }

    private func endSession(_ database: OpaquePointer, id: String) throws {
        try execute(
            database,
            "UPDATE sessions SET ended_at = last_activity_at + 1 WHERE id = ?",
            bindings: [id]
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
