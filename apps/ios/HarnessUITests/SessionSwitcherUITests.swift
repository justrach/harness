import XCTest

@MainActor
final class SessionSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    private var rows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "switcher-"))
    }

    /// Row ids top to bottom. A row with a pull request badge is two buttons
    /// carrying the row's id, so each id counts once.
    private var order: [String] {
        var seen = Set<String>()
        return rows.allElementsBoundByIndex.map(\.identifier).filter { seen.insert($0).inserted }
    }

    private func row(_ id: String) -> XCUIElement {
        app.buttons.matching(identifier: id).firstMatch
    }

    /// The demo has sessions running and waiting on you. Home shows them as the
    /// Now strip; in a session the pill lists them in one fixed order, the open
    /// one stays in its place, marked, and picking another swaps it in.
    func testPillListsSessionsInOneOrderAndJumpsBetweenThem() {
        let card = app.buttons["now-card-chat-veil"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()

        let pill = app.buttons["session-switcher"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let order = self.order
        XCTAssertGreaterThan(order.count, 1)
        XCTAssertEqual(row("switcher-chat-veil").value as? String, "Open")
        let other = order.first { $0 != "switcher-chat-veil" }!
        row(other).tap()

        // Jumping swaps the session: one Back returns Home.
        XCTAssertTrue(app.buttons["session-switcher"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home-status-all"].waitForExistence(timeout: 5))
    }
}
