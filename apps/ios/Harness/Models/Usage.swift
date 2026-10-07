// Usage as the host engines report it: the CodeGraff account a computer is
// signed in with (`CodegraffUsage`, codegraff_auth.rs — snake_case on the
// wire) and each agent CLI's rate-limit windows (`ListAgentAccounts`,
// harness-proto AgentAccountsSnapshot — camelCase). Formatting mirrors the
// desktop's Settings → Accounts (crates/ui/src/settings/accounts.rs).

import Foundation

struct CodegraffUsage: Decodable, Equatable {
    var email: String
    var tier: String
    var creditsMicroUSD: Int64
    var spend30dMicroUSD: Int64
    var requests30d: Int64
    var keyBudgetMonthlyMicroUSD: Int64?
    var keySpendMonthlyMicroUSD: Int64
    var keyBudgetResetsAt: String

    enum CodingKeys: String, CodingKey {
        case email, tier
        case creditsMicroUSD = "credits_micro_usd"
        case spend30dMicroUSD = "spend_30d_micro_usd"
        case requests30d = "requests_30d"
        case keyBudgetMonthlyMicroUSD = "key_budget_monthly_micro_usd"
        case keySpendMonthlyMicroUSD = "key_spend_monthly_micro_usd"
        case keyBudgetResetsAt = "key_budget_resets_at"
    }

    /// The monthly key budget as a meter; nil when the key has no budget.
    var budgetWindow: UsageWindow? {
        guard let limit = keyBudgetMonthlyMicroUSD else { return nil }
        let fraction = limit <= 0 ? 1 : min(max(Double(keySpendMonthlyMicroUSD) / Double(limit), 0), 1)
        return UsageWindow(label: "Monthly key budget", usedFraction: fraction,
                           resetsAt: parseUsageDate(keyBudgetResetsAt))
    }
}

struct UsageWindow: Equatable, Identifiable {
    var id: String { label }
    var label: String
    /// 0...1
    var usedFraction: Double
    var resetsAt: Date?

    enum Level: Equatable { case normal, warn, critical }

    /// accounts.rs USAGE_WARN_FRACTION / USAGE_CRITICAL_FRACTION.
    var level: Level {
        if usedFraction >= 0.95 { return .critical }
        if usedFraction >= 0.80 { return .warn }
        return .normal
    }
}

struct AgentAccountsSnapshot: Decodable, Equatable {
    var accounts: [AgentAccount]

    enum CodingKeys: String, CodingKey { case accounts }
}

struct AgentAccount: Decodable, Equatable, Identifiable {
    var id: String
    var harness: String
    var email: String?
    var planLabel: String?
    var displayName: String?
    var active: Bool
    var usageWindows: [UsageWindow]

    enum CodingKeys: String, CodingKey {
        case id, harness, email, planLabel, displayName, active, usageWindows
    }

    private struct WireWindow: Decodable {
        var label: String
        var usedFraction: Double
        var resetsAt: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        harness = try c.decode(String.self, forKey: .harness)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        planLabel = try c.decodeIfPresent(String.self, forKey: .planLabel)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        usageWindows = (try c.decodeIfPresent([WireWindow].self, forKey: .usageWindows) ?? []).map {
            UsageWindow(label: $0.label, usedFraction: min(max($0.usedFraction, 0), 1),
                        resetsAt: $0.resetsAt.flatMap(parseUsageDate))
        }
    }

    /// Who the login belongs to, for the row title.
    var title: String {
        email ?? displayName ?? HarnessCatalog.label(for: harness)
    }
}

/// accounts.rs `format_micro_usd`: more decimals for small amounts so a
/// few cents of spend never reads as $0.00.
func formatMicroUSD(_ amount: Int64) -> String {
    let dollars = Double(amount) / 1_000_000
    let decimals = abs(dollars) < 0.01 ? 6 : abs(dollars) < 1 ? 4 : 2
    return String(format: "$%.\(decimals)f", dollars)
}

/// "Resets in 3h 20m" / "Resets in 2d 4h"; nil once the reset has passed.
func formatResetsIn(_ resetsAt: Date?, now: Date = Date()) -> String? {
    guard let resetsAt else { return nil }
    let seconds = Int(resetsAt.timeIntervalSince(now))
    guard seconds > 0 else { return nil }
    let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
    if days > 0 { return "Resets in \(days)d \(hours % 24)h" }
    if hours > 0 { return "Resets in \(hours)h \(minutes % 60)m" }
    return "Resets in \(max(minutes, 1))m"
}

/// RFC 3339, with or without fractional seconds (chrono emits both).
func parseUsageDate(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
}
