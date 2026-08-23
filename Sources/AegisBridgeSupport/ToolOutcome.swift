import Foundation

public enum ToolOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
}

/// Reads only structured execution signals. Plain text is deliberately ignored:
/// successful tools often print words such as "error", while a failed command
/// can produce no output at all.
public enum StructuredToolOutcomeDetector {
    public static func explicitOutcome(from value: Any?) -> ToolOutcome? {
        var foundSuccess = false
        var foundFailure = false
        inspect(value, foundSuccess: &foundSuccess, foundFailure: &foundFailure)
        if foundFailure { return .failure }
        if foundSuccess { return .success }
        return nil
    }

    private static func inspect(
        _ value: Any?,
        foundSuccess: inout Bool,
        foundFailure: inout Bool
    ) {
        guard let value, !(value is NSNull) else { return }

        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalizedKey = key
                    .replacingOccurrences(of: "_", with: "")
                    .lowercased()

                switch normalizedKey {
                case "exitcode":
                    if let code = integer(child) {
                        if code == 0 { foundSuccess = true }
                        else { foundFailure = true }
                    }
                case "iserror":
                    if let isError = boolean(child) {
                        if isError { foundFailure = true }
                        else { foundSuccess = true }
                    }
                case "success", "toolsuccess":
                    if let success = boolean(child) {
                        if success { foundSuccess = true }
                        else { foundFailure = true }
                    }
                case "tooloutcome", "outcome":
                    if let outcome = namedOutcome(child) {
                        if outcome == .failure { foundFailure = true }
                        else { foundSuccess = true }
                    }
                default:
                    inspect(child, foundSuccess: &foundSuccess, foundFailure: &foundFailure)
                }
            }
            return
        }

        if let array = value as? [Any] {
            for child in array {
                inspect(child, foundSuccess: &foundSuccess, foundFailure: &foundFailure)
            }
            return
        }

        if let string = value as? String,
           let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            inspect(decoded, foundSuccess: &foundSuccess, foundFailure: &foundFailure)
        }
    }

    public static func namedOutcome(_ value: Any?) -> ToolOutcome? {
        guard let raw = value as? String else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "success", "succeeded", "ok", "completed", "complete":
            return .success
        case "failure", "failed", "error", "timeout", "timedout", "timed_out":
            return .failure
        default:
            return nil
        }
    }

    private static func integer(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolean(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
