import XCTest

@MainActor
final class SessionPagerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", ""]
        app.launch()
    }

    /// Any element type: the strip and header are composed views.
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testNowStripListsActiveSessionsAndOpensOne() {
        XCTAssertTrue(element("now-strip").waitForExistence(timeout: 10))
        let card = app.buttons["now-card-chat-veil"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["now-card-chat-picker"].exists)
        card.tap()
        XCTAssertTrue(element("session-header").waitForExistence(timeout: 10))
    }

    func testSwipingTheHeaderPagesBetweenActiveSessions() {
        let first = app.buttons["now-card-chat-veil"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let header = element("session-header")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let before = header.label
        XCTAssertTrue(before.contains("Streaming veil"), before)

        header.swipeLeft()
        let moved = NSPredicate(format: "label CONTAINS %@", "Model picker")
        expectation(for: moved, evaluatedWith: element("session-header"))
        waitForExpectations(timeout: 5)

        // And back the other way.
        element("session-header").swipeRight()
        let back = NSPredicate(format: "label CONTAINS %@", "Streaming veil")
        expectation(for: back, evaluatedWith: element("session-header"))
        waitForExpectations(timeout: 5)
    }
}
