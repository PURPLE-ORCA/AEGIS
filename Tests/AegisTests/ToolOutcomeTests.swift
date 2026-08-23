import XCTest
@testable import AegisBridgeSupport

final class ToolOutcomeTests: XCTestCase {
    func testExitCodeIsAnExplicitOutcome() {
        XCTAssertEqual(StructuredToolOutcomeDetector.explicitOutcome(from: ["exit_code": 0]), .success)
        XCTAssertEqual(StructuredToolOutcomeDetector.explicitOutcome(from: ["exit_code": 1]), .failure)
    }

    func testNestedJSONTextIsDecoded() {
        let output: [String: Any] = [
            "output": [["type": "input_text", "text": #"{"exit_code":124,"output":"timed out"}"#]],
        ]
        XCTAssertEqual(StructuredToolOutcomeDetector.explicitOutcome(from: output), .failure)
    }

    func testStructuredErrorFlagIsDetected() {
        XCTAssertEqual(StructuredToolOutcomeDetector.explicitOutcome(from: ["isError": true]), .failure)
        XCTAssertEqual(StructuredToolOutcomeDetector.explicitOutcome(from: ["success": true]), .success)
    }

    func testFailureDominatesNestedSuccess() {
        let output: [String: Any] = ["success": true, "result": ["exitCode": 2]]
        XCTAssertEqual(StructuredToolOutcomeDetector.explicitOutcome(from: output), .failure)
    }

    func testPlainTextIsNeverGuessed() {
        XCTAssertNil(StructuredToolOutcomeDetector.explicitOutcome(from: "error: permission denied"))
        XCTAssertNil(StructuredToolOutcomeDetector.explicitOutcome(from: "completed successfully"))
    }

    func testOnlyExplicitNamedOutcomesAreRecognized() {
        XCTAssertEqual(StructuredToolOutcomeDetector.namedOutcome("timeout"), .failure)
        XCTAssertEqual(StructuredToolOutcomeDetector.namedOutcome("completed"), .success)
        XCTAssertNil(StructuredToolOutcomeDetector.namedOutcome("blocked"))
        XCTAssertNil(StructuredToolOutcomeDetector.namedOutcome("cancelled"))
    }
}
