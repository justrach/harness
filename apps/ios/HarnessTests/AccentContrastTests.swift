import XCTest
import UIKit
@testable import Harness

/// The composer's send button is filled with the theme accent; its glyph must
/// stay readable on any accent a theme or the person picks.
final class AccentContrastTests: XCTestCase {
    func testDarkAccentsGetWhiteAndLightAccentsGetBlack() {
        let navy = UIColor(red: 0.10, green: 0.20, blue: 0.55, alpha: 1)
        let amber = UIColor(red: 1.00, green: 0.80, blue: 0.20, alpha: 1)
        XCTAssertEqual(Theme.readableForeground(on: navy), .white)
        XCTAssertEqual(Theme.readableForeground(on: amber), .black)
    }

    func testTheChosenForegroundIsTheMoreReadableOne() {
        // The desktop's orange accent: whichever is picked must beat the other.
        let orange = UIColor(red: 0.80, green: 0.47, blue: 0.13, alpha: 1)
        let chosen = Theme.readableForeground(on: orange)
        let other: UIColor = chosen == .black ? .white : .black
        XCTAssertGreaterThanOrEqual(
            Theme.contrastRatio(chosen, orange), Theme.contrastRatio(other, orange))
    }

    func testContrastRatioMatchesWCAGAtTheExtremes() {
        XCTAssertEqual(Theme.contrastRatio(.black, .white), 21, accuracy: 0.01)
        XCTAssertEqual(Theme.contrastRatio(.white, .white), 1, accuracy: 0.01)
    }
}
