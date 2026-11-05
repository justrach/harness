import XCTest

/// A guided pass through the app as a new install meets it, for people to look at rather than a gate: every step
/// leaves a numbered screenshot, and what got in the way is written down instead of failing the run, so one pass
/// shows the whole journey. `scripts/ios-walkthrough.sh` installs the app fresh, runs this, and collects the
/// screenshots and notes into a folder.
///
/// Nothing is pinned beyond the offline demo: Split view starts as a new install has it, and is turned on the way a
/// person would, from Settings. `WALKTHROUGH_ARGS` (the script's `--args`) adds launch arguments, such as
/// `-phoneSplit sideBySide`.
@MainActor
final class WalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stepNumber = 0
    private var notes: [String] = []

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        let extra = ProcessInfo.processInfo.environment["WALKTHROUGH_ARGS"] ?? ""
        app.launchArguments = ["-demo"] + extra.split(separator: " ").map(String.init)
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        let text = notes.isEmpty ? "Nothing got in the way.\n" : notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        let attachment = XCTAttachment(string: text)
        attachment.name = "notes"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: helpers

    private func step(_ name: String) {
        stepNumber += 1
        Thread.sleep(forTimeInterval: 0.8)  // let the transition settle before the picture
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = String(format: "%02d-%@", stepNumber, name)
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Something a person would trip over. Recorded with the step it happened at; the walk goes on.
    private func note(_ text: String) {
        notes.append(String(format: "step %02d: %@", stepNumber, text))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private var header: XCUIElement { element("session-header") }
    private var listButton: XCUIElement { app.buttons["new-session"] }

    /// The session's own Back: in a split the list above has a bar of its own, so the first bar button may be
    /// the list's.
    private func back() {
        let buttons = app.navigationBars.buttons.allElementsBoundByIndex.filter(\.isHittable)
        let button = header.exists
            ? buttons.first { abs($0.frame.midY - header.frame.midY) < 30 && $0.frame.maxX <= header.frame.minX }
            : buttons.first
        if let button { button.tap() } else { note("no Back button") }
    }

    /// The session row titled `title`, lowest on screen when it shows more than once (Home above, a picker below).
    private func row(_ title: String, lowest: Bool = false) -> XCUIElement? {
        let matches = app.staticTexts.matching(identifier: title).allElementsBoundByIndex.filter(\.isHittable)
        return lowest ? matches.max { $0.frame.minY < $1.frame.minY } : matches.first
    }

    private func open(_ title: String, lowest: Bool = false) -> Bool {
        guard let row = row(title, lowest: lowest) else {
            note("no session row titled \"\(title)\" on screen")
            return false
        }
        row.tap()
        return true
    }

    // MARK: the walk

    func testFirstRunWalkthrough() {
        // Home, as a new install opens it.
        XCTAssertTrue(app.buttons["home-status-all"].waitForExistence(timeout: 15), "Home did not open")
        step("home")

        // Open a session the way a person does, from its row.
        if open("Tool group header colors"), header.waitForExistence(timeout: 10) {
            step("session-single-stack")
            if !listButton.isHittable { note("with Split view off (the default), the open session replaces the list") }
            back()
        }

        // Juggle sessions: the app offers the split once there is room and three opens come close together.
        for title in ["Model picker catalog sync", "OKLCH conversion drift", "Streaming veil on transcript rows"] {
            if open(title), header.waitForExistence(timeout: 10) { back() }
        }
        _ = app.buttons["home-status-all"].waitForExistence(timeout: 5)
        step("home-after-juggling")
        // Upright there is no split that fits, so nothing should be offered here.
        if element("split-offer").exists {
            step("split-offer")
            note("Split view was offered in portrait, where no split fits")
        }

        // Find Split view in Settings and choose Auto.
        let settings = app.buttons["home-settings"]
        guard settings.waitForExistence(timeout: 5) else {
            note("no Settings button on Home")
            return
        }
        settings.tap()
        let picker = element("settings-phone-split")
        var swipes = 0
        while !(picker.exists && picker.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        step("settings-layout")
        if swipes > 1 { note("Split view is \(swipes) screens down in Settings") }
        guard picker.isHittable else {
            note("Split view is not in Settings")
            return
        }
        picker.tap()
        let auto = app.buttons["Auto"].firstMatch
        if auto.waitForExistence(timeout: 3) {
            step("split-view-choices")
            if app.buttons["Stacked"].exists { note("the Split view picker still offers Stacked") }
            auto.tap()
        } else {
            note("the Split view picker did not show its choices")
        }
        step("split-view-auto")
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() } else { app.swipeDown(velocity: .fast) }
        step("home-auto")

        // Upright, Auto keeps the single stack: the session replaces the list.
        guard open("Tool group header colors"), header.waitForExistence(timeout: 10) else { return }
        step("auto-portrait-session")

        // Type and send.
        let input = app.textViews["composer-input"]
        if input.waitForExistence(timeout: 5) {
            input.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                input.typeText("Walk me through the change")
                step("typing")
                if !input.isHittable { note("the composer is hidden while typing") }
                app.buttons["composer-send"].tap()
                step("sent")
                Thread.sleep(forTimeInterval: 3)
                step("reply")
            } else {
                note("tapping the composer did not bring up the keyboard")
            }
        } else {
            note("no composer on the open session")
        }

        // Landscape: Auto puts the list beside the session where the window is wide enough.
        XCUIDevice.shared.orientation = .landscapeLeft
        step("landscape")
        XCUIDevice.shared.orientation = .portrait
        step("portrait-again")

        back()
        _ = app.buttons["home-status-all"].waitForExistence(timeout: 5)
        step("home-at-the-end")
    }
}
