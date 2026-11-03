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

    /// A Max-class iPhone is regular width in landscape: it gets the sidebar and the two-pane split screen
    /// (SplitScreenUITests), never the compact phone split, so the landscape cases here do not apply.
    private func skipIfRegularWidthInLandscape(_ app: XCUIApplication) throws {
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width >= 900, "a Max-class iPhone in landscape is regular width (window is \(width)pt wide)")
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSideBySideKeepsTheListBesideTheOpenSession() throws {
        let app = launch("sideBySide", orientation: .landscapeLeft)
        try skipIfRegularWidthInLandscape(app)
        XCTAssertTrue(header(app).waitForExistence(timeout: 10), "the session did not open")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(named: "side-by-side")
        XCTAssertTrue(listButton(app).exists, "the list is still on screen next to the session")
        XCTAssertLessThan(listButton(app).frame.maxX, header(app).frame.minX, "the list sits left of the session")
    }

    /// Stacked was removed: a phone that had it saved gets Auto, so the list stays beside the session in
    /// landscape instead of the split switching off.
    func testASavedStackedChoiceFallsBackToAuto() throws {
        let app = launch("stacked", orientation: .landscapeLeft)
        try skipIfRegularWidthInLandscape(app)
        XCTAssertTrue(header(app).waitForExistence(timeout: 10), "the session did not open")
        XCTAssertTrue(listButton(app).exists, "Auto keeps the list beside the session")
        XCTAssertLessThan(listButton(app).frame.maxX, header(app).frame.minX, "the list sits left of the session")
    }

    /// Settings offers Off, Auto and Side by side; Stacked is gone.
    func testSettingsOffersOffAutoAndSideBySide() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-phoneSplit", "off", "-sheet", "settings"]
        app.launch()
        let picker = app.descendants(matching: .any)["settings-phone-split"]
        XCTAssertTrue(app.buttons["settings-appearance"].waitForExistence(timeout: 10), "Settings did not open")
        var swipes = 0
        while !(picker.exists && picker.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        picker.tap()
        XCTAssertTrue(app.buttons["Auto"].firstMatch.waitForExistence(timeout: 5), "the choices did not open")
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(named: "split-view-choices")
        XCTAssertTrue(app.buttons["Off"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Side by side"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Stacked"].firstMatch.exists, "Stacked was removed")
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

    func testTheOfferAppearsWithRoomAndTryingItSplitsTheScreen() throws {
        let app = launchJuggling(orientation: .landscapeLeft)
        try skipIfRegularWidthInLandscape(app)
        XCTAssertTrue(offer(app).waitForExistence(timeout: 10), "juggling with room should offer the split")
        attachScreenshot(named: "split-offer")
        app.buttons["split-offer-try"].tap()
        XCTAssertTrue(app.staticTexts["Pick a session, or start one with +"].waitForExistence(timeout: 5),
                      "Try it should turn the split on")
        XCTAssertFalse(offer(app).exists, "the offer goes away once answered")
    }

    func testNotNowHidesTheOfferAndLeavesTheSplitOff() throws {
        let app = launchJuggling(orientation: .landscapeLeft)
        try skipIfRegularWidthInLandscape(app)
        XCTAssertTrue(offer(app).waitForExistence(timeout: 10))
        app.buttons["split-offer-later"].tap()
        XCTAssertFalse(offer(app).waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Pick a session, or start one with +"].exists, "the split stays off")
    }

    /// Upright there is no split that fits, so there is nothing to offer.
    func testPortraitOffersNothing() {
        let app = launchJuggling(orientation: .portrait)
        XCTAssertTrue(listButton(app).waitForExistence(timeout: 10), "home is on screen")
        XCTAssertFalse(offer(app).waitForExistence(timeout: 3), "no offer in portrait")
    }
}
