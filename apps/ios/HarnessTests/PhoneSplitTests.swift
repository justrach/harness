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
        XCTAssertEqual(wide?.axis, .sideBySide)
        XCTAssertEqual(wide?.listExtent ?? 0, 874 * 0.38, accuracy: 0.001)
    }

    func testStackedNeedsHeightAndIsLeftAloneInLandscape() {
        XCTAssertNil(PhoneSplit.arrangement(mode: .stacked, in: landscape), "too short for two panes")
        XCTAssertNil(PhoneSplit.arrangement(mode: .stacked, in: CGSize(width: 393, height: 599)))
        let tall = PhoneSplit.arrangement(mode: .stacked, in: portrait)
        XCTAssertEqual(tall?.axis, .stacked)
        XCTAssertEqual(tall?.listExtent ?? 0, 852 * 0.45, accuracy: 0.001)
    }

    func testThePaneNeverGetsTooSmallOrTooLarge() {
        XCTAssertEqual(PhoneSplit.arrangement(mode: .sideBySide, in: CGSize(width: 1400, height: 800))?.listExtent,
                       PhoneSplit.sideListRange.upperBound)
        XCTAssertEqual(PhoneSplit.arrangement(mode: .sideBySide, in: CGSize(width: 600, height: 400))?.listExtent,
                       PhoneSplit.sideListRange.lowerBound)
        XCTAssertEqual(PhoneSplit.arrangement(mode: .stacked, in: CGSize(width: 400, height: 1600))?.listExtent,
                       PhoneSplit.stackedListRange.upperBound)
        // At the smallest window the stacked shape is allowed in, the pane is already comfortably above its floor.
        XCTAssertEqual(PhoneSplit.arrangement(mode: .stacked, in: CGSize(width: 400, height: 600))?.listExtent ?? 0,
                       270, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(270, PhoneSplit.stackedListRange.lowerBound)
    }

    func testAnUnknownStoredValueFallsBackToOff() {
        XCTAssertEqual(PhoneSplit(rawValue: "sideBySide"), .sideBySide)
        XCTAssertEqual(PhoneSplit(rawValue: "stacked"), .stacked)
        XCTAssertNil(PhoneSplit(rawValue: "diagonal"))
        XCTAssertEqual(PhoneSplit(rawValue: "diagonal") ?? .off, .off)
        XCTAssertEqual(PhoneSplit.allCases.map(\.label), ["Off", "Auto", "Side by side", "Stacked"])
    }

    func testAutoSplitsSideBySideOnlyWhereThereIsRoomAndNeverStacks() {
        XCTAssertNil(PhoneSplit.arrangement(mode: .auto, in: portrait), "no room: Auto leaves the single stack")
        XCTAssertNil(PhoneSplit.arrangement(mode: .auto, in: CGSize(width: 599, height: 900)))
        XCTAssertEqual(PhoneSplit.arrangement(mode: .auto, in: landscape),
                       PhoneSplit.arrangement(mode: .sideBySide, in: landscape))
        XCTAssertEqual(PhoneSplit.arrangement(mode: .auto, in: landscape)?.axis, .sideBySide)
        // A tall, wide window (an unfolded fold) is still side by side, never stacked.
        XCTAssertEqual(PhoneSplit.arrangement(mode: .auto, in: CGSize(width: 700, height: 900))?.axis, .sideBySide)
    }
}
