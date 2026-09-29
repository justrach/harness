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

    /// Opening a session and coming back must not lose what was typed: the query is
    /// the whole reason someone went looking, and they usually return to refine it.
    func testSearchTextSurvivesOpeningASessionAndComingBack() {
        XCTAssertTrue(rows("OKLCH conversion drift").firstMatch.waitForExistence(timeout: 10))
        let other = rows("Tool group header colors")
        XCTAssertTrue(other.firstMatch.exists)
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("OKLCH")
        XCTAssertFalse(other.firstMatch.waitForExistence(timeout: 2), "the query should narrow the list")

        rows("OKLCH conversion drift").firstMatch.tap()
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()

        let returned = app.searchFields.firstMatch
        XCTAssertTrue(returned.waitForExistence(timeout: 10))
        XCTAssertEqual(returned.value as? String, "OKLCH", "the search text was forgotten")
        XCTAssertFalse(other.firstMatch.exists, "the list should still be narrowed")
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
