import XCTest
import SwiftUI
@testable import Harness

/// iPhone Duo: which way the fold splits the window, and padding around hardware that covers content.
final class FoldLayoutTests: XCTestCase {
    private let inner = CGSize(width: 669, height: 951)

    func testNoDivisionIsOneRegion() {
        XCTAssertEqual(FoldSplit.from(division: nil, in: inner), .none)
        XCTAssertEqual(FoldSplit.from(division: .null, in: inner), .none)
    }

    func testABookFoldSplitsSideBySideOnTheFold() {
        // A vertical division: 40pt wide, centred on the fold line.
        let fold = CGRect(x: 314.5, y: 0, width: 40, height: inner.height)
        XCTAssertEqual(FoldSplit.from(division: fold, in: inner), .sideBySide(leading: 314.5, gap: 40))
    }

    func testALaptopFoldStacks() {
        let fold = CGRect(x: 0, y: 455.5, width: inner.width, height: 40)
        XCTAssertEqual(FoldSplit.from(division: fold, in: inner), .stacked(top: 455.5, gap: 40))
    }

    func testADivisionOutsideTheViewIsIgnored() {
        let fold = CGRect(x: 900, y: 0, width: 40, height: inner.height)
        XCTAssertEqual(FoldSplit.from(division: fold, in: inner), .none)
    }

    func testIPhoneDuoLyingFlatIsTheOneColumnApp() {
        // Main put every regular-width window in the split, including the Duo's inner display lying flat.
        XCTAssertFalse(HomeColumns.listBesideSession(regularWidth: true, regularHeight: true, phone: true, fold: .none))
        // Folded like a laptop the layout stacks around the fold elsewhere; it is not the list beside the session.
        XCTAssertFalse(HomeColumns.listBesideSession(
            regularWidth: true, regularHeight: true, phone: true, fold: .stacked(top: 455.5, gap: 40)))
    }

    func testIPhoneDuoFoldedLikeABookSplitsOnTheFold() {
        XCTAssertTrue(HomeColumns.listBesideSession(
            regularWidth: true, regularHeight: true, phone: true, fold: .sideBySide(leading: 314.5, gap: 40)))
    }

    func testIPadAndAMaxInLandscapeKeepTheListBesideTheSession() {
        XCTAssertTrue(HomeColumns.listBesideSession(regularWidth: true, regularHeight: true, phone: false, fold: .none))
        XCTAssertTrue(HomeColumns.listBesideSession(regularWidth: true, regularHeight: false, phone: true, fold: .none))
    }

    func testCompactWidthIsOneColumn() {
        XCTAssertFalse(HomeColumns.listBesideSession(regularWidth: false, regularHeight: true, phone: true, fold: .none))
        XCTAssertFalse(HomeColumns.listBesideSession(regularWidth: false, regularHeight: true, phone: false, fold: .none))
    }

    func testOcclusionsOutsideTheBoundsAddNothing() {
        // The status bar strip sits in the safe area, outside the content's bounds.
        let bar = CGRect(x: inner.width, y: 0, width: 84, height: inner.height)
        XCTAssertEqual(OcclusionInsets.insets(for: [bar], in: inner), EdgeInsets())
    }

    func testACameraAtTheTopPushesContentDown() {
        let camera = CGRect(x: 300, y: -10, width: 60, height: 40)
        let insets = OcclusionInsets.insets(for: [camera], in: inner)
        XCTAssertEqual(insets.top, 30)
        XCTAssertEqual(insets.leading, 0)
        XCTAssertEqual(insets.bottom, 0)
        XCTAssertEqual(insets.trailing, 0)
    }

    func testACameraOnTheTrailingEdgePushesContentIn() {
        let camera = CGRect(x: inner.width - 30, y: 400, width: 50, height: 60)
        XCTAssertEqual(OcclusionInsets.insets(for: [camera], in: inner).trailing, 30)
    }

    func testFoldedSearchSitsInTheBar() {
        // Folded either way, the floating field covered a row of the half-height list or the column.
        XCTAssertTrue(SessionSearchPlacement.inBar(phoneSplit: false, fold: .stacked(top: 455.5, gap: 40)))
        XCTAssertTrue(SessionSearchPlacement.inBar(phoneSplit: false, fold: .sideBySide(leading: 314.5, gap: 40)))
        XCTAssertTrue(SessionSearchPlacement.inBar(phoneSplit: true, fold: .none))
        XCTAssertFalse(SessionSearchPlacement.inBar(phoneSplit: false, fold: .none))
    }
}
