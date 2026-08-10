import XCTest
@testable import CaesuraIsland

final class RegressionBaselineTests: XCTestCase {
    func testSessionDisplayNamePrefersProviderTitle() {
        var session = makeSession(cwd: "/tmp/caesura-project")
        session.firstPrompt = "Fallback prompt"
        session.sessionTitle = "Provider task title"

        XCTAssertEqual(session.displayName, "Provider task title")
    }

    func testSessionDisplayNameFallsBackToMeaningfulDirectory() {
        let session = makeSession(cwd: "/tmp/caesura-project")

        XCTAssertEqual(session.displayName, "caesura-project")
    }

    func testMarkdownBlocksPreserveCodeAndProseOrder() {
        let blocks = MarkdownText.blocks(from: "Before\n```swift\nlet answer = 42\n```\nAfter")

        XCTAssertEqual(blocks.count, 3)
        guard case .text(let before) = blocks[0],
              case .code(let code) = blocks[1],
              case .text(let after) = blocks[2] else {
            return XCTFail("Expected prose, code, prose")
        }
        XCTAssertEqual(before, "Before")
        XCTAssertEqual(code, "let answer = 42")
        XCTAssertEqual(after, "After")
    }

    @MainActor
    func testPermissionHeightIsBounded() {
        let compact = NotchViewModel.computePermissionHeight(
            filePath: nil,
            contentLines: nil,
            hasDescription: false
        )
        let large = NotchViewModel.computePermissionHeight(
            filePath: "/tmp/file.swift",
            contentLines: 10_000,
            hasDescription: false
        )

        XCTAssertGreaterThanOrEqual(compact, 200)
        XCTAssertLessThanOrEqual(large, 600)
    }

    private func makeSession(cwd: String) -> Session {
        Session(
            id: UUID().uuidString,
            cwd: cwd,
            startedAt: Date(),
            status: .idle,
            terminalInfo: nil,
            source: "codex"
        )
    }
}
