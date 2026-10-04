import XCTest

/// Folding or unfolding a foldable phone swaps the stack for the split and
/// rebuilds the open session, so what a person was typing has to live outside
/// the session view. Leaving the session and coming back rebuilds it the same
/// way, which a phone can drive without folding.
@MainActor
final class FoldableUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "phone layouts only")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    /// A foldable's cover display lays bars out vertically, where the back
    /// button is not inside a navigation bar element.
    private func goBack() {
        let back = app.buttons["BackButton"]
        if back.waitForExistence(timeout: 3) {
            back.tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    func testDraftSurvivesTheSessionBeingRebuilt() {
        let session = row("Tool group header colors")
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()

        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("half a thought")

        // Back to the list tears the session down; reopening rebuilds it.
        goBack()
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()

        let restored = app.textViews["composer-input"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.value as? String, "half a thought")
    }
}
