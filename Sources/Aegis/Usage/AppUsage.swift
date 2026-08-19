import Foundation

/// One rate-limit window (for example, Codex's 7d). usedPercent is
/// normalized to 0...1 regardless of what the upstream API returns.
struct WindowUsage {
    let usedPercent: Double
    let resetAt: Date?
    let windowSeconds: TimeInterval?
    let error: String?

    static let unknown = WindowUsage(usedPercent: 0, resetAt: nil, windowSeconds: nil, error: "no data")

    init(usedPercent: Double, resetAt: Date?, windowSeconds: TimeInterval? = nil, error: String?) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
        self.error = error
    }

    var percentInt: Int { Int((usedPercent * 100).rounded()) }
}

struct AppUsage {
    var fiveHour: WindowUsage
    var weekly: WindowUsage
    /// Provider-reported plan tier, when available.
    /// or Codex's `plan_type` (free/plus/pro). nil when unknown.
    var plan: String?

    init(fiveHour: WindowUsage, weekly: WindowUsage, plan: String? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.plan = plan
    }

    static let empty = AppUsage(fiveHour: .unknown, weekly: .unknown)
}
