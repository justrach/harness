import XCTest

/// Settings → Simulators: demo mode's made-up Mac offline, and (when a test run
/// passes an engine port) a real engine and a real simulator on this Mac.
@MainActor
final class SimulatorsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
    }

    private func openSettings(_ extra: [String] = []) {
        app.launchArguments = ["-demo", "-sethomefilter", "", "-phoneSplit", "off"] + extra
        app.launch()
        let settings = app.buttons["home-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openSimulators() {
        let row = app.buttons["settings-simulators"]
        row.scrollIntoView(in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Simulators"].waitForExistence(timeout: 5))
    }

    /// Set up is the consent step; after it the Mac's simulators are listed,
    /// and opening a running one shows its screen and takes touches and Home.
    func testSetUpThenWatchAndUseASimulator() {
        openSettings()
        openSimulators()
        let setUp = app.buttons["simulators-set-up"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'installs a pinned helper'"))
            .firstMatch.exists)
        keep("simulators-set-up")
        setUp.tap()

        let running = app.buttons["simulator-5D3A1C2E-8F4B-4A6D-9E21-7B0C3D4E5F60"]
        XCTAssertTrue(running.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Running"].exists)
        XCTAssertTrue(app.staticTexts["Off"].exists)
        keep("simulators-list")
        running.tap()

        let screen = app.images["simulator-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["simulator-home"].exists)
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        let tapped = NSPredicate(format: "label == %@", "iPhone 17 Pro screen")
        XCTAssertTrue(app.images.matching(tapped).firstMatch.exists)
        keep("simulator-live")
        app.buttons["simulator-home"].tap()
        app.buttons["simulator-close"].tap()
        XCTAssertTrue(app.navigationBars["Simulators"].waitForExistence(timeout: 5))
    }

    /// An off simulator starts when opened; a running one can be shut down by swiping.
    func testOpeningAnOffSimulatorStartsItAndSwipeShutsItDown() {
        openSettings(["-simulators-set-up"])
        openSimulators()
        let off = app.buttons["simulator-A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"]
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        off.tap()
        XCTAssertTrue(app.images["simulator-screen"].waitForExistence(timeout: 8))
        app.buttons["simulator-close"].tap()
        XCTAssertTrue(app.navigationBars["Simulators"].waitForExistence(timeout: 5))
        let started = app.buttons["simulator-A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"]
        XCTAssertTrue(started.waitForExistence(timeout: 5))
        started.swipeLeft()
        let shutDown = app.buttons["Shut down"]
        XCTAssertTrue(shutDown.waitForExistence(timeout: 3))
        shutDown.tap()
        // Back under Off: the footer about starting it is there again.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Opening one starts it'"))
            .firstMatch.waitForExistence(timeout: 5))
    }

    /// Without a Mac among your computers, Settings has no Simulators row.
    func testNoMacNoSimulatorsRow() {
        openSettings(["-ios-only"])
        XCTAssertFalse(app.buttons["settings-simulators"].exists)
    }

    /// End to end against a real engine on this Mac: `TEST_RUNNER_HARNESS_SIM_ENGINE_PORT`
    /// (the engine's local RPC port) and `TEST_RUNNER_HARNESS_SIM_UDID` (a simulator the
    /// run created, booted, and allowlisted on that engine). Skipped otherwise.
    func testLiveSimulatorThroughARealEngine() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["HARNESS_SIM_ENGINE_PORT"], let udid = env["HARNESS_SIM_UDID"] else {
            throw XCTSkip("no engine port given")
        }
        openSettings(["-simulator-engine", port])
        openSimulators()
        let row = app.buttons["simulator-\(udid)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        keep("live-simulators-list")
        row.tap()
        let screen = app.images["simulator-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 60))
        sleep(2)
        keep("live-simulator-home")
        // The Settings app icon on a fresh simulator's first home page (third row, last column).
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.49)).tap()
        sleep(6)
        keep("live-simulator-tapped")
        app.buttons["simulator-home"].tap()
        sleep(2)
        keep("live-simulator-home-again")
        app.buttons["simulator-close"].tap()
    }
}

private extension XCUIElement {
    func scrollIntoView(in app: XCUIApplication, attempts: Int = 6) {
        var left = attempts
        while (!exists || !isHittable) && left > 0 {
            app.swipeUp()
            left -= 1
        }
    }
}
