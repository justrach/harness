import XCTest

/// Run on the Duo cover simulator, with synthetic demo sessions only.
@MainActor
final class CoverSessionDrawerUITests: XCTestCase {
    private func launch(duo: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs",
                               "-phoneSplit", "off", "-foldableDevice", duo ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 10))
        return app
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDrawerOpensOverChatAndClosesWithoutReplacingIt() {
        let app = launch()
        let toggle = app.buttons["duo-cover-toggle-sessions"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.exists)
        XCTAssertLessThan(abs(toggle.frame.midY - back.frame.midY), 100,
                          "The sessions button belongs beside Back, not at the bottom of the rail")
        let title = app.descendants(matching: .any)["session-header"].label
        screenshot("cover-drawer-collapsed")
        toggle.tap()
        XCTAssertTrue(app.textFields["cover-sessions-search"].waitForExistence(timeout: 5))
        let list = app.descendants(matching: .any)["cover-sessions-list"]
        let backdrop = app.buttons["cover-sessions-backdrop"]
        XCTAssertGreaterThanOrEqual(backdrop.frame.width, 44)
        XCTAssertLessThan(backdrop.frame.maxX, list.frame.maxX)
        screenshot("cover-drawer-expanded")
        backdrop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["session-header"].label, title)
        XCTAssertFalse(app.textFields["cover-sessions-search"].exists)
    }

    func testSearchAndSelectionSwitchInPlaceIncludingBackToTheOriginalSession() {
        let app = launch()
        let original = app.descendants(matching: .any)["session-header"].label
        app.buttons["duo-cover-toggle-sessions"].tap()
        let search = app.textFields["cover-sessions-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("no matching synthetic session")
        XCTAssertTrue(app.staticTexts["No matching sessions"].waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                               count: "no matching synthetic session".count))
        // Pick another synthetic demo session, then pick the original again. Back must still lead Home.
        let other = app.descendants(matching: .any)["cover-session-chat-deploy"]
        if !other.isHittable { app.swipeUp() }
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertFalse(search.exists)
        XCTAssertNotEqual(app.descendants(matching: .any)["session-header"].label, original)
        app.buttons["duo-cover-toggle-sessions"].tap()
        let row = app.descendants(matching: .any)["cover-session-chat-tabs"]
        if !row.isHittable { app.swipeDown() }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["session-header"].label, original)
        XCTAssertFalse(search.exists)
    }

    func testOrdinaryPhoneDoesNotOfferTheDrawer() {
        let app = launch(duo: false)
        XCTAssertFalse(app.buttons["duo-cover-toggle-sessions"].exists)
    }
}
