import Foundation

/// Claude Pro/Max usage. Tries the Claude Code CLI login first (Keychain),
/// then falls back to a claude.ai sessionKey pasted in settings.
enum ClaudeProvider {
    struct Result {
        var usage: Loadable<PlanUsage>
        var retryAfter: TimeInterval?   // set when the server asked us to slow down
    }

    static func fetch(sessionKey: String?) async -> Result {
        do {
            return Result(usage: try await load(sessionKey: sessionKey))
        } catch FetchError.rateLimited(let after) {
            return Result(usage: .failed("请求太频繁，稍后再试"), retryAfter: after ?? 600)
        } catch {
            return Result(usage: .failed(HTTP.describe(error)))
        }
    }

    private static func load(sessionKey: String?) async throws -> Loadable<PlanUsage> {
        var cli = currentCredentials()
        let plan = planLabel(cli: cli)
        var renewFailed = false

        // The CLI only renews its login while it's in use, so the app renews its own copy
        // shortly before it expires.
        if let current = cli, current.needsRenewal, current.refreshToken != nil {
            do {
                cli = try await renew(current)
            } catch {
                renewFailed = true
            }
        }

        if let cli, cli.expiresAt.map({ $0 > Date() }) ?? true {
            do {
                var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
                req.setValue("Bearer \(cli.token)", forHTTPHeaderField: "Authorization")
                req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                let json = try await HTTP.json(req)
                return .loaded(PlanUsage(plan: plan, windows: parseWindows(json)))
            } catch {
                if sessionKey == nil { throw error }
            }
        }

        guard let sessionKey, !sessionKey.isEmpty else {
            if cli != nil {
                return .missing(renewFailed ? "Claude Code 登录已失效，在终端运行 claude 重新登录"
                                            : "Claude Code 登录已过期，在终端运行一次 claude 即可")
            }
            return .missing("在设置里填写 claude.ai 的 sessionKey")
        }

        do {
            let orgId = try await webOrganization(sessionKey: sessionKey)
            let req = webRequest("https://claude.ai/api/organizations/\(orgId)/usage", sessionKey: sessionKey)
            let json = try await HTTP.json(req)
            return .loaded(PlanUsage(plan: plan, windows: parseWindows(json)))
        } catch FetchError.http(let code) where code == 401 || code == 403 {
            return .failed("sessionKey 已失效，请重新复制")
        }
    }

    // MARK: - Parsing

    static func parseWindows(_ json: Any) -> [UsageWindow] {
        guard let dict = json as? [String: Any] else { return [] }
        func window(_ key: String, _ label: String, short: Bool) -> UsageWindow? {
            guard let w = dict[key] as? [String: Any], let pct = doubleValue(w["utilization"]) else { return nil }
            return UsageWindow(label: label, percent: pct, resetsAt: parseISODate(w["resets_at"] as? String), isShort: short)
        }
        var result: [UsageWindow] = []
        if let w = window("five_hour", "5 小时", short: true) { result.append(w) }
        if let w = window("seven_day", "本周", short: false) { result.append(w) }
        if let w = window("seven_day_opus", "Opus", short: false) {
            result.append(w)
        } else if let w = window("seven_day_sonnet", "Sonnet", short: false) {
            result.append(w)
        }
        return result
    }

    // MARK: - Credentials

    struct CLICredentials {
        var token: String
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?
        var refreshToken: String?
        var scopes: [String]
        var oauth: [String: Any]      // the stored claudeAiOauth object, so other fields survive a write-back

        init?(oauth: [String: Any]) {
            guard let token = oauth["accessToken"] as? String else { return nil }
            self.token = token
            self.expiresAt = doubleValue(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
            self.subscriptionType = oauth["subscriptionType"] as? String
            self.rateLimitTier = oauth["rateLimitTier"] as? String
            self.refreshToken = oauth["refreshToken"] as? String
            self.scopes = oauth["scopes"] as? [String] ?? []
            self.oauth = oauth
        }

        var needsRenewal: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 15 * 60
        }
        var expiry: Date { expiresAt ?? .distantPast }
    }

    private static let keychainService = "Claude Code-credentials"
    private static var credentialsFile: String { NSHomeDirectory() + "/.claude/.credentials.json" }

    /// The login to use: whichever is newer of the CLI's shared Keychain item and the app's
    /// own copy. The shared item can be overwritten by other Claude Code instances (the
    /// desktop app rewrites it from a stale cache), so the app keeps a copy of its own.
    static func currentCredentials() -> CLICredentials? {
        let shared = readShared()?.oauth.flatMap(CLICredentials.init(oauth:))
        let own = Keychain.get(.claudeOAuth)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .flatMap(CLICredentials.init(oauth:))
        if let shared, shared.expiry > (own?.expiry ?? .distantPast) || own?.token == shared.token {
            if own?.token != shared.token { storeOwnCopy(shared.oauth) }
            return shared
        }
        return own
    }

    private static func storeOwnCopy(_ oauth: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: oauth) else { return }
        Keychain.set(.claudeOAuth, String(data: data, encoding: .utf8))
    }

    /// Claude Code stores its login in the Keychain via /usr/bin/security,
    /// so reading it through the same tool doesn't trigger an access prompt.
    private static func readShared() -> (json: [String: Any], oauth: [String: Any]?, fromFile: Bool)? {
        var fromFile = false
        var raw = runSecurity(["find-generic-password", "-s", keychainService, "-w"])
        if raw == nil {
            raw = try? String(contentsOfFile: credentialsFile, encoding: .utf8)
            fromFile = raw != nil
        }
        guard let data = raw?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json, json["claudeAiOauth"] as? [String: Any], fromFile)
    }

    /// Same refresh request the CLI makes (client id and endpoint taken from the CLI itself).
    /// Refresh tokens rotate: the new pair goes into the app's own copy, and into the CLI's
    /// item too when that item is still on the same login, so the CLI isn't logged out.
    private static func renew(_ old: CLICredentials) async throws -> CLICredentials {
        // The CLI may have just renewed on its own.
        if let fresh = currentCredentials(), !fresh.needsRenewal { return fresh }

        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": old.refreshToken ?? "",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]
        if !old.scopes.isEmpty { body["scope"] = old.scopes.joined(separator: " ") }
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let json = try await HTTP.json(req) as? [String: Any],
              let access = json["access_token"] as? String,
              let expiresIn = doubleValue(json["expires_in"]) else { throw FetchError.badResponse }

        var oauth = old.oauth
        oauth["accessToken"] = access
        oauth["refreshToken"] = json["refresh_token"] as? String ?? old.refreshToken
        oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        if let scope = json["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        storeOwnCopy(oauth)

        // Merge into the CLI's item (re-read just now, only claudeAiOauth replaced) when it
        // still holds the login we just renewed; anything else there is left alone.
        if let shared = readShared(), let current = shared.oauth,
           current["refreshToken"] as? String == old.refreshToken {
            var merged = shared.json
            merged["claudeAiOauth"] = oauth
            try? save(try JSONSerialization.data(withJSONObject: merged), toFile: shared.fromFile)
        }
        guard let updated = CLICredentials(oauth: oauth) else { throw FetchError.badResponse }
        return updated
    }

    private static func save(_ data: Data, toFile: Bool) throws {
        if toFile {
            try data.write(to: URL(fileURLWithPath: credentialsFile), options: .atomic)
            return
        }
        // Fed through `security -i` on stdin so the tokens never show up in the process list.
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(NSUserName())\" -s \"\(keychainService)\" -X \(hex)\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        input.fileHandleForWriting.write(Data(command.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FetchError.message("写回钥匙串失败") }
    }

    private static func runSecurity(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func claudeJSONAccount() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["oauthAccount"] as? [String: Any]
    }

    static func planLabel(cli: CLICredentials?) -> String {
        let account = claudeJSONAccount()
        let tier = (cli?.rateLimitTier ?? account?["organizationRateLimitTier"] as? String ?? "").lowercased()
        let kind = (cli?.subscriptionType ?? account?["organizationType"] as? String ?? "").lowercased()
        if tier.contains("20x") { return "Max 20x" }
        if tier.contains("5x") { return "Max 5x" }
        if kind.contains("max") { return "Max" }
        if kind.contains("pro") { return "Pro" }
        if kind.contains("team") { return "Team" }
        if kind.contains("enterprise") { return "Enterprise" }
        return "Claude"
    }

    // MARK: - claude.ai web fallback

    private static func webRequest(_ url: String, sessionKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func webOrganization(sessionKey: String) async throws -> String {
        let json = try await HTTP.json(webRequest("https://claude.ai/api/organizations", sessionKey: sessionKey))
        guard let orgs = json as? [[String: Any]], !orgs.isEmpty else { throw FetchError.badResponse }
        let preferred = claudeJSONAccount()?["organizationUuid"] as? String
        if let preferred, orgs.contains(where: { $0["uuid"] as? String == preferred }) { return preferred }
        let chat = orgs.first { (($0["capabilities"] as? [String]) ?? []).contains("chat") }
        guard let uuid = (chat ?? orgs[0])["uuid"] as? String else { throw FetchError.badResponse }
        return uuid
    }
}
