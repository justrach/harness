import XCTest

@MainActor
final class SessionSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    /// The demo has sessions running and waiting on you: the pill lists
    /// them, and picking one opens it with the pill still there for the rest.
    func testPillListsActiveSessionsAndJumpsBetweenThem() {
        let pill = app.buttons["session-switcher"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "switcher-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let first = rows.firstMatch.identifier
        rows.firstMatch.tap()

        // In the session: the compact pill offers the others.
        let inSession = app.buttons["session-switcher"]
        XCTAssertTrue(inSession.waitForExistence(timeout: 10))
        inSession.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[first].exists, "the open session isn't offered again")
        rows.firstMatch.tap()

        // Jumping swaps the session: one Back returns Home.
        XCTAssertTrue(app.buttons["session-switcher"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home-status-all"].waitForExistence(timeout: 5))
    }
}
