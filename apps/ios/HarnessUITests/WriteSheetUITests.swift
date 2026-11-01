import XCTest

/// The Write page: the composer's draft on a full-height sheet, the same text
/// in both places, and Send from the sheet sends it.
@MainActor
final class WriteSheetUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-phoneSplit", "off", "-route", "chat:chat-tabs"]
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var composer: XCUIElement { app.textViews["composer-input"] }
    private var page: XCUIElement { app.textViews["write-input"] }

    /// Type into the composer, then open the Write page from its corner button.
    private func openWrite(typing draft: String) {
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(draft)
        let expand = app.buttons["composer-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "the expanded composer offers the Write page")
        XCTAssertEqual(expand.label, "Write in full screen")
        capture("composer-with-expand")
        expand.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "the Write page opens")
    }

    func testTheWritePageEditsTheComposersDraft() {
        openWrite(typing: "Notes on the renderer")
        XCTAssertEqual(page.value as? String, "Notes on the renderer", "the page shows the composer's draft")
        XCTAssertEqual(app.staticTexts["write-words"].label, "4 words")

        page.typeText("\n## Keep it short\n- Cap the reel at `30s`\n- **Reuse** the hotkey")
        let combined = "Notes on the renderer\n## Keep it short\n- Cap the reel at `30s`\n- **Reuse** the hotkey"
        XCTAssertEqual(page.value as? String, combined)
        capture("write-page")

        app.buttons["write-done"].tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5), "Done closes the page")
        XCTAssertEqual(composer.value as? String, combined, "Done keeps everything typed on the page")
    }

    func testTheLaunchHookOpensTheWritePage() {
        app.terminate()
        app.launchArguments += ["-sheet", "write"]
        app.launch()
        XCTAssertTrue(page.waitForExistence(timeout: 10), "-sheet write opens the Write page")
        XCTAssertEqual(app.staticTexts["write-words"].label, "0 words")
        XCTAssertFalse(app.buttons["write-send"].isEnabled, "nothing to send yet")
    }

    func testSendingFromTheWritePageSendsTheDraft() {
        openWrite(typing: "Ship the renderer")
        page.typeText(" today")
        let send = app.buttons["write-send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5), "sending closes the page")
        let transcript = app.otherElements["transcript"]
        XCTAssertTrue(transcript.staticTexts["Ship the renderer today"].waitForExistence(timeout: 10),
                      "the message is in the transcript")
        XCTAssertEqual(composer.value as? String ?? "", "", "the composer is empty after sending")
        capture("write-sent")
    }
}
