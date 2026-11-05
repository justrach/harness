import XCTest

@MainActor
final class SessionHeaderEdgeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(count: Int, current: Int = 0, idle: Bool = false, split: String = "off") {
        let id = current == 0 ? "chat-veil" : "header-status-\(current)"
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:\(id)",
                               "-header-status-count", "\(count)", "-phoneSplit", split]
            + (idle ? ["-header-status-idle"] : [])
        app.launch()
        XCTAssertTrue(element("session-header").waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func assertFits() {
        let title = element("session-header")
        let marks = element("session-status-indicators")
        XCTAssertTrue(marks.exists)
        XCTAssertGreaterThanOrEqual(title.frame.width, 120)
        XCTAssertLessThanOrEqual(title.frame.maxX, marks.frame.minX)
        XCTAssertLessThanOrEqual(marks.frame.maxX, app.frame.maxX - 8)
        XCTAssertFalse(app.buttons["session-switcher"].exists)
    }

    func testCompactBControlsKeepIndependentHitTargets() {
        launch(count: 7)
        assertFits()
        let title = element("session-header")
        let previous = app.buttons["session-page-previous"]
        let next = app.buttons["session-page-next"]
        XCTAssertEqual(next.frame.width, 28, accuracy: 1)
        XCTAssertGreaterThanOrEqual(next.frame.height, 44)
        XCTAssertLessThanOrEqual(title.frame.maxX, previous.frame.minX)
        next.tap()
        XCTAssertEqual(element("session-page-position").label, "Session 2 of 7")
        XCTAssertFalse(app.alerts["Rename session"].exists)
        title.tap()
        XCTAssertTrue(app.alerts["Rename session"].waitForExistence(timeout: 2))
        app.alerts["Rename session"].buttons["Cancel"].tap()
        capture("header-compact-B")
    }

    func testSingleSessionHidesNavigationAndOverflow() {
        launch(count: 1)
        assertFits()
        XCTAssertFalse(app.buttons["session-page-previous"].exists)
        XCTAssertFalse(app.buttons["session-page-next"].exists)
        XCTAssertEqual(element("session-status-indicators").value as? String, "All sessions shown")
        XCTAssertTrue(element("session-status-indicators").label.contains("current session"))
        capture("header-single-session")
    }

    func testTwelveSessionsKeepTheLastCurrentVisibleAndCountAllHiddenSessions() {
        launch(count: 12, current: 11)
        assertFits()
        XCTAssertEqual(element("session-page-position").label, "Session 12 of 12")
        XCTAssertFalse(app.buttons["session-page-next"].isEnabled)
        XCTAssertTrue(app.buttons["session-page-previous"].isEnabled)
        let marks = element("session-status-indicators")
        let overflow = marks.value as? String ?? ""
        let hidden = Int(overflow.split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(hidden, 0)
        XCTAssertTrue(overflow.hasSuffix(" more"))
        XCTAssertFalse(overflow.contains("+"), "Accessibility describes the hidden count in words")
        XCTAssertTrue(marks.label.contains("\(hidden) more sessions not shown"))
        XCTAssertTrue(marks.label.contains("Session 12 — A long planning conversation 📝: Idle, no unread reply, current session"))
        let point = marks.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        point.tap()
        point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: -100, dy: 0)))
        XCTAssertEqual(element("session-page-position").label, "Session 12 of 12")
        XCTAssertFalse(app.alerts["Rename session"].exists)
        XCTAssertFalse(app.navigationBars["Your sessions"].exists)
        capture("header-twelve-sessions-overflow")
    }

    func testOneMoreLabelAfterRotationDoesNotBecomeAnAddButton() {
        launch(count: 7)
        assertFits()
        XCUIDevice.shared.orientation = .landscapeLeft
        let marks = element("session-status-indicators")
        expectation(for: NSPredicate(format: "value == %@", "1 more"), evaluatedWith: marks)
        waitForExpectations(timeout: 5)
        assertFits()
        XCTAssertEqual(element("session-page-position").label, "Session 1 of 7")
        XCTAssertFalse(app.buttons["session-status-indicators"].exists)
        XCTAssertFalse(app.buttons["session-status-overflow"].exists)
        capture("header-one-more-landscape")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate(format: "value != %@", "1 more"), evaluatedWith: marks)
        waitForExpectations(timeout: 5)
        assertFits()
        XCTAssertEqual(element("session-page-position").label, "Session 1 of 7")
        capture("header-seven-sessions-portrait")
    }

    func testAllIdleSessionsUseTheSameFallbackForMarksAndArrows() {
        launch(count: 4, idle: true)
        assertFits()
        XCTAssertEqual(element("session-page-position").label, "Session 1 of 4")
        let label = element("session-status-indicators").label
        XCTAssertEqual(label.components(separatedBy: "Idle, no unread reply").count - 1, 4)
        app.buttons["session-page-next"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Session 2 of 4"),
                    evaluatedWith: element("session-page-position"))
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.alerts["Rename session"].exists)
    }
}
