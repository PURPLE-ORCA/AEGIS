import Foundation
import SQLite3

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

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hermes")
    private lazy var databaseURL = root.appendingPathComponent("state.db")
    private let queue = DispatchQueue(label: "dev.caesura.island.hermes-desktop", qos: .utility)
    private var monitor: FileEventMonitor?
    private var database: OpaquePointer?
    private var lastMessageId: Int64 = 0
    private var refreshWorkItem: DispatchWorkItem?

    func start() {
        queue.async { [weak self] in
            guard let self, self.openDatabase() else { return }
            self.lastMessageId = self.maximumMessageId()
            let monitor = FileEventMonitor(
                root: self.root,
                label: "dev.caesura.island.hermes-desktop.events",
                includeFile: { $0.lastPathComponent.hasPrefix("state.db") }
            ) { [weak self] paths in
                self?.scheduleRefresh()
            }
            self.monitor = monitor
            monitor.start()
            Log.info("Hermes Desktop watcher started at \(self.databaseURL.path), lastMessageId=\(self.lastMessageId)")
        }
    }

    func stop() {
        queue.sync {
            refreshWorkItem?.cancel()
            refreshWorkItem = nil
            monitor?.stop()
            monitor = nil
            if let database { sqlite3_close(database) }
            database = nil
        }
    }

    private func scheduleRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.readNewMessages() }
            self.refreshWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    private func openDatabase() -> Bool {
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

    private func readNewMessages() {
        guard let database else { return }
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
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
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
