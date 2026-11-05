import UIKit
import XCTest

@MainActor
final class MessageFooterUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs",
                               "-links", "-phoneSplit", "off"]
        app.launch()
        XCTAssertTrue(app.otherElements["transcript"].waitForExistence(timeout: 15))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSentPromptAndResponseHaveVisibleTimestampAndCopyControls() {
        capture("message-footers")
        for id in ["links-ask", "links-reply"] {
            let copy = app.buttons["message-copy-\(id)"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5), "Both message roles need a visible copy button")
            XCTAssertTrue(copy.isHittable)
            // Accessibility coordinate conversion can report 44 as
            // 43.999999999999986; allow rounding noise, not a smaller target.
            XCTAssertGreaterThanOrEqual(copy.frame.width, 44 - 0.001)
            XCTAssertGreaterThanOrEqual(copy.frame.height, 44 - 0.001)
            let timestamp = app.staticTexts["message-timestamp-\(id)"]
            XCTAssertTrue(timestamp.exists)
            XCTAssertFalse(timestamp.label.isEmpty)
        }
    }

    private func assertCopy(_ id: String, equals expected: String) {
        let copy = app.buttons["message-copy-\(id)"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        UIPasteboard.general.string = "Synthetic clipboard sentinel"
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")
        capture("message-copied-\(id)")
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        // Compare without logging unexpected clipboard content.
        XCTAssertTrue(composer.value as? String == expected, "Copy must contain the full message, without footer metadata")
    }

    func testCopySentPrompt() {
        assertCopy("links-ask", equals: "Where is the preview?")
    }

    func testCopyResponsePreservesMarkdownAndLinks() {
        assertCopy("links-reply", equals: "Bare: http://127.0.0.1:3777/bare and markdown: [the preview](http://127.0.0.1:3777/md).")
    }
}
