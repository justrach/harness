import XCTest

/// Split screen on a Max iPhone (landscape, regular width): open a second session beside the first with one tap,
/// and close either pane. Needs an iPhone Pro Max simulator; on any other device it skips.
@MainActor
final class SplitScreenUITests: XCTestCase {
    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs"]
        app.launch()
        // Only a window at regular width has split screen; skip elsewhere instead of failing.
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width < 900, "needs a Max-class iPhone in landscape (window is \(width)pt wide)")
        return app
    }

    private func headers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "session-header")
    }

    private func closeButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "split-close-pane")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitForHeaders(_ count: Int, in app: XCUIApplication, _ message: String) {
        expectation(for: NSPredicate(format: "count == %d", count), evaluatedWith: headers(app))
        waitForExpectations(timeout: 8) { error in
            if error != nil { XCTFail(message) }
        }
    }

    func testOneTapOpensTheMostRecentSessionBesideTheFirstAndEitherPaneCloses() throws {
        let app = try launch()
        XCTAssertTrue(headers(app).firstMatch.waitForExistence(timeout: 10), "the session did not open")
        XCTAssertEqual(headers(app).count, 1)
        XCTAssertTrue(app.buttons["split-open-beside"].exists, "one pane offers a second")
        XCTAssertTrue(app.buttons["split-toggle-list"].exists, "one pane can bring the list in")
        XCTAssertFalse(closeButtons(app).firstMatch.exists, "a lone pane has nothing to close")
        attach("one-pane")

        // One tap: the most recent other session opens beside it. Two is the most.
        app.buttons["split-open-beside"].tap()
        waitForHeaders(2, in: app, "a second pane did not open")
        XCTAssertEqual(closeButtons(app).count, 2, "each pane can be closed")
        XCTAssertFalse(app.buttons["split-open-beside"].exists, "two panes is the most")
        Thread.sleep(forTimeInterval: 1)
        attach("two-panes")

        // Close the second pane: back to one, and a second can be added again.
        closeButtons(app).element(boundBy: 1).tap()
        waitForHeaders(1, in: app, "closing the second pane should leave one")
        XCTAssertTrue(app.buttons["split-open-beside"].waitForExistence(timeout: 5))

        // Open again, then close the FIRST pane: the second is promoted and stays on screen.
        app.buttons["split-open-beside"].tap()
        waitForHeaders(2, in: app, "a second pane did not open again")
        closeButtons(app).element(boundBy: 0).tap()
        waitForHeaders(1, in: app, "closing the first pane should leave one")
        XCTAssertTrue(app.buttons["split-open-beside"].waitForExistence(timeout: 5), "the other session is still open")
    }
}
