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

    func testWholeNavigationPageMovesWithoutShrinkingTheChat() {
        // The drawer includes its own 84pt native rail. Translate the full old
        // page so Back (at x 418) lands in the 64pt strip at x 16.
        let width: CGFloat = 466
        let drawer = CoverSessionDrawer.width(in: width)
        XCTAssertEqual(drawer, 402)
        XCTAssertEqual(width - drawer, 64)
        XCTAssertEqual(drawer - 84, 318)
        XCTAssertEqual(CoverSessionDrawer.chatOffset(shown: false, width: width), 0)
        XCTAssertEqual(CoverSessionDrawer.chatOffset(shown: true, width: width), -drawer)
        XCTAssertEqual(418 + CoverSessionDrawer.chatOffset(shown: true, width: width), 16)
        XCTAssertEqual(CoverSessionDrawer.width(in: 200), 164)
        XCTAssertEqual(CoverSessionDrawer.width(in: 0), 0)
    }
}
