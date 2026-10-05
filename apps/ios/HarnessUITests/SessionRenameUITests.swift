import XCTest

@MainActor
final class SessionRenameUITests: XCTestCase {
    private func launch(_ chatId: String, split: String = "off") -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:\(chatId)",
                               "-phoneSplit", split, "-rollout.stackedSplitDrag", "off"]
        app.launch()
        return app
    }

    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "session-header").firstMatch
    }

    private func replaceTitle(_ field: XCUIElement, with title: String) {
        // The alert focuses the field with its caret at the end. Tapping it
        // again moves the caret mid-title and leaves a suffix after deletion.
        let length = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length) + title)
        XCTAssertEqual(field.value as? String, title)
    }

    func testTitleOffersRenameCancelAndRejectsBlankNames() {
        let app = launch("chat-tabs")
        XCTAssertTrue(header(app).waitForExistence(timeout: 10))
        let original = header(app).label
        header(app).tap()
        let alert = app.alerts["Rename session"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        replaceTitle(alert.textFields.firstMatch, with: "Cancelled edit")
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(header(app).label, original)

        header(app).tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        replaceTitle(alert.textFields.firstMatch, with: " ")
        XCTAssertFalse(alert.buttons["Save"].isEnabled)
        replaceTitle(alert.textFields.firstMatch, with: "Release plan")
        alert.buttons["Save"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Release plan"), evaluatedWith: header(app))
        waitForExpectations(timeout: 5)
    }

    func testSplitHeaderCanRename() {
        let app = launch("chat-veil", split: "stacked")
        XCTAssertTrue(header(app).waitForExistence(timeout: 10))
        header(app).tap()
        let alert = app.alerts["Rename session"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        replaceTitle(alert.textFields.firstMatch, with: "Renamed active session")
        alert.buttons["Save"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Renamed active session"), evaluatedWith: header(app))
        waitForExpectations(timeout: 5)
    }

    func testRenamedHeaderStillPagesBetweenActiveSessions() {
        let app = launch("chat-veil")
        XCTAssertTrue(header(app).waitForExistence(timeout: 10))
        header(app).tap()
        let alert = app.alerts["Rename session"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        replaceTitle(alert.textFields.firstMatch, with: "Renamed active session")
        alert.buttons["Save"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Renamed active session"), evaluatedWith: header(app))
        waitForExpectations(timeout: 5)
        header(app).swipeLeft()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Model picker"), evaluatedWith: header(app))
        waitForExpectations(timeout: 5)
        header(app).swipeRight()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Renamed active session"), evaluatedWith: header(app))
        waitForExpectations(timeout: 5)
    }
}
