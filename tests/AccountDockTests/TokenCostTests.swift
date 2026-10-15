import XCTest
@testable import AccountDock

final class TokenCostTests: XCTestCase {
    private func usage(_ input: Int64 = 100_000, cached: Int64 = 50_000, writes: Int64 = 10_000, output: Int64 = 1_000) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": writes,
         "output_tokens": output, "reasoning_output_tokens": 500, "total_tokens": input + output]
    }
    func testCacheAndReasoningAreNotDoubleCharged() throws {
        let value = try XCTUnwrap(TokenPricing.estimate(model: "gpt-6.1-sol", usage: usage(), expected: 101_000))
        XCTAssertEqual(value.usd, 0.12, accuracy: 0.000001)
        XCTAssertEqual(value.tokens, 101_000)
        let long = try XCTUnwrap(TokenPricing.estimate(model: "gpt-6.1-sol", usage: usage(300_000), expected: 301_000))
        XCTAssertEqual(long.usd, 1.035, accuracy: 0.000001)
    }
    func testUnknownIncompleteAndInvalidUsageIsNotPriced() {
        XCTAssertNil(TokenPricing.estimate(model: "unknown", usage: usage(), expected: 101_000))
        XCTAssertNil(TokenPricing.estimate(model: "gpt-6.1-sol", usage: usage(), expected: 102_000))
        XCTAssertNil(TokenPricing.estimate(model: "gpt-6.1-sol", usage: usage(cached: 100_001), expected: 101_000))
        var missing = usage(); missing.removeValue(forKey: "cache_write_input_tokens")
        XCTAssertNil(TokenPricing.estimate(model: "gpt-6.1-sol", usage: missing, expected: 101_000))
        XCTAssertNil(TokenPricing.count(true)); XCTAssertNil(TokenPricing.count(-1)); XCTAssertNil(TokenPricing.count(Double.infinity))
    }
    private func event(_ type: String, _ payload: [String: Any]) throws -> Data {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        var data = Data(("{\"type\":\"" + type + "\",\"timestamp\":\"2026-10-14T00:00:00Z\",\"payload\":").utf8)
        data.append(payloadData); data.append(Data("}".utf8))
        data.append(10); return data
    }
    func testModelSwitchAndDuplicateEvents() throws {
        var state = ActivityLogState()
        state.append(try event("session_meta", ["creator_account_id": "a"]))
        state.append(try event("turn_context", ["model": "gpt-6.1-sol"]))
        let first = try event("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 101_000], "last_token_usage": usage()]])
        state.append(first); state.append(first)
        state.append(try event("turn_context", ["model": "gpt-6-astra"]))
        state.append(try event("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 202_000], "last_token_usage": usage()]]))
        let total = try XCTUnwrap(state.costs).values.reduce(0) { $0 + $1["a"]!.usd }
        XCTAssertEqual(total, 0.745, accuracy: 0.000001)
        let restored = try JSONDecoder().decode(ActivityLogState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.costs!.values.first!["a"]!.tokens, 202_000)
    }
    func testReplayPreservesPreviouslyAttributedTotalsAndNewUsageContinues() throws {
        var state = ActivityLogState()
        state.account = "a"; state.days = ["2026-10-14": ["a": 101_000]]; state.replayUntil = 100
        state.consume(try event("turn_context", ["model": "gpt-6.1-sol"]))
        state.consume(try event("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 101_000], "last_token_usage": usage()]]), at: 0)
        XCTAssertEqual(state.days["2026-10-14"]?["a"], 101_000)
        state.consume(try event("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 202_000], "last_token_usage": usage()]]), at: 100)
        XCTAssertEqual(state.days["2026-10-14"]?["a"], 202_000)
        XCTAssertEqual(state.costs?["2026-10-14"]?["a"]?.tokens, 202_000)
    }
    func testInheritedCounterDoesNotBecomeDailyUsageAndMigrationRepairsOldBucket() throws {
        let first = try event("event_msg", ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": 2_500_101_000], "last_token_usage": usage()]])
        for migrated in [false, true] {
            var state = ActivityLogState(); state.account = "a"; state.model = "gpt-6.1-sol"
            if migrated {
                state.days = ["2026-10-14": ["a": 2_500_101_000, "other": 42]]
                state.replayUntil = 100
            }
            state.consume(first, at: 0)
            XCTAssertEqual(state.days["2026-10-14"]?["a"], 101_000)
            state.consume(first, at: 0)
            XCTAssertEqual(state.days["2026-10-14"]?["a"], 101_000)
            state.consume(try event("event_msg", ["type": "token_count", "info": [
                "total_token_usage": ["total_tokens": 2_500_202_000], "last_token_usage": usage()]]), at: 100)
            XCTAssertEqual(state.days["2026-10-14"]?["a"], 202_000)
            XCTAssertEqual(state.costs?["2026-10-14"]?["a"]?.tokens, 202_000)
            if migrated { XCTAssertEqual(state.days["2026-10-14"]?["other"], 42) }
            let restored = try JSONDecoder().decode(ActivityLogState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(restored.previousTotal, 2_500_202_000)
        }
    }
    func testAccountAndDayCostFilters() {
        var snapshot = ActivitySnapshot()
        snapshot.costs = ["2026-10-14": ["a": TokenCost(usd: 1, tokens: 20), "b": TokenCost(usd: 2, tokens: 40)]]
        XCTAssertEqual(snapshot.filtered(accounts: ["a"]).cost().usd, 1)
        XCTAssertEqual(snapshot.cost(account: "b", day: "2026-10-14").tokens, 40)
        XCTAssertEqual(snapshot.cost(day: "2000-01-01").tokens, 0)
    }
    func testPriceRefreshRevaluesExistingTokenBreakdown() throws {
        let cost = try XCTUnwrap(TokenPricing.estimate(model: "gpt-6.1-sol", usage: usage(), expected: 101_000))
        let repriced = cost.valued(rates: ["gpt-6.1-sol": [4, 0.2, 5, 20, 8, 0.4, 10, 30]])
        XCTAssertEqual(repriced.usd, 0.24, accuracy: 0.000001)
        XCTAssertEqual(cost.valued(rates: [:]).tokens, 0)
    }
    func testOnlyStandardPriceTableIsImported() {
        let text = """
        ### Standard pricing data
        | gpt-6.1-sol | $2 | $0.1 | $2.5 | $10 | $4 | $0.2 | $5 | $15 |
        | gpt-invalid | $-2 | $1 | $1 | $1 | $1 | $1 | $1 | $1 |
        ### Batch pricing data
        | gpt-6.1-sol | $1 | $0.05 | $1.25 | $5 | $2 | $0.1 | $2.5 | $7.5 |
        """
        XCTAssertEqual(PricingStore.parsePrices(text)["gpt-6.1-sol"]?.first, 2)
        XCTAssertNil(PricingStore.parsePrices(text)["gpt-invalid"])
        XCTAssertTrue(PricingStore.parsePrices("<html>Changed page</html>").isEmpty)
    }
    func testExchangePairAndRateValidation() throws {
        let data = Data(#"{"date":"2026-10-14","base":"USD","quote":"KRW","rate":1339.21}"#.utf8)
        XCTAssertEqual(try PricingStore.parseFX(data).0, 1339.21)
        XCTAssertThrowsError(try PricingStore.parseFX(Data(#"{"date":"2026-10-14","base":"EUR","quote":"KRW","rate":1339.21}"#.utf8)))
    }

}
