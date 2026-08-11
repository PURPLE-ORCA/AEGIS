import SwiftUI

struct FinishedView: View {
    let session: Session
    let onDismiss: () -> Void
    @ObservedObject var rateLimitStore: RateLimitStore
    @ObservedObject var settingsStore: SettingsStore
    let onOpenSettings: () -> Void
    let onToggleExpand: (Bool) -> Void

    @Environment(\.notchTheme) private var theme
    @State private var isExpanded = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The completion popup starts as one glanceable object: agent + reply.
    /// Everything else is deliberately deferred until the user asks for it.
    private var compactMessage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: NotchViewModel.notchOverlap + 8)

            Button(action: { setExpanded(true) }) {
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
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .notchCard(theme, tint: session.provider.accentColor)
                .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message from \(session.provider.displayName)")
            .accessibilityValue(FinishedMessagePresentation.preview(for: session))
            .accessibilityHint("Shows the full reply and session details")
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
                VStack(spacing: 0) {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 9))
                                .foregroundColor(.green.opacity(0.7))
                            Text("reply")
                                .font(theme.font(size: 9, weight: .bold))
                                .foregroundColor(theme.wellForeground.opacity(0.5))
                                .kerning(0.5)
                        }
                        Spacer()
                        Text(replyMetric(reply))
                            .font(theme.font(size: 9))
                            .foregroundColor(theme.wellForeground.opacity(0.4))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: theme.boxRadius, topTrailingRadius: theme.boxRadius)
                            .fill(theme.boxFill)
                    )

                    ScrollView(showsIndicators: false) {
                        MarkdownText(
                            text: reply,
                            color: theme.wellForeground.opacity(0.85),
                            codeBackground: theme.lightWells ? Color.black.opacity(0.07) : Color.black.opacity(0.35)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxHeight: 360)
                    .background(
                        UnevenRoundedRectangle(bottomLeadingRadius: theme.boxRadius, bottomTrailingRadius: theme.boxRadius)
                            .fill(theme.boxFill)
                    )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: theme.boxRadius, style: .continuous)
                        .strokeBorder(theme.boxStroke, lineWidth: 1)
                )
                .padding(.horizontal, 14)
            }

            Spacer(minLength: 10)

            let dismissInk = theme.buttonInk(.green)
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Dismiss")
                        .font(theme.font(size: 11, weight: .semibold))
                }
                .foregroundColor(dismissInk.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .notchButton(theme, fill: dismissInk.fill, stroke: dismissInk.stroke)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.easeOut(duration: 0.18)) {
            isExpanded = expanded
        }
        onToggleExpand(expanded)
    }

    private func replyMetric(_ reply: String) -> String {
        let lines = reply.components(separatedBy: "\n").count
        let bytes = reply.utf8.count
        let lineLabel = "\(lines) line\(lines == 1 ? "" : "s")"
        let byteLabel = bytes >= 1024 ? String(format: "%.1fkB", Double(bytes) / 1024.0) : "\(bytes)B"
        return "\(lineLabel) · \(byteLabel)"
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
