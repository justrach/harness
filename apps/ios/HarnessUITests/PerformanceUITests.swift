import XCTest

@MainActor
final class PerformanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    /// Opening a session and settling a page shows up under Settings > Performance.
    func testOpeningASessionIsMeasuredAndShownInSettings() {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tool group header colors")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        let settings = app.buttons["home-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let link = app.buttons["settings-performance"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()

        XCTAssertTrue(app.navigationBars["Performance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["nav.open"].waitForExistence(timeout: 5), "opening a session was not measured")
        XCTAssertTrue(app.staticTexts["startup.firstFrame"].exists, "startup was not measured")
        // The list is longer than the screen: the report buttons sit at the bottom.
        app.swipeUp()
        XCTAssertTrue(app.buttons["Copy report"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Reset"].exists)
    }
}
