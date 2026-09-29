import XCTest

/// What someone typed and did not send is still theirs when they come back to it.
@MainActor
final class DraftUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    private var composer: XCUIElement { app.descendants(matching: .any)["composer-input"].firstMatch }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
    }

    func testAnUnsentMessageSurvivesLeavingTheSession() {
        XCTAssertTrue(row("Tool group header colors").waitForExistence(timeout: 10))
        row("Tool group header colors").tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("half-written thought")
        XCTAssertEqual(composer.value as? String, "half-written thought")

        // Dismiss the keyboard, leave, and open the same session again.
        app.swipeDown()
        goBack()
        XCTAssertTrue(row("Tool group header colors").waitForExistence(timeout: 10))
        row("Tool group header colors").tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "half-written thought", "the unsent draft was forgotten")
    }

    func testEachSessionKeepsItsOwnDraft() {
        XCTAssertTrue(row("Tool group header colors").waitForExistence(timeout: 10))
        row("Tool group header colors").tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("only for the first")
        app.swipeDown()
        goBack()

        XCTAssertTrue(row("Streaming veil on transcript rows").waitForExistence(timeout: 10))
        row("Streaming veil on transcript rows").tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertNotEqual(composer.value as? String, "only for the first", "a draft leaked into another session")
    }
}
