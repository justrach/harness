import XCTest

/// A localhost link in a chat opens on the phone: the host-link sheet offers
/// it, and the page view shows demo mode's made-up page and answers taps,
/// links, Back and typing.
@MainActor
final class LocalhostPageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs", "-links",
                               "-phoneSplit", "off"]
        app.launch()
        XCTAssertTrue(app.otherElements["transcript"].waitForExistence(timeout: 15))
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Tap the page at a point of its own (page points; the demo page is drawn at the view's size).
    private func tapPage(_ page: XCUIElement, x: CGFloat = 100, y: CGFloat) {
        page.coordinate(withNormalizedOffset: CGVector(dx: x / page.frame.width, dy: y / page.frame.height)).tap()
    }

    func testALocalhostLinkOpensOnThePhoneAndTakesInput() {
        let link = app.links["the preview"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let open = app.buttons["host-link-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["host-link-copy"].exists, "Copy link stays")
        XCTAssertTrue(app.buttons["host-server-5173"].waitForExistence(timeout: 5), "the computer's servers are listed")
        keep("host-link-sheet")
        open.tap()

        let page = app.images["localhost-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertEqual(page.label, "Garden planner")
        XCTAssertFalse(app.buttons["localhost-back"].isEnabled)
        tapPage(page, y: 262)  // Water the tomatoes
        sleep(1)
        keep("localhost-page")

        tapPage(page, y: 540)  // All plants ›
        XCTAssertTrue(app.images["Plants · Garden planner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["localhost-back"].isEnabled)
        app.buttons["localhost-back"].tap()
        XCTAssertTrue(app.images["Garden planner"].waitForExistence(timeout: 5))

        tapPage(page, y: 340)  // the plant field
        app.buttons["localhost-keyboard"].tap()
        let field = app.textFields["localhost-type-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Basil")
        sleep(1)
        keep("localhost-typing")

        app.buttons["localhost-done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Done returns to the sheet")
    }

    func testAnAddressOffTheComputerIsRefusedInTheAddressBar() {
        app.links["the preview"].tap()
        let open = app.buttons["host-link-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.images["localhost-page"].waitForExistence(timeout: 10))
        let address = app.textFields["localhost-address"]
        address.tap()
        address.clearAndType("example.com\n")
        let notice = app.buttons["localhost-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Only pages on"), notice.label)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 4))
        }
        typeText(text)
    }
}
