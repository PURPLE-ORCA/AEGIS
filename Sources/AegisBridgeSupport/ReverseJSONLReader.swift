import Foundation

public struct ReverseJSONLSearchResult<Value> {
    public let value: Value?
    public let bytesRead: Int
}

public struct ReverseJSONLReader {
    public static let defaultChunkSize = 64 * 1024

    private let url: URL
    private let chunkSize: Int

    public init(path: String, chunkSize: Int = Self.defaultChunkSize) {
        self.url = URL(fileURLWithPath: path)
        self.chunkSize = max(1, chunkSize)
    }

    public func firstMatch<Value>(
        _ transform: (Data) -> Value?
    ) throws -> ReverseJSONLSearchResult<Value> {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        var position = fileSize
        var carry = Data()
        var bytesRead = 0

        while position > 0 {
            let readCount = min(UInt64(chunkSize), position)
            position -= readCount
            try handle.seek(toOffset: position)

            var data = try handle.read(upToCount: Int(readCount)) ?? Data()
            bytesRead += data.count
            data.append(carry)

            let parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstCompleteIndex = position == 0 ? 0 : 1
            if firstCompleteIndex < parts.count {
                for part in parts[firstCompleteIndex...].reversed() where !part.isEmpty {
                    if let value = transform(Data(part)) {
                        return ReverseJSONLSearchResult(value: value, bytesRead: bytesRead)
                    }
                }
            }

            carry = position == 0 ? Data() : Data(parts.first ?? Data.SubSequence())
        }

        return ReverseJSONLSearchResult(value: nil, bytesRead: bytesRead)
    }
}

public func codexAssistantFromTranscript(_ path: String) -> String? {
    try? ReverseJSONLReader(path: path).firstMatch { line in
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "response_item",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "assistant",
              let content = payload["content"] as? [[String: Any]] else { return nil }

        let combined = content.reduce(into: "") { text, item in
            text += (item["text"] as? String) ?? (item["output_text"] as? String) ?? ""
        }
        let cleaned = combined
            .replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(4_000))
    }.value
}

public func agUserRequestFromTranscript(_ path: String) -> String? {
    try? ReverseJSONLReader(path: path).firstMatch { line in
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "USER_INPUT",
              var content = json["content"] as? String else { return nil }

        if let start = content.range(of: "<USER_REQUEST>"),
           let end = content.range(of: "</USER_REQUEST>") {
            content = String(content[start.upperBound..<end.lowerBound])
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }.value
}

public func agAssistantFromTranscript(_ path: String) -> String? {
    try? ReverseJSONLReader(path: path).firstMatch { line in
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "PLANNER_RESPONSE",
              json["source"] as? String == "MODEL",
              let content = json["content"] as? String else { return nil }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }.value
}
