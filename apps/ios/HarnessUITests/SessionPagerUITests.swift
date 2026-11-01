import XCTest

@MainActor
final class SessionPagerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", "", "-homeGroupBy", "none"]
        app.launch()
    }

    /// Any element type: the strip and header are composed views.
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testNowStripListsActiveSessionsAndOpensOne() {
        // SwiftUI need not expose the noninteractive strip container to AX.
        let card = app.buttons["now-card-chat-veil"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
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

        let previous = app.buttons["session-page-previous"]
        let next = app.buttons["session-page-next"]
        XCTAssertFalse(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)
        // Layout B: 28×44-point arrows, 3 points after the title.
        XCTAssertEqual(next.frame.width, 28, accuracy: 1)
        XCTAssertGreaterThanOrEqual(next.frame.height, 44)
        XCTAssertGreaterThanOrEqual(header.frame.width, 120)
        XCTAssertEqual(previous.frame.minX - header.frame.maxX, 3, accuracy: 1)

        let indicators = element("session-status-indicators")
        XCTAssertTrue(indicators.exists)
        XCTAssertLessThanOrEqual(next.frame.maxX, indicators.frame.minX)
        XCTAssertLessThanOrEqual(indicators.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(indicators.frame.maxX, app.frame.maxX - 24)
        XCTAssertTrue(indicators.label.contains("Running"))
        XCTAssertTrue(indicators.label.contains("Needs your input"))
        XCTAssertTrue(indicators.label.contains("Finished, unread reply"))
        XCTAssertFalse(app.buttons["session-switcher"].exists)
        let marks = indicators.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        marks.tap()
        marks.press(forDuration: 0.1, thenDragTo: marks.withOffset(CGVector(dx: -100, dy: 0)))
        XCTAssertEqual(header.label, before)
        XCTAssertFalse(app.alerts["Rename session"].exists)
        XCTAssertFalse(app.navigationBars["Your sessions"].exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "passive-header-status-indicators"
        preview.lifetime = .keepAlways
        add(preview)

        // Even tapping the disabled arrow's coordinates must not hit Rename.
        previous.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.alerts["Rename session"].exists)
        XCTAssertEqual(header.label, before)
        next.tap()
        let moved = NSPredicate(format: "label CONTAINS %@", "Model picker")
        expectation(for: moved, evaluatedWith: element("session-header"))
        waitForExpectations(timeout: 5)

        XCTAssertFalse(app.alerts["Rename session"].exists)
        XCTAssertTrue(previous.isEnabled)
        previous.tap()
        let back = NSPredicate(format: "label CONTAINS %@", "Streaming veil")
        expectation(for: back, evaluatedWith: element("session-header"))
        waitForExpectations(timeout: 5)

        // Swipe the navigation region, not the passive status marks or Back edge.
        element("session-navigation-controls").swipeLeft()
        expectation(for: moved, evaluatedWith: element("session-header"))
        waitForExpectations(timeout: 5)
        element("session-navigation-controls").swipeRight()
        expectation(for: back, evaluatedWith: element("session-header"))
        waitForExpectations(timeout: 5)

        // Reach the other boundary; its disabled arrow cannot rename either.
        for _ in 0..<10 where next.isEnabled { next.tap() }
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(previous.isEnabled)
        let last = element("session-header").label
        next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.alerts["Rename session"].exists)
        XCTAssertEqual(element("session-header").label, last)
    }
}
