import UIKit
import XCTest

@MainActor
final class PromptSelectionUITests: XCTestCase {
    private var app: XCUIApplication!
    private let firstPrompt = "Select this word and drag across lines.\n\nOnly this prompt belongs in the copied range."
    private let longPrompt = """
        Long prompt starts here.
        Second line.
        Third line.
        Fourth line.
        Fifth line.
        Hidden sixth line.
        Hidden seventh line.
        Hidden eighth line.
        """

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs",
                               "-promptselection", "-phoneSplit", "off"]
        app.launch()
        XCTAssertTrue(app.otherElements["transcript"].waitForExistence(timeout: 15))
    }

    private func text(startingWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix
        )).firstMatch
    }

    private func menu(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func copyAndPaste(action: String = "Copy") -> String {
        let copy = menu(action)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Long-press must offer the requested native copy action")
        capture(action == "Copy" ? "prompt-selected-range" : "prompt-copy-full-menu")
        // A failed copy must paste synthetic text, never pre-existing simulator
        // clipboard content. Do not include unexpected pasted values in logs.
        UIPasteboard.general.string = "Synthetic clipboard sentinel"
        copy.tap()
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = menu("Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        return (composer.value as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
    }

    func testLongPressSentPromptCopiesOnlySelectedWord() {
        let prompt = text(startingWith: "Select this word")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue(prompt.isHittable)
        capture("prompt-before-word-selection")
        prompt.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
            .press(forDuration: 1.2)
        capture("prompt-after-word-selection")
        XCTAssertTrue(copyAndPaste() == "Select", "Copy must contain only the selected prompt word")
    }

    func testDraggingBeyondSentPromptCopiesOnlyThatPrompt() {
        let prompt = text(startingWith: "Select this word")
        let reply = text(startingWith: "Assistant reply one:")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(prompt.isHittable)
        XCTAssertTrue(reply.isHittable)
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        XCTAssertLessThan(reply.frame.maxY, composer.frame.minY,
                          "The first prompt and reply must fit above the composer without scrolling")
        capture("prompt-before-cross-message-drag")
        let start = prompt.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
        // Drag into the assistant reply, below the final prompt paragraph.
        // The native selection endpoint must clamp to this prompt's text.
        let end = reply.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: reply.frame.width - 2,
            dy: min(reply.frame.height + 40, composer.frame.minY - reply.frame.minY - 8)))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        capture("prompt-after-cross-message-drag")
        let copied = copyAndPaste()
        XCTAssertTrue(copied == firstPrompt, "Dragging beyond a prompt must copy both paragraphs of only that prompt")
        XCTAssertFalse(copied.contains("Assistant reply"), "Prompt selection must exclude assistant messages")
        XCTAssertFalse(copied.contains("Long prompt"), "Prompt selection must exclude the next sent prompt")
        XCTAssertFalse(copied.contains("Hidden"), "Prompt selection must not enter another prompt's hidden lines")
    }

    func testCopyPromptIncludesHiddenLinesWhileCollapsedAndExcludesOtherMessages() {
        let prompt = text(startingWith: "Long prompt starts here.")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue(prompt.isHittable)
        XCTAssertTrue(app.buttons["Show more"].waitForExistence(timeout: 5),
                      "The eight-line synthetic prompt must initially be collapsed")
        capture("prompt-before-collapsed-full-copy")
        prompt.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
            .press(forDuration: 1.2)
        capture("prompt-after-collapsed-long-press")
        let copied = copyAndPaste(action: "Copy prompt")
        XCTAssertTrue(copied == longPrompt, "Copy prompt must include all eight lines even while collapsed")
        XCTAssertTrue(copied.contains("Hidden sixth line.\nHidden seventh line.\nHidden eighth line."),
                      "Whole-prompt copy must retain the hidden tail and its line breaks")
        XCTAssertFalse(copied.contains("Assistant reply"), "Whole-prompt copy must exclude assistant messages")
        XCTAssertFalse(copied.contains("Select this word"), "Whole-prompt copy must exclude the other sent prompt")
    }
}
