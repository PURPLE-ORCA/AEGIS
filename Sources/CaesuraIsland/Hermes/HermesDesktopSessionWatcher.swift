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

    private let root: URL
    private let automaticallyMonitorsChanges: Bool
    private let reconciliationPolicy: HermesReconciliationPolicy?
    private let staleTurnInterval: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.caesura.island.hermes-desktop.catalog", qos: .utility)
    private var workers: [String: HermesDesktopDatabaseWatcher] = [:]
    private var preferredStoreBySession: [String: String] = [:]
    private var activeSessionsByStore: [String: Set<String>] = [:]
    private var monitor: FileEventMonitor?
    private var reconciliationTimer: DispatchSourceTimer?
    private var refreshWorkItem: DispatchWorkItem?
    private var isRunning = false

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"),
        automaticallyMonitorsChanges: Bool = true,
        reconciliationSchedule: HermesReconciliationSchedule? = .standard,
        staleTurnInterval: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.automaticallyMonitorsChanges = automaticallyMonitorsChanges
        self.reconciliationPolicy = reconciliationSchedule.map(HermesReconciliationPolicy.init)
        self.staleTurnInterval = staleTurnInterval
        self.now = now
    }

    func start(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else {
                completion?()
                return
            }
            self.isRunning = true
            self.refreshWorkers {
                guard self.isRunning else {
                    completion?()
                    return
                }
                if self.automaticallyMonitorsChanges { self.startMonitor() }
                self.scheduleSafetyCheck(after: self.workers.isEmpty ? .databaseUnavailable : .databaseOpened)
                Log.info("Hermes Desktop catalog watching \(self.workers.count) database(s)")
                completion?()
            }
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            refreshWorkItem?.cancel()
            refreshWorkItem = nil
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            monitor?.stop()
            monitor = nil
            workers.values.forEach { $0.stop() }
            workers.removeAll()
            preferredStoreBySession.removeAll()
            activeSessionsByStore.removeAll()
        }
    }

    func reconcileNow() {
        queue.async { [weak self] in
            guard self?.isRunning == true else { return }
            self?.reconcileStores()
        }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        let rootPath = root.path
        let profilesPath = root.appendingPathComponent("profiles", isDirectory: true).path
        let monitor = FileEventMonitor(
            root: root,
            label: "dev.caesura.island.hermes-desktop.events",
            recursive: true,
            includeEvent: { path, _ in
                path == rootPath
                    || path == rootPath + "/state.db"
                    || path == rootPath + "/state.db-wal"
                    || path == rootPath + "/state.db-shm"
                    || path == profilesPath
                    || path.hasPrefix(profilesPath + "/")
            },
            includeFile: { url in
                ["state.db", "state.db-wal", "state.db-shm"].contains(url.lastPathComponent)
            }
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
        self.monitor = monitor
        monitor.start()
    }

    private func scheduleRefresh() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.refreshWorkItem?.cancel()
            self.scheduleSafetyCheck(after: .newRows)
            let work = DispatchWorkItem { [weak self] in self?.reconcileStores() }
            self.refreshWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    private func scheduleSafetyCheck(after outcome: HermesReadOutcome) {
        guard isRunning, let reconciliationPolicy else { return }
        let delay = reconciliationPolicy.delay(after: outcome)
        guard delay > 0 else { return }
        if reconciliationTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.reconcileStores() }
            reconciliationTimer = timer
            timer.resume()
        }
        reconciliationTimer?.schedule(deadline: .now() + delay, leeway: .milliseconds(500))
    }

    private func reconcileStores() {
        guard isRunning else { return }
        refreshWorkers { [weak self] in
            guard let self, self.isRunning else { return }
            self.workers.values.forEach { $0.reconcileNow() }
            self.scheduleSafetyCheck(after: self.workers.isEmpty ? .databaseUnavailable : .noChanges)
        }
    }

    private func refreshWorkers(completion: @escaping () -> Void) {
        let databaseURLs = discoverDatabaseURLs()
        let discoveredKeys = Set(databaseURLs.map(\.path))
        let previousPreferredStores = preferredStoreBySession
        let nextPreferredStores = preferredStores(in: databaseURLs)
        for key in Set(workers.keys).subtracting(discoveredKeys) {
            removeWorker(for: key, nextPreferredStores: nextPreferredStores)
        }
        preferredStoreBySession = nextPreferredStores

        let group = DispatchGroup()
        for databaseURL in databaseURLs where workers[databaseURL.path] == nil {
            let key = databaseURL.path
            let worker = HermesDesktopDatabaseWatcher(
                root: databaseURL.deletingLastPathComponent(),
                automaticallyMonitorsChanges: false,
                reconciliationSchedule: nil,
                staleTurnInterval: staleTurnInterval,
                now: now
            )
            worker.onMessage = { [weak self] message in
                self?.queue.async { self?.handle(message, from: key) }
            }
            workers[key] = worker
            group.enter()
            worker.start { group.leave() }
        }
        group.notify(queue: queue) { [weak self] in
            guard let self else { return }
            let reassignedSessions = nextPreferredStores.compactMap { sessionId, store -> (String, String)? in
                guard previousPreferredStores[sessionId] != nil,
                      previousPreferredStores[sessionId] != store else { return nil }
                return (sessionId, store)
            }
            for (sessionId, store) in reassignedSessions {
                self.workers[store]?.replaySession(sessionId)
            }
            completion()
        }
    }

    private func removeWorker(for key: String, nextPreferredStores: [String: String]) {
        workers.removeValue(forKey: key)?.stop()
        let orphanedSessions = activeSessionsByStore.removeValue(forKey: key) ?? []
        for sessionId in orphanedSessions where nextPreferredStores[sessionId] == nil {
            emit(BridgeMessage(sessionId: sessionId, hookEvent: "SessionEnd", source: "hermes"))
        }
    }

    private func handle(_ message: BridgeMessage, from store: String) {
        guard isRunning else { return }
        guard preferredStoreBySession[message.sessionId].map({ $0 == store }) ?? true else { return }
        if message.hookEvent == "Stop" || message.hookEvent == "SessionEnd" {
            activeSessionsByStore[store, default: []].remove(message.sessionId)
        } else {
            activeSessionsByStore[store, default: []].insert(message.sessionId)
        }
        emit(message)
    }

    private func emit(_ message: BridgeMessage) {
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }

    private func discoverDatabaseURLs() -> [URL] {
        let fileManager = FileManager.default
        let profilesRoot = root.appendingPathComponent("profiles", isDirectory: true)
        let profileDirectories = (try? fileManager.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let profileDatabases = profileDirectories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.appendingPathComponent("state.db") }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        let legacyDatabase = root.appendingPathComponent("state.db")
        return profileDatabases + (fileManager.fileExists(atPath: legacyDatabase.path) ? [legacyDatabase] : [])
    }

    private func preferredStores(in databaseURLs: [URL]) -> [String: String] {
        var preferred: [String: String] = [:]
        for databaseURL in databaseURLs {
            for sessionId in sessionIDs(in: databaseURL) where preferred[sessionId] == nil {
                preferred[sessionId] = databaseURL.path
            }
        }
        return preferred
    }

    private func sessionIDs(in databaseURL: URL) -> [String] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT id FROM sessions", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var sessionIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
            sessionIDs.append(String(cString: value))
        }
        return sessionIDs
    }
}

private final class HermesDesktopDatabaseWatcher {
    var onMessage: ((BridgeMessage) -> Void)?

    private struct ActiveTurnSnapshot {
        let sessionId: String
        let latestMessageAt: TimeInterval?
        let lastActivityAt: TimeInterval?

        var activityAt: TimeInterval? {
            [latestMessageAt, lastActivityAt].compactMap { $0 }.max()
        }
    }

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
    private let staleTurnInterval: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.caesura.island.hermes-desktop", qos: .utility)
    private var monitor: FileEventMonitor?
    private var reconciliationTimer: DispatchSourceTimer?
    private var database: OpaquePointer?
    private var lastMessageId: Int64 = 0
    private var refreshWorkItem: DispatchWorkItem?
    private var presentedActiveSessionIds = Set<String>()

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"),
        automaticallyMonitorsChanges: Bool = true,
        reconciliationSchedule: HermesReconciliationSchedule? = .standard,
        staleTurnInterval: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.databaseURL = self.root.appendingPathComponent("state.db")
        self.automaticallyMonitorsChanges = automaticallyMonitorsChanges
        self.reconciliationPolicy = reconciliationSchedule.map(HermesReconciliationPolicy.init)
        self.staleTurnInterval = staleTurnInterval
        self.now = now
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

    func replaySession(_ sessionId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.presentedActiveSessionIds.remove(sessionId)
            self.reconcileActiveSessions()
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
        reconcileActiveSessions()
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
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            reconcileActiveSessions()
            return .noChanges
        }
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
        reconcileActiveSessions()
        return rows.isEmpty ? .noChanges : .newRows
    }

    /// Reconcile provider-owned liveness, including database updates that do
    /// not append a message. Hermes keeps open tabs in `sessions`, so an
    /// unfinished message shape is only considered live while its durable
    /// activity heartbeat remains fresh.
    private func reconcileActiveSessions() {
        guard let snapshots = activeTurnSnapshots() else {
            Log.info("Hermes Desktop skipped liveness reconciliation because the snapshot query failed")
            return
        }
        let structurallyActiveIds = Set(snapshots.map(\.sessionId))

        for sessionId in presentedActiveSessionIds.subtracting(structurallyActiveIds) {
            endPresentedSession(sessionId: sessionId, reason: "provider ended")
        }

        for snapshot in snapshots {
            if isFresh(snapshot) {
                if !presentedActiveSessionIds.contains(snapshot.sessionId) {
                    restoreSession(snapshot.sessionId)
                }
            } else if presentedActiveSessionIds.contains(snapshot.sessionId) {
                endPresentedSession(sessionId: snapshot.sessionId, reason: "activity heartbeat stale")
            }
        }
    }

    private func activeTurnSnapshots() -> [ActiveTurnSnapshot]? {
        guard let database else { return nil }
        let sql = """
            WITH latest_messages AS (
                SELECT m.*
                FROM messages m
                JOIN (
                    SELECT session_id, MAX(id) AS id
                    FROM messages
                    GROUP BY session_id
                ) latest ON latest.id = m.id
            )
            SELECT s.id, latest.timestamp, s.last_activity_at
            FROM sessions s
            JOIN latest_messages latest ON latest.session_id = s.id
            WHERE s.source = 'desktop'
              AND s.ended_at IS NULL
              AND (
                  latest.role IN ('user', 'tool')
                  OR (latest.role = 'assistant' AND COALESCE(latest.finish_reason, '') != 'stop')
              )
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }

        var snapshots: [ActiveTurnSnapshot] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let sessionId = text(statement, 0), !sessionId.isEmpty {
                snapshots.append(ActiveTurnSnapshot(
                    sessionId: sessionId,
                    latestMessageAt: double(statement, 1),
                    lastActivityAt: double(statement, 2)
                ))
            }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? snapshots : nil
    }

    private func isFresh(_ snapshot: ActiveTurnSnapshot) -> Bool {
        guard let activityAt = snapshot.activityAt else { return true }
        return now().timeIntervalSince1970 - activityAt <= staleTurnInterval
    }

    private func restoreSession(_ sessionId: String) {
        guard let database else { return }
        let sql = """
            WITH turn_start AS (
                SELECT COALESCE(
                    (SELECT MAX(id) FROM messages WHERE session_id = ? AND role = 'user'),
                    (SELECT MIN(id) FROM messages WHERE session_id = ?)
                ) AS first_message_id
            )
            SELECT m.id, m.session_id, m.role, m.content, m.tool_name,
                   m.tool_calls, m.finish_reason, s.cwd, s.model, s.title
            FROM turn_start turn
            JOIN messages m ON m.session_id = ? AND m.id >= turn.first_message_id
            JOIN sessions s ON s.id = m.session_id
            ORDER BY m.id
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bind(sessionId, to: statement, indexes: [1, 2, 3])

        var restored = false
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
            restored = true
            ingest(row)
        }
        if restored {
            presentedActiveSessionIds.insert(sessionId)
            Log.info("Hermes Desktop restored active session=\(sessionId.prefix(8))")
        }
    }

    private func endPresentedSession(sessionId: String, reason: String) {
        presentedActiveSessionIds.remove(sessionId)
        Log.info("Hermes Desktop ended session=\(sessionId.prefix(8)) reason=\(reason)")
        emit(BridgeMessage(
            sessionId: sessionId,
            hookEvent: "SessionEnd",
            source: "hermes"
        ))
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
            presentedActiveSessionIds.insert(row.sessionId)
            emit(base("UserPromptSubmit", nil, nil, row.content, nil))
        case "tool":
            presentedActiveSessionIds.insert(row.sessionId)
            emit(base("PostToolUse", row.toolName ?? "Tool", nil, nil, nil))
        case "assistant":
            let tools = parseToolCalls(row.toolCalls)
            if !tools.isEmpty {
                presentedActiveSessionIds.insert(row.sessionId)
            }
            for tool in tools {
                emit(base("PreToolUse", tool.name, tool.arguments, nil, nil))
            }
            if row.finishReason == "stop" {
                presentedActiveSessionIds.remove(row.sessionId)
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

    private func double(_ statement: OpaquePointer?, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    private func bind(_ value: String, to statement: OpaquePointer?, indexes: [Int32]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for index in indexes {
            sqlite3_bind_text(statement, index, value, -1, transient)
        }
    }
}
