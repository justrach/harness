import XCTest

/// Synthetic coverage for ordinary iPhones: the Duo reveal must not replace their navigation.
@MainActor
final class RegularPhoneNavigationUITests: XCTestCase {
    private func launch(_ orientation: UIDeviceOrientation) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-homeGroupBy", "none",
                               "-route", "chat:chat-tabs", "-phoneSplit", "off", "-foldableDevice", "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["duo-cover-toggle-sessions"].exists)
        XCTAssertFalse(app.textFields["cover-sessions-search"].exists)
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPortraitComposerAndBackNavigationPreserveTheDraft() {
        let app = launch(.portrait)
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.isHittable)
        composer.tap()
        if let existing = composer.value as? String, existing != "Message", !existing.isEmpty {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        composer.typeText("Unsent synthetic draft")
        XCTAssertEqual(composer.value as? String, "Unsent synthetic draft")
        XCTAssertTrue(composer.isHittable, "The keyboard must not cover the composer")
        capture(app, "regular-phone-portrait-keyboard")
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["new-session"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tool group header colors")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Unsent synthetic draft")
    }

    func testLandscapeKeepsTheSessionAndComposerReachable() {
        let app = launch(.landscapeLeft)
        let window = app.windows.firstMatch
        let landscape = NSPredicate { _, _ in window.frame.width > window.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 5), .completed)
        let header = app.descendants(matching: .any)["session-header"].firstMatch
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(header.isHittable)
        XCTAssertTrue(composer.isHittable)
        XCTAssertGreaterThanOrEqual(header.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(header.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.frame.maxY)
        capture(app, "regular-phone-landscape")
    }
}
