import XCTest

/// The regular-width layout: the session list stays as a sidebar and picking
/// a session replaces the detail column instead of stacking behind it.
@MainActor
final class IPadSplitUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout only")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    func testSidebarStaysWhileSessionsSwapInTheDetail() {
        XCTAssertTrue(app.staticTexts["Pick a session, or start one with +"].waitForExistence(timeout: 10))

        let first = row("OKLCH conversion drift")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        let transcript = app.otherElements["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        // The list is still on screen next to the session.
        XCTAssertTrue(app.buttons["space-filter"].exists)
        XCTAssertTrue(row("Wrangler deploy hygiene").isHittable)

        row("Wrangler deploy hygiene").tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Pick a session, or start one with +"].exists)
        // Replaced, not pushed: the detail has nothing to go back to.
        XCTAssertFalse(app.navigationBars.buttons["OKLCH conversion drift"].exists)
    }

    func testLaunchRouteOpensTheSessionInTheDetail() {
        app.terminate()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-oklch"]
        app.launch()
        XCTAssertTrue(app.otherElements["transcript"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["space-filter"].exists)
    }
}
