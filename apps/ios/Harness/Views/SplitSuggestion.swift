// A one-time, gentle offer of the phone split. The split is a setting most people will never open, so the app
// offers it at the moment it helps: the window has room for it AND the person is juggling sessions (opening one
// after another). Everything here is local — a few timestamps in UserDefaults, never uploaded — and the rule is
// pure so the trigger and the frequency cap are unit-tested.
//
// It never offers when there is nothing to offer (no room), when the setting is already on, for large text, or
// more than twice, a week apart. "Not now" and "Try it" both count as an answer.

import SwiftUI

struct SplitSuggestion: Equatable {
    var shownCount = 0
    var lastShownAt: TimeInterval?
    /// Recent session opens, epoch seconds, trimmed to the window that can still count.
    var opens: [TimeInterval] = []

    static let maxShows = 2
    static let minimumGap: TimeInterval = 7 * 24 * 3600
    /// Opening this many sessions inside the window reads as juggling.
    static let jugglingOpens = 3
    static let jugglingWindow: TimeInterval = 10 * 60
    static let storageKey = "splitSuggestion"

    struct Context {
        var mode: PhoneSplit
        var isPhone: Bool
        var compactWidth: Bool
        var size: CGSize
        var largeText: Bool
    }

    mutating func recordOpen(at now: TimeInterval) {
        opens.append(now)
        opens = opens.filter { now - $0 <= Self.jugglingWindow }
    }

    mutating func markShown(at now: TimeInterval) {
        shownCount += 1
        lastShownAt = now
    }

    func shouldOffer(_ context: Context, now: TimeInterval) -> Bool {
        guard context.isPhone, context.compactWidth, context.mode == .off, !context.largeText else { return false }
        // No room, nothing to offer: the split would not appear, so asking would only confuse.
        guard context.size.width >= PhoneSplit.minimumWidthSideBySide else { return false }
        guard shownCount < Self.maxShows else { return false }
        if let last = lastShownAt, now - last < Self.minimumGap { return false }
        return opens.filter { now - $0 <= Self.jugglingWindow }.count >= Self.jugglingOpens
    }

    // MARK: Storage
    // Three plain keys, not one JSON blob: a launch argument can only carry a plain string, so a UI test can seed
    // each of these (`-splitSuggestion.opens 1790.5,1791.5`) and a person can read them with `defaults read`.

    private static func key(_ name: String) -> String { "\(storageKey).\(name)" }

    static func load(_ defaults: UserDefaults = .standard) -> SplitSuggestion {
        var value = SplitSuggestion()
        value.shownCount = max(0, defaults.integer(forKey: key("shown")))
        if defaults.object(forKey: key("lastShownAt")) != nil {
            value.lastShownAt = defaults.double(forKey: key("lastShownAt"))
        }
        value.opens = (defaults.string(forKey: key("opens")) ?? "")
            .split(separator: ",")
            .compactMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        return value
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(shownCount, forKey: Self.key("shown"))
        if let lastShownAt {
            defaults.set(lastShownAt, forKey: Self.key("lastShownAt"))
        } else {
            defaults.removeObject(forKey: Self.key("lastShownAt"))
        }
        defaults.set(opens.map { String($0) }.joined(separator: ","), forKey: Self.key("opens"))
    }
}

/// The inline offer, above the session list. Two plain answers, and where to change it later.
struct SplitOfferBanner: View {
    let tryIt: () -> Void
    let notNow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep your list beside the session")
                    .font(Theme.sans(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("There's room for both. Split view shows your sessions while you work. You can change it in Settings → Layout.")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textMuted)
                HStack(spacing: 16) {
                    Button("Try it", action: tryIt)
                        .font(Theme.sans(13, weight: .medium))
                        .accessibilityIdentifier("split-offer-try")
                    Button("Not now", action: notNow)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityIdentifier("split-offer-later")
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("split-offer")
    }
}
