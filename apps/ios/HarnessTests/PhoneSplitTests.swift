import XCTest
@testable import Harness

/// When a phone gets a split, and how big each pane is. Pure, so no UI is needed.
final class PhoneSplitTests: XCTestCase {
    private let portrait = CGSize(width: 393, height: 852)
    private let landscape = CGSize(width: 874, height: 402)

    func testOffNeverSplits() {
        XCTAssertNil(PhoneSplit.arrangement(mode: .off, in: portrait))
        XCTAssertNil(PhoneSplit.arrangement(mode: .off, in: landscape))
        XCTAssertNil(PhoneSplit.arrangement(mode: .off, in: CGSize(width: 1400, height: 1000)))
    }

    func testSideBySideNeedsWidthAndIsLeftAloneOnAPortraitPhone() {
        XCTAssertNil(PhoneSplit.arrangement(mode: .sideBySide, in: portrait), "too narrow for two panes")
        XCTAssertNil(PhoneSplit.arrangement(mode: .sideBySide, in: CGSize(width: 599, height: 400)))
        let wide = PhoneSplit.arrangement(mode: .sideBySide, in: landscape)
        XCTAssertEqual(wide?.listExtent ?? 0, 874 * 0.38, accuracy: 0.001)
    }

    func testThePaneNeverGetsTooSmallOrTooLarge() {
        XCTAssertEqual(PhoneSplit.arrangement(mode: .sideBySide, in: CGSize(width: 1400, height: 800))?.listExtent,
                       PhoneSplit.sideListRange.upperBound)
        XCTAssertEqual(PhoneSplit.arrangement(mode: .sideBySide, in: CGSize(width: 600, height: 400))?.listExtent,
                       PhoneSplit.sideListRange.lowerBound)
    }

    func testTheChoicesAreOffAutoAndSideBySide() {
        XCTAssertEqual(PhoneSplit.allCases.map(\.label), ["Off", "Auto", "Side by side"])
    }

    /// Stacked was removed. Someone who had picked it asked for a split, so it becomes Auto, not Off.
    func testAStoredStackedBecomesAutoAndAnUnknownValueOff() {
        XCTAssertEqual(PhoneSplit.stored("stacked"), .auto)
        XCTAssertEqual(PhoneSplit.stored("diagonal"), .off)
        XCTAssertEqual(PhoneSplit.stored(""), .off)
        for mode in PhoneSplit.allCases {
            XCTAssertEqual(PhoneSplit.stored(mode.rawValue), mode, "\(mode) round-trips")
        }
    }

    func testMigrationRewritesAStoredStackedAndDropsTheHandleKeys() {
        let name = "phone-split-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("stacked", forKey: PhoneSplit.storageKey)
        defaults.set("on", forKey: "rollout.stackedSplitDrag")
        defaults.set(true, forKey: "onboarding.stackedSplitDrag.seen")
        defaults.set(3, forKey: "usage.stackedSplitDrag.on.folded")
        defaults.set(7, forKey: "usage.other.on.folded")
        PhoneSplit.migrateStored(defaults)
        XCTAssertEqual(defaults.string(forKey: PhoneSplit.storageKey), "auto")
        XCTAssertNil(defaults.object(forKey: "rollout.stackedSplitDrag"))
        XCTAssertNil(defaults.object(forKey: "onboarding.stackedSplitDrag.seen"))
        XCTAssertNil(defaults.object(forKey: "usage.stackedSplitDrag.on.folded"))
        XCTAssertEqual(defaults.integer(forKey: "usage.other.on.folded"), 7, "other keys are left alone")

        defaults.set("sideBySide", forKey: PhoneSplit.storageKey)
        PhoneSplit.migrateStored(defaults)
        XCTAssertEqual(defaults.string(forKey: PhoneSplit.storageKey), "sideBySide", "a current choice is kept")
    }

    func testAutoSplitsSideBySideOnlyWhereThereIsRoom() {
        XCTAssertNil(PhoneSplit.arrangement(mode: .auto, in: portrait), "no room: Auto leaves the single stack")
        XCTAssertNil(PhoneSplit.arrangement(mode: .auto, in: CGSize(width: 599, height: 900)))
        XCTAssertEqual(PhoneSplit.arrangement(mode: .auto, in: landscape),
                       PhoneSplit.arrangement(mode: .sideBySide, in: landscape))
        // A tall, wide window (an unfolded fold) is side by side too.
        XCTAssertNotNil(PhoneSplit.arrangement(mode: .auto, in: CGSize(width: 700, height: 900)))
    }

    func testTheKeyboardDoesNotReshapeTheSplit() {
        let portrait = CGSize(width: 402, height: 778)
        // The keyboard: same width, shorter. The split keeps choosing from the full height.
        XCTAssertEqual(PhoneSplit.layoutSize(previous: portrait, measured: CGSize(width: 402, height: 484)), portrait)
        // The keyboard going away, or the first measurement: taken as measured.
        XCTAssertEqual(PhoneSplit.layoutSize(previous: CGSize(width: 402, height: 484), measured: portrait), portrait)
        XCTAssertEqual(PhoneSplit.layoutSize(previous: .zero, measured: portrait), portrait)
        // Rotating or unfolding changes the width: a new window, measured afresh.
        let landscape = CGSize(width: 874, height: 402)
        XCTAssertEqual(PhoneSplit.layoutSize(previous: portrait, measured: landscape), landscape)
    }
}
