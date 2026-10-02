import XCTest

/// The opt-in phone split: with it on, the session list and the open session are on screen together.
@MainActor
final class PhoneSplitUITests: XCTestCase {
    private func launch(_ mode: String, orientation: UIDeviceOrientation) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 1)  // let a rotation from the previous test finish
        let app = XCUIApplication()
        // Opens the session straight away (the route the screenshot tests use), so nothing depends on a row's
        // position in a list that may be scrolled.
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs", "-phoneSplit", mode]
        app.launch()
        return app
    }

    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["session-header"]
    }

    /// The list pane's own button: present only while the list is on screen.
    private func listButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["new-session"]
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSideBySideKeepsTheListBesideTheOpenSession() {
        let app = launch("sideBySide", orientation: .landscapeLeft)
        XCTAssertTrue(header(app).waitForExistence(timeout: 10), "the session did not open")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(named: "side-by-side")
        XCTAssertTrue(listButton(app).exists, "the list is still on screen next to the session")
        XCTAssertLessThan(listButton(app).frame.maxX, header(app).frame.minX, "the list sits left of the session")
    }

    func testStackedKeepsTheListAboveTheOpenSession() {
        let app = launch("stacked", orientation: .portrait)
        XCTAssertTrue(header(app).waitForExistence(timeout: 10), "the session did not open")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(named: "stacked")
        XCTAssertTrue(listButton(app).exists, "the list is still on screen above the session")
        XCTAssertLessThan(listButton(app).frame.maxY, header(app).frame.minY, "the list sits above the session")
    }

    func testOffKeepsTheSingleStackAndTheSessionReplacesTheList() {
        let app = launch("off", orientation: .portrait)
        XCTAssertTrue(header(app).waitForExistence(timeout: 10), "the session did not open")
        XCTAssertFalse(listButton(app).isHittable, "with the split off, an open session replaces the list")
    }

    // MARK: the one-time offer

    /// Home with the split off, and the offer's memory seeded as "three sessions opened in the last minute".
    private func launchJuggling(orientation: UIDeviceOrientation) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 1)
        let now = Date().timeIntervalSince1970
        // Launch arguments carry plain strings only, so the memory is a comma-separated list of times.
        let opens = "\(now - 30),\(now - 20),\(now - 10)"
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-phoneSplit", "off",
                               "-splitSuggestion.opens", opens, "-splitSuggestion.shown", "0",
                               // An earlier test's answer is saved in the app's defaults; pin it to "long ago".
                               "-splitSuggestion.lastShownAt", "0"]
        app.launch()
        return app
    }

    private func offer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["split-offer"]
    }

    func testTheOfferAppearsWithRoomAndTryingItSplitsTheScreen() {
        let app = launchJuggling(orientation: .landscapeLeft)
        XCTAssertTrue(offer(app).waitForExistence(timeout: 10), "juggling with room should offer the split")
        attachScreenshot(named: "split-offer")
        app.buttons["split-offer-try"].tap()
        XCTAssertTrue(app.staticTexts["Pick a session, or start one with +"].waitForExistence(timeout: 5),
                      "Try it should turn the split on")
        XCTAssertFalse(offer(app).exists, "the offer goes away once answered")
    }

    func testNotNowHidesTheOfferAndLeavesTheSplitOff() {
        let app = launchJuggling(orientation: .landscapeLeft)
        XCTAssertTrue(offer(app).waitForExistence(timeout: 10))
        app.buttons["split-offer-later"].tap()
        XCTAssertFalse(offer(app).waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Pick a session, or start one with +"].exists, "the split stays off")
    }

    func testNoOfferWithoutRoomEvenWhileJuggling() {
        let app = launchJuggling(orientation: .portrait)
        XCTAssertTrue(app.buttons["new-session"].waitForExistence(timeout: 10), "Home did not load")
        XCTAssertFalse(offer(app).waitForExistence(timeout: 2), "a portrait phone has no room, so nothing to offer")
    }
}
