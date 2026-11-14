import XCTest
@testable import Harness

final class CoverSessionDrawerTests: XCTestCase {
    func testOnlyTheDuoCoverOffersTheDrawer() {
        XCTAssertTrue(CoverSessionDrawer.isAvailable(duo: true, compactWidth: true, fold: .none))
        XCTAssertFalse(CoverSessionDrawer.isAvailable(duo: false, compactWidth: true, fold: .none))
        XCTAssertFalse(CoverSessionDrawer.isAvailable(duo: true, compactWidth: false, fold: .none))
        XCTAssertFalse(CoverSessionDrawer.isAvailable(duo: true, compactWidth: true,
                                                     fold: .sideBySide(leading: 300, gap: 20)))
        XCTAssertFalse(CoverSessionDrawer.isAvailable(duo: true, compactWidth: true,
                                                     fold: .stacked(top: 300, gap: 20)))
    }

    func testDrawerLeavesATappableChatStripAndNeverConsumesTheControlRail() {
        // The 466pt cover has an 84pt system control rail; use only the remaining safe width.
        let safeWidth: CGFloat = 466 - 84
        XCTAssertEqual(CoverSessionDrawer.width(in: safeWidth), 318)
        XCTAssertEqual(safeWidth - CoverSessionDrawer.width(in: safeWidth), 64)
        XCTAssertLessThan(CoverSessionDrawer.width(in: safeWidth), safeWidth)
        XCTAssertEqual(CoverSessionDrawer.width(in: 200), 164)
        XCTAssertEqual(CoverSessionDrawer.width(in: 0), 0)
    }
}
