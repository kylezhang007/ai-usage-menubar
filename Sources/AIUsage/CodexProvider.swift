import Foundation

/// Codex (ChatGPT plan) usage. Asks ChatGPT's usage endpoint (the one Codex's own
/// status view uses) so usage from any device shows up; falls back to the rate-limit
/// snapshots Codex writes into ~/.codex/sessions/**/rollout-*.jsonl.
enum CodexProvider {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex") }

    static func fetch() async -> Loadable<PlanUsage> {
        if let live = try? await fetchLive() { return .loaded(live) }
        return fetchFromLogs()
    }

    private static func fetchLive() async throws -> PlanUsage {
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("auth.json").path),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { throw FetchError.badResponse }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        guard let json = try await HTTP.json(req) as? [String: Any],
              let limits = json["rate_limit"] as? [String: Any] else { throw FetchError.badResponse }

        // Reshape the live windows into the snapshot format the log parser already understands.
        func snapshot(_ any: Any?) -> [String: Any]? {
            guard let w = any as? [String: Any] else { return nil }
            var out: [String: Any] = ["used_percent": w["used_percent"] ?? 0]
            if let secs = doubleValue(w["limit_window_seconds"]) { out["window_minutes"] = secs / 60 }
            if let at = doubleValue(w["reset_at"]) {
                out["resets_at"] = at
            } else if let after = doubleValue(w["reset_after_seconds"]) {
                out["resets_at"] = Date().timeIntervalSince1970 + after
            }
            return out
        }
        var windows: [UsageWindow] = []
        if let w = window(snapshot(limits["primary_window"]), fallbackShort: true) { windows.append(w) }
        if let w = window(snapshot(limits["secondary_window"]), fallbackShort: false) { windows.append(w) }
        guard !windows.isEmpty else { throw FetchError.badResponse }
        return PlanUsage(plan: planLabel(json["plan_type"] as? String), windows: windows)
    }

    private static func fetchFromLogs() -> Loadable<PlanUsage> {
        let sessions = home.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            return .missing(L("这台 Mac 上还没用过 Codex", "Codex hasn't been used on this Mac"))
        }
        for file in recentRollouts(in: sessions).prefix(8) {
            if let limits = latestRateLimits(in: file) {
                let plan = planLabel(limits["plan_type"] as? String)
                var windows: [UsageWindow] = []
                if let w = window(limits["primary"], fallbackShort: true) { windows.append(w) }
                if let w = window(limits["secondary"], fallbackShort: false) { windows.append(w) }
                if !windows.isEmpty { return .loaded(PlanUsage(plan: plan, windows: windows)) }
            }
        }
        return .missing(L("用一次 Codex 后就会显示额度", "Use Codex once to see your limits"))
    }

    private static func window(_ any: Any?, fallbackShort: Bool) -> UsageWindow? {
        guard let w = any as? [String: Any], var pct = doubleValue(w["used_percent"]) else { return nil }
        let minutes = doubleValue(w["window_minutes"])
        var resets = doubleValue(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        if resets == nil, let secs = doubleValue(w["resets_in_seconds"]), let ts = w["_timestamp"] as? Date {
            resets = ts.addingTimeInterval(secs)
        }
        // The snapshot is from the last Codex request; if that window has since reset, usage is back to zero.
        if let r = resets, r < Date() {
            pct = 0
            resets = nil
        }
        let short = minutes.map { $0 <= 24 * 60 } ?? fallbackShort
        let kind: UsageWindow.Kind
        switch minutes {
        case .some(300): kind = .fiveHour
        case .some(10080): kind = .week
        case .some(let m) where m < 24 * 60: kind = .hours(Int(m / 60))
        case .some(let m): kind = .days(Int(m / 1440))
        case .none: kind = fallbackShort ? .fiveHour : .week
        }
        return UsageWindow(kind: kind, percent: pct, resetsAt: resets, isShort: short)
    }

    private static func recentRollouts(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var files: [(URL, Date)] = []
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if date > cutoff { files.append((url, date)) }
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Reads only the tail of the file and returns the newest `rate_limits` object.
    private static func latestRateLimits(in file: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 1_000_000
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let payload = json["payload"] as? [String: Any] ?? json
            let msg = payload["msg"] as? [String: Any]
            guard var limits = (payload["rate_limits"] ?? msg?["rate_limits"]) as? [String: Any] else { continue }
            let ts = parseISODate(json["timestamp"] as? String)
            for key in ["primary", "secondary"] {
                if var w = limits[key] as? [String: Any] { w["_timestamp"] = ts; limits[key] = w }
            }
            return limits
        }
        return nil
    }

    private static func planLabel(_ fromLimits: String?) -> String {
        let raw = fromLimits ?? planFromAuth() ?? ""
        switch raw.lowercased() {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "team": return "ChatGPT Team"
        case "business": return "ChatGPT Business"
        case "enterprise": return "ChatGPT Enterprise"
        case "edu": return "ChatGPT Edu"
        case "free": return "ChatGPT Free"
        case "": return "ChatGPT"
        default: return "ChatGPT " + raw.capitalized
        }
    }

    /// The plan lives in the id_token claims inside ~/.codex/auth.json.
    private static func planFromAuth() -> String? {
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("auth.json").path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let payload = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_plan_type"] as? String
    }
}
