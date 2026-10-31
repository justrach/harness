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
}
