import XCTest

@MainActor
final class RefCatalogLoadingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String]) {
        // Ref/checkout chrome is deliberately hidden by the default Zen preset.
        // Exercise the preserved developer workflow, independent of saved UI preferences.
        app.launchArguments = ["-demo", "-route", "space:space-harness", "-sheet", "newsession",
                               "-phoneSplit", "off", "-homeUiMode", "developer",
                               "-homeUiPartOverrides", ""] + arguments
        app.launch()
        let ref = app.buttons["session-ref"]
        XCTAssertTrue(ref.waitForExistence(timeout: 5))
        ref.tap()
    }

    func testEmptyRepositoryShowsCompletedEmptyStateNotLoading() {
        launch(["-refs-empty"])
        XCTAssertTrue(app.staticTexts["refs-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["refs-loading"].firstMatch.exists)
        XCTAssertTrue(app.buttons["refs-retry"].exists)
    }

    func testFailedRefRequestShowsErrorAndRetryRecovers() {
        launch(["-refs-fail-once", "-slow-refs"])
        XCTAssertTrue(app.staticTexts["refs-load-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["refs-loading"].firstMatch.exists)
        let retry = app.buttons["refs-retry"]
        retry.tap()
        let main = app.scrollViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "main,")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["refs-load-error"].exists)
        XCTAssertFalse(app.staticTexts["refs-empty"].exists)
    }
}
