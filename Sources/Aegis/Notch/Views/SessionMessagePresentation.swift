import Foundation

enum SessionMessagePresentation {
    static func preview(
        _ message: String?,
        fallback: String,
        maximumLength: Int = 280
    ) -> String {
        let limit = max(1, maximumLength)
        let flattened = message?
            .replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ") ?? ""

        let resolved = flattened.isEmpty ? fallback : flattened
        guard resolved.count > limit else { return resolved }
        return String(resolved.prefix(limit - 1)) + "…"
    }
}

enum SessionCardPresentation {
    static func compactTitle(for session: Session, maximumLength: Int = 80) -> String {
        let title = [session.lastUserMessage, session.sessionTitle, session.firstPrompt]
            .compactMap { value -> String? in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else { return nil }
                return trimmed
            }
            .first

        return SessionMessagePresentation.preview(
            title,
            fallback: "Untitled session",
            maximumLength: maximumLength
        )
    }

    static func detail(for session: Session, maximumLength: Int = 400) -> String {
        switch session.status {
        case .toolUse:
            return SessionMessagePresentation.preview(
                session.activitySummary ?? session.currentTool.map(SessionActivitySummary.toolLabel) ?? session.lastAssistantMessage,
                fallback: "Working",
                maximumLength: maximumLength
            )
        case .thinking:
            return SessionMessagePresentation.preview(
                session.activitySummary ?? session.lastAssistantMessage,
                fallback: "Thinking…",
                maximumLength: maximumLength
            )
        case .waitingPermission:
            let tool = session.pendingPermission?.toolName ?? session.currentTool
            let message = tool.map { "Needs approval to use \($0)" }
            return SessionMessagePresentation.preview(
                message,
                fallback: "Needs your approval",
                maximumLength: maximumLength
            )
        case .error:
            return SessionMessagePresentation.preview(
                session.lastAssistantMessage,
                fallback: "\(session.displayName) ran into an error",
                maximumLength: maximumLength
            )
        case .idle, .completed:
            return SessionMessagePresentation.preview(
                session.lastAssistantMessage,
                fallback: "Ready",
                maximumLength: maximumLength
            )
        }
    }
}
