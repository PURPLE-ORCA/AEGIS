import XCTest
@testable import Aegis

final class SyntaxHighlighterPerformanceTests: XCTestCase {
    func testCachedHighlightingPreservesSourceText() {
        let source = "let answer: ExampleType = \"42\" // result"

        let highlighted = SyntaxHighlighter.highlight(source, withLineNumbers: false)

        XCTAssertEqual(String(highlighted.characters), source)
    }

    func testDiffHighlightingBenchmark() {
        let old = (1...40).map { index in
            "let previous\(index): ExampleType = \"value \\(index)\" // old"
        }.joined(separator: "\n")
        let new = (1...40).map { index in
            "let current\(index): ExampleType = \"value \\(index + 1)\" // new"
        }.joined(separator: "\n")

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<5 {
                _ = SyntaxHighlighter.diff(old: old, new: new)
            }
        }
    }
}
