import Foundation

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

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    private let queue = DispatchQueue(label: "dev.caesura.island.codex-desktop", qos: .utility)
    private var monitor: FileEventMonitor?
    private var offsets: [String: UInt64] = [:]
    private var buffers: [String: Data] = [:]
    private var states: [String: SessionState] = [:]

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.seedExistingFiles()
            let monitor = FileEventMonitor(
                root: self.root,
                label: "dev.caesura.island.codex-desktop.events",
                recursive: true,
                includeFile: { $0.pathExtension == "jsonl" }
            ) { [weak self] paths in
                self?.queue.async { self?.process(paths: paths) }
            }
            self.monitor = monitor
            monitor.start()
            Log.info("Codex Desktop watcher started at \(self.root.path)")
        }
    }

    func stop() {
        queue.sync {
            monitor?.stop()
            monitor = nil
        }
    }

    private func seedExistingFiles() {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let path = url.path
            offsets[path] = fileSize(url)
            states[path] = readMetadata(url)
        }
    }

    private func process(paths: [String]) {
        var files = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if url.pathExtension == "jsonl" {
                files.insert(path)
            } else if url.hasDirectoryPath || FileManager.default.fileExists(atPath: path) {
                discoverJSONLFiles(at: url, into: &files)
            }
        }
        for path in files { readAppendedLines(at: URL(fileURLWithPath: path)) }
    }

    private func discoverJSONLFiles(at url: URL, into files: inout Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let child as URL in enumerator where child.pathExtension == "jsonl" {
            files.insert(child.path)
        }
    }

    private func readAppendedLines(at url: URL) {
        let path = url.path
        let size = fileSize(url)
        let isNew = offsets[path] == nil
        var offset = offsets[path] ?? 0
        if size < offset {
            offset = 0
            buffers[path] = nil
            states[path] = SessionState()
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
                emit(.init(sessionId: sessionId, hookEvent: "UserPromptSubmit", cwd: state.cwd, source: "codex", model: state.model))
            case "user_message":
                let text = payload["message"] as? String
                emit(.init(sessionId: sessionId, hookEvent: "UserPromptSubmit", cwd: state.cwd, userMessage: text, source: "codex", model: state.model))
            case "agent_message":
                state.lastAssistantMessage = payload["message"] as? String
            case "task_complete":
                state.active = false
                let message = (payload["last_agent_message"] as? String) ?? state.lastAssistantMessage
                emit(.init(sessionId: sessionId, hookEvent: "Stop", cwd: state.cwd, assistantMessage: message, durationMs: payload["duration_ms"] as? Int, source: "codex", model: state.model))
            case "turn_aborted":
                state.active = false
                emit(.init(sessionId: sessionId, hookEvent: "Stop", cwd: state.cwd, assistantMessage: state.lastAssistantMessage, source: "codex", model: state.model))
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
                emit(.init(sessionId: sessionId, hookEvent: "PostToolUse", cwd: state.cwd, toolName: name, source: "codex", model: state.model))
            default:
                break
            }
        }
        states[path] = state
    }

    private func emit(_ message: BridgeMessage) {
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
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
