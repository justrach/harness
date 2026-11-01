import XCTest

@MainActor
final class SessionSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", "", "-homeGroupBy", "none", "-phoneSplit", "off"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The demo has sessions running and waiting on you. Home shows them as the
    /// Now strip; in a session the header's arrows step through them in one
    /// fixed order (#430: the status marks beside them are display-only, so the
    /// floating pill and its list are gone). Stepping swaps the open session in
    /// place rather than pushing another screen.
    func testHeaderArrowsJumpBetweenSessionsInPlace() {
        let card = app.buttons["now-card-chat-veil"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()

        let header = element("session-header")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["session-switcher"].exists)
        let position = element("session-page-position")
        XCTAssertTrue(position.label.hasPrefix("Session 1 of "), position.label)
        let before = header.label

        app.buttons["session-page-next"].tap()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: header)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(position.label.hasPrefix("Session 2 of "), position.label)

        // Jumping swaps the session: one Back returns Home.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home-group-by"].waitForExistence(timeout: 5))
    }
}
