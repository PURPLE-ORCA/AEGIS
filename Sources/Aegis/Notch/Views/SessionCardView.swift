import SwiftUI

struct SessionCardView: View {
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    var onDone: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isPointerHovering = false
    @State private var hoverExpansionTask: Task<Void, Never>?
    @State private var detailContentHeight: CGFloat = 0

    private var showsDetails: Bool {
        isHovering
    }

    private var detailPresentation: SessionCardDetailPresentation {
        .resolve(measuredHeight: detailContentHeight, isExpanded: showsDetails)
    }

    private var isActive: Bool {
        session.status == .thinking || session.status == .toolUse
    }

    private var morphAnimation: Animation {
        reduceMotion ? NotchMotion.reducedSessionCard : NotchMotion.sessionCardMorph
    }

    private var statusAccent: Color {
        switch session.status {
        case .thinking, .toolUse: return .cyan
        case .idle, .completed: return .green
        case .waitingPermission: return .orange
        case .error: return .red
        }
    }

    /// The colour the card itself is tinted with. Most themes use the status
    /// colour; Pixel/Brutalist override the normal thinking/idle states with
    /// fixed mockup hues (terracotta / sky) but keep error + waiting semantic.
    private var cardTint: Color {
        switch session.status {
        case .thinking, .toolUse: return theme.cardHueActive ?? statusAccent
        case .idle, .completed:   return theme.cardHueIdle ?? statusAccent
        case .waitingPermission, .error: return statusAccent
        }
    }

    /// Web-Slinger uses suit red for *thinking*, so a red error card would be
    /// indistinguishable from a working one. `cardInkError` swaps it for the
    /// black symbiote treatment. Every other theme leaves this nil.
    private var cardInk: NotchCardInk? {
        session.status == .error ? theme.cardInkError : nil
    }

    var body: some View {
        Button {
            TerminalJumper.jump(to: session)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                compactMessage

                if detailPresentation.keepsContentMounted {
                    detailContent
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: SessionCardDetailHeightKey.self,
                                    value: geometry.size.height
                                )
                            }
                        }
                        .frame(height: detailPresentation.height, alignment: .top)
                        .opacity(detailPresentation.opacity)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .notchCard(theme, tint: cardTint, active: isActive, ink: cardInk)
            .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(
            "Open \(session.provider.displayName) session \(SessionCardPresentation.compactTitle(for: session))"
        )
        .accessibilityValue(SessionCardPresentation.detail(for: session))
        .accessibilityHint("Opens this session in its app or terminal when activated.")
        .onPreferenceChange(SessionCardDetailHeightKey.self) { height in
            guard height > 0, abs(detailContentHeight - height) > 0.5 else { return }
            detailContentHeight = height
        }
        .onHover { hovering in
            isPointerHovering = hovering
            hoverExpansionTask?.cancel()

            let delay = hovering
                ? NotchMotion.sessionCardHoverDelay
                : NotchMotion.sessionCardHoverExitGrace
            hoverExpansionTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, isPointerHovering == hovering else { return }

                withAnimation(morphAnimation) {
                    isHovering = hovering
                }
                hoverExpansionTask = nil
            }
        }
        .onDisappear {
            hoverExpansionTask?.cancel()
            hoverExpansionTask = nil
        }
    }

    private var compactMessage: some View {
        HStack(alignment: .center, spacing: 12) {
            SessionMascot(
                status: session.status,
                size: 24,
                animated: isActive,
                provider: session.provider
            )

            Text(SessionCardPresentation.compactTitle(for: session))
                .font(theme.font(size: 12, weight: .medium))
                .foregroundColor(theme.cardForeground.opacity(0.90))
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            compactStatusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    }

    private var detailContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(MarkdownText.inline(SessionCardPresentation.detail(for: session)))
                .font(theme.font(size: 11))
                .foregroundColor(theme.cardForeground.opacity(0.75))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let model = session.shortModelName {
                Text(model)
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundColor(theme.cardForeground.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 1)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var compactStatusBadge: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(compactStatusText)
                .font(theme.font(size: 10, weight: .bold))
                .foregroundColor(statusAccent)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .notchPill(theme, fill: theme.chipFill(statusAccent.opacity(0.15)))
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.status {
        case .thinking, .toolUse:
            AnimatedSparkle(color: statusAccent)
        case .idle, .completed:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10))
                .foregroundColor(statusAccent)
        case .waitingPermission:
            Image(systemName: "lock")
                .font(.system(size: 10))
                .foregroundColor(statusAccent)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(statusAccent)
        }
    }

    private var compactStatusText: String {
        switch session.status {
        case .thinking, .toolUse: return "Thinking..."
        case .idle, .completed: return "Idle"
        case .waitingPermission: return "Needs approval"
        case .error: return "Error"
        }
    }
}

private struct SessionCardDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Pulsing/rotating sparkle used as the "thinking" indicator on the session card.
struct AnimatedSparkle: View {
    let color: Color
    @State private var phase = 0

    // Same extremes as the old smooth pulse (0.85↔1.25, 0.6↔1.0, ±18°), but as
    // 4 discrete frames — matches the pixel-art mascots' stepped motion.
    private static let scales: [CGFloat] = [0.85, 1.05, 1.25, 1.05]
    private static let opacities: [Double] = [0.6, 0.8, 1.0, 0.8]
    private static let angles: [Double] = [-18, 0, 18, 0]

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 10))
            .foregroundColor(color)
            .scaleEffect(Self.scales[phase])
            .opacity(Self.opacities[phase])
            .rotationEffect(.degrees(Self.angles[phase]))
            .onReceive(mascotAnimationClock) { _ in
                phase = (phase + 1) % 4
            }
    }
}

struct BadgePill: View {
    @Environment(\.notchTheme) private var theme
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(theme.font(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .notchPill(theme, fill: theme.chipFill(color.opacity(0.15)), base: 4)
    }
}

struct EffortBadge: View {
    @Environment(\.notchTheme) private var theme
    let level: String

    private var color: Color {
        switch level.lowercased() {
        case "low": return .green
        case "medium": return .yellow
        case "high": return .purple
        case "xhigh", "max": return .pink
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(level.uppercased())
                .font(theme.font(size: 9, weight: .heavy))
                .foregroundColor(color)
                .kerning(0.5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .notchPill(theme, fill: theme.chipFill(color.opacity(0.15)), base: 4)
    }
}

private func formatDuration(_ ms: Int) -> String {
    if ms >= 1000 {
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
    return "\(ms)ms"
}
