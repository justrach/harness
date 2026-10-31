import UIKit
import XCTest

@MainActor
final class ReasoningConfirmationUITests: XCTestCase {
    func testConfirmationMatchesSelectionAcrossThemes() throws {
        continueAfterFailure = false
        let themes = [
            ("harnesser-light", "light"),
            ("codegraff-dark", "dark"),
            ("tokyo-night", "dark"),
            ("gruvbox-light", "light"),
            ("synthwave-84", "dark"),
        ]
        for (theme, appearance) in themes {
            let app = XCUIApplication()
            app.launchArguments = ["-demo", "-route", "chat:chat-tabs", "-phoneSplit", "off",
                                   "-theme.mode", appearance, "-theme.\(appearance)", theme,
                                   "-theme.followDesktop", "NO"]
            app.launch()
            let composer = app.descendants(matching: .any)["composer-input"].firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            composer.tap()
            let high = app.buttons["High"]
            XCTAssertTrue(high.waitForExistence(timeout: 5))
            high.tap()

            let confirm = app.buttons["reasoning-picker-confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            XCTAssertEqual(confirm.label, "Close", theme)
            let slider = app.descendants(matching: .any)["reasoning-slider"].firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            XCTAssertEqual(slider.value as? String, "High", theme)

            // The track's left end is the fastest level; the thumb settles on it.
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            XCTAssertEqual(slider.value as? String, "Low", theme)
            XCTAssertEqual(confirm.label, "Done", theme)
            XCTAssertTrue(confirm.isHittable)

            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "reasoning-confirmation-\(theme)"
            attachment.lifetime = .keepAlways
            add(attachment)

            try select("High", on: slider)
            XCTAssertEqual(confirm.label, "Close", "A → B → A restores X: \(theme)")
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            XCTAssertEqual(confirm.label, "Done", theme)
            confirm.tap()
            let low = app.buttons["Low"]
            XCTAssertTrue(low.waitForExistence(timeout: 5))
            low.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            XCTAssertEqual(confirm.label, "Close", "Reopening resets the baseline: \(theme)")
            confirm.tap()
            app.terminate()
        }
    }

    /// Tap along the track until the thumb settles on `level`.
    private func select(_ level: String, on slider: XCUIElement) throws {
        for step in 1..<20 {
            slider.coordinate(withNormalizedOffset: CGVector(dx: Double(step) / 20, dy: 0.5)).tap()
            if slider.value as? String == level { return }
        }
        XCTFail("No point on the track settles on \(level)")
    }
}
