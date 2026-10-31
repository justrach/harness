import XCTest
import UIKit
@testable import Harness

/// The desktop's lifted plane on the phone: the session column beside another column washes toward white on
/// light themes, and the working spinners take the theme's accent family.
final class ContentPlaneTests: XCTestCase {
    private func hex(_ css: String) -> HexColor { HexColor(css)! }

    private func luminance(_ c: HexColor) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    // MARK: The plane

    func testDarkThemesKeepTheColumnFlush() {
        XCTAssertNil(Theme.contentPlaneLift(dark: true))
        XCTAssertEqual(Theme.liftedPage(hex("#16140f"), dark: true), hex("#16140f"))
    }

    func testLightThemesLayTheDesktopsWhiteOverThePage() {
        XCTAssertEqual(Theme.contentPlaneLift(dark: false), 0.55)
        // Codegraff Light's page, 55% white over it.
        let lifted = Theme.liftedPage(hex("#faf8f3"), dark: false)
        XCTAssertEqual(lifted.red, (250.0 / 255) * 0.45 + 0.55, accuracy: 1e-9)
        XCTAssertEqual(lifted.green, (248.0 / 255) * 0.45 + 0.55, accuracy: 1e-9)
        XCTAssertEqual(lifted.blue, (243.0 / 255) * 0.45 + 0.55, accuracy: 1e-9)
        XCTAssertEqual(lifted.alpha, 1)
        // A white page has nowhere to go.
        XCTAssertEqual(Theme.liftedPage(hex("#ffffff"), dark: false), hex("#ffffff"))
    }

    func testOnEveryLightThemeTheLiftedPageIsBrighterThanTheListBesideIt() {
        let light = ThemeCatalog.builtin.variants.filter { $0.appearance == .light }
        XCTAssertFalse(light.isEmpty)
        for variant in light {
            let page = Theme.liftedPage(variant.colors.background, dark: false)
            XCTAssertGreaterThan(luminance(page), luminance(variant.colors.shell), variant.id)
            XCTAssertGreaterThanOrEqual(luminance(page), luminance(variant.colors.background), variant.id)
        }
    }

    // MARK: Spinner tints

    func testEveryThemesSpinnerRunsLightToDeepThroughItsAccent() {
        for variant in ThemeCatalog.builtin.variants {
            let accent = variant.accent
            let tints = GradientSpin.rowTints(glyph: accent.glyph, primary: accent.primary,
                                              dark: variant.appearance == .dark)
            XCTAssertEqual(tints.count, 3, variant.id)
            XCTAssertEqual(tints[1], accent.primary, variant.id)
            XCTAssertGreaterThan(luminance(tints[0]), luminance(tints[1]), variant.id)
            XCTAssertGreaterThan(luminance(tints[1]), luminance(tints[2]), variant.id)
        }
    }

    func testTheSpinnerNoLongerUsesTheFixedSunriseTints() {
        let sunrise = [hex("#B6D3EF"), hex("#EDB185"), hex("#F888A0")]
        let accent = ThemeCatalog.builtin.variant("harnesser-light")!.accent
        XCTAssertNotEqual(GradientSpin.rowTints(glyph: accent.glyph, primary: accent.primary, dark: false), sunrise)
    }

    func testWithoutAuthoredTonesTheAccentIsMixedTowardWhiteAndBlack() {
        let primary = hex("#5b43e8")
        for dark in [false, true] {
            let tints = GradientSpin.rowTints(glyph: nil, primary: primary, dark: dark)
            XCTAssertEqual(tints.count, 3)
            XCTAssertEqual(tints[1], primary)
            XCTAssertGreaterThan(luminance(tints[0]), luminance(primary))
            XCTAssertLessThan(luminance(tints[2]), luminance(primary))
            // Mixing toward white or black keeps the accent's hue.
            for tint in [tints[0], tints[2]] {
                var hue: CGFloat = 0, accentHue: CGFloat = 0
                UIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
                    .getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
                UIColor(red: primary.red, green: primary.green, blue: primary.blue, alpha: 1)
                    .getHue(&accentHue, saturation: nil, brightness: nil, alpha: nil)
                XCTAssertEqual(hue, accentHue, accuracy: 0.002)
            }
        }
        // A malformed glyph (not three rows) falls back the same way.
        XCTAssertEqual(GradientSpin.rowTints(glyph: [primary], primary: primary, dark: false),
                       GradientSpin.rowTints(glyph: nil, primary: primary, dark: false))
    }
}
