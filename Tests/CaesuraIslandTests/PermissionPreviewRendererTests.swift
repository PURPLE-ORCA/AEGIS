import XCTest
@testable import CaesuraIsland

final class PermissionPreviewRendererTests: XCTestCase {
    func testWritePreviewReportsLinesAndBytes() throws {
        let permission = PendingPermission(
            toolName: "Write",
            description: nil,
            filePath: "/tmp/example.swift",
            content: "let a = 1\nlet b = 2",
            oldString: nil,
            newString: nil,
            respond: { _ in }
        )
        let input = try XCTUnwrap(PermissionPreviewInput(permission: permission))

        let preview = try XCTUnwrap(PermissionPreviewRenderer.render(input, lightWells: false))

        XCTAssertEqual(preview.label, "content")
        XCTAssertEqual(preview.metric, "2 lines · 19B")
    }

    func testPermissionWithoutPreviewContentHasNoInput() {
        let permission = PendingPermission(
            toolName: "Read",
            description: nil,
            filePath: "/tmp/example.swift",
            content: nil,
            oldString: nil,
            newString: nil,
            respond: { _ in }
        )

        XCTAssertNil(PermissionPreviewInput(permission: permission))
    }
}
