import XCTest

@MainActor
final class ProfileUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    /// The person button opens the account (Profile); the gear opens app
    /// preferences (Settings), which no longer carries account rows.
    func testProfileAndSettingsAreSeparateDestinations() {
        let profile = app.buttons["home-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile-usage"].exists)
        XCTAssertTrue(app.buttons["profile-sign-out"].exists)
        app.navigationBars["Profile"].buttons["Done"].tap()

        let settings = app.buttons["home-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-appearance"].exists)
        XCTAssertFalse(app.buttons["Sign out"].exists)
        XCTAssertFalse(app.buttons["profile-usage"].exists)
    }
}
