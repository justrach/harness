import XCTest
@testable import Harness

final class UsageTests: XCTestCase {
    func testCodegraffUsageDecodesTheEngineWireShape() throws {
        let json = """
        {"email":"me@codegraff.dev","tier":"pro","credits_micro_usd":5000000,
         "spend_30d_micro_usd":1200000,"requests_30d":42,"prompt_tokens_30d":10,
         "completion_tokens_30d":20,"key_budget_monthly_micro_usd":8000000,
         "key_spend_monthly_micro_usd":7000000,"key_budget_resets_at":"2026-11-01T00:00:00Z"}
        """
        let usage = try JSONDecoder().decode(CodegraffUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.email, "me@codegraff.dev")
        XCTAssertEqual(usage.requests30d, 42)
        let budget = try XCTUnwrap(usage.budgetWindow)
        XCTAssertEqual(budget.usedFraction, 0.875, accuracy: 0.0001)
        XCTAssertEqual(budget.level, .warn)
        XCTAssertNotNil(budget.resetsAt)
    }

    func testSignedOutHostDecodesAsNoUsage() throws {
        let usage = try JSONDecoder().decode(CodegraffUsage?.self, from: Data("null".utf8))
        XCTAssertNil(usage)
    }

    func testAgentAccountsDecodeUsageWindows() throws {
        let json = """
        {"accounts":[{"id":"a1","harness":"claude-code","email":"me@example.com","planLabel":"Max",
          "active":true,"switchable":true,"usageWindows":[
            {"label":"5-hour","usedFraction":0.97,"resetsAt":"2026-10-04T05:00:00.123Z"},
            {"label":"Weekly","usedFraction":0.2,"resetsAt":null}]}],
         "warnings":[]}
        """
        let snapshot = try JSONDecoder().decode(AgentAccountsSnapshot.self, from: Data(json.utf8))
        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(account.title, "me@example.com")
        XCTAssertEqual(account.usageWindows.map(\.level), [.critical, .normal])
        XCTAssertNotNil(account.usageWindows[0].resetsAt, "fractional-second timestamps parse")
        XCTAssertNil(account.usageWindows[1].resetsAt)
    }

    func testMicroUSDMatchesTheDesktopFormatting() {
        XCTAssertEqual(formatMicroUSD(5_000_000), "$5.00")
        XCTAssertEqual(formatMicroUSD(120_000), "$0.1200")
        XCTAssertEqual(formatMicroUSD(1_234), "$0.001234")
    }

    func testResetCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(formatResetsIn(Date(timeIntervalSince1970: 3 * 3600 + 20 * 60), now: now), "Resets in 3h 20m")
        XCTAssertEqual(formatResetsIn(Date(timeIntervalSince1970: 2 * 86400 + 4 * 3600), now: now), "Resets in 2d 4h")
        XCTAssertNil(formatResetsIn(Date(timeIntervalSince1970: -5), now: now))
    }
}
