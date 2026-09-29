import XCTest

/// The "Use your ChatGPT plan" sheet against the demo computer, which answers "pending" twice and then the outcome the
/// launch argument names.
@MainActor
final class ChatGPTSignInUITests: XCTestCase {
    private func launch(result: String) -> XCUIApplication {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-onboarding-noagent", "-chatgpt-result", result, "-sethomefilter", ""]
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
}
