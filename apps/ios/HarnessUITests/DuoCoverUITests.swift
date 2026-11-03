import XCTest

/// iPhone Duo's cover display (466 x 678 pt): the system's vertical bar takes an 84pt column on the trailing
/// side, so the chat has 382pt. The context card has to fit in what is left, the running turn's chips must
/// not float over the transcript's text, and the rows should use the width beside the bar. The first two hold
/// on any phone that has marked itself a Duo; the width check runs on the cover display only.
@MainActor
final class DuoCoverUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "phone layouts only")
        continueAfterFailure = false
    }

    /// A running turn (the pill row) with the context meter, on a device marked as a Duo.
    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-phoneSplit", "off", "-foldableDevice", "YES", "-route", "chat:chat-veil",
                               "-demo-context", "-demo-agent-work"] + extra
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// The card used to be 398pt whatever the screen. The system clamps the popover to the screen and centers
    /// the card in it, so "Context" started left of the screen and the counts were cut off on the right.
    func testContextCardFitsOnScreen() {
        launch(["-demo-context-card"])
        let card = element("context-card")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(card.frame.minX, window.minX, "card starts off screen: \(card.frame)")
        XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX, "card ends off screen: \(card.frame)")
        for text in card.staticTexts.allElementsBoundByIndex where text.exists {
            XCTAssertTrue(card.frame.insetBy(dx: -1, dy: -1).contains(text.frame),
                          "\"\(text.label)\" \(text.frame) is cut off by the card \(card.frame)")
        }
        // Beside the cover display's vertical bar the card stays out of the bar's column.
        let back = app.buttons["BackButton"]
        let transcript = element("transcript")
        if back.exists, transcript.exists, back.frame.minX >= transcript.frame.maxX {
            XCTAssertLessThanOrEqual(card.frame.maxX, back.frame.minX)
        }
    }

    /// The pill row floated over the bottom of the transcript, and text showed through and between the chips.
    /// The transcript now ends above the row.
    func testTranscriptEndsAboveTheRunningTurnsChips() {
        launch()
        let pill = element("run-status-pill")
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        let transcript = element("transcript")
        XCTAssertTrue(transcript.exists)
        XCTAssertLessThanOrEqual(transcript.frame.maxY, pill.frame.minY + 0.5,
                                 "transcript \(transcript.frame) runs under the pill \(pill.frame)")
        let ring = element("context-ring")
        if ring.exists {
            XCTAssertLessThanOrEqual(transcript.frame.maxY, ring.frame.minY + 0.5)
        }
    }

    /// On the cover display the bar's column is the system's (84pt); the rows padded 20pt a side inside what
    /// was left, a 342pt column of the 466pt display. Beside the bar they keep 8pt to the safe edge.
    func testCoverRowsUseTheWidthBesideTheBar() throws {
        launch()
        let card = element("diff-summary-card")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        let back = app.buttons["BackButton"]
        try XCTSkipUnless(window.width == 466 && back.exists && back.frame.minX > window.width - 84,
                          "the cover display's vertical bar only")
        XCTAssertGreaterThanOrEqual(card.frame.width, 356, "row column \(card.frame)")
        XCTAssertLessThanOrEqual(card.frame.maxX, back.frame.minX - 16, "row runs into the bar \(card.frame)")
    }
}
