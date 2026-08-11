import XCTest
@testable import CaesuraIsland

final class FileLogWriterTests: XCTestCase {
    func testFormatterProducesStructuredLine() {
        let formatter = LogLineFormatter(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)
        )

        let line = formatter.line(date: Date(timeIntervalSince1970: 0), level: "INFO", message: "ready")

        XCTAssertTrue(line.hasPrefix("["))
        XCTAssertTrue(line.hasSuffix("] [INFO] ready\n"))
    }

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

    func testAsyncSinkPreservesFIFOOrderAndDrainsOnShutdown() throws {
        let (root, url, sink) = makeSink()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 0)

        for index in 0..<100 {
            sink.enqueue(date: date, level: "INFO", message: "message-\(index)")
        }
        sink.shutdown()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.count, 100)
        for (index, line) in lines.enumerated() {
            XCTAssertTrue(line.hasSuffix("[INFO] message-\(index)"))
        }
    }

    func testConcurrentProducersWriteCompleteLines() throws {
        let (root, url, sink) = makeSink()
        defer { try? FileManager.default.removeItem(at: root) }
        let producerQueue = DispatchQueue(label: "dev.caesura.tests.log-producers", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<200 {
            group.enter()
            producerQueue.async {
                sink.enqueue(date: Date(timeIntervalSince1970: 0), level: "INFO", message: "concurrent-\(index)")
                group.leave()
            }
        }
        group.wait()
        sink.shutdown()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        XCTAssertTrue(lines.allSatisfy { $0.contains("] [INFO] concurrent-") })
    }

    private func makeSink() -> (root: URL, log: URL, sink: AsyncLogSink) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("caesura-log-tests-\(UUID().uuidString)")
        let url = root.appendingPathComponent("debug.log")
        let sink = AsyncLogSink(
            writer: FileLogWriter(url: url, maxBytes: 1_024 * 1_024),
            makeFormatter: {
                LogLineFormatter(
                    locale: Locale(identifier: "en_US_POSIX"),
                    timeZone: TimeZone(secondsFromGMT: 0)
                )
            },
            label: "dev.caesura.tests.logger.\(UUID().uuidString)"
        )
        return (root, url, sink)
    }
}
