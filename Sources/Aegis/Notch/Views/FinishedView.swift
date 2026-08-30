import SwiftUI

struct FinishedView: View {
    let session: Session
    @ObservedObject var rateLimitStore: RateLimitStore
    @ObservedObject var settingsStore: SettingsStore
    let onOpenSettings: () -> Void
    let onToggleExpand: (Bool) -> Void
    let onContentHeightChange: (CGFloat) -> Void

    @Environment(\.notchTheme) private var theme
    @State private var isExpanded = true
    @State private var measuredReplyHeight = FinishedReplyWindowLayout.initialReplyHeight

    var body: some View {
        Group {
            if isExpanded {
                details
                    .transition(.opacity)
            } else {
                compactMessage
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onPreferenceChange(FinishedReplyContentHeightKey.self) { height in
            guard isExpanded, height > 0,
                  abs(measuredReplyHeight - height) > 0.5 else { return }
            measuredReplyHeight = height
        }
        .onPreferenceChange(FinishedDetailsHeightKey.self) { height in
            guard isExpanded, height > 0 else { return }
            onContentHeightChange(FinishedReplyWindowLayout.fittedHeight(height))
        }
    }

    /// The user can collapse the automatic full-reply presentation into this
    /// glanceable card without losing the session jump action.
    private var compactMessage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: NotchViewModel.notchOverlap + 8)

            HStack(spacing: 0) {
                Button(action: { TerminalJumper.jump(to: session) }) {
                    HStack(alignment: .center, spacing: 12) {
                        SessionMascot(
                            status: .idle,
                            size: 24,
                            animated: false,
                            provider: session.provider
                        )

                        Text(MarkdownText.inline(FinishedMessagePresentation.preview(for: session)))
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundColor(theme.cardForeground.opacity(0.90))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(session.provider.displayName) session")
                .accessibilityValue(FinishedMessagePresentation.preview(for: session))
                .accessibilityHint("Opens this session in its app or terminal")

                Button(action: { setExpanded(true) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.cardForeground.opacity(0.58))
                        .frame(width: 40, height: 50)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show full reply")
                .accessibilityHint("Expands the finished session details")
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .notchCard(theme, tint: session.provider.accentColor)
            .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RateLimitBar(rateLimitStore: rateLimitStore, provider: session.provider)
                Spacer()
                Button(action: { settingsStore.soundEnabled.toggle() }) {
                    Image(systemName: settingsStore.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(settingsStore.soundEnabled ? 0.6 : 0.3))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settingsStore.soundEnabled ? "Mute sounds" : "Unmute sounds")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open settings")

                Button(action: { setExpanded(false) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse message")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Button(action: openSession) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        SessionMascot(status: .idle, size: 18, provider: session.provider)
                        Text(session.displayName)
                            .font(theme.font(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Finished in \(session.durationText)")
                                .font(theme.font(size: 9, weight: .semibold))
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .notchPill(theme, fill: .green.opacity(0.18))
                        Spacer()
                        if let effort = session.effortLevel {
                            EffortBadge(level: effort)
                        }
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    if let userMsg = session.lastUserMessage {
                        HStack(spacing: 7) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 11))
                                .foregroundColor(theme.wellForeground.opacity(0.65))
                            Text("you")
                                .font(theme.font(size: 9, weight: .bold))
                                .foregroundColor(theme.wellForeground.opacity(0.5))
                                .kerning(0.5)
                            Text(userMsg)
                                .font(theme.font(size: 11))
                                .foregroundColor(theme.wellForeground.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .notchBox(theme)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }

                    if let reply = session.lastAssistantMessage, !reply.isEmpty {
                        ScrollView(showsIndicators: false) {
                            MarkdownText(
                                text: reply,
                                color: theme.wellForeground.opacity(0.85),
                                codeBackground: theme.lightWells ? Color.black.opacity(0.07) : Color.black.opacity(0.35)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: FinishedReplyContentHeightKey.self,
                                        value: geometry.size.height
                                    )
                                }
                            }
                        }
                        .frame(height: FinishedReplyWindowLayout.replyViewportHeight(
                            contentHeight: measuredReplyHeight
                        ))
                        .background(
                            RoundedRectangle(cornerRadius: theme.boxRadius, style: .continuous)
                                .fill(theme.boxFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.boxRadius, style: .continuous)
                                .strokeBorder(theme.boxStroke, lineWidth: 1)
                        )
                        .padding(.horizontal, 14)
                    }

                    Color.clear.frame(height: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(session.provider.displayName) session \(session.displayName)")
            .accessibilityValue(FinishedMessagePresentation.preview(for: session))
            .accessibilityHint("Opens this session in its app or terminal")
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: FinishedDetailsHeightKey.self,
                    value: geometry.size.height
                )
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.easeOut(duration: 0.18)) {
            isExpanded = expanded
        }
        onToggleExpand(expanded)
    }

    private func openSession() {
        TerminalJumper.jump(to: session)
    }

}

enum FinishedReplyWindowLayout {
    static let initialReplyHeight: CGFloat = 44
    static let minimumReplyHeight: CGFloat = 28
    static let maximumReplyHeight: CGFloat = 360
    static let minimumWindowHeight: CGFloat = 104
    static let maximumWindowHeight: CGFloat = 560

    static func replyViewportHeight(contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, minimumReplyHeight), maximumReplyHeight)
    }

    static func fittedHeight(_ contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, minimumWindowHeight), maximumWindowHeight)
    }
}

private struct FinishedReplyContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FinishedDetailsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum FinishedMessagePresentation {
    static func preview(for session: Session, maximumLength: Int = 280) -> String {
        SessionMessagePresentation.preview(
            session.lastAssistantMessage,
            fallback: "\(session.displayName) finished",
            maximumLength: maximumLength
        )
    }
}
