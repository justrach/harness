import XCTest
@testable import Harness

/// When the app offers the phone split: only with room, only while juggling, and never more than twice.
final class SplitSuggestionTests: XCTestCase {
    private let now: TimeInterval = 1_000_000
    private let landscape = CGSize(width: 874, height: 402)
    private let portrait = CGSize(width: 393, height: 852)

    private func context(mode: PhoneSplit = .off, isPhone: Bool = true, compact: Bool = true,
                         size: CGSize? = nil, largeText: Bool = false) -> SplitSuggestion.Context {
        .init(mode: mode, isPhone: isPhone, compactWidth: compact, size: size ?? landscape, largeText: largeText)
    }

    private func juggling(opens: Int = 3, secondsAgo: TimeInterval = 30) -> SplitSuggestion {
        var s = SplitSuggestion()
        for i in 0..<opens { s.recordOpen(at: now - secondsAgo + Double(i)) }
        return s
    }

    func testOffersWhenThereIsRoomAndTheyAreJuggling() {
        XCTAssertTrue(juggling().shouldOffer(context(), now: now))
    }

    func testOneOrTwoOpensIsNotJuggling() {
        XCTAssertFalse(juggling(opens: 1).shouldOffer(context(), now: now))
        XCTAssertFalse(juggling(opens: 2).shouldOffer(context(), now: now))
    }

    func testOpensOlderThanTenMinutesDoNotCount() {
        XCTAssertFalse(juggling(opens: 3, secondsAgo: 11 * 60).shouldOffer(context(), now: now))
        var mixed = SplitSuggestion()
        mixed.recordOpen(at: now - 15 * 60)
        mixed.recordOpen(at: now - 20)
        mixed.recordOpen(at: now - 10)
        XCTAssertEqual(mixed.opens.count, 2, "the stale open is dropped as new ones arrive")
        XCTAssertFalse(mixed.shouldOffer(context(), now: now))
    }

    func testNeverOffersWithNoRoomBecauseThereWouldBeNothingToTurnOn() {
        XCTAssertFalse(juggling().shouldOffer(context(size: portrait), now: now))
        XCTAssertFalse(juggling().shouldOffer(context(size: CGSize(width: 599, height: 900)), now: now))
    }

    func testNeverOffersWhenTheSplitIsAlreadyOnOrOnAnotherKindOfDevice() {
        for mode in [PhoneSplit.auto, .sideBySide, .stacked] {
            XCTAssertFalse(juggling().shouldOffer(context(mode: mode), now: now), "\(mode) is already chosen")
        }
        XCTAssertFalse(juggling().shouldOffer(context(isPhone: false), now: now), "iPad already splits")
        XCTAssertFalse(juggling().shouldOffer(context(compact: false), now: now),
                       "a regular-width phone (a Pro Max in landscape) already has the sidebar")
    }

    func testLargeTextIsLeftAlone() {
        XCTAssertFalse(juggling().shouldOffer(context(largeText: true), now: now))
    }

    func testAnswerCapsTheOfferAtTwiceAWeekApart() {
        var s = juggling()
        s.markShown(at: now)
        XCTAssertFalse(s.shouldOffer(context(), now: now + 3 * 86_400), "not again within a week")
        s.recordOpen(at: now + 8 * 86_400 - 5); s.recordOpen(at: now + 8 * 86_400 - 4)
        s.recordOpen(at: now + 8 * 86_400 - 3)
        XCTAssertTrue(s.shouldOffer(context(), now: now + 8 * 86_400), "a week on, while juggling, once more")
        s.markShown(at: now + 8 * 86_400)
        s.recordOpen(at: now + 20 * 86_400 - 5); s.recordOpen(at: now + 20 * 86_400 - 4)
        s.recordOpen(at: now + 20 * 86_400 - 3)
        XCTAssertFalse(s.shouldOffer(context(), now: now + 20 * 86_400), "two answers is the limit")
    }

    func testStorageRoundTripsAndNothingStoredStartsFresh() {
        let defaults = UserDefaults(suiteName: "split-suggestion-tests")!
        defaults.removePersistentDomain(forName: "split-suggestion-tests")
        XCTAssertEqual(SplitSuggestion.load(defaults), SplitSuggestion())

        var s = juggling()
        s.markShown(at: now)
        s.save(defaults)
        XCTAssertEqual(SplitSuggestion.load(defaults), s)
    }

    func testBrokenStoredValuesAreIgnoredNotTrusted() {
        let defaults = UserDefaults(suiteName: "split-suggestion-tests-broken")!
        defaults.removePersistentDomain(forName: "split-suggestion-tests-broken")
        defaults.set("1.5, not-a-number ,2.5,,", forKey: "\(SplitSuggestion.storageKey).opens")
        defaults.set(-4, forKey: "\(SplitSuggestion.storageKey).shown")
        let s = SplitSuggestion.load(defaults)
        XCTAssertEqual(s.opens, [1.5, 2.5], "only the readable times are kept")
        XCTAssertEqual(s.shownCount, 0, "a negative count is clamped, never read as already-shown")
        XCTAssertNil(s.lastShownAt)
    }

    func testAPlainStringSeedsTheOpensTheWayALaunchArgumentDoes() {
        // A launch argument can only be a plain string: `-splitSuggestion.opens 100.5,101.5,102.5`.
        let defaults = UserDefaults(suiteName: "split-suggestion-tests-seed")!
        defaults.removePersistentDomain(forName: "split-suggestion-tests-seed")
        defaults.set("\(now - 30),\(now - 20),\(now - 10)", forKey: "\(SplitSuggestion.storageKey).opens")
        XCTAssertTrue(SplitSuggestion.load(defaults).shouldOffer(context(), now: now))
    }
}
