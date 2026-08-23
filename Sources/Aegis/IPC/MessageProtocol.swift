import Foundation
import AegisBridgeSupport

/// Incoming message from the bridge CLI.
struct BridgeMessage: Codable {
    let sessionId: String
    let hookEvent: String
    let cwd: String?
    let toolName: String?
    let toolInput: String?
    let notification: String?
    let env: [String: String]?
    let userMessage: String?
    let assistantMessage: String?
    let effortLevel: String?
    let durationMs: Int?
    /// Structured provider result. Nil means the provider did not expose a
    /// trustworthy outcome; callers must not infer failure from output text.
    let toolOutcome: ToolOutcome?
    let toolFilePath: String?
    let toolContent: String?
    let toolOldString: String?
    let toolNewString: String?
    let sessionTitle: String?
    /// Identifier of the AI provider that fired this hook.
    /// Defaults to "codex" if the bridge doesn't stamp this field.
    let source: String?
    /// PID of the agent process that spawned the bridge (getppid in the bridge).
    /// Used to detect when an agent exits without firing SessionEnd.
    let agentPid: Int?
    /// Model name the agent is using, captured from the hook payload.
    let model: String?

    init(
        sessionId: String,
        hookEvent: String,
        cwd: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        notification: String? = nil,
        env: [String: String]? = nil,
        userMessage: String? = nil,
        assistantMessage: String? = nil,
        effortLevel: String? = nil,
        durationMs: Int? = nil,
        toolOutcome: ToolOutcome? = nil,
        toolFilePath: String? = nil,
        toolContent: String? = nil,
        toolOldString: String? = nil,
        toolNewString: String? = nil,
        sessionTitle: String? = nil,
        source: String? = nil,
        agentPid: Int? = nil,
        model: String? = nil
    ) {
        self.sessionId = sessionId
        self.hookEvent = hookEvent
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.notification = notification
        self.env = env
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.effortLevel = effortLevel
        self.durationMs = durationMs
        self.toolOutcome = toolOutcome
        self.toolFilePath = toolFilePath
        self.toolContent = toolContent
        self.toolOldString = toolOldString
        self.toolNewString = toolNewString
        self.sessionTitle = sessionTitle
        self.source = source
        self.agentPid = agentPid
        self.model = model
    }

    var terminalInfo: TerminalInfo? {
        guard let env else { return nil }
        return TerminalInfo(
            itermSessionId: env["ITERM_SESSION_ID"],
            termSessionId: env["TERM_SESSION_ID"],
            tmuxPane: env["TMUX_PANE"],
            tty: env["_TTY"],
            appBundleId: env["_TERM_BUNDLE_ID"],
            kittyWindowId: env["KITTY_WINDOW_ID"],
            weztermSocket: env["WEZTERM_UNIX_SOCKET"]
        )
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEvent = "hook_event"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case notification
        case env = "_env"
        case userMessage = "user_message"
        case assistantMessage = "assistant_message"
        case effortLevel = "effort_level"
        case durationMs = "duration_ms"
        case toolOutcome = "tool_outcome"
        case toolFilePath = "tool_file_path"
        case toolContent = "tool_content"
        case toolOldString = "tool_old_string"
        case toolNewString = "tool_new_string"
        case sessionTitle = "session_title"
        case source
        case agentPid = "agent_pid"
        case model
    }
}

/// Response sent back to the bridge (for permission requests).
/// Canonical permission response returned through the bridge.
struct BridgeResponse: Codable {
    let hookSpecificOutput: HookSpecificOutput

    struct HookSpecificOutput: Codable {
        let hookEventName: String
        let decision: Decision
    }

    struct Decision: Codable {
        let behavior: String  // "allow" or "deny"
    }

    static func allow() -> BridgeResponse {
        BridgeResponse(
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: "PermissionRequest",
                decision: Decision(behavior: "allow")
            )
        )
    }

    static func deny() -> BridgeResponse {
        BridgeResponse(
            hookSpecificOutput: HookSpecificOutput(
                hookEventName: "PermissionRequest",
                decision: Decision(behavior: "deny")
            )
        )
    }

    /// Allow and add a permission rule for this specific tool (session-scoped)
    static func allowAllForTool(_ toolName: String) -> Data? {
        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "updatedPermissions": [
                        [
                            "type": "addRules",
                            "rules": [["toolName": toolName]],
                            "behavior": "allow",
                            "destination": "session",
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try? JSONSerialization.data(withJSONObject: response)
    }

    /// Defer to the provider's own prompt in the terminal or app.
    /// Used when user clicks "Answer in terminal" on a question.
    static func deferToTerminal() -> Data? {
        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "ask",
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try? JSONSerialization.data(withJSONObject: response)
    }

    /// Build a response for AskUserQuestion with the user's answers.
    static func allowWithAnswers(questions: [QuestionItem], answers: [String: String]) -> Data? {
        // Build the response with updatedInput containing answers and original questions
        var questionsArray: [[String: Any]] = []
        for q in questions {
            var qDict: [String: Any] = [
                "question": q.question,
                "multiSelect": q.multiSelect,
            ]
            if let header = q.header { qDict["header"] = header }
            qDict["options"] = q.options.map { opt in
                var d: [String: Any] = ["label": opt.label]
                if let desc = opt.description { d["description"] = desc }
                return d
            }
            questionsArray.append(qDict)
        }

        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "updatedInput": [
                        "questions": questionsArray,
                        "answers": answers,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try? JSONSerialization.data(withJSONObject: response)
    }
}
