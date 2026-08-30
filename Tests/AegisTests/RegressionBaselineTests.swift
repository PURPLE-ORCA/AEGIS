import XCTest
@testable import Aegis

final class RegressionBaselineTests: XCTestCase {
    func testSessionDisplayNamePrefersProviderTitle() {
        var session = makeSession(cwd: "/tmp/aegis-project")
        session.firstPrompt = "Fallback prompt"
        session.sessionTitle = "Provider task title"

        XCTAssertEqual(session.displayName, "Provider task title")
    }

    func testSessionDisplayNameFallsBackToMeaningfulDirectory() {
        let session = makeSession(cwd: "/tmp/aegis-project")

        XCTAssertEqual(session.displayName, "aegis-project")
    }

    func testQuestionResponseCapabilitiesAreExplicit() {
        XCTAssertEqual(AIProvider.codex.questionResponseMode, .providerApp)
        XCTAssertEqual(AIProvider.hermes.questionResponseMode, .providerApp)
        XCTAssertEqual(AIProvider.opencode.questionResponseMode, .inline)
        XCTAssertEqual(AIProvider.antigravity.questionResponseMode, .inline)
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

    func testFinishedReplyMarkdownPreservesStructuredBlocks() {
        let markdown = """
        # Finished

        - [x] Tests pass

        ```swift
        let status = "ready"
        ```

        Ready to ship.
        """
        let blocks = MarkdownText.blocks(from: markdown)

        XCTAssertEqual(blocks.count, 4)
        guard case .header(let level, let title) = blocks[0],
              case .text(let task) = blocks[1],
              case .code(let code) = blocks[2],
              case .text(let conclusion) = blocks[3] else {
            return XCTFail("Expected heading, task, code, and prose blocks")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(title, "Finished")
        XCTAssertEqual(task, "- [x] Tests pass")
        XCTAssertEqual(code, "let status = \"ready\"")
        XCTAssertEqual(conclusion, "Ready to ship.")
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
