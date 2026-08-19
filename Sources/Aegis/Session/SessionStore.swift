import Foundation
import Combine

enum SessionEvent {
    case sessionStarted(String)
    case sessionEnded(String)
    case statusChanged(String, SessionStatus)
    case toolStarted(String, String)
    case toolEnded(String, String)
    case permissionRequested(String)
    case permissionResponded(String, Bool)
    case questionAsked(String)
    case pendingDismissedExternally(String)
    case notification(String, String)
}

enum SessionMessageOrigin: Equatable {
    case providerHook
    case durableProviderState
}

@MainActor
final class SessionStore: ObservableObject {
    private static let codexIdleThreshold: TimeInterval = 5 * 60
    private static let hookOnlyThinkingIdleThreshold: TimeInterval = 15 * 60
    private static let hookOnlyThinkingSources: Set<String> = ["hermes", "antigravity"]

    @Published var sessions: [String: Session] = [:]

    let onEvent = PassthroughSubject<SessionEvent, Never>()

    private enum PostCommitEffect {
        case event(SessionEvent)
        case action(() -> Void)
        case scheduleRemoval(sessionId: String, delay: TimeInterval)
    }

    /// Polls every 5s to check whether the AI agent process is still alive.
    /// Cleaner than time-based cleanup because long idle sessions stay open
    /// while genuinely-exited sessions get removed quickly.
    private var processSweepTimer: Timer?

    /// In-flight removal tasks keyed by session id. A late event can cancel
    /// the pending removal and re-activate the session, instead of having
    /// the timer fire and silently delete a freshly-recreated session with
    /// the same id (issues #8, #9, #10).
    private var pendingRemovals: [String: Task<Void, Never>] = [:]

    init() {
        processSweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepClosedAgents() }
        }
    }

    deinit {
        processSweepTimer?.invalidate()
    }

    /// Marks sessions whose agent has exited as ended, then removes them.
    ///
    /// Three detection strategies, used in parallel:
    ///   1. PID probe via `kill(pid, 0)` — reliable for providers where the
    ///      hook bridge's `getppid()` returns the agent's own short-lived
    ///      process. Returns -1 with errno=ESRCH when the process is gone.
    ///   2. Codex-only inactivity timeout — Codex routes hooks through a
    ///      persistent `app-server` daemon (the bridge's parent is always
    ///      that long-lived process), so PID detection never fires. If a
    ///      Codex session goes 5+ minutes without ANY hook, we treat it as
    ///      ended. 5 minutes is conservative enough that an actively-used
    ///      session won't be killed even mid-tool-call.
    ///   3. Hook-only thinking timeout — Hermes background work and AntiGravity
    ///      windows can disappear before their closing hook fires. Durable
    ///      sessions retain their provider watcher, while hook-only sessions are
    ///      retired after 15 minutes without progress. Tool and approval states
    ///      remain exempt so long-running commands and user decisions stay visible.
    func sweepClosedAgents(at now: Date = Date()) {

        for (id, session) in sessions {
            guard session.status != .completed else { continue }

            var shouldClose = false

            // Strategy 1: PID probe — also check process start time so we
            // don't keep a dead session alive forever because the kernel
            // recycled the pid to some unrelated process (issue #29).
            if let pid = session.agentPid {
                let result = kill(pid_t(pid), 0)
                if result != 0 && errno == ESRCH {
                    shouldClose = true
                } else if let startSec = session.agentStartSec,
                          let startUsec = session.agentStartUsec,
                          let now = Self.processStartTime(pid: pid_t(pid)),
                          (Int(now.tv_sec) != startSec || Int(now.tv_usec) != startUsec) {
                    // PID is alive but it's a different process now.
                    shouldClose = true
                }
            }

            // Strategy 2: inactivity timeout (Codex only — PID is unreliable
            // because hooks route through a long-lived daemon). Skip when
            // a tool is in flight — Codex emits PreToolUse then nothing
            // until PostToolUse, and we'd kill the session mid-tool on
            // anything that takes more than 5 minutes (issue #11).
            if !shouldClose && session.source == "codex" && session.status == .idle {
                if now.timeIntervalSince(session.lastActivityAt) > Self.codexIdleThreshold {
                    shouldClose = true
                }
            }

            if !shouldClose,
               Self.hookOnlyThinkingSources.contains(session.source),
               !session.isDurablyTracked,
               session.status == .thinking,
               now.timeIntervalSince(session.lastActivityAt) > Self.hookOnlyThinkingIdleThreshold {
                Log.info("Hook session expired after inactivity source=\(session.source) session=\(id.prefix(8))")
                shouldClose = true
            }

            if shouldClose {
                markCompletedAndScheduleRemoval(sessionId: id, after: 2.0)
            }
        }
    }

    // MARK: - Removal helpers

    /// Mark the session completed, emit `sessionEnded`, and schedule its
    /// removal after `delay`. A late hook arrival within `delay` cancels
    /// the removal and resurrects the session via `handleLateEvent`.
    private func markCompletedAndScheduleRemoval(sessionId: String, after delay: TimeInterval) {
        guard sessions[sessionId]?.status != .completed else { return }
        sessions[sessionId]?.status = .completed
        onEvent.send(.sessionEnded(sessionId))
        scheduleRemoval(sessionId: sessionId, after: delay)
    }

    private func scheduleRemoval(sessionId: String, after delay: TimeInterval) {
        pendingRemovals[sessionId]?.cancel()
        pendingRemovals[sessionId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard let self else { return }
                self.pendingRemovals.removeValue(forKey: sessionId)
                // Re-check completed — a brand-new session with the same id
                // Resumed or reused sessions will have status
                // reset to .idle / .thinking by ensureSession + handleMessage.
                if self.sessions[sessionId]?.status == .completed {
                    self.sessions.removeValue(forKey: sessionId)
                }
            }
        }
    }

    private func cancelPendingRemoval(sessionId: String) {
        pendingRemovals[sessionId]?.cancel()
        pendingRemovals.removeValue(forKey: sessionId)
    }

    /// Returns the start time of the process at `pid`, or nil if it's
    /// unreadable. Used to detect PID reuse alongside `kill(pid, 0)`.
    private static func processStartTime(pid: pid_t) -> timeval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = withUnsafeMutablePointer(to: &mib[0]) { mibPtr in
            sysctl(mibPtr, 4, &info, &size, nil, 0)
        }
        if result == 0 {
            return info.kp_proc.p_starttime
        }
        return nil
    }

    var activeSessions: [String: Session] {
        sessions.filter { _, session in
            switch session.status {
            case .thinking, .toolUse, .waitingPermission, .error:
                return true
            case .idle, .completed:
                return false
            }
        }
    }

    /// The canonical events the store understands. Every provider bridge
    /// normalizes its native vocabulary to one of these before sending; a
    /// a message arriving with a raw, un-normalized name bypassed our
    /// normalization and belongs to
    /// a foreign/misconfigured integration sharing the socket — drop it so it
    /// can't create phantom sessions or clobber a correctly-attributed one.
    private static let canonicalEvents: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "Notification", "SubagentStart", "SubagentStop", "PreCompact",
    ]

    func handleMessage(
        _ message: BridgeMessage,
        respond: ((BridgeResponse) -> Void)?,
        respondRaw: ((Data) -> Void)? = nil,
        origin: SessionMessageOrigin = .providerHook
    ) {
        let sessionId = message.sessionId
        guard Self.canonicalEvents.contains(message.hookEvent) else {
            Log.info("Ignoring non-canonical event '\(message.hookEvent)' from source=\(message.source ?? "?") session=\(sessionId.prefix(8))")
            return
        }

        if message.hookEvent == "Stop",
           let assistantMessage = message.assistantMessage,
           Self.isSuggestionsBlob(assistantMessage),
           sessions[sessionId]?.status == .idle {
            return
        }

        let now = Date()
        var effects: [PostCommitEffect] = []
        var session: Session
        if let existing = sessions[sessionId] {
            session = existing
            if let cwd = message.cwd, !cwd.isEmpty, session.cwdIsPlaceholder {
                session.cwd = cwd
                session.cwdIsPlaceholder = false
            }
        } else {
            session = Session(
                id: sessionId,
                cwd: message.cwd ?? "~",
                startedAt: now,
                status: .idle,
                terminalInfo: message.terminalInfo,
                source: message.source ?? "codex"
            )
            session.cwdIsPlaceholder = message.cwd == nil
            session.announced = true
            effects.append(.event(.sessionStarted(sessionId)))
        }

        if let terminalInfo = message.terminalInfo {
            session.terminalInfo = terminalInfo
        }
        if let source = message.source {
            session.source = source
        }
        if origin == .durableProviderState {
            session.isDurablyTracked = true
        }

        // A late buffered hook may arrive after we've marked a session
        // .completed and scheduled removal. Cancel the pending removal so
        // the brand-new session (for example, Codex thread reuse) isn't
        // deleted out from under us, and reset .completed back to .idle so
        // the per-event switch below can transition normally (issue #10).
        if session.status == .completed {
            cancelPendingRemoval(sessionId: sessionId)
            session.status = .idle
        }
        // Stamp activity time on every event so the collapsed notch tracks
        // whatever provider is most recently doing something.
        session.lastActivityAt = now
        let statusBefore = session.status

        // Always update effort level if present (it's on most hooks)
        if let effort = message.effortLevel {
            session.effortLevel = effort
        }
        // Stamp the model whenever the hook carries one.
        if let m = message.model, !m.isEmpty {
            session.model = m
        }
        // Always update session title if present
        if let title = message.sessionTitle, !title.isEmpty {
            session.sessionTitle = title
        }
        // Capture the agent PID — used to detect when the agent exits.
        // Also stamp its start time so PID reuse can be detected later
        // (issue #29).
        if let pid = message.agentPid, pid > 0 {
            if session.agentPid != pid {
                session.agentPid = pid
                if let start = Self.processStartTime(pid: pid_t(pid)) {
                    session.agentStartSec = Int(start.tv_sec)
                    session.agentStartUsec = Int(start.tv_usec)
                }
            }
        }

        // If a new event arrives while a permission/question is still pending,
        // the user must have answered it via the terminal — dismiss the notch.
        // Critical: capture the respond closures BEFORE clearing pending state
        // and invoke them with safe defaults so the socket fd closes and the
        // bridge unblocks. Dropping the closures without invoking them leaks
        // the fd and leaves the bridge in read() for 300s (issue #2).
        let isProgressEvent = ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"].contains(message.hookEvent)
        if isProgressEvent {
            let droppedPermission = session.pendingPermission
            let droppedQuestion = session.pendingQuestion
            if droppedPermission != nil || droppedQuestion != nil {
                session.pendingPermission = nil
                session.pendingQuestion = nil
                effects.append(.action {
                    droppedPermission?.respond(.allowOnce)
                    if let droppedQuestion, let data = BridgeResponse.deferToTerminal() {
                        droppedQuestion.respond(data)
                    }
                    Log.info("Pending resolved externally for session=\(sessionId.prefix(8)) (event=\(message.hookEvent))")
                })
                effects.append(.event(.pendingDismissedExternally(sessionId)))
            }
        }

        switch message.hookEvent {
        case "SessionStart":
            session.status = .idle
            // ensureSession already emitted .sessionStarted for first-time
            // creates. Suppress the redundant SessionStart-hook emit so
            // subscribers (sounds, metrics) see exactly one start per id
            // (issue #37).
            if !session.announced {
                session.announced = true
                effects.append(.event(.sessionStarted(sessionId)))
            }

        case "SessionEnd":
            session.status = .completed
            effects.append(.event(.sessionEnded(sessionId)))
            effects.append(.scheduleRemoval(sessionId: sessionId, delay: 5.0))

        case "UserPromptSubmit":
            let userMsg = message.userMessage ?? message.toolInput
            if let msg = userMsg {
                session.lastUserMessage = msg
                if session.firstPrompt == nil {
                    session.firstPrompt = msg
                }
            }
            session.status = .thinking
            session.currentTool = nil
            effects.append(.event(.statusChanged(sessionId, .thinking)))

        case "PreToolUse":
            let toolName = message.toolName ?? "unknown"
            session.status = .toolUse
            session.currentTool = toolName
            effects.append(.event(.toolStarted(sessionId, toolName)))

            // Codex's `request_user_input` and Hermes' `clarify` are their
            // AskUserQuestion equivalents — they fire through PreToolUse, not
            // PermissionRequest, and the hook can't substitute an answer. So we
            // mirror the question in the notch and route any click to the app/
            // terminal where the user actually answers. (The Hermes bridge has
            // already reshaped clarify's {question,choices} into the canonical
            // questions JSON.) PostToolUse dismisses it once they've answered.
            let src = message.source ?? "codex"
            let isMirroredQuestion = (src == "codex" && toolName == "request_user_input")
                || (src == "hermes" && toolName == "clarify")
            if isMirroredQuestion,
               let desc = message.toolInput,
               let parsedQuestions = Self.parseQuestion(desc) {
                session.status = .waitingPermission
                session.pendingQuestion = PendingQuestion(
                    questions: parsedQuestions,
                    respond: { [weak self] _ in
                        // Can't answer via hook — surface Codex.app so the
                        // user finishes there. PostToolUse will dismiss the
                        // notch's question view once they've answered.
                        if let session = self?.sessions[sessionId] {
                            TerminalJumper.jump(to: session)
                        }
                    }
                )
                effects.append(.event(.questionAsked(sessionId)))
            }

        case "PostToolUse":
            let toolName = message.toolName ?? "unknown"
            session.status = .thinking
            session.currentTool = nil
            session.lastToolDurationMs = message.durationMs
            // Don't update lastAssistantMessage from tool output
            effects.append(.event(.toolEnded(sessionId, toolName)))

        case "PermissionRequest":
            let toolName = message.toolName ?? "unknown"
            let description = message.toolInput

            // OpenCode question events use the canonical AskUserQuestion name.
            if toolName == "AskUserQuestion",
               let desc = description,
               let parsedQuestions = Self.parseQuestion(desc) {
                session.status = .waitingPermission
                session.pendingQuestion = PendingQuestion(
                    questions: parsedQuestions,
                    respond: { rawData in
                        Log.info("Question answered for session=\(sessionId.prefix(8))")
                        // State is already cleared by respondToQuestion() synchronously
                        respondRaw?(rawData)
                    }
                )
                effects.append(.event(.questionAsked(sessionId)))
            } else {
                session.status = .waitingPermission
                session.pendingPermission = PendingPermission(
                    toolName: toolName,
                    description: description,
                    filePath: message.toolFilePath,
                    content: message.toolContent,
                    oldString: message.toolOldString,
                    newString: message.toolNewString,
                    respond: { [weak self] action in
                        Log.info("Permission responded: \(action) for session=\(sessionId.prefix(8)), respondRaw=\(respondRaw != nil)")
                        // State is already cleared by respondToPermission() synchronously.
                        // Codex rejects `updatedPermissions`, so we
                        // persist allow-all / bypass via a TOML rules file instead
                        // and return a plain `behavior: allow`.
                        let isCodex = self?.sessions[sessionId]?.source == "codex"
                        switch action {
                        case .deny:
                            respond?(BridgeResponse.deny())
                        case .allowOnce:
                            respond?(BridgeResponse.allow())
                        case .allowAll:
                            if isCodex {
                                // For Codex, persist a prefix_rule for Bash only;
                                // non-Bash tools can't be matched against
                                // shell-command prefixes (issue #17). Either way,
                                // ack the current call with a one-shot allow.
                                let persisted = CodexPermissionRules.persistAlwaysAllow(toolName: toolName, toolInput: description)
                                if !persisted {
                                    Log.info("Codex Allow All not persisted for tool=\(toolName); allowing once")
                                }
                                respond?(BridgeResponse.allow())
                            } else if let data = BridgeResponse.allowAllForTool(toolName), respondRaw != nil {
                                Log.info("Sending allow-all response (\(data.count) bytes)")
                                respondRaw?(data)
                            } else {
                                respond?(BridgeResponse.allow())
                            }
                        case .bypass:
                            if isCodex {
                                let persisted = CodexPermissionRules.persistAlwaysAllow(toolName: toolName, toolInput: description, broad: true)
                                if !persisted {
                                    Log.info("Codex Bypass not persisted for tool=\(toolName); allowing once")
                                }
                                respond?(BridgeResponse.allow())
                            } else {
                                respond?(BridgeResponse.allow())
                            }
                        }
                    }
                )
                effects.append(.event(.permissionRequested(sessionId)))
            }

        case "Stop":
            // Codex emits its follow-up suggestions as a SEPARATE Stop whose
            // assistant_message is a raw `{"suggestions":[…]}` object — never the
            // real reply. Don't render that JSON, and if the turn already
            // finished (the real reply's Stop already fired), drop it entirely so
            // it doesn't pop a duplicate Finished card.
            if let msg = message.assistantMessage, Self.isSuggestionsBlob(msg) {
                // otherwise complete the turn but keep the prior reply (if any)
            } else if let msg = message.assistantMessage {
                session.lastAssistantMessage = msg
            }
            session.status = .idle
            session.currentTool = nil
            effects.append(.event(.statusChanged(sessionId, .idle)))

        case "Notification":
            if let msg = message.assistantMessage {
                session.lastAssistantMessage = msg
            }
            let text = message.notification ?? ""
            effects.append(.event(.notification(sessionId, text)))

        case "SubagentStart":
            session.currentTool = "Agent"
            effects.append(.event(.toolStarted(sessionId, "Agent")))

        case "SubagentStop":
            session.currentTool = nil
            effects.append(.event(.toolEnded(sessionId, "Agent")))

        case "PreCompact":
            break

        default:
            break
        }

        // Maintain the live "active timer" used by the session card. Starts when
        // we first enter an active state from idle; carries through across
        // thinking ↔ toolUse transitions; resets when we go back to idle.
        let wasActive = statusBefore == .thinking || statusBefore == .toolUse
        let isActive = session.status == .thinking || session.status == .toolUse
        if isActive && !wasActive {
            session.activeStartedAt = now
        } else if !isActive {
            session.activeStartedAt = nil
        }

        sessions[sessionId] = session

        for effect in effects {
            switch effect {
            case .event(let event):
                onEvent.send(event)
            case .action(let action):
                action()
            case .scheduleRemoval(let sessionId, let delay):
                scheduleRemoval(sessionId: sessionId, after: delay)
            }
        }
    }

    // MARK: - Question Parsing

    private static func parseQuestion(_ json: String) -> [QuestionItem]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questions = parsed["questions"] as? [[String: Any]],
              !questions.isEmpty else {
            return nil
        }

        return questions.enumerated().map { qIndex, q in
            let questionText = q["question"] as? String ?? ""
            let header = q["header"] as? String
            // Accept both common multi-select field spellings.
            let multiSelect = q["multiSelect"] as? Bool ?? q["multi"] as? Bool ?? false
            let options = (q["options"] as? [[String: Any]] ?? []).enumerated().map { oIndex, opt in
                QuestionOption(
                    id: opt["label"] as? String ?? "q\(qIndex)_o\(oIndex)",
                    label: opt["label"] as? String ?? "Option \(oIndex + 1)",
                    description: opt["description"] as? String
                )
            }
            return QuestionItem(
                id: "q\(qIndex)",
                header: header,
                question: questionText,
                options: options,
                multiSelect: multiSelect
            )
        }
    }

    /// Codex's "suggested follow-ups" arrive as an assistant_message that's a raw
    /// JSON object `{"suggestions":[{"title":…,"description":…}]}` — never a reply
    /// to show. Detect it so we don't render the JSON or pop a Finished card.
    private static func isSuggestionsBlob(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), t.contains("\"suggestions\"") else { return false }
        guard let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["suggestions"] != nil
    }

    func respondToPermission(sessionId: String, action: PermissionAction) {
        guard let pending = sessions[sessionId]?.pendingPermission else { return }
        // Clear immediately so nextPendingPermission() won't find it again
        sessions[sessionId]?.pendingPermission = nil
        sessions[sessionId]?.status = .thinking
        pending.respond(action)
        onEvent.send(.permissionResponded(sessionId, action != .deny))
    }

    /// Returns the session ID of the next session with a pending permission,
    /// ordered by enqueue time (oldest first) for deterministic FIFO across
    /// arbitrary dictionary iteration (issue #6).
    func nextPendingPermission() -> String? {
        sessions.values
            .compactMap { s -> (id: String, at: Date)? in
                guard let p = s.pendingPermission else { return nil }
                return (s.id, p.requestedAt)
            }
            .min(by: { $0.at < $1.at })?.id
    }

    /// Returns the session ID of the next session with a pending question,
    /// ordered by enqueue time (oldest first).
    func nextPendingQuestion(excluding excludedSessionIDs: Set<String> = []) -> String? {
        sessions.values
            .compactMap { s -> (id: String, at: Date)? in
                guard !excludedSessionIDs.contains(s.id) else { return nil }
                guard let q = s.pendingQuestion else { return nil }
                return (s.id, q.requestedAt)
            }
            .min(by: { $0.at < $1.at })?.id
    }

    /// Defer the pending question to the provider's terminal or app.
    func deferQuestionToTerminal(sessionId: String) {
        guard let q = sessions[sessionId]?.pendingQuestion else { return }
        sessions[sessionId]?.pendingQuestion = nil
        sessions[sessionId]?.status = .thinking
        let data = BridgeResponse.deferToTerminal()
        if let data { q.respond(data) }
        if let session = sessions[sessionId] {
            TerminalJumper.jump(to: session)
        }
    }

    /// Called from QuestionView with answers keyed by `QuestionItem.id`.
    /// Multi-select answers come as comma-joined option labels — matches
    /// the canonical provider question format.
    func respondToQuestion(sessionId: String, answersByQuestionId: [String: String]) {
        guard let q = sessions[sessionId]?.pendingQuestion else { return }

        // BridgeResponse.allowWithAnswers expects answers keyed by the
        // question text, so translate.
        var answersByText: [String: String] = [:]
        for question in q.questions {
            if let v = answersByQuestionId[question.id] {
                answersByText[question.question] = v
            }
        }

        Log.info("Question answered for session=\(sessionId.prefix(8)), count=\(answersByText.count)")

        // Clear immediately so nextPendingQuestion() won't find it again
        sessions[sessionId]?.pendingQuestion = nil
        sessions[sessionId]?.status = .thinking

        if let data = BridgeResponse.allowWithAnswers(questions: q.questions, answers: answersByText) {
            q.respond(data)
        }
    }
}
