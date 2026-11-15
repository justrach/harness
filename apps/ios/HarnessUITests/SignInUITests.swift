import XCTest

/// The sign-in sheet end to end: AuthenticationServices loads when it is first
/// needed, so this is the real session, reporting back through the runtime.
final class SignInUITests: XCTestCase {
    /// Closing the sheet must reach the app as a cancel: the button comes back.
    /// Needs a signed-out app, so `simctl uninstall` first on a simulator that has
    /// a saved sign-in. Loads the sign-in page in a private session.
    func testClosingTheBrowserSheetLeavesTheButtonReady() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-phoneSplit", "off"]
        app.launch()
        let login = app.buttons["Log in to Harness"]
        guard login.waitForExistence(timeout: 15) else {
            throw XCTSkip("This simulator has a saved sign-in")
        }
        login.tap()
        let close = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the browser sheet opens")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "signin-sheet"
        shot.lifetime = .keepAlways
        add(shot)
        close.tap()
        XCTAssertTrue(login.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "isEnabled == true")
        wait(for: [XCTNSPredicateExpectation(predicate: ready, object: login)], timeout: 10)
        XCTAssertTrue(login.isEnabled, "the completion never reported the cancel")
    }
}
