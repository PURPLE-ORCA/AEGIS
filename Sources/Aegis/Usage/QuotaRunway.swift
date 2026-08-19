import Foundation

enum QuotaRunwayStatus: Int, Comparable {
    case comfortable
    case watch
    case tight

    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .watch: return "Watch"
        case .tight: return "Tight"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct QuotaRunway {
    let status: QuotaRunwayStatus
    let windowLabel: String
}

/// Tracks recent local quota movement. The estimate intentionally speaks only
/// to whether the current allowance will last until reset; it is not a cost or
/// token forecast.
struct QuotaRunwayEstimator {
    private struct WindowKey: Hashable {
        let providerID: String
        let slot: String
    }

    private struct WindowState {
        let usedFraction: Double
        let observedAt: Date
        let resetsAt: Date
        let velocity: Double?
    }

    private var states: [WindowKey: WindowState] = [:]
    private let smoothingFactor: Double
    private let maximumObservationGap: TimeInterval

    init(smoothingFactor: Double = 0.35, maximumObservationGap: TimeInterval = 5 * 60) {
        self.smoothingFactor = min(max(smoothingFactor, 0), 1)
        self.maximumObservationGap = maximumObservationGap
    }

    mutating func record(
        providerID: String,
        fiveHour: RateLimit?,
        sevenDay: RateLimit?,
        observedAt: Date = Date()
    ) -> QuotaRunway? {
        let candidates = [
            runway(providerID: providerID, slot: "short", limit: fiveHour, observedAt: observedAt),
            runway(providerID: providerID, slot: "long", limit: sevenDay, observedAt: observedAt),
        ].compactMap { $0 }

        return candidates.max { $0.status < $1.status }
    }

    private mutating func runway(
        providerID: String,
        slot: String,
        limit: RateLimit?,
        observedAt: Date
    ) -> QuotaRunway? {
        guard let limit, limit.resetsAt > observedAt else { return nil }

        let key = WindowKey(providerID: providerID, slot: slot)
        let usedFraction = 1 - limit.remainingFraction
        guard let previous = states[key] else {
            states[key] = WindowState(
                usedFraction: usedFraction,
                observedAt: observedAt,
                resetsAt: limit.resetsAt,
                velocity: nil
            )
            return limit.remainingFraction == 0
                ? QuotaRunway(status: .tight, windowLabel: limit.windowLabel)
                : nil
        }

        let elapsed = observedAt.timeIntervalSince(previous.observedAt)
        let usageDelta = usedFraction - previous.usedFraction
        let resetAdvanced = limit.resetsAt.timeIntervalSince(previous.resetsAt) > 5 * 60
        let beganNewWindow = usageDelta < -0.005 || resetAdvanced && usageDelta <= 0

        guard elapsed > 0, elapsed <= maximumObservationGap, !beganNewWindow else {
            states[key] = WindowState(
                usedFraction: usedFraction,
                observedAt: observedAt,
                resetsAt: limit.resetsAt,
                velocity: nil
            )
            return limit.remainingFraction == 0
                ? QuotaRunway(status: .tight, windowLabel: limit.windowLabel)
                : nil
        }

        let currentVelocity = max(0, usageDelta) / elapsed
        let velocity = previous.velocity.map {
            smoothingFactor * currentVelocity + (1 - smoothingFactor) * $0
        } ?? currentVelocity

        states[key] = WindowState(
            usedFraction: usedFraction,
            observedAt: observedAt,
            resetsAt: limit.resetsAt,
            velocity: velocity
        )

        guard limit.remainingFraction > 0 else {
            return QuotaRunway(status: .tight, windowLabel: limit.windowLabel)
        }

        let projectedConsumption = velocity * limit.resetsAt.timeIntervalSince(observedAt)
        let runwayRatio = projectedConsumption / limit.remainingFraction
        let status: QuotaRunwayStatus
        if runwayRatio > 1 {
            status = .tight
        } else if runwayRatio > 0.7 {
            status = .watch
        } else {
            status = .comfortable
        }
        return QuotaRunway(status: status, windowLabel: limit.windowLabel)
    }
}
