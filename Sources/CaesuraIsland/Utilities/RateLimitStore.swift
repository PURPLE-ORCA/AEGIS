import Foundation
import Combine

/// One rate-limit window in the format the notch UI consumes.
/// Wraps `WindowUsage` (normalized 0…1 percent + optional reset time) with
/// the "Xh / Xm / Xd remaining" formatting the bar prints.
struct RateLimit {
    let remainingPercentage: Int
    let resetsAt: Date
    let windowLabel: String

    var timeRemaining: String {
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }
        let total = Int(remaining)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        // Keep the next-finer unit visible so 25h59m doesn't collapse to
        // "1d" (and so the value doesn't appear to jump backwards when
        // transitioning across the 24h boundary) — issue #39.
        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))m"
        }
        return "\(minutes)m"
    }

    init?(window: WindowUsage, fallbackLabel: String) {
        guard let reset = window.resetAt else { return nil }
        self.remainingPercentage = max(0, min(100, 100 - window.percentInt))
        self.resetsAt = reset
        self.windowLabel = Self.label(for: window.windowSeconds) ?? fallbackLabel
    }

    private static func label(for seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let totalHours = Int(seconds / 3600)
        if totalHours >= 48, totalHours.isMultiple(of: 24) {
            return "\(totalHours / 24)d"
        }
        return "\(totalHours)h"
    }
}

/// Per-provider snapshot of rate-limit data + a human-readable error caption.
struct ProviderUsage {
    let fiveHour: RateLimit?
    let sevenDay: RateLimit?
    let plan: String?
    let error: String?

    static let empty = ProviderUsage(fiveHour: nil, sevenDay: nil, plan: nil, error: nil)
}

/// Fetches Codex usage on a five-minute timer and publishes the latest snapshot.
@MainActor
final class RateLimitStore: ObservableObject {
    @Published private(set) var usage: [String: ProviderUsage] = [:]

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 60

    init() {
        // Kick off an initial fetch and start the refresh timer.
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// Look up the latest cached snapshot for a provider.
    func snapshot(for provider: AIProvider) -> ProviderUsage {
        usage[provider.id] ?? .empty
    }

    func fiveHour(for provider: AIProvider) -> RateLimit? {
        usage[provider.id]?.fiveHour
    }

    func sevenDay(for provider: AIProvider) -> RateLimit? {
        usage[provider.id]?.sevenDay
    }

    func refresh() async {
        usage["codex"] = Self.snapshot(from: await UsageFetcher.fetchCodex())
    }

    private static func snapshot(from app: AppUsage) -> ProviderUsage {
        ProviderUsage(
            fiveHour: RateLimit(window: app.fiveHour, fallbackLabel: "5h"),
            sevenDay: RateLimit(window: app.weekly, fallbackLabel: "7d"),
            plan: app.plan,
            error: app.fiveHour.error ?? app.weekly.error
        )
    }
}
