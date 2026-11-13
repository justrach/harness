import XCTest

@MainActor
final class SessionFolderHeaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
    }

    private var header: XCUIElement {
        app.descendants(matching: .any)["session-header"].firstMatch
    }

    private func openDemoChat(_ title: String) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "missing demo row \(title)")
        row.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
    }

    func testSessionHeaderShowsAbbreviatedFolderAndWorktreePaths() {
        app.launchArguments = ["-demo", "-sethomefilter", "", "-phoneSplit", "off"]
        app.launch()

        openDemoChat("Model picker catalog sync")
        XCTAssertTrue(header.label.contains("~/harness @ MacBook Pro"), header.label)

        app.navigationBars.buttons.firstMatch.tap()
        openDemoChat("Streaming veil on transcript rows")
        XCTAssertTrue(header.label.contains("~/.harness/worktrees/harness-veil-fade @ MacBook Pro"), header.label)

        app.navigationBars.buttons.firstMatch.tap()
        openDemoChat("Wrangler deploy hygiene")
        XCTAssertTrue(header.label.contains("/srv/deploys/edge @ Codegraff Cloud"), header.label)
    }

    func testFlatDuoPaneHeaderShowsFolderWithoutNavigationBarOverflow() {
        app.launchArguments = ["-demo", "-sethomefilter", "", "-demo-duo-flat", "-phoneSplit", "off"]
        app.launch()

        openDemoChat("Model picker catalog sync")
        XCTAssertTrue(header.isHittable)
        XCTAssertGreaterThanOrEqual(header.frame.width, 140)
        XCTAssertTrue(header.label.contains("Model picker catalog sync"), header.label)
        XCTAssertTrue(header.label.contains("~/harness @ MacBook Pro"), header.label)
        XCTAssertFalse(app.navigationBars.buttons["More"].exists)

        let toggle = app.buttons["duo-flat-toggle-list"]
        if toggle.exists {
            toggle.tap()
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            XCTAssertTrue(header.isHittable)
            XCTAssertTrue(header.label.contains("~/harness @ MacBook Pro"), header.label)
        }

        let back = app.buttons["duo-flat-back"]
        XCTAssertTrue(back.exists)
        back.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Model picker catalog sync")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }
}
