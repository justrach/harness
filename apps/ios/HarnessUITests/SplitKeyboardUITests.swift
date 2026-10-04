import XCTest

/// Typing in a split session: the keyboard comes up, stays up, and the text lands in the composer. The keyboard
/// takes room from the window, which must not reshape the split under the person typing.
@MainActor
final class SplitKeyboardUITests: XCTestCase {
    private func launch(phoneSplit: String, orientation: UIDeviceOrientation) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 1)  // let a rotation from the previous test finish
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs", "-phoneSplit", phoneSplit]
        app.launch()
        return app
    }

    private func typeInComposer(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let input = app.textViews["composer-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "no composer", file: file, line: line)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard did not come up",
                      file: file, line: line)
        // Long enough for a layout that flips on the keyboard's arrival to have flipped.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard went away by itself", file: file, line: line)
        input.typeText("split keys")
        XCTAssertEqual(app.textViews["composer-input"].firstMatch.value as? String, "split keys",
                       "the text did not reach the composer", file: file, line: line)
    }

    func testTypingInTheStackedSplit() {
        let app = launch(phoneSplit: "stacked", orientation: .portrait)
        typeInComposer(app)
        XCTAssertTrue(app.buttons["new-session"].exists, "the list left while typing: the split collapsed")
    }

    func testTypingInTheSideBySideSplit() {
        let app = launch(phoneSplit: "sideBySide", orientation: .landscapeLeft)
        typeInComposer(app)
    }

    func testTypingInTheAutoSplit() {
        let app = launch(phoneSplit: "auto", orientation: .landscapeLeft)
        typeInComposer(app)
    }

    /// The Max's two panes: type in each in turn.
    func testTypingInBothPanesOnAMax() throws {
        let app = launch(phoneSplit: "off", orientation: .landscapeLeft)
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width < 900, "needs a Max-class iPhone in landscape (window is \(width)pt wide)")
        let openBeside = app.buttons["split-open-beside"]
        XCTAssertTrue(openBeside.waitForExistence(timeout: 10), "no open-beside button")
        openBeside.tap()
        let inputs = app.textViews.matching(identifier: "composer-input")
        XCTAssertTrue(inputs.element(boundBy: 1).waitForExistence(timeout: 10), "the second pane did not open")
        for ix in 0..<2 {
            let input = inputs.element(boundBy: ix)
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "pane \(ix): no keyboard")
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertTrue(app.keyboards.firstMatch.exists, "pane \(ix): the keyboard went away by itself")
            input.typeText("pane \(ix)")
            XCTAssertEqual(inputs.element(boundBy: ix).value as? String, "pane \(ix)", "pane \(ix): text lost")
        }
    }
}
