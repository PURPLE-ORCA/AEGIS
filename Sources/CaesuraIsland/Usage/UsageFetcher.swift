import Foundation

enum UsageFetcher {
    // MARK: - Codex

    /// Codex usage lives at chatgpt.com/backend-api/wham/usage and accepts
    /// the access_token from ~/.codex/auth.json. The endpoint is reliable
    /// and rarely rate-limited, so this is the easy half of the integration.
    static func fetchCodex() async -> AppUsage {
        guard let token = readCodexAccessToken() else {
            return errorPair("no codex auth")
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 401 means the access_token in ~/.codex/auth.json has expired.
            // The Codex CLI rotates this token on its own — there's nothing
            // we can do from here, so surface the exact remediation step.
            if status == 401 {
                return errorPair("auth expired — codex login")
            }
            if status != 200 {
                return errorPair("http \(status)")
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rl = obj["rate_limit"] as? [String: Any] else {
                return errorPair("parse error")
            }
            let windows = parseCodexWindows(rl)
            return AppUsage(fiveHour: windows.short, weekly: windows.long, plan: obj["plan_type"] as? String)
        } catch {
            return errorPair(error.localizedDescription)
        }
    }

    private static func errorPair(_ message: String) -> AppUsage {
        AppUsage(
            fiveHour: WindowUsage(usedPercent: 0, resetAt: nil, error: message),
            weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: message)
        )
    }

    private static func readCodexAccessToken() -> String? {
        let path = NSString("~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        return token
    }

    private static func parseCodexWindow(_ obj: Any?) -> WindowUsage {
        guard let d = obj as? [String: Any] else { return .unknown }
        let used = (d["used_percent"] as? Double) ?? 0
        let resetAt = (d["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let windowSeconds = d["limit_window_seconds"] as? Double
        return WindowUsage(usedPercent: used / 100, resetAt: resetAt, windowSeconds: windowSeconds, error: nil)
    }

    /// Codex no longer guarantees primary=5h and secondary=7d. Pro Lite, for
    /// example, currently returns one 7d primary window. Classify by duration
    /// so UI labels and slots follow the API instead of field position.
    private static func parseCodexWindows(_ rateLimit: [String: Any]) -> (short: WindowUsage, long: WindowUsage) {
        let primary = parseCodexWindow(rateLimit["primary_window"])
        let secondary = parseCodexWindow(rateLimit["secondary_window"])
        let available = [primary, secondary].filter { $0.resetAt != nil }

        let short = available.first { ($0.windowSeconds ?? 0) < 2 * 86_400 }
        let long = available.first { ($0.windowSeconds ?? 0) >= 2 * 86_400 }

        // Old responses omitted duration but still used primary/secondary order.
        return (short ?? (primary.windowSeconds == nil ? primary : .unknown),
                long ?? (secondary.windowSeconds == nil ? secondary : .unknown))
    }

}
