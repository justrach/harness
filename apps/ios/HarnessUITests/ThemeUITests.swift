import XCTest

/// The desktop theme catalog on the phone: picking a variant repaints the app
/// live, and the appearance mode swaps between the light and dark choices.
@MainActor
final class ThemeUITests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func preview(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["theme-preview"]
    }

    func testPickingAThemeRepaintsLiveAndModeSwapsVariants() {
        let app = XCUIApplication()
        // Launch-argument defaults pin the starting point regardless of what
        // an earlier run persisted.
        app.launchArguments = ["-demo", "-theme.mode", "dark",
                               "-theme.dark", "harnesser-dark", "-theme.light", "harnesser-light"]
        app.launch()

        let menu = app.buttons["account-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Appearance"].tap()
        XCTAssertTrue(preview(app).waitForExistence(timeout: 5))
        XCTAssertEqual(preview(app).label, "Preview of Harness Dark")
        capture("theme-sheet-harness-dark")

        let nord = app.buttons["theme-nord"]
        for _ in 0..<6 where !nord.isHittable { app.swipeUp() }
        nord.tap()
        for _ in 0..<6 where !preview(app).isHittable { app.swipeDown() }
        XCTAssertEqual(preview(app).label, "Preview of Nord")
        capture("theme-sheet-nord")

        app.segmentedControls["appearance-mode"].buttons["Light"].tap()
        XCTAssertEqual(preview(app).label, "Preview of Harness Light")
        capture("theme-sheet-harness-light")

        app.buttons["appearance-done"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        capture("theme-home-harness-light")
    }
}
