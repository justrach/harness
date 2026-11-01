import XCTest

/// Links in a settled agent reply open on tap: a markdown link and a bare
/// URL alike. Both demo links are loopback, so a tap reaches the transcript's
/// openURL handler and opens the host-link sheet instead of leaving the app.
@MainActor
final class LinkTapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs", "-links", "-phoneSplit", "off"]
        app.launch()
        XCTAssertTrue(app.otherElements["transcript"].waitForExistence(timeout: 15))
    }

    private func assertSheet(for target: String) {
        let sheet = app.descendants(matching: .any)["host-link-target"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "tapping \(target) opened nothing")
        XCTAssertEqual(sheet.label, target)
    }

    func testMarkdownLinkInSettledReplyOpens() {
        let link = app.links["the preview"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "markdown link is not a link:\n\(app.debugDescription)")
        link.tap()
        assertSheet(for: "http://127.0.0.1:3777/md")
    }

    func testHostLinkSheetFitsItsContent() {
        let link = app.links["the preview"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        assertSheet(for: "http://127.0.0.1:3777/md")
        let copy = app.buttons["host-link-copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        // Wait for the sheet's presentation and measured-size update to settle.
        let compact = NSPredicate { _, _ in
            let bottomInset = self.app.frame.maxY - copy.frame.maxY
            return (20..<100).contains(bottomInset)
        }
        expectation(for: compact, evaluatedWith: copy)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Host link sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        copy.tap()
        XCTAssertTrue(app.buttons["host-link-copy"].label.contains("Copied"))
        app.buttons["Done"].tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
    }

    func testBareURLInSettledReplyOpens() {
        let link = app.links["http://127.0.0.1:3777/bare"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "bare URL is not a link:\n\(app.debugDescription)")
        link.tap()
        assertSheet(for: "http://127.0.0.1:3777/bare")
    }
}
