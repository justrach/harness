import XCTest

@MainActor
final class HomeGroupingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    private func group(by option: String) {
        let filter = app.buttons["space-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.tap()
        let groupBy = app.buttons["Group by"]
        XCTAssertTrue(groupBy.waitForExistence(timeout: 5))
        groupBy.tap()
        let choice = app.buttons[option]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func headers(_ prefix: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home-group-\(prefix)"))
    }

    func testGroupByProjectAndDeviceWithCollapsibleSections() {
        group(by: "Project")
        XCTAssertTrue(headers("project:").firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(headers("project:").count, 1)

        // Collapsing a section hides its sessions; expanding brings them back.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "OKLCH conversion drift"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let header = headers("project:").firstMatch
        let before = app.cells.count
        header.tap()
        XCTAssertLessThan(app.cells.count, before)
        header.tap()
        XCTAssertEqual(app.cells.count, before)

        group(by: "Device")
        XCTAssertTrue(headers("device:").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(headers("project:").firstMatch.exists)

        group(by: "None")
        XCTAssertFalse(headers("device:").firstMatch.waitForExistence(timeout: 2))
    }
}
