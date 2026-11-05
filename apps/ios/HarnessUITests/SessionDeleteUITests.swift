import XCTest

/// Error cards name a sign-in problem, and a session's Delete asks first.
/// Demo data only (`-demo`); nothing reaches a host.
@MainActor
final class SessionDeleteUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-phoneSplit", "off"] + extra
        app.launch()
        return app
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testErrorCardsNameSignedOutAndLimitReached() {
        let app = launch(["-route", "chat:chat-tabs", "-errors"])
        let labels = app.descendants(matching: .any).matching(identifier: "error-chip-label")
        XCTAssertTrue(labels.firstMatch.waitForExistence(timeout: 15))
        let texts = (0..<labels.count).map { labels.element(boundBy: $0).label }
        XCTAssertTrue(texts.contains("Signed out"), "\(texts)")
        XCTAssertTrue(texts.contains("Limit reached"), "\(texts)")
        XCTAssertTrue(texts.contains("Error"), "\(texts)")
        // Where to sign in, on the two the phone can't fix itself.
        let hints = app.descendants(matching: .any).matching(identifier: "error-chip-hint")
        XCTAssertEqual(hints.count, 2)
        keep(app, "error-cards")
    }

    func testDeleteAsksFirstThenRemovesTheSession() {
        let app = launch([])
        let title = "Wrangler deploy hygiene"
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        row.swipeLeft()
        let delete = app.buttons["session-delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        keep(app, "delete-swipe")
        delete.tap()
        let alert = app.alerts["Delete session?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        keep(app, "delete-confirm")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Cancel keeps the session")

        row.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].firstMatch.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
    }
}
