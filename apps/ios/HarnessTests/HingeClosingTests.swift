import XCTest
@testable import Harness

final class HingeClosingTests: XCTestCase {
    func testFlatAndBookPosesAreUntouched() {
        XCTAssertEqual(HingeClosing.progress(degrees: 180), 0)
        XCTAssertEqual(HingeClosing.progress(degrees: 128), 0)
        XCTAssertEqual(HingeClosing.progress(degrees: HingeClosing.startDegrees), 0)
    }

    func testClosedIsFullyReceded() {
        XCTAssertEqual(HingeClosing.progress(degrees: HingeClosing.endDegrees), 1)
        XCTAssertEqual(HingeClosing.progress(degrees: 0), 1)
    }

    func testProgressGrowsAsTheHingeCloses() {
        // The angles a simulated close sweeps through.
        let sweep = [106.0, 89, 73, 64, 52, 20].map { HingeClosing.progress(degrees: $0) }
        XCTAssertEqual(sweep, sweep.sorted())
        XCTAssertGreaterThan(sweep[1], 0.1)
        XCTAssertGreaterThan(sweep[4], 0.5)
    }
}
