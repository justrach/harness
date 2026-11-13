import XCTest

@MainActor
final class SlashCommandUITests: XCTestCase {
    private func launchCatalog() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-command-catalog", "-sethomefilter", "", "-phoneSplit", "off",
                               "-route", "chat:chat-tabs"]
        app.launch()
        XCTAssertTrue(app.textViews["composer-input"].waitForExistence(timeout: 10))
        return app
    }

    func testCommandMenuShowsFullDescriptionsWithoutHorizontalScrolling() {
        let app = launchCatalog()
        let input = app.textViews["composer-input"]
        input.tap()
        input.typeText("/")
        let row = app.buttons["composer-command-model"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let title = row.staticTexts.element(boundBy: 0)
        let detail = row.staticTexts.element(boundBy: 1)
        XCTAssertEqual(title.label, "/model")
        XCTAssertEqual(detail.label,
                       "switch model/provider, fuzzy match (e.g. \"sonnet\", \"opus\"); name a provider to pin the seat")
        XCTAssertGreaterThan(detail.frame.height, 30, "Long descriptions must wrap rather than truncate")
        XCTAssertGreaterThanOrEqual(row.frame.height, detail.frame.height,
                                   "The touch target must grow with its complete description")
        XCTAssertGreaterThanOrEqual(detail.frame.minX, row.frame.minX)
        XCTAssertLessThanOrEqual(detail.frame.maxX, row.frame.maxX,
                                 "Reading the full description must not require horizontal scrolling")
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "wrapped-command-menu"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testCommandsBeyondGoalCanBeFilteredSelectedAndSent() {
        let app = launchCatalog()
        let input = app.textViews["composer-input"]
        input.tap()
        for (index, name) in ["compact", "effort", "tools", "workspace", "help"].enumerated() {
            if index > 0 {
                // Demo sends stay live without a real host to finish them.
                // Use a fresh synthetic session rather than testing its unsupported queue.
                app.terminate()
                app.launch()
                XCTAssertTrue(input.waitForExistence(timeout: 10))
                input.tap()
            }
            input.typeText("/" + name)
            let command = app.buttons["composer-command-" + name]
            XCTAssertTrue(command.waitForExistence(timeout: 5), "Missing /\(name)")
            command.tap()
            XCTAssertEqual(input.value as? String, "\u{00a0}/\(name)\u{00a0} ")
            app.buttons["composer-send"].tap()
            XCTAssertEqual(input.value as? String, "")
        }
        input.typeText("/")
        let menu = app.descendants(matching: .any)["composer-command-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["composer-command-model"].exists)
        menu.swipeUp()
        XCTAssertFalse(app.buttons["composer-command-model"].isHittable,
                       "Scrolling must move beyond the initial catalog rows")
        XCTAssertTrue(app.buttons.allElementsBoundByIndex.contains {
            $0.identifier.hasPrefix("composer-command-") && $0.isHittable && $0.frame.intersects(menu.frame)
        }, "Later commands must remain selectable after scrolling")
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "full-command-catalog-scrolls"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testHarnessSettingsAndRenamePerformLocalActionsInsteadOfSendingPrompts() {
        let app = launchCatalog()
        let input = app.textViews["composer-input"]
        input.tap()
        input.typeText("/settings")
        let settings = app.buttons["composer-command-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertEqual(input.value as? String, "", "A local action must not become a provider chip")
        input.tap()
        input.typeText("/harness:rename")
        let rename = app.buttons["composer-command-harness:rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "Keep the provider's /rename separate")
        rename.tap()
        XCTAssertTrue(app.alerts["Rename session"].waitForExistence(timeout: 5))
        app.alerts["Rename session"].buttons["Cancel"].tap()
        XCTAssertEqual(input.value as? String, "")
        input.tap()
        input.typeText("/harness:resume")
        let resume = app.buttons["composer-command-harness:resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["Search sessions"].exists)
        app.buttons["Done"].tap()
        XCTAssertEqual(input.value as? String, "")
    }

    func testGoalCanBeExplicitlySelectedInTheComposer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demo-command-catalog", "-sethomefilter", "", "-phoneSplit", "off",
                               "-route", "chat:chat-tabs"]
        app.launch()
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("/goal")
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "slash-command-typed"
        before.lifetime = .keepAlways
        add(before)
        let command = app.buttons["composer-command-goal"]
        XCTAssertTrue(command.waitForExistence(timeout: 5), "Typing /goal must offer the host's command")
        let suggestions = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        suggestions.name = "slash-command-suggestions"
        suggestions.lifetime = .keepAlways
        add(suggestions)
        let menu = app.descendants(matching: .any)["composer-command-menu"].firstMatch
        XCTAssertTrue(menu.exists)
        let lastMatch = app.buttons["composer-command-goals"]
        XCTAssertTrue(lastMatch.exists, "The full catalog also offers /goals")
        XCTAssertLessThanOrEqual(menu.frame.maxY - lastMatch.frame.maxY, 2,
                                 "The menu must not leave an empty strip below its last row")
        command.tap()
        XCTAssertEqual(input.value as? String, "\u{00a0}/goal\u{00a0} ")
        XCTAssertFalse(command.exists, "Selecting a command dismisses completion")
        input.typeText("Build a demo calculator")
        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selected.name = "slash-command-selected"
        selected.lifetime = .keepAlways
        add(selected)
        app.buttons["composer-send"].tap()
        XCTAssertEqual(input.value as? String, "")
    }
}
