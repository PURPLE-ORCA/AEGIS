import Foundation
import AegisBridgeSupport

enum CodexReconciliationScope: Hashable {
    case active
    case recentDiscovery
    case fullAudit
}

struct CodexReconciliationSchedule: Equatable {
    let activeInterval: TimeInterval
    let recentDiscoveryInterval: TimeInterval
    let fullAuditInterval: TimeInterval

    static let standard = CodexReconciliationSchedule(
        activeInterval: 1,
        recentDiscoveryInterval: 10,
        fullAuditInterval: 300
    )
}

struct CodexReconciliationPolicy {
    let schedule: CodexReconciliationSchedule
    private(set) var nextRecentDiscovery: TimeInterval
    private(set) var nextFullAudit: TimeInterval

    init(schedule: CodexReconciliationSchedule, startTime: TimeInterval) {
        self.schedule = schedule
        self.nextRecentDiscovery = startTime + schedule.recentDiscoveryInterval
        self.nextFullAudit = startTime + schedule.fullAuditInterval
    }

    mutating func dueScopes(at time: TimeInterval, hasActiveTranscripts: Bool) -> Set<CodexReconciliationScope> {
        var scopes: Set<CodexReconciliationScope> = hasActiveTranscripts ? [.active] : []

        if time >= nextFullAudit {
            scopes.insert(.fullAudit)
            nextFullAudit = time + schedule.fullAuditInterval
            nextRecentDiscovery = time + schedule.recentDiscoveryInterval
        } else if time >= nextRecentDiscovery {
            scopes.insert(.recentDiscovery)
            nextRecentDiscovery = time + schedule.recentDiscoveryInterval
        }

        return scopes
    }

    mutating func recordFullAudit(at time: TimeInterval) {
        nextFullAudit = time + schedule.fullAuditInterval
        nextRecentDiscovery = time + schedule.recentDiscoveryInterval
    }

    func nextDelay(at time: TimeInterval, hasActiveTranscripts: Bool) -> TimeInterval {
        if hasActiveTranscripts { return schedule.activeInterval }
        return max(0.1, min(nextRecentDiscovery, nextFullAudit) - time)
    }
}

struct CodexRecentDirectoryDiscovery {
    static func dateLeafDirectories(
        under root: URL,
        limit: Int,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard limit > 0 else { return [] }

        var leaves: [(key: String, url: URL)] = []
        for year in numericDirectories(in: root, digits: 4, fileManager: fileManager) {
            for month in numericDirectories(in: year, digits: 2, fileManager: fileManager) {
                for day in numericDirectories(in: month, digits: 2, fileManager: fileManager) {
                    let key = "\(year.lastPathComponent)/\(month.lastPathComponent)/\(day.lastPathComponent)"
                    leaves.append((key, day))
                }
            }
        }

        return leaves
            .sorted { $0.key > $1.key }
            .prefix(limit)
            .map(\.url)
    }

    private static func numericDirectories(
        in parent: URL,
        digits: Int,
        fileManager: FileManager
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let children = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.filter { child in
            let name = child.lastPathComponent
            guard name.count == digits, name.allSatisfy(\.isNumber) else { return false }
            return (try? child.resourceValues(forKeys: keys).isDirectory) == true
        }
    }
}

final class CodexDesktopSessionWatcher {
    var onMessage: ((BridgeMessage) -> Void)?

    private struct SessionState {
        var id: String?
        var cwd: String?
        var model: String?
        var active = false
        var lastAssistantMessage: String?
        var tools: [String: String] = [:]
    }

    private let root: URL
    private let automaticallyMonitorsChanges: Bool
    private let reconciliationSchedule: CodexReconciliationSchedule?
    private let queue = DispatchQueue(label: "dev.aegis.app.codex-desktop", qos: .utility)
    private var monitor: FileEventMonitor?
    private var reconciliationTimer: DispatchSourceTimer?
    private var reconciliationPolicy: CodexReconciliationPolicy?
    private var offsets: [String: UInt64] = [:]
    private var buffers: [String: Data] = [:]
    private var states: [String: SessionState] = [:]

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        automaticallyMonitorsChanges: Bool = true,
        reconciliationSchedule: CodexReconciliationSchedule? = .standard
    ) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.automaticallyMonitorsChanges = automaticallyMonitorsChanges
        self.reconciliationSchedule = reconciliationSchedule
    }

    func start(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.seedExistingFiles()
            if let reconciliationSchedule = self.reconciliationSchedule {
                self.reconciliationPolicy = CodexReconciliationPolicy(
                    schedule: reconciliationSchedule,
                    startTime: ProcessInfo.processInfo.systemUptime
                )
            }
            if self.automaticallyMonitorsChanges {
                let monitor = FileEventMonitor(
                    root: self.root,
                    label: "dev.aegis.app.codex-desktop.events",
                    recursive: true,
                    includeFile: { $0.pathExtension == "jsonl" }
                ) { [weak self] paths in
                    self?.queue.async { self?.process(paths: paths) }
                }
                self.monitor = monitor
                monitor.start()
            }
            self.scheduleNextReconciliation()
            Log.info("Codex Desktop watcher started at \(self.root.path)")
            completion?()
        }
    }

    func stop() {
        queue.sync {
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            reconciliationPolicy = nil
            monitor?.stop()
            monitor = nil
        }
    }

    /// Reconcile transcript sizes without relying on a filesystem callback.
    /// Useful for deterministic tests and for callers that need an immediate
    /// catch-up after an external lifecycle transition.
    func reconcileNow() {
        reconcileNow(scope: .fullAudit)
    }

    func reconcileNow(scope: CodexReconciliationScope) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if scope == .fullAudit {
                self.reconciliationPolicy?.recordFullAudit(at: now)
            }
            self.reconcileTranscripts(scopes: [scope])
            self.scheduleNextReconciliation()
        }
    }

    private func seedExistingFiles() {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let path = canonicalPath(url)
            offsets[path] = fileSize(url)
        }
    }

    private func process(paths: [String]) {
        var files = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if url.pathExtension == "jsonl" {
                files.insert(canonicalPath(url))
            } else if url.hasDirectoryPath || FileManager.default.fileExists(atPath: path) {
                discoverJSONLFiles(at: url, into: &files)
            }
        }
        for path in files { readAppendedLines(at: URL(fileURLWithPath: path)) }
        scheduleNextReconciliation()
    }

    private func scheduleNextReconciliation() {
        guard let policy = reconciliationPolicy else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = policy.nextDelay(at: now, hasActiveTranscripts: hasActiveTranscripts)

        if reconciliationTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                self?.runScheduledReconciliation()
            }
            reconciliationTimer = timer
            timer.resume()
        }

        reconciliationTimer?.schedule(
            deadline: .now() + delay,
            leeway: .milliseconds(150)
        )
    }

    private func runScheduledReconciliation() {
        guard var policy = reconciliationPolicy else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let scopes = policy.dueScopes(at: now, hasActiveTranscripts: hasActiveTranscripts)
        reconciliationPolicy = policy
        reconcileTranscripts(scopes: scopes)
        scheduleNextReconciliation()
    }

    private var hasActiveTranscripts: Bool {
        states.values.contains { $0.active || !$0.tools.isEmpty }
    }

    private func reconcileTranscripts(scopes: Set<CodexReconciliationScope>) {
        var paths = Set<String>()

        if scopes.contains(.fullAudit) {
            paths.formUnion(offsets.keys)
            discoverJSONLFiles(at: root, into: &paths)
        } else {
            if scopes.contains(.recentDiscovery) {
                for directory in CodexRecentDirectoryDiscovery.dateLeafDirectories(under: root, limit: 2) {
                    discoverJSONLFiles(at: directory, into: &paths)
                }
            }
            if scopes.contains(.active) {
                paths.formUnion(states.compactMap { path, state in
                    state.active || !state.tools.isEmpty ? path : nil
                })
            }
        }

        for path in paths {
            readAppendedLines(at: URL(fileURLWithPath: path))
        }
    }

    private func discoverJSONLFiles(at url: URL, into files: inout Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let child as URL in enumerator where child.pathExtension == "jsonl" {
            files.insert(canonicalPath(child))
        }
    }

    private func readAppendedLines(at url: URL) {
        let path = canonicalPath(url)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            offsets[path] = nil
            buffers[path] = nil
            states[path] = nil
            return
        }
        let size = fileSize(url)
        let isNew = offsets[path] == nil
        var offset = offsets[path] ?? 0
        if size < offset {
            offset = 0
            buffers[path] = nil
            states[path] = SessionState()
        }
        if states[path] == nil {
            states[path] = readMetadata(url)
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let chunk = try handle.readToEnd() ?? Data()
            offsets[path] = offset + UInt64(chunk.count)
            var data = buffers[path] ?? Data()
            data.append(chunk)
            let parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            buffers[path] = parts.last.map { Data($0) } ?? Data()
            for part in parts.dropLast() where !part.isEmpty {
                ingest(Data(part), path: path)
            }
        } catch {
            if isNew { offsets[path] = nil }
        }
    }

    private func ingest(_ data: Data, path: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }

        var state = states[path] ?? SessionState()
        if type == "session_meta" {
            state.id = (payload["id"] as? String) ?? (payload["session_id"] as? String)
            state.cwd = payload["cwd"] as? String
            states[path] = state
            return
        }
        if type == "turn_context" {
            state.cwd = payload["cwd"] as? String ?? state.cwd
            state.model = payload["model"] as? String ?? state.model
            states[path] = state
            return
        }

        guard let sessionId = state.id else { return }
        if type == "event_msg", let event = payload["type"] as? String {
            switch event {
            case "task_started":
                state.active = true
                state.lastAssistantMessage = nil
                state.tools.removeAll()
                emit(.init(sessionId: sessionId, hookEvent: "UserPromptSubmit", cwd: state.cwd, source: "codex", model: state.model))
            case "user_message":
                let text = payload["message"] as? String
                emit(.init(sessionId: sessionId, hookEvent: "UserPromptSubmit", cwd: state.cwd, userMessage: text, source: "codex", model: state.model))
            case "agent_message":
                state.lastAssistantMessage = payload["message"] as? String
            case "task_complete":
                state.active = false
                state.tools.removeAll()
                let message = (payload["last_agent_message"] as? String) ?? state.lastAssistantMessage
                emit(.init(sessionId: sessionId, hookEvent: "Stop", cwd: state.cwd, assistantMessage: message, durationMs: payload["duration_ms"] as? Int, source: "codex", model: state.model))
            case "turn_aborted":
                state.active = false
                state.tools.removeAll()
                emit(.init(sessionId: sessionId, hookEvent: "Stop", cwd: state.cwd, source: "codex", model: state.model))
            default:
                break
            }
        } else if type == "response_item", let itemType = payload["type"] as? String {
            let callId = payload["call_id"] as? String
            switch itemType {
            case "custom_tool_call", "function_call":
                let name = payload["name"] as? String ?? "Tool"
                if let callId { state.tools[callId] = name }
                let input = (payload["input"] as? String) ?? (payload["arguments"] as? String)
                emit(.init(sessionId: sessionId, hookEvent: "PreToolUse", cwd: state.cwd, toolName: name, toolInput: input, source: "codex", model: state.model))
            case "custom_tool_call_output", "function_call_output":
                let name = callId.flatMap { state.tools.removeValue(forKey: $0) } ?? "Tool"
                let outcome = StructuredToolOutcomeDetector.explicitOutcome(from: payload["output"])
                    ?? StructuredToolOutcomeDetector.explicitOutcome(from: payload)
                emit(.init(
                    sessionId: sessionId,
                    hookEvent: "PostToolUse",
                    cwd: state.cwd,
                    toolName: name,
                    toolOutcome: outcome,
                    source: "codex",
                    model: state.model
                ))
            default:
                break
            }
        }
        states[path] = state
    }

    private func emit(_ message: BridgeMessage) {
        RunLoop.main.perform { [weak self] in self?.onMessage?(message) }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func readMetadata(_ url: URL) -> SessionState {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return SessionState() }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let line = data.split(separator: 0x0A).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return SessionState() }
        return SessionState(
            id: (payload["id"] as? String) ?? (payload["session_id"] as? String),
            cwd: payload["cwd"] as? String
        )
    }
}
