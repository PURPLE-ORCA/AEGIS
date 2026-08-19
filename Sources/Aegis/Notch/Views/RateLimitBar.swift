import SwiftUI

/// Compact rate-limit bar for a provider snapshot.
struct RateLimitBar: View {
    @ObservedObject var rateLimitStore: RateLimitStore
    var provider: AIProvider = .codex
    /// Optional tap handler — when set, the bar becomes a button that cycles
    /// to the next provider. Used in SessionListView to let users flip
    /// between available provider snapshots without touching the filter chips.
    var onTap: (() -> Void)? = nil
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let snapshot = rateLimitStore.snapshot(for: provider)
        if let onTap {
            Button(action: onTap) {
                content(snapshot: snapshot)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.displayName) usage limits")
            .accessibilityHint("Shows the next provider")
        } else {
            content(snapshot: snapshot)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(provider.displayName) usage limits")
        }
    }

    private func content(snapshot: ProviderUsage) -> some View {
        HStack(spacing: 5) {
            // Provider logo up front — disambiguates whose rate limit this is.
            ProviderIcon(provider: provider, size: 12)

            if let fh = snapshot.fiveHour {
                Text(fh.windowLabel)
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Text("\(fh.remainingPercentage)% left")
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundColor(colorForRemaining(fh.remainingPercentage))
                Text(fh.timeRemaining)
                    .font(theme.font(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            if snapshot.fiveHour != nil && snapshot.sevenDay != nil {
                Text("|")
                    .font(theme.font(size: 10))
                    .foregroundColor(.white.opacity(0.2))
            }

            if let sd = snapshot.sevenDay {
                Text(sd.windowLabel)
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Text("\(sd.remainingPercentage)% left")
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundColor(colorForRemaining(sd.remainingPercentage))
                Text(sd.timeRemaining)
                    .font(theme.font(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            if let runway = snapshot.runway {
                Text("|")
                    .font(theme.font(size: 10))
                    .foregroundColor(.white.opacity(0.2))
                Text("RUNWAY")
                    .font(theme.font(size: 8, weight: .heavy))
                    .foregroundColor(.white.opacity(0.4))
                    .kerning(0.6)
                Text(runway.status.label)
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundColor(color(for: runway.status))
                    .help("Quota runway based on the \(runway.windowLabel) window")
                    .accessibilityLabel("Quota runway \(runway.status.label)")
            }

            // No data yet (auth error, no token, still loading). Surface a
            // compact hint instead of an empty row so users know why it's blank.
            if snapshot.fiveHour == nil && snapshot.sevenDay == nil {
                Text(snapshot.error ?? "—")
                    .font(theme.font(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .contentShape(Rectangle())
    }

    private func colorForRemaining(_ pct: Int) -> Color {
        if pct <= 10 { return .red }
        if pct <= 30 { return .orange }
        if pct <= 50 { return .yellow }
        return .green
    }

    private func color(for status: QuotaRunwayStatus) -> Color {
        switch status {
        case .comfortable: return .green
        case .watch: return .orange
        case .tight: return .red
        }
    }
}
