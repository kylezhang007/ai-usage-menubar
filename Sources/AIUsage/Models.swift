import Foundation

/// One rate-limit window, e.g. Claude's 5-hour window or Codex's weekly window.
struct UsageWindow: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var percent: Double          // 0...100
    var resetsAt: Date?
    var isShort: Bool            // short windows show "h:mm left", long ones show a weekday

    /// The panel and menu bar both show what's left, matching how Codex reports it.
    var remaining: Double { max(0, 100 - percent) }
}

struct PlanUsage: Equatable {
    var plan: String
    var windows: [UsageWindow]
}

struct Money: Equatable {
    var amount: Double
    var currency: String         // "USD" or "CNY"

    var formatted: String {
        let symbol = currency.uppercased() == "CNY" ? "¥" : "$"
        return symbol + String(format: "%.2f", amount)
    }
}

enum Loadable<T: Equatable>: Equatable {
    case idle
    case missing(String)         // not configured / not logged in
    case failed(String)
    case loaded(T)

    var value: T? {
        if case .loaded(let v) = self { return v }
        return nil
    }
}

enum FetchError: LocalizedError {
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case badResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "Key 无效或没有权限"
        case .http(429), .rateLimited: return "请求太频繁，稍后再试"
        case .http(let code): return "请求失败（\(code)）"
        case .badResponse: return "返回的数据看不懂"
        case .message(let m): return m
        }
    }
}

enum HTTP {
    static func json(_ request: URLRequest) async throws -> Any {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        if http.statusCode == 429 {
            throw FetchError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? FetchError { return e.errorDescription ?? "出错了" }
        if (error as NSError).domain == NSURLErrorDomain { return "网络连接失败" }
        return "出错了"
    }
}

/// Parses timestamps like "2025-11-04T04:59:59.943648+00:00" (fractional digits vary).
func parseISODate(_ string: String?) -> Date? {
    guard var s = string else { return nil }
    if let dot = s.firstIndex(of: "."),
       let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        s.removeSubrange(dot..<end)
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func doubleValue(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String { return Double(s) }
    return nil
}
