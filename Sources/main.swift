// TokenMeter: a tiny macOS menu bar meter for Claude plan usage limits.
// Primary source: the rate limits Claude Code already receives, saved by a status line hook.
// Fallback: Anthropic's usage endpoint, called rarely because it rate-limits aggressively.

import AppKit

// MARK: - Model

struct UsageWindow: Codable {
    let percent: Double // 0...100
    let resetsAt: Date?

    var rounded: Int { Int(percent.rounded()) }

    /// A window whose reset time has passed is empty, however old the saved number is.
    func current(at now: Date) -> UsageWindow {
        if let resetsAt, resetsAt <= now { return UsageWindow(percent: 0, resetsAt: nil) }
        return self
    }
}

struct UsageSnapshot: Codable {
    let session: UsageWindow
    let weekly: UsageWindow
    let fetchedAt: Date

    func current(at now: Date) -> UsageSnapshot {
        UsageSnapshot(session: session.current(at: now), weekly: weekly.current(at: now), fetchedAt: fetchedAt)
    }
}

enum UsageError: LocalizedError {
    case notLoggedIn
    case expired
    case rateLimited
    case http(Int)
    case badData

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "No Claude Code login found. Run `claude` and log in."
        case .expired: return "Login expired. Open Claude Code once to refresh it."
        case .rateLimited: return "Anthropic is rate limiting usage checks."
        case .http(let code): return "Usage service returned HTTP \(code)."
        case .badData: return "Unexpected response from usage service."
        }
    }
}

// MARK: - Credentials

enum Credentials {
    /// Claude Code stores its OAuth login in the Keychain using /usr/bin/security,
    /// so reading it through the same tool avoids a Keychain permission prompt.
    static func accessToken() -> String? {
        runSecurity().flatMap(parse)
    }

    /// Email of the signed-in account, shown so a shared Mac knows whose limits these are.
    /// Async so the (possibly large) ~/.claude.json is read off the main thread.
    static func accountEmail() async -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return account["emailAddress"] as? String
    }

    private static func runSecurity() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func parse(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}

// MARK: - Claude Code status line (primary source)

/// Claude Code passes `rate_limits` to its status line command after every reply. The bundled
/// hook (statusline.sh) saves that payload here, so most updates cost zero network requests.
enum StatusLineFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/tokenmeter/status.json")

    static func read() -> UsageSnapshot? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any]
        else { return nil }

        func window(_ key: String) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any],
                  let percent = (w["used_percentage"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(percent: percent, resetsAt: resets)
        }
        guard let session = window("five_hour"), let weekly = window("seven_day") else { return nil }
        return UsageSnapshot(session: session, weekly: weekly, fetchedAt: modified)
    }
}

// MARK: - API (fallback)

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let isoFormatter = ISO8601DateFormatter()

    static func fetch() async throws -> UsageSnapshot {
        guard let token = Credentials.accessToken() else { throw UsageError.notLoggedIn }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 401: throw UsageError.expired
        case 429: throw UsageError.rateLimited // its Retry-After is unreliable (often 0), so it's ignored
        case let code: throw UsageError.http(code)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj.keys.contains("five_hour") || obj.keys.contains("seven_day")
        else { throw UsageError.badData }

        func window(_ key: String) -> UsageWindow {
            guard let w = obj[key] as? [String: Any],
                  let utilization = (w["utilization"] as? NSNumber)?.doubleValue
            else { return UsageWindow(percent: 0, resetsAt: nil) }
            return UsageWindow(percent: utilization, resetsAt: parseDate(w["resets_at"] as? String))
        }

        return UsageSnapshot(session: window("five_hour"), weekly: window("seven_day"), fetchedAt: Date())
    }

    /// The API returns microsecond timestamps, which ISO8601DateFormatter can't read, so drop the fraction.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoFormatter.date(from: trimmed)
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
