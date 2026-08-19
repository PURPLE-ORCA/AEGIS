import XCTest
@testable import Aegis

final class QuotaRunwayEstimatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testRunwayNeedsTwoLocalSnapshots() {
        var estimator = QuotaRunwayEstimator()

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.2, resetsIn: 3_600),
            sevenDay: nil,
            observedAt: start
        )

        XCTAssertNil(runway)
    }

    func testRunwayIsComfortableWhenProjectedUseIsWellWithinRemainingQuota() {
        var estimator = QuotaRunwayEstimator()
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.20, resetsIn: 600),
            sevenDay: nil,
            observedAt: start
        )

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.21, resetsIn: 540),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(60)
        )

        XCTAssertEqual(runway?.status, .comfortable)
    }

    func testRunwayWarnsWhenProjectedUseApproachesRemainingQuota() {
        var estimator = QuotaRunwayEstimator()
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.40, resetsIn: 660),
            sevenDay: nil,
            observedAt: start
        )

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.45, resetsIn: 600),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(60)
        )

        XCTAssertEqual(runway?.status, .watch)
    }

    func testRunwayIsTightWhenProjectedUseExceedsRemainingQuota() {
        var estimator = QuotaRunwayEstimator()
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.40, resetsIn: 1_260),
            sevenDay: nil,
            observedAt: start
        )

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.45, resetsIn: 1_200),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(60)
        )

        XCTAssertEqual(runway?.status, .tight)
    }

    func testEWMAKeepsOneQuietRefreshFromErasingRecentConsumption() {
        var estimator = QuotaRunwayEstimator()
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.40, resetsIn: 1_260),
            sevenDay: nil,
            observedAt: start
        )
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.45, resetsIn: 1_200),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(60)
        )

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.45, resetsIn: 1_140),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(120)
        )

        XCTAssertEqual(runway?.status, .tight)
    }

    func testMostConstrainedWindowSetsProviderRunway() {
        var estimator = QuotaRunwayEstimator()
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.20, resetsIn: 600, label: "5h"),
            sevenDay: limit(used: 0.40, resetsIn: 1_260, label: "7d"),
            observedAt: start
        )

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.21, resetsIn: 540, label: "5h"),
            sevenDay: limit(used: 0.45, resetsIn: 1_200, label: "7d"),
            observedAt: start.addingTimeInterval(60)
        )

        XCTAssertEqual(runway?.status, .tight)
        XCTAssertEqual(runway?.windowLabel, "7d")
    }

    func testQuotaResetStartsAnewVelocityBaseline() {
        var estimator = QuotaRunwayEstimator()
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.80, resetsIn: 60),
            sevenDay: nil,
            observedAt: start
        )
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.90, resetsIn: 30),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(30)
        )

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.02, resetsIn: 18_000),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(60)
        )

        XCTAssertNil(runway)
    }

    func testLongObservationGapStartsAnewVelocityBaseline() {
        var estimator = QuotaRunwayEstimator(maximumObservationGap: 300)
        _ = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.20, resetsIn: 3_600),
            sevenDay: nil,
            observedAt: start
        )

        let runway = estimator.record(
            providerID: "codex",
            fiveHour: limit(used: 0.50, resetsIn: 3_000),
            sevenDay: nil,
            observedAt: start.addingTimeInterval(600)
        )

        XCTAssertNil(runway)
    }

    private func limit(used: Double, resetsIn seconds: TimeInterval, label: String = "5h") -> RateLimit {
        let window = WindowUsage(
            usedPercent: used,
            resetAt: start.addingTimeInterval(seconds),
            windowSeconds: label == "7d" ? 7 * 86_400 : 5 * 3_600,
            error: nil
        )
        return try! XCTUnwrap(RateLimit(window: window, fallbackLabel: label))
    }
}
