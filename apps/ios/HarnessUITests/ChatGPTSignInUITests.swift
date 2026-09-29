import XCTest

/// The "Use your ChatGPT plan" sheet against the demo computer, which answers "pending" twice and then the outcome the
/// launch argument names.
@MainActor
final class ChatGPTSignInUITests: XCTestCase {
    private func launch(result: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-onboarding-noagent", "-chatgpt-result", result, "-sethomefilter", ""] + extra
        app.launch()
        return app
    }

    private func launchPlan(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-chatgpt-plan", "-sethomefilter", ""] + extra
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["chatgpt-status"] }

    private func openSheetAndContinue(_ app: XCUIApplication) {
        let entry = app.buttons["onboarding-chatgpt"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.staticTexts["Use your ChatGPT plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Choose the computer"].exists)
        XCTAssertTrue(app.staticTexts["Prefer the terminal? Run"].exists)
        app.buttons["chatgpt-continue"].tap()
    }

    func testAnApprovedSignInWithPlanUsageEndsWithTheOneTimeConfirmation() {
        let app = launch(result: "connected")
        openSheetAndContinue(app)
        XCTAssertTrue(status(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keep this open until it finishes."].exists)
        XCTAssertTrue(app.buttons["chatgpt-cancel"].exists)
        XCTAssertTrue(app.staticTexts["You're using your ChatGPT plan"].waitForExistence(timeout: 10))
        XCTAssertEqual(status(app).value as? String, "connected")
        XCTAssertTrue(app.buttons["chatgpt-manage-usage"].exists)
        app.buttons["chatgpt-done"].tap()
        XCTAssertTrue(app.staticTexts["Bring in your agent"].waitForExistence(timeout: 5))
    }

    func testASignInWithoutPlanUsageIsNotReadyAndOffersAnotherTry() {
        let app = launch(result: "planUsageOff")
        openSheetAndContinue(app)
        XCTAssertTrue(app.staticTexts["Signed in, but plan usage is off"].waitForExistence(timeout: 10))
        XCTAssertEqual(status(app).value as? String, "planUsageOff")
        XCTAssertTrue(app.buttons["chatgpt-retry"].exists)
        XCTAssertFalse(app.buttons["chatgpt-manage-usage"].exists)
    }

    func testDecliningOnTheComputerSaysNothingChanged() {
        let app = launch(result: "declined")
        openSheetAndContinue(app)
        XCTAssertTrue(app.staticTexts["You didn't approve the sign-in"].waitForExistence(timeout: 10))
        XCTAssertEqual(status(app).value as? String, "declined")
    }

    func testCancelWhileWaitingReturnsToTheStart() {
        let app = launch(result: "connected")
        openSheetAndContinue(app)
        XCTAssertTrue(app.buttons["chatgpt-cancel"].waitForExistence(timeout: 5))
        app.buttons["chatgpt-cancel"].tap()
        XCTAssertTrue(app.buttons["chatgpt-continue"].waitForExistence(timeout: 5))
        XCTAssertFalse(status(app).exists)
    }

    func testTheConfirmationIsOnlyForTheFirstSignIn() {
        let app = launch(result: "connected", extra: ["-chatgpt-welcome-seen"])
        openSheetAndContinue(app)
        // Already confirmed once: the sheet closes on its own and shows nothing more.
        XCTAssertTrue(app.staticTexts["Bring in your agent"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["You're using your ChatGPT plan"].exists)
    }

    func testTheFirstSignInConfirmsThatTheChatGPTPlanIsInUse() {
        let app = launch(result: "connected")
        openSheetAndContinue(app)
        XCTAssertTrue(app.staticTexts["You're using your ChatGPT plan"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Eligible AI requests in this app use your ChatGPT plan. You can manage usage in ChatGPT settings."].exists)
        XCTAssertTrue(app.buttons["chatgpt-done"].exists)
    }

    func testSettingsOffersTheOptionAndThenShowsThePlanIsInUse() {
        let app = launch(result: "connected")
        XCTAssertTrue(app.buttons["home-settings"].waitForExistence(timeout: 10))
        app.buttons["home-settings"].tap()
        let card = app.descendants(matching: .any)["chatgpt-plan-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Complete eligible AI requests in this app with usage included in your ChatGPT plan or credits balance."].exists)
        app.buttons["continue-with-chatgpt"].tap()
        XCTAssertTrue(app.buttons["chatgpt-continue"].waitForExistence(timeout: 5))
        app.buttons["chatgpt-continue"].tap()
        XCTAssertTrue(app.buttons["chatgpt-done"].waitForExistence(timeout: 15))
        app.buttons["chatgpt-done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan-usage-line"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["continue-with-chatgpt"].exists)
    }

    func testSomeoneWithSessionsIsInvitedByABannerUntilTheyConnect() {
        let app = launchPlan()
        let banner = app.descendants(matching: .any)["chatgpt-plan-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["New"].exists)
        XCTAssertTrue(app.staticTexts["Use your ChatGPT plan in this app"].exists)
        app.buttons["continue-with-chatgpt"].tap()
        XCTAssertTrue(app.buttons["chatgpt-continue"].waitForExistence(timeout: 5))
        app.buttons["chatgpt-continue"].tap()
        XCTAssertTrue(app.buttons["chatgpt-done"].waitForExistence(timeout: 15))
        app.buttons["chatgpt-done"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: banner)
        waitForExpectations(timeout: 5)
    }

    func testASessionOnThePlanShowsWhereToManageUsageAndItsLimitCard() {
        let app = launchPlan(["-route", "chat:chat-plan"])
        let line = app.descendants(matching: .any)["plan-usage-line"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Using ChatGPT plan"].exists)
        XCTAssertTrue(app.buttons["chatgpt-manage-usage"].exists)
        let card = app.descendants(matching: .any)["usage-limit-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Usage limit reached"].exists)
        XCTAssertTrue(app.staticTexts["Review your plan or app limit in ChatGPT settings."].exists)
    }
}
