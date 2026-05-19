import Foundation

struct UsageBucket: Equatable {
    let utilizationPct: Double
    let resetAt: Date?
}

struct ClaudeLimits: Equatable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let extraUsage: ExtraUsage?
    let fetchedAt: Date
}

struct ExtraUsage: Equatable {
    let isEnabled: Bool
    let utilizationPct: Double
    let usedCredits: Double
    let monthlyLimit: Double
    let currency: String?
}

enum LimitsError: LocalizedError {
    case missingSessionKey
    case noOrganization
    case unauthorized
    case http(Int)
    case decode(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingSessionKey: return "No session key saved"
        case .noOrganization: return "No organizations found on this account"
        case .unauthorized: return "Session key is invalid or expired"
        case .http(let code): return "claude.ai returned HTTP \(code)"
        case .decode(let m): return "Decode error: \(m)"
        case .transport(let m): return "Network error: \(m)"
        }
    }
}

struct LimitsClient {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let base = "https://claude.ai/api"

    /// Fetches usage for the given org, discovering org ID if not supplied.
    /// Returns (limits, orgId so caller can persist it).
    func fetch(sessionKey: String, orgId: String?) async throws -> (ClaudeLimits, String) {
        let resolvedOrg: String
        if let orgId { resolvedOrg = orgId }
        else { resolvedOrg = try await firstOrganization(sessionKey: sessionKey) }
        let limits = try await usage(sessionKey: sessionKey, orgId: resolvedOrg)
        return (limits, resolvedOrg)
    }

    private func firstOrganization(sessionKey: String) async throws -> String {
        let url = URL(string: "\(Self.base)/organizations")!
        let data = try await getJSON(url: url, sessionKey: sessionKey)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let uuid = first["uuid"] as? String
        else {
            throw LimitsError.noOrganization
        }
        return uuid
    }

    private func usage(sessionKey: String, orgId: String) async throws -> ClaudeLimits {
        let url = URL(string: "\(Self.base)/organizations/\(orgId)/usage")!
        let data = try await getJSON(url: url, sessionKey: sessionKey)

        // Debug: dump the raw response so we can see claude.ai's actual shape.
        let dumpPath = "/tmp/claude-viewer-usage.json"
        try? data.write(to: URL(fileURLWithPath: dumpPath))

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.decode("usage payload was not a JSON object")
        }
        return ClaudeLimits(
            fiveHour: Self.bucket(from: obj["five_hour"]),
            sevenDay: Self.bucket(from: obj["seven_day"]),
            sevenDayOpus: Self.bucket(from: obj["seven_day_opus"]),
            sevenDaySonnet: Self.bucket(from: obj["seven_day_sonnet"]),
            extraUsage: Self.extraUsage(from: obj["extra_usage"]),
            fetchedAt: Date()
        )
    }

    private static func extraUsage(from any: Any?) -> ExtraUsage? {
        guard let d = any as? [String: Any] else { return nil }
        guard let enabled = d["is_enabled"] as? Bool, enabled else { return nil }
        let pct = (d["utilization"] as? Double) ?? Double((d["utilization"] as? Int) ?? 0)
        let used = (d["used_credits"] as? Double) ?? 0
        let limit = (d["monthly_limit"] as? Double) ?? Double((d["monthly_limit"] as? Int) ?? 0)
        let currency = d["currency"] as? String
        return ExtraUsage(
            isEnabled: enabled,
            utilizationPct: pct,
            usedCredits: used,
            monthlyLimit: limit,
            currency: currency
        )
    }

    private static func bucket(from any: Any?) -> UsageBucket? {
        guard let d = any as? [String: Any] else { return nil }
        let pct: Double
        if let n = d["utilization"] as? Double { pct = n }
        else if let n = d["utilization"] as? Int { pct = Double(n) }
        else if let n = d["utilization_pct"] as? Double { pct = n } // legacy fallback
        else if let n = d["utilization_pct"] as? Int { pct = Double(n) }
        else { return nil }
        let resetAt: Date? = {
            let raw = (d["resets_at"] as? String) ?? (d["reset_at"] as? String)
            guard let s = raw else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }()
        return UsageBucket(utilizationPct: pct, resetAt: resetAt)
    }

    private func getJSON(url: URL, sessionKey: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LimitsError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LimitsError.http(0)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LimitsError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LimitsError.http(http.statusCode)
        }
        return data
    }
}
