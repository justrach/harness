import XCTest

@MainActor
final class ConnectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    /// Settings > Diagnostics > Connection answers "why offline?" in plain words, with a Copy button.
    func testConnectionScreenShowsSignInRegistryAndDevices() {
        let settings = app.buttons["home-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let link = app.buttons["settings-connection"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()

        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Account"].exists)
        XCTAssertTrue(app.staticTexts["Access token"].exists)
        XCTAssertTrue(app.staticTexts["Last refresh"].exists)
        XCTAssertTrue(app.staticTexts["Status"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Copy report"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh"].exists)
    }
}
