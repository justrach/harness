import XCTest

/// Links in a settled agent reply open on tap: a markdown link and a bare
/// URL alike. Both demo links are loopback, so a tap reaches the transcript's
/// openURL handler and opens the host-link sheet instead of leaving the app.
@MainActor
final class LinkTapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs", "-links"]
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

    func testBareURLInSettledReplyOpens() {
        let link = app.links["http://127.0.0.1:3777/bare"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "bare URL is not a link:\n\(app.debugDescription)")
        link.tap()
        assertSheet(for: "http://127.0.0.1:3777/bare")
    }
}
