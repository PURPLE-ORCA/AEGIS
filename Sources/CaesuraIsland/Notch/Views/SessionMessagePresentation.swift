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
    static func preview(for session: Session, maximumLength: Int = 280) -> String {
        switch session.status {
        case .thinking:
            return previewTask(
                for: session,
                prefix: "Working on",
                fallback: "Working on \(session.displayName)",
                maximumLength: maximumLength
            )
        case .toolUse:
            if let tool = session.currentTool?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tool.isEmpty {
                return SessionMessagePresentation.preview(
                    "Using \(tool)",
                    fallback: "Working on \(session.displayName)",
                    maximumLength: maximumLength
                )
            }
            return previewTask(
                for: session,
                prefix: "Working on",
                fallback: "Working on \(session.displayName)",
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
            let fallback = preferredTask(for: session) ?? "\(session.displayName) is ready"
            return SessionMessagePresentation.preview(
                session.lastAssistantMessage,
                fallback: fallback,
                maximumLength: maximumLength
            )
        }
    }

    private static func previewTask(
        for session: Session,
        prefix: String,
        fallback: String,
        maximumLength: Int
    ) -> String {
        let message = preferredTask(for: session).map { "\(prefix) \($0)" }
        return SessionMessagePresentation.preview(
            message,
            fallback: fallback,
            maximumLength: maximumLength
        )
    }

    private static func preferredTask(for session: Session) -> String? {
        [session.lastUserMessage, session.firstPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}
