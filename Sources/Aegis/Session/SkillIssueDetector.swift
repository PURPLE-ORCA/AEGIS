import AegisBridgeSupport
import Foundation

struct SkillIssueDetector {
    struct Policy: Equatable {
        let failureThreshold: Int
        let window: TimeInterval

        static let standard = Policy(failureThreshold: 3, window: 90)
    }

    private struct Key: Hashable {
        let sessionId: String
        let toolName: String
    }

    private struct Streak {
        var failures: [Date] = []
        var alreadyTriggered = false
    }

    private let policy: Policy
    private var streaks: [Key: Streak] = [:]

    init(policy: Policy = .standard) {
        self.policy = policy
    }

    mutating func record(
        sessionId: String,
        toolName: String,
        outcome: ToolOutcome?,
        at now: Date = Date()
    ) -> Bool {
        guard let outcome else { return false }
        let normalizedTool = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTool.isEmpty else { return false }

        let key = Key(sessionId: sessionId, toolName: normalizedTool)
        if outcome == .success {
            streaks.removeValue(forKey: key)
            return false
        }

        var streak = streaks[key] ?? Streak()
        let cutoff = now.addingTimeInterval(-policy.window)
        streak.failures.removeAll { $0 < cutoff }
        streak.failures.append(now)

        let shouldTrigger = streak.failures.count >= policy.failureThreshold
            && !streak.alreadyTriggered
        if shouldTrigger { streak.alreadyTriggered = true }
        streaks[key] = streak
        return shouldTrigger
    }

    mutating func reset(sessionId: String) {
        streaks = streaks.filter { $0.key.sessionId != sessionId }
    }
}
