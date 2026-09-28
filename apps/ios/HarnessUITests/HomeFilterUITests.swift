import XCTest

@MainActor
final class HomeFilterUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    private func rows(_ title: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
    }

    func testStatusChipsNarrowTheList() {
        let running = app.buttons["home-status-running"]
        XCTAssertTrue(running.waitForExistence(timeout: 10))
        let before = app.cells.count

        running.tap()
        XCTAssertLessThan(app.cells.count, before)
        XCTAssertFalse(app.staticTexts["home-empty"].exists)

        // Tapping the active chip again clears it.
        running.tap()
        XCTAssertEqual(app.cells.count, before)

        app.buttons["home-status-attention"].tap()
        XCTAssertLessThan(app.cells.count, before)
        app.buttons["home-status-all"].tap()
        XCTAssertEqual(app.cells.count, before)
    }

    /// "OKLCH conversion drift" is archived in the demo: search covers the
    /// archived shelf too.
    func testSearchFindsSessionsAndShowsEmptyState() {
        XCTAssertTrue(rows("OKLCH conversion drift").firstMatch.waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) {
            // Collapsed into the list: pull down to reveal it.
            app.swipeDown()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("OKLCH")
        XCTAssertTrue(rows("OKLCH conversion drift").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows("OKLCH conversion drift").count, 1)

        search.typeText(" zzzz-no-such-session")
        XCTAssertTrue(app.staticTexts["home-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(rows("OKLCH conversion drift").firstMatch.exists)
    }
}
