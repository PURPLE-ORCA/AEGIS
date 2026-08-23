import Foundation
import XCTest
@testable import Aegis
import AegisBridgeSupport

final class SkillIssueDetectorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testThirdFailureForTheSameToolWithinWindowTriggersOnce() {
        var detector = SkillIssueDetector(policy: .init(failureThreshold: 3, window: 90))

        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 0))
        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 20))
        XCTAssertTrue(recordOutcome(.failure, with: &detector, at: 40))
        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 60))
    }

    func testToolsAndSessionsHaveIndependentStreaks() {
        var detector = SkillIssueDetector(policy: .init(failureThreshold: 2, window: 90))

        XCTAssertFalse(recordOutcome(.failure, with: &detector, tool: "Read", at: 0))
        XCTAssertFalse(recordOutcome(.failure, with: &detector, tool: "Bash", at: 1))
        XCTAssertTrue(recordOutcome(.failure, with: &detector, tool: "read", at: 2))
        XCTAssertFalse(recordOutcome(.failure, with: &detector, session: "other", tool: "Read", at: 3))
    }

    func testSuccessResetsFailureStreak() {
        var detector = SkillIssueDetector(policy: .init(failureThreshold: 2, window: 90))

        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 0))
        XCTAssertFalse(recordOutcome(.success, with: &detector, at: 1))
        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 2))
        XCTAssertTrue(recordOutcome(.failure, with: &detector, at: 3))
    }

    func testFailuresOutsideWindowDoNotFormAStreak() {
        var detector = SkillIssueDetector(policy: .init(failureThreshold: 2, window: 10))

        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 0))
        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 11))
        XCTAssertTrue(recordOutcome(.failure, with: &detector, at: 12))
    }

    func testUnknownOutcomeIsIgnoredAndSessionResetClearsState() {
        var detector = SkillIssueDetector(policy: .init(failureThreshold: 2, window: 90))

        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 0))
        XCTAssertFalse(recordOutcome(nil, with: &detector, at: 1))
        detector.reset(sessionId: "session")
        XCTAssertFalse(recordOutcome(.failure, with: &detector, at: 2))
    }

    private func recordOutcome(
        _ outcome: ToolOutcome?,
        with detector: inout SkillIssueDetector,
        session: String = "session",
        tool: String = "Bash",
        at offset: TimeInterval
    ) -> Bool {
        detector.record(
            sessionId: session,
            toolName: tool,
            outcome: outcome,
            at: start.addingTimeInterval(offset)
        )
    }
}
