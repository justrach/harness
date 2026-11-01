import XCTest

/// Home's project and grouping controls sit together above the list, say what
/// they choose, and report their choice to VoiceOver (#419).
@MainActor
final class HomeListControlsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", "", "-phoneSplit", "off"]
        app.launch()
    }

    private var project: XCUIElement { app.buttons["space-filter"] }
    private var grouping: XCUIElement { app.buttons["home-group-by"] }

    private func choose(_ title: String, in control: XCUIElement) {
        control.tap()
        // A project row's label carries its device ("harness, @ MacBook Pro").
        let choice = app.collectionViews.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", title, "\(title), ")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(title) in the menu")
        choice.tap()
    }

    func testProjectAndGroupingSitTogetherOnOneRowBelowTheBar() {
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        XCTAssertTrue(grouping.waitForExistence(timeout: 5))
        // Not split between the nav bar and a row of its own.
        XCTAssertFalse(app.navigationBars.buttons["space-filter"].exists, "the project control is still in the bar")
        XCTAssertEqual(project.frame.midY, grouping.frame.midY, accuracy: 4, "the two controls are on different rows")
        XCTAssertLessThan(project.frame.maxX, grouping.frame.minX, "project should lead, grouping follow")
        XCTAssertLessThan(grouping.frame.minX - project.frame.maxX, 40, "the pair should sit together")
        // Visible text says what each one chooses.
        XCTAssertTrue(app.staticTexts["All projects"].exists)
        XCTAssertTrue(app.staticTexts["By status"].exists)
        XCTAssertFalse(app.staticTexts["Status"].exists)
    }

    func testAccessibilityLabelsCarryTheCurrentChoice() {
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        XCTAssertEqual(project.label, "Filter by space")
        XCTAssertEqual(project.value as? String, "All projects")
        XCTAssertEqual(grouping.label, "Group by")
        XCTAssertEqual(grouping.value as? String, "Status")

        choose("harness", in: project)
        XCTAssertTrue(app.staticTexts["harness"].waitForExistence(timeout: 5))
        XCTAssertEqual(project.value as? String, "harness")
        // Still one row while scoped.
        XCTAssertEqual(project.frame.midY, grouping.frame.midY, accuracy: 4)

        choose("Project", in: grouping)
        XCTAssertTrue(app.staticTexts["By project"].waitForExistence(timeout: 5))
        XCTAssertEqual(grouping.value as? String, "Project")

        choose("All projects", in: project)
        XCTAssertTrue(app.staticTexts["All projects"].waitForExistence(timeout: 5))
        XCTAssertEqual(project.value as? String, "All projects")
    }
}
