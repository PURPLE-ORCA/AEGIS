import Foundation
import XCTest
@testable import AegisBridgeSupport

final class ReverseJSONLReaderTests: XCTestCase {
    func testFindsNewestMatchWithAndWithoutFinalNewline() throws {
        for finalNewline in [false, true] {
            let transcript = try makeTranscript(
                lines: [#"{"value":"older"}"#, #"{"value":"newest"}"#],
                finalNewline: finalNewline
            )
            defer { try? FileManager.default.removeItem(at: transcript) }

            let result = try ReverseJSONLReader(path: transcript.path, chunkSize: 8).firstMatch(parseValue)

            XCTAssertEqual(result.value, "newest")
        }
    }

    func testReadsRecordSpanningChunksAndPreservesUnicodeBoundary() throws {
        let expected = String(repeating: "é", count: 70_000)
        let data = try JSONSerialization.data(withJSONObject: ["value": expected])
        let transcript = try makeTranscript(data: data)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let result = try ReverseJSONLReader(path: transcript.path).firstMatch(parseValue)

        XCTAssertEqual(result.value, expected)
    }

    func testSkipsMalformedNewestRecord() throws {
        let transcript = try makeTranscript(lines: [#"{"value":"valid"}"#, #"{"value":"broken""#])
        defer { try? FileManager.default.removeItem(at: transcript) }

        let result = try ReverseJSONLReader(path: transcript.path, chunkSize: 7).firstMatch(parseValue)

        XCTAssertEqual(result.value, "valid")
    }

    func testReturnsNilWhenNoRecordMatches() throws {
        let transcript = try makeTranscript(lines: [#"{"other":true}"#])
        defer { try? FileManager.default.removeItem(at: transcript) }

        let result = try ReverseJSONLReader(path: transcript.path).firstMatch(parseValue)

        XCTAssertNil(result.value)
    }

    func testCodexParserStripsPlanWrapperAndCapsOutput() throws {
        let content = "<proposed_plan>" + String(repeating: "x", count: 4_200) + "</proposed_plan>"
        let line = try jsonLine([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": content]],
            ],
        ])
        let transcript = try makeTranscript(data: line)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let result = try XCTUnwrap(codexAssistantFromTranscript(transcript.path))

        XCTAssertEqual(result.count, 4_000)
        XCTAssertFalse(result.contains("proposed_plan"))
    }

    func testAntiGravityParsersPreserveProviderSemanticsAndCaps() throws {
        let request = "<USER_REQUEST>  " + String(repeating: "r", count: 600) + "  </USER_REQUEST><ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>"
        let userLine = try jsonLine(["type": "USER_INPUT", "content": request])
        let assistantLine = try jsonLine([
            "type": "PLANNER_RESPONSE",
            "source": "MODEL",
            "content": String(repeating: "a", count: 600),
        ])
        let transcript = try makeTranscript(data: userLine + Data([0x0A]) + assistantLine)
        defer { try? FileManager.default.removeItem(at: transcript) }

        XCTAssertEqual(agUserRequestFromTranscript(transcript.path)?.count, 500)
        XCTAssertEqual(agAssistantFromTranscript(transcript.path)?.count, 500)
    }

    func testNearEndMatchInLargeFileReadsLessThanFourChunks() throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-large-jsonl-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let handle = try FileHandle(forWritingTo: transcript)
        let filler = Data((#"{"padding":""# + String(repeating: "x", count: 4_064) + #""}"# + "\n").utf8)
        let targetSize = 128 * 1024 * 1024
        var written = 0
        while written + filler.count < targetSize {
            try handle.write(contentsOf: filler)
            written += filler.count
        }
        try handle.write(contentsOf: Data(#"{"value":"near-end"}"#.utf8))
        try handle.close()

        let result = try ReverseJSONLReader(path: transcript.path).firstMatch(parseValue)

        XCTAssertEqual(result.value, "near-end")
        XCTAssertLessThan(result.bytesRead, 256 * 1024)
    }

    private func parseValue(_ line: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        return object?["value"] as? String
    }

    private func jsonLine(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func makeTranscript(lines: [String], finalNewline: Bool = true) throws -> URL {
        var data = Data(lines.joined(separator: "\n").utf8)
        if finalNewline { data.append(0x0A) }
        return try makeTranscript(data: data)
    }

    private func makeTranscript(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-reverse-jsonl-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }
}
