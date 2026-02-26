import XCTest
@testable import ClaudeMonitor

final class AnthropicServiceTests: XCTestCase {

    func testParsesCostResponse() throws {
        // amount is in cents: "421.00" = $4.21
        let json = """
        {
            "data": [
                { "starting_at": "2026-02-01T00:00:00Z", "ending_at": "2026-02-02T00:00:00Z",
                  "results": [{ "amount": "300.00", "currency": "USD" }] },
                { "starting_at": "2026-02-02T00:00:00Z", "ending_at": "2026-02-03T00:00:00Z",
                  "results": [{ "amount": "121.00", "currency": "USD" }] }
            ],
            "has_more": false
        }
        """.data(using: .utf8)!

        let usage = try AnthropicService.parseCostResponse(json)
        XCTAssertEqual(usage.costUSD, 4.21, accuracy: 0.001)
        XCTAssertNotNil(usage.periodStart)
    }

    func testParsesUsageResponse() throws {
        let json = """
        {
            "data": [
                { "starting_at": "2026-02-01T00:00:00Z",
                  "results": [{ "uncached_input_tokens": 800000, "output_tokens": 200000,
                                "cache_read_input_tokens": 100000,
                                "cache_creation": { "ephemeral_1h_input_tokens": 0,
                                                    "ephemeral_5m_input_tokens": 0 } }] }
            ],
            "has_more": false
        }
        """.data(using: .utf8)!

        let tokens = try AnthropicService.parseTotalTokens(json)
        XCTAssertEqual(tokens, 1_100_000)
    }
}
