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
        copy.tap()
        let composer = app.descendants(matching: .any)["composer-input"].firstMatch
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = menu("Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        return composer.value as? String ?? ""
    }

    func testLongPressSelectsOneWordAndCopiesOnlyThatWord() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        capture("output-before-selection")
        output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
            .press(forDuration: 1.2)
        XCTAssertEqual(copyAndPaste(), "Select")
    }

    func testDraggingToTheEndCopiesOnlyTheOutputParagraph() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        let start = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
        let end = output.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: output.frame.width - 2, dy: output.frame.height + 60))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        capture("output-whole-paragraph")
        XCTAssertEqual(copyAndPaste(),
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
        XCTAssertEqual(copyAndPaste(), "Select", "Reselecting must replace the previous multi-line range")
    }

    func testLongPressDragCopiesMultipleWordsAcrossLines() {
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        let start = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: 13))
        // iOS keeps the selection endpoint above the finger so it remains
        // visible. Move below the second line, not just onto its glyphs.
        let end = output.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 180, dy: 95))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let copied = copyAndPaste()
        XCTAssertTrue(copied.hasPrefix("Select this word"), "Copied: \(copied)")
        XCTAssertTrue(copied.contains("multiple lines"), "Drag must extend selection past the first line: \(copied)")
        XCTAssertFalse(copied.contains("stays unselected"), "Copy must not copy the whole message")
    }
}
