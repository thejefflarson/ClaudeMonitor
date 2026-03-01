import Foundation

enum AnthropicService {
    private static let base = "https://api.anthropic.com"
    private static let apiVersion = "2023-06-01"

    // MARK: - Public API

    /// Fetches cost and token usage for the current calendar month.
    static func fetchUsage(apiKey: String) async throws -> UsageData {
        let monthStart = currentMonthStart()
        let now = ISO8601DateFormatter().string(from: Date())

        async let costData = fetch(
            path: "/v1/organizations/cost_report",
            apiKey: apiKey,
            params: ["starting_at": monthStart, "ending_at": now, "bucket_width": "1d"]
        )
        async let usageData = fetch(
            path: "/v1/organizations/usage_report/messages",
            apiKey: apiKey,
            params: ["starting_at": monthStart, "ending_at": now, "bucket_width": "1d"]
        )

        var result = try await parseCostResponse(costData)
        result.tokensUsed = (try? await parseTotalTokens(usageData)) ?? 0
        result.lastFetched = Date()
        return result
    }

    // MARK: - Parsing (internal for testing)

    static func parseCostResponse(_ data: Data) throws -> UsageData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else {
            throw AnthropicError.badResponse
        }
        var totalCents = 0.0
        var firstDate: Date?
        let iso = ISO8601DateFormatter()

        for bucket in dataArr {
            if firstDate == nil, let s = bucket["starting_at"] as? String {
                firstDate = iso.date(from: s)
            }
            for result in (bucket["results"] as? [[String: Any]] ?? []) {
                if let n = result["amount"] as? Double {
                    totalCents += n
                } else if let s = result["amount"] as? String, let n = Double(s) {
                    totalCents += n
                }
            }
        }
        var usage = UsageData()
        usage.costUSD = totalCents / 100.0
        usage.periodStart = firstDate
        return usage
    }

    static func parseTotalTokens(_ data: Data) throws -> Int {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else {
            throw AnthropicError.badResponse
        }
        var total = 0
        for bucket in dataArr {
            for result in (bucket["results"] as? [[String: Any]] ?? []) {
                total += result["uncached_input_tokens"] as? Int ?? 0
                total += result["output_tokens"] as? Int ?? 0
                total += result["cache_read_input_tokens"] as? Int ?? 0
                if let cc = result["cache_creation"] as? [String: Any] {
                    total += cc["ephemeral_1h_input_tokens"] as? Int ?? 0
                    total += cc["ephemeral_5m_input_tokens"] as? Int ?? 0
                }
            }
        }
        return total
    }

    // MARK: - Private helpers

    private static func fetch(path: String, apiKey: String, params: [String: String]) async throws -> Data {
        var components = URLComponents(string: base + path)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AnthropicError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private static func currentMonthStart() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: Date())
        let start = cal.date(from: comps)!
        return ISO8601DateFormatter().string(from: start)
    }

    enum AnthropicError: Error {
        case badResponse
        case httpError(Int)
    }
}
