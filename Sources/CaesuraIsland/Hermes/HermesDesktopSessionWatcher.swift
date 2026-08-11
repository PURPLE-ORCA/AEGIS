import Foundation
import SQLite3

struct HermesReconciliationSchedule: Equatable {
    let afterNewRows: TimeInterval
    let afterDatabaseOpened: TimeInterval
    let whileIdle: TimeInterval
    let whileDatabaseAbsent: TimeInterval

    static let standard = HermesReconciliationSchedule(
        afterNewRows: 10,
        afterDatabaseOpened: 10,
        whileIdle: 15,
        whileDatabaseAbsent: 30
    )
}

enum HermesReadOutcome: Equatable {
    case newRows
    case databaseOpened
    case noChanges
    case databaseUnavailable
}

struct HermesReconciliationPolicy {
    let schedule: HermesReconciliationSchedule

    func delay(after outcome: HermesReadOutcome) -> TimeInterval {
        switch outcome {
        case .newRows:
            return schedule.afterNewRows
        case .databaseOpened:
            return schedule.afterDatabaseOpened
        case .noChanges:
            return schedule.whileIdle
        case .databaseUnavailable:
            return schedule.whileDatabaseAbsent
        }
    }
}

final class HermesDesktopSessionWatcher {
    var onMessage: ((BridgeMessage) -> Void)?

    private struct MessageRow {
        let id: Int64
        let sessionId: String
        let role: String
        let content: String?
        let toolName: String?
        let toolCalls: String?
        let finishReason: String?
        let cwd: String?
        let model: String?
        let title: String?
    }

    private let root: URL
    private let databaseURL: URL
    private let automaticallyMonitorsChanges: Bool
    private let reconciliationPolicy: HermesReconciliationPolicy?
    private let queue = DispatchQueue(label: "dev.caesura.island.hermes-desktop", qos: .utility)
    private var monitor: FileEventMonitor?
    private var reconciliationTimer: DispatchSourceTimer?
    private var database: OpaquePointer?
    private var lastMessageId: Int64 = 0
    private var refreshWorkItem: DispatchWorkItem?

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"),
        automaticallyMonitorsChanges: Bool = true,
        reconciliationSchedule: HermesReconciliationSchedule? = .standard
    ) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.databaseURL = self.root.appendingPathComponent("state.db")
        self.automaticallyMonitorsChanges = automaticallyMonitorsChanges
        self.reconciliationPolicy = reconciliationSchedule.map(HermesReconciliationPolicy.init)
    }

    func start(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let initialOutcome = self.openDatabaseAndRestoreActiveSessions()
            if self.automaticallyMonitorsChanges {
                let databasePaths = Set([
                    self.databaseURL.path,
                    self.databaseURL.path + "-wal",
                    self.databaseURL.path + "-shm",
                ])
                let monitor = FileEventMonitor(
                    root: self.root,
                    label: "dev.caesura.island.hermes-desktop.events",
                    includeEvent: { path, _ in databasePaths.contains(path) },
                    includeFile: { _ in true }
                ) { [weak self] _ in
                    self?.scheduleRefresh()
                }
                self.monitor = monitor
                monitor.start()
            }
            self.scheduleSafetyCheck(after: initialOutcome)
            Log.info("Hermes Desktop watcher started at \(self.databaseURL.path), lastMessageId=\(self.lastMessageId)")
            completion?()
        }
    }

    func stop() {
        queue.sync {
            refreshWorkItem?.cancel()
            refreshWorkItem = nil
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            monitor?.stop()
            monitor = nil
            if let database { sqlite3_close(database) }
            database = nil
        }
    }

    func reconcileNow() {
        queue.async { [weak self] in
            self?.readAndScheduleNextSafetyCheck()
        }
    }

    private func scheduleRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshWorkItem?.cancel()
            self.scheduleSafetyCheck(after: .newRows)
            let work = DispatchWorkItem { [weak self] in self?.readAndScheduleNextSafetyCheck() }
            self.refreshWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    private func scheduleSafetyCheck(after outcome: HermesReadOutcome) {
        guard let reconciliationPolicy else { return }
        let delay = reconciliationPolicy.delay(after: outcome)
        guard delay > 0 else { return }

        if reconciliationTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                self?.readAndScheduleNextSafetyCheck()
            }
            reconciliationTimer = timer
            timer.resume()
        }

        reconciliationTimer?.schedule(
            deadline: .now() + delay,
            leeway: .milliseconds(500)
        )
    }

    private func readAndScheduleNextSafetyCheck() {
        scheduleSafetyCheck(after: readNewMessages())
    }

    private func openDatabaseAndRestoreActiveSessions() -> HermesReadOutcome {
        guard openDatabase() else { return .databaseUnavailable }
        lastMessageId = maximumMessageId()
        restoreActiveSessions()
        return .databaseOpened
    }

    private func openDatabase() -> Bool {
        if database != nil { return true }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return false }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            return false
        }
        sqlite3_busy_timeout(database, 150)
        return true
    }

    private func maximumMessageId() -> Int64 {
        guard let database else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(MAX(id), 0) FROM messages", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func readNewMessages() -> HermesReadOutcome {
        if database == nil {
            return openDatabaseAndRestoreActiveSessions()
        }
        guard let database else { return .databaseUnavailable }
        let sql = """
            SELECT m.id, m.session_id, m.role, m.content, m.tool_name,
                   m.tool_calls, m.finish_reason, s.cwd, s.model, s.title
            FROM messages m
            JOIN sessions s ON s.id = m.session_id
            WHERE m.id > ? AND s.source = 'desktop'
            ORDER BY m.id
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return .noChanges }
        sqlite3_bind_int64(statement, 1, lastMessageId)

        var rows: [MessageRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(MessageRow(
                id: sqlite3_column_int64(statement, 0),
                sessionId: text(statement, 1) ?? "",
                role: text(statement, 2) ?? "",
                content: text(statement, 3),
                toolName: text(statement, 4),
                toolCalls: text(statement, 5),
                finishReason: text(statement, 6),
                cwd: text(statement, 7),
                model: text(statement, 8),
                title: text(statement, 9)
            ))
        }

        for row in rows where !row.sessionId.isEmpty {
            lastMessageId = max(lastMessageId, row.id)
            ingest(row)
        }
        return rows.isEmpty ? .noChanges : .newRows
    }

    /// Reconstruct only unfinished desktop turns after an app relaunch. Hermes
    /// keeps open tabs in `sessions` even after a reply is complete, so
    /// `ended_at IS NULL` alone is not enough; the newest message must still
    /// represent active work. Replaying from the latest user message restores
    /// the exact thinking/tool state without surfacing old completed tabs.
    private func restoreActiveSessions() {
        guard let database else { return }
        let sql = """
            WITH latest_messages AS (
                SELECT m.*
                FROM messages m
                JOIN (
                    SELECT session_id, MAX(id) AS id
                    FROM messages
                    GROUP BY session_id
                ) latest ON latest.id = m.id
            ), active_sessions AS (
                SELECT s.id
                FROM sessions s
                JOIN latest_messages latest ON latest.session_id = s.id
                WHERE s.source = 'desktop'
                  AND s.ended_at IS NULL
                  AND (
                      latest.role IN ('user', 'tool')
                      OR (latest.role = 'assistant' AND COALESCE(latest.finish_reason, '') != 'stop')
                  )
            ), turn_starts AS (
                SELECT active.id AS session_id,
                       COALESCE(
                           (SELECT MAX(id) FROM messages WHERE session_id = active.id AND role = 'user'),
                           (SELECT MIN(id) FROM messages WHERE session_id = active.id)
                       ) AS first_message_id
                FROM active_sessions active
            )
            SELECT m.id, m.session_id, m.role, m.content, m.tool_name,
                   m.tool_calls, m.finish_reason, s.cwd, s.model, s.title
            FROM turn_starts turn
            JOIN messages m ON m.session_id = turn.session_id AND m.id >= turn.first_message_id
            JOIN sessions s ON s.id = m.session_id
            ORDER BY m.id
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }

        var restoredSessionIds = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let row = MessageRow(
                id: sqlite3_column_int64(statement, 0),
                sessionId: text(statement, 1) ?? "",
                role: text(statement, 2) ?? "",
                content: text(statement, 3),
                toolName: text(statement, 4),
                toolCalls: text(statement, 5),
                finishReason: text(statement, 6),
                cwd: text(statement, 7),
                model: text(statement, 8),
                title: text(statement, 9)
            )
            guard !row.sessionId.isEmpty else { continue }
            restoredSessionIds.insert(row.sessionId)
            ingest(row)
        }
        if !restoredSessionIds.isEmpty {
            Log.info("Hermes Desktop restored \(restoredSessionIds.count) active session(s)")
        }
    }

    private func ingest(_ row: MessageRow) {
        let base = { (event: String, toolName: String?, toolInput: String?, user: String?, assistant: String?) in
            BridgeMessage(
                sessionId: row.sessionId,
                hookEvent: event,
                cwd: row.cwd,
                toolName: toolName,
                toolInput: toolInput,
                userMessage: user,
                assistantMessage: assistant,
                sessionTitle: row.title,
                source: "hermes",
                model: row.model
            )
        }

        switch row.role {
        case "user":
            emit(base("UserPromptSubmit", nil, nil, row.content, nil))
        case "tool":
            emit(base("PostToolUse", row.toolName ?? "Tool", nil, nil, nil))
        case "assistant":
            for tool in parseToolCalls(row.toolCalls) {
                emit(base("PreToolUse", tool.name, tool.arguments, nil, nil))
            }
            if row.finishReason == "stop" {
                emit(base("Stop", nil, nil, nil, row.content))
            }
        default:
            break
        }
    }

    private func parseToolCalls(_ json: String?) -> [(name: String, arguments: String?)] {
        guard let json,
              let data = json.data(using: .utf8),
              let calls = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return calls.compactMap { call in
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            return (name, function["arguments"] as? String)
        }
    }

    private func emit(_ message: BridgeMessage) {
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}
