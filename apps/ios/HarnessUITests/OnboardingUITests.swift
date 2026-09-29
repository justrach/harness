import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", scenario, "-sethomefilter", ""]
        app.launch()
        return app
    }

    private func agent(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["onboarding-agent-\(id)"]
    }

    func testNoComputerExplainsWhatToDoAndOffersTheLink() {
        let app = launch("-onboarding-nocomputer")
        XCTAssertTrue(app.staticTexts["Bring in your agent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Get Harness on your computer"].exists)
        XCTAssertTrue(app.buttons["onboarding-copy-link"].exists)
        XCTAssertTrue(app.buttons["onboarding-share-link"].exists)
        for id in ["graff", "claude-code", "codex"] {
            XCTAssertTrue(agent(app, id).waitForExistence(timeout: 5), id)
            XCTAssertTrue(agent(app, id).label.contains("Needs a computer"), "\(id): \(agent(app, id).label)")
        }
    }

    func testAComputerWithNoAgentReadySaysWhatIsMissingOnIt() {
        let app = launch("-onboarding-noagent")
        XCTAssertTrue(app.staticTexts["Bring in your agent"].waitForExistence(timeout: 10))
        // A computer is online, so there is no download prompt.
        XCTAssertFalse(app.staticTexts["Get Harness on your computer"].exists)
        XCTAssertTrue(agent(app, "graff").waitForExistence(timeout: 5))
        XCTAssertEqual(agent(app, "graff").value as? String, "off")
        XCTAssertTrue(agent(app, "graff").label.contains("Switched off on MacBook Pro"))
        XCTAssertEqual(agent(app, "claude-code").value as? String, "canInstall")
        XCTAssertTrue(agent(app, "claude-code").label.contains("Not installed on MacBook Pro"))
        XCTAssertEqual(agent(app, "codex").value as? String, "missing")
        XCTAssertTrue(agent(app, "codex").label.contains("Not found on MacBook Pro"))
    }

    func testOnceAnAgentIsReadyHomeShowsItsPlainEmptyLine() {
        let app = launch("-onboarding-ready")
        XCTAssertTrue(app.staticTexts["home-empty"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Bring in your agent"].exists)
    }
}
