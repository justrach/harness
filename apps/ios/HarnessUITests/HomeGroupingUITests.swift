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
        // Its own bar button, not a submenu under every space.
        let groupBy = app.buttons["home-group-by"]
        XCTAssertTrue(groupBy.waitForExistence(timeout: 10))
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

    /// A pinned session leaves its project and sits in a Pinned section above them all.
    func testPinnedSessionsGatherAboveTheGroups() {
        let title = "Tool group header colors"
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeRight()
        let pin = app.buttons["Pin"]
        if pin.waitForExistence(timeout: 3) { pin.tap() }
        group(by: "Project")

        let pinned = app.buttons["home-group-pinned"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "no Pinned section")
        let firstProject = headers("project:").firstMatch
        XCTAssertTrue(firstProject.waitForExistence(timeout: 5))
        XCTAssertLessThan(pinned.frame.minY, firstProject.frame.minY, "Pinned should sit above the project groups")
        XCTAssertTrue(pinned.label.hasPrefix("Pinned"))
    }
}

