import Foundation

/// Month-to-date API spend (Anthropic, OpenAI) and DeepSeek balance.
enum SpendProvider {
    static func anthropic(key: String?) async -> Loadable<Money> {
        guard let key, !key.isEmpty else { return .missing(L("未设置", "Not set")) }
        do {
            var total = 0.0
            var page: String?
            repeat {
                var c = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
                c.queryItems = [
                    URLQueryItem(name: "starting_at", value: iso(monthStart)),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31"),
                ]
                if let page { c.queryItems?.append(URLQueryItem(name: "page", value: page)) }
                var req = URLRequest(url: c.url!)
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                guard let json = try await HTTP.json(req) as? [String: Any] else { throw FetchError.badResponse }
                for bucket in json["data"] as? [[String: Any]] ?? [] {
                    for r in bucket["results"] as? [[String: Any]] ?? [] {
                        total += doubleValue(r["amount"]) ?? 0   // in cents
                    }
                }
                page = (json["has_more"] as? Bool == true) ? json["next_page"] as? String : nil
            } while page != nil
            return .loaded(Money(amount: total / 100, currency: "USD"))
        } catch {
            return .failed(HTTP.describe(error))
        }
    }

    static func openAI(key: String?) async -> Loadable<Money> {
        guard let key, !key.isEmpty else { return .missing(L("未设置", "Not set")) }
        do {
            var total = 0.0
            var page: String?
            repeat {
                var c = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
                c.queryItems = [
                    URLQueryItem(name: "start_time", value: String(Int(monthStart.timeIntervalSince1970))),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31"),
                ]
                if let page { c.queryItems?.append(URLQueryItem(name: "page", value: page)) }
                var req = URLRequest(url: c.url!)
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                guard let json = try await HTTP.json(req) as? [String: Any] else { throw FetchError.badResponse }
                for bucket in json["data"] as? [[String: Any]] ?? [] {
                    for r in bucket["results"] as? [[String: Any]] ?? [] {
                        total += doubleValue((r["amount"] as? [String: Any])?["value"]) ?? 0
                    }
                }
                page = (json["has_more"] as? Bool == true) ? json["next_page"] as? String : nil
            } while page != nil
            return .loaded(Money(amount: total, currency: "USD"))
        } catch {
            return .failed(HTTP.describe(error))
        }
    }

    static func deepSeekBalance(key: String?) async -> Loadable<Money> {
        guard let key, !key.isEmpty else { return .missing(L("未设置", "Not set")) }
        do {
            var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let json = try await HTTP.json(req) as? [String: Any],
                  let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else { throw FetchError.badResponse }
            let info = infos.first { ($0["currency"] as? String) == "CNY" } ?? infos[0]
            return .loaded(Money(amount: doubleValue(info["total_balance"]) ?? 0,
                                 currency: info["currency"] as? String ?? "CNY"))
        } catch {
            return .failed(HTTP.describe(error))
        }
    }

    /// Billing months are in UTC.
    static var monthStart: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
