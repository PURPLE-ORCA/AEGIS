import XCTest
@testable import CaesuraIsland

final class FileLogWriterTests: XCTestCase {
    func testWriterReusesFileAndRotatesAtLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("caesura-log-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("debug.log")
        let writer = FileLogWriter(url: url, maxBytes: 20)
        writer.write("first-message\n")
        writer.write("second-message\n")
        writer.close()

        let active = try String(contentsOf: url, encoding: .utf8)
        let rotated = try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertEqual(active, "second-message\n")
        XCTAssertEqual(rotated, "first-message\n")
    }
}
