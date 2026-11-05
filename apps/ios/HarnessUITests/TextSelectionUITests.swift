import UIKit
import XCTest

@MainActor
final class TextSelectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs",
                               "-textselection", "-phoneSplit", "off"]
        app.launch()
        XCTAssertTrue(app.otherElements["transcript"].waitForExistence(timeout: 15))
    }

    private var output: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Select this word", "Select this word"
        )).firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func menu(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func copyAndPaste() -> String {
        let copy = menu("Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Long-press must show the native Copy menu")
        capture("output-selection")
        // A failed Copy must paste a synthetic sentinel, never pre-existing
        // simulator clipboard content. Keep unexpected clipboard text out of logs.
        UIPasteboard.general.string = "Synthetic clipboard sentinel"
        copy.tap()
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = menu("Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        return composer.value as? String ?? ""
    }

    private func responseText(startingWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix
        )).firstMatch
    }

    func testDraggingAcrossWholeResponseCopiesParagraphsHeadingListAndCode() {
        app.terminate()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs",
                               "-responseselection", "-phoneSplit", "off"]
        app.launch()
        XCTAssertTrue(app.otherElements["transcript"].waitForExistence(timeout: 15))

        let first = responseText(startingWith: "Start here.")
        let last = responseText(startingWith: "Finish here.")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        // Block-based rendering exposes the final paragraph separately; a
        // unified native surface exposes the full response as one text value.
        let finalBlock = last.waitForExistence(timeout: 1) ? last : first
        XCTAssertTrue(finalBlock.isHittable)
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        XCTAssertLessThan(finalBlock.frame.maxY, composer.frame.minY,
                          "The complete synthetic reply must fit above the composer")
        capture("response-before-selection")

        let start = first.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
        // Keep the finger below the final glyphs: iOS positions the selection
        // endpoint above it. The continuous gesture must cross every block.
        let end = finalBlock.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: finalBlock.frame.width - 2,
            dy: min(finalBlock.frame.height + 60, composer.frame.minY - finalBlock.frame.minY - 8)))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        capture("response-after-selection")
        let copied = copyAndPaste().replacingOccurrences(of: "\r\n", with: "\n")

        XCTAssertTrue(copied.hasPrefix("Start here."), "Selection must start at the first word")
        // Native word-granularity dragging may stop before the final period;
        // either range must include the final paragraph's words.
        XCTAssertTrue(copied.hasSuffix("Finish here.") || copied.hasSuffix("Finish here"),
                      "Selection must reach the final paragraph")
        XCTAssertFalse(copied.contains("Keep this prompt out of copied text."),
                       "Copy must exclude the preceding user prompt")
        let blocks = ["Start here.", "Second paragraph.", "Quick steps", "First item.",
                      "Second item.", "let total = 2\nprint(total)", "Finish here"]
        var previousEnd = copied.startIndex
        for (index, block) in blocks.enumerated() {
            guard let range = copied.range(of: block, range: previousEnd..<copied.endIndex) else {
                XCTFail("Whole-response copy must include every block in order (block \(index))")
                return
            }
            if index > 0 {
                XCTAssertTrue(copied[previousEnd..<range.lowerBound].contains("\n"),
                              "Copy must preserve line breaks between Markdown blocks (block \(index))")
            }
            previousEnd = range.upperBound
        }
    }

    func testLongPressSelectsOneWordAndCopiesOnlyThatWord() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        capture("output-before-selection")
        output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
            .press(forDuration: 1.2)
        XCTAssertTrue(copyAndPaste() == "Select", "Copy must contain only the selected word")
    }

    func testDraggingToTheEndCopiesOnlyTheOutputParagraph() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        let start = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
        let end = output.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: output.frame.width - 2, dy: output.frame.height + 60))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        capture("output-whole-paragraph")
        XCTAssertTrue(copyAndPaste() ==
                      "Select this word and drag across multiple lines to copy only the highlighted passage. The rest of this response stays unselected.",
                      "A full-range selection must include the final word, but not surrounding transcript UI")
    }

    func testDismissingRangeSelectionAllowsReselectingASingleWord() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        let start = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
        let end = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 180, dy: 95))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(menu("Copy").waitForExistence(timeout: 5))
        capture("output-range-before-dismissal")

        // Moving focus to the composer dismisses selection without copying it.
        // Do not paste here: the later copy must come from a fresh selection,
        // not a stale range retained when the text view loses first responder.
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        composer.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: menu("Copy"))
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        capture("output-selection-dismissed")

        // Resolve coordinates again because the keyboard can move the output.
        XCTAssertTrue(output.isHittable)
        output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
            .press(forDuration: 1.2)
        capture("output-after-reselection")
        XCTAssertTrue(copyAndPaste() == "Select", "Reselecting must replace the previous multi-line range")
    }

    func testSelectionHandleExtendsAcrossWrappedLines() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        let origin = output.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 22, dy: 13)).press(forDuration: 1.2)
        XCTAssertTrue(menu("Copy").waitForExistence(timeout: 5))
        capture("output-word-before-handle-drag")
        // After lifting the initial long press, drag the word's trailing
        // handle, rather than extending in the same uninterrupted gesture.
        let handle = origin.withOffset(CGVector(dx: 49, dy: 30))
        let end = origin.withOffset(CGVector(dx: 180, dy: 95))
        handle.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        capture("output-after-handle-drag")
        let copied = copyAndPaste()
        XCTAssertTrue(copied.hasPrefix("Select this word"), "Copy must start at the selected word")
        XCTAssertTrue(copied.contains("multiple lines"), "A selection handle must extend past the first visual line")
        XCTAssertFalse(copied.contains("stays unselected"), "Copy must not copy the whole message")
    }

    func testLongPressDragCopiesMultipleWordsAcrossLines() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        let start = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
        // iOS keeps the selection endpoint above the finger so it remains
        // visible. Move below the second line, not just onto its glyphs.
        let end = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 180, dy: 95))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let copied = copyAndPaste()
        XCTAssertTrue(copied.hasPrefix("Select this word"), "Copy must start at the selected word")
        XCTAssertTrue(copied.contains("multiple lines"), "Drag must extend selection past the first line")
        XCTAssertFalse(copied.contains("stays unselected"), "Copy must not copy the whole message")
    }
}
