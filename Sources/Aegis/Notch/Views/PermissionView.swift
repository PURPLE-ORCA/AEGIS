import SwiftUI

struct PermissionView: View {
    let session: Session
    let permission: PendingPermission
    let onRespond: (PermissionAction) -> Void
    @ObservedObject var rateLimitStore: RateLimitStore
    @ObservedObject var settingsStore: SettingsStore
    let onOpenSettings: () -> Void
    let onToggleExpand: (Bool) -> Void

    @Environment(\.notchTheme) private var theme
    @State private var isExpanded = false
    @State private var preview: PermissionPreviewData?

    private var previewInput: PermissionPreviewInput? {
        PermissionPreviewInput(permission: permission)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar: rate limits + sound + gear
            HStack(spacing: 10) {
                RateLimitBar(rateLimitStore: rateLimitStore, provider: session.provider)
                Spacer()
                Button(action: { settingsStore.soundEnabled.toggle() }) {
                    Image(systemName: settingsStore.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(settingsStore.soundEnabled ? 0.6 : 0.3))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settingsStore.soundEnabled ? "Mute sounds" : "Unmute sounds")
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open settings")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Session header + Needs approval badge
            HStack(spacing: 8) {
                SessionMascot(status: .waitingPermission, size: 18, provider: session.provider)
                Text(session.displayName)
                    .font(theme.font(size: 13, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("Needs approval")
                        .font(theme.font(size: 9, weight: .semibold))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .notchPill(theme, fill: .orange.opacity(0.15))
                Spacer()
                if let effort = session.effortLevel {
                    EffortBadge(level: effort)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Tool pill + subtitle (color per tool type)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: iconForTool(permission.toolName))
                        .font(.system(size: 10))
                    Text(permission.toolName)
                        .font(theme.font(size: 11, weight: .bold))
                }
                .foregroundColor(colorForTool(permission.toolName))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .notchPill(theme, fill: colorForTool(permission.toolName).opacity(0.15))
                Text(subtitleForTool(permission.toolName))
                    .font(theme.font(size: 11))
                    .foregroundColor(.white.opacity(0.65))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            // File path / URL / pattern row (if available)
            if let path = permission.filePath {
                HStack(spacing: 7) {
                    Image(systemName: pathRowIcon(permission.toolName))
                        .font(.system(size: 11))
                        .foregroundColor(colorForTool(permission.toolName).opacity(0.8))
                    Text(pathRowLabel(permission.toolName))
                        .font(theme.font(size: 9, weight: .bold))
                        .foregroundColor(theme.wellForeground.opacity(0.5))
                        .kerning(0.5)
                    Text(shortenPath(path))
                        .font(theme.font(size: 11))
                        .foregroundColor(theme.wellForeground.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notchBox(theme)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // Content preview (Write content, Edit diff, or command/description)
            if let preview {
                VStack(spacing: 0) {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 9))
                                .foregroundColor(theme.wellForeground.opacity(0.5))
                            Text(preview.label)
                                .font(theme.font(size: 9, weight: .bold))
                                .foregroundColor(theme.wellForeground.opacity(0.5))
                                .kerning(0.5)
                        }
                        Spacer()
                        Text(preview.metric)
                            .font(theme.font(size: 9))
                            .foregroundColor(theme.wellForeground.opacity(0.4))
                        Button(action: {
                            isExpanded.toggle()
                            onToggleExpand(isExpanded)
                        }) {
                            Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.wellForeground.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "Collapse" : "Expand content")
                        .accessibilityLabel(isExpanded ? "Collapse content" : "Expand content")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: theme.boxRadius, topTrailingRadius: theme.boxRadius)
                            .fill(theme.boxFill)
                    )

                    ScrollView(showsIndicators: false) {
                        Text(preview.attributed)
                            .font(theme.font(size: 11))
                            .foregroundColor(theme.wellForeground.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: isExpanded ? 400 : 220)
                    .background(
                        UnevenRoundedRectangle(bottomLeadingRadius: theme.boxRadius, bottomTrailingRadius: theme.boxRadius)
                            .fill(theme.boxFill)
                    )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: theme.boxRadius, style: .continuous)
                        .strokeBorder(theme.boxStroke, lineWidth: theme.strokeWidth)
                )
                .padding(.horizontal, 14)
            } else if previewInput != nil {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.wellForeground.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .notchBox(theme)
                    .padding(.horizontal, 14)
            }

            Spacer(minLength: 12)

            // Provider-aware action buttons — only what the tool's hook supports.
            HStack(spacing: 6) {
                ForEach(session.provider.permissionActions, id: \.self) { action in
                    let b = Self.actionConfig(for: action, provider: session.provider)
                    ActionButton(icon: b.icon, label: b.label, hint: "", color: b.color) {
                        onRespond(action)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: PermissionPreviewTaskID(input: previewInput, lightWells: theme.lightWells)) {
            guard let input = previewInput else {
                preview = nil
                return
            }
            let lightWells = theme.lightWells
            let rendered = await Task.detached(priority: .userInitiated) {
                PermissionPreviewRenderer.render(input, lightWells: lightWells)
            }.value
            guard !Task.isCancelled else { return }
            preview = rendered
        }
    }

    /// Icon, label, and color for each supported permission action.
    static func actionConfig(for action: PermissionAction, provider: AIProvider) -> (icon: String, label: String, color: Color) {
        switch action {
        case .deny:       return ("xmark", "Deny", Color(red: 0.92, green: 0.55, blue: 0.55))
        case .allowOnce:  return ("checkmark", "Allow Once", Color(red: 0.45, green: 0.78, blue: 0.86))
        case .allowAll:   return ("checkmark.circle", "Allow All", Color(red: 0.55, green: 0.78, blue: 0.55))
        case .bypass:     return ("bolt", "Bypass", Color(red: 0.70, green: 0.62, blue: 0.92))
        }
    }

    private func subtitleForTool(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash": return "wants to execute a shell command"
        case "read": return "wants to read a file"
        case "write": return "wants to write a file"
        case "edit", "multiedit": return "wants to edit a file"
        case "glob": return "wants to search for files"
        case "grep": return "wants to search code"
        case "webfetch": return "wants to fetch an external URL"
        case "websearch": return "wants to search the web"
        case "task", "agent": return "wants to run a subagent"
        default: return "wants to run \(tool)"
        }
    }

    private func colorForTool(_ tool: String) -> Color {
        switch tool.lowercased() {
        case "bash", "write": return Color(red: 1.0, green: 0.42, blue: 0.42)        // red
        case "edit", "multiedit": return Color(red: 1.0, green: 0.72, blue: 0.30)    // orange
        case "read", "webfetch": return Color(red: 0.30, green: 0.80, blue: 1.0)     // cyan
        case "grep", "glob", "websearch": return Color(red: 0.65, green: 0.55, blue: 0.98)  // purple
        case "task", "agent": return Color(red: 0.45, green: 0.78, blue: 0.45)       // green
        default: return Color(red: 1.0, green: 0.42, blue: 0.42)                     // red default
        }
    }

    private func iconForTool(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash": return "terminal.fill"
        case "read": return "doc.text.fill"
        case "write": return "doc.badge.plus"
        case "edit", "multiedit": return "pencil"
        case "glob", "grep": return "magnifyingglass"
        case "webfetch": return "globe"
        case "websearch": return "magnifyingglass.circle"
        default: return "wrench.fill"
        }
    }

    private func pathRowLabel(_ tool: String) -> String {
        switch tool.lowercased() {
        case "webfetch": return "url"
        case "grep", "glob": return "pattern"
        default: return "path"
        }
    }

    private func pathRowIcon(_ tool: String) -> String {
        switch tool.lowercased() {
        case "webfetch": return "link"
        case "grep", "glob": return "magnifyingglass"
        default: return "doc.text"
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

}

struct PermissionPreviewInput: Hashable, Sendable {
    let toolName: String
    let filePath: String?
    let content: String?
    let description: String?
    let oldString: String?
    let newString: String?

    init?(permission: PendingPermission) {
        let hasEdit = permission.oldString != nil && permission.newString != nil
        let hasContent = permission.content?.isEmpty == false
        let hasStandaloneDescription = permission.filePath == nil && permission.description?.isEmpty == false
        guard hasEdit || hasContent || hasStandaloneDescription else { return nil }

        toolName = permission.toolName
        filePath = permission.filePath
        content = permission.content
        description = permission.description
        oldString = permission.oldString
        newString = permission.newString
    }
}

struct PermissionPreviewTaskID: Hashable {
    let input: PermissionPreviewInput?
    let lightWells: Bool
}

struct PermissionPreviewData: Sendable {
    let label: String
    let metric: String
    let attributed: AttributedString
}

enum PermissionPreviewRenderer {
    static func render(
        _ input: PermissionPreviewInput,
        lightWells: Bool
    ) -> PermissionPreviewData? {
        let syntaxTheme: SyntaxHighlighter.Theme = lightWells ? .light : .dark

        if let oldString = input.oldString, let newString = input.newString {
            let newLines = newString.components(separatedBy: "\n").count
            let oldLines = oldString.components(separatedBy: "\n").count
            let startLine = input.filePath.map {
                SyntaxHighlighter.findStartLine(filePath: $0, needle: oldString)
            } ?? 1
            return PermissionPreviewData(
                label: "edit",
                metric: "−\(oldLines) +\(newLines) lines",
                attributed: SyntaxHighlighter.diff(
                    old: oldString,
                    new: newString,
                    theme: syntaxTheme,
                    startLine: startLine
                )
            )
        }

        if let content = input.content, !content.isEmpty {
            let isWebFetch = input.toolName.lowercased() == "webfetch"
            let lines = content.components(separatedBy: "\n").count
            return PermissionPreviewData(
                label: isWebFetch ? "prompt" : "content",
                metric: isWebFetch
                    ? ""
                    : "\(lines) line\(lines == 1 ? "" : "s") · \(formatBytes(content.utf8.count))",
                attributed: isWebFetch
                    ? AttributedString(content)
                    : SyntaxHighlighter.highlight(
                        content,
                        theme: syntaxTheme,
                        withLineNumbers: true,
                        startLine: 1
                    )
            )
        }

        if let description = input.description, !description.isEmpty, input.filePath == nil {
            let isBash = input.toolName.lowercased() == "bash"
            return PermissionPreviewData(
                label: isBash ? "command" : "input",
                metric: "",
                attributed: isBash
                    ? SyntaxHighlighter.highlight(description, theme: syntaxTheme)
                    : AttributedString(description)
            )
        }

        return nil
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_024 {
            return String(format: "%.1fkB", Double(bytes) / 1_024.0)
        }
        return "\(bytes)B"
    }
}

struct ActionButton: View {
    let icon: String
    let label: String
    let hint: String
    let color: Color
    let action: () -> Void

    @Environment(\.notchTheme) private var theme

    var body: some View {
        let ink = theme.buttonInk(color)
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(theme.font(size: 11, weight: .semibold))
            }
            .foregroundColor(ink.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .notchButton(theme, fill: ink.fill, stroke: ink.stroke)
        }
        .buttonStyle(.plain)
    }
}
