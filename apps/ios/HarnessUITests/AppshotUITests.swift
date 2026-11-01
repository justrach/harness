import XCTest

@MainActor
final class AppshotUITests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRemoteAppshotsRemainReadableAndOpenOnPhone() {
        let app = XCUIApplication()
        // Pin the phone split off: PhoneSplitUITests' "Try it" saves a split mode in the app's defaults, and a
        // stacked split leaves the strip too little room to swipe.
        app.launchArguments = ["-demo", "-phoneSplit", "off", "-route", "chat:chat-tabs", "-appshots"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let card = app.buttons["appshot-card-2:/demo/appshot-square.png"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "PRIVATE_OBSERVED_TEXT_MUST_STAY_HIDDEN")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Check the narrow layout."].exists)
        capture("appshots-ios-portrait")
        let strip = app.scrollViews["appshot-attachments"]
        strip.swipeRight()
        strip.swipeRight()
        let first = app.buttons["appshot-card-0:/demo/appshot-wide.png"]
        XCTAssertTrue(first.isHittable)
        capture("appshots-ios-first-capture")
        first.tap()
        let close = app.buttons["Close image preview"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture("appshots-ios-lightbox")
        close.tap()
        let images = app.buttons["Preview image, 2 more attachments"]
        XCTAssertTrue(images.waitForExistence(timeout: 5))
        images.tap()
        XCTAssertTrue(app.navigationBars["Queued images"].waitForExistence(timeout: 5))
        capture("appshots-ios-queue-gallery")
        app.buttons["Done"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(images.waitForExistence(timeout: 5))
        capture("appshots-ios-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["More queue actions"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Move down"].waitForExistence(timeout: 5))
        capture("appshots-ios-queue-actions")
    }

    // MARK: Queued message attachments (#187, #493)

    private func launchQueue() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-phoneSplit", "off", "-route", "chat:chat-tabs", "-appshots"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        return app
    }

    /// Retyping a queued message in the composer can attach images to it.
    /// Seed the simulator library with an image via simctl addmedia first.
    func testRetypingAQueuedMessageCanAttachImages() {
        let app = launchQueue()
        let edit = app.buttons.matching(NSPredicate(format: "label == %@", "Edit"))
        XCTAssertTrue(edit.element(boundBy: 1).waitForExistence(timeout: 10))
        edit.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["Stop editing"].firstMatch.waitForExistence(timeout: 5))
        let attach = app.buttons["Attach photos"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5), "editing a queued message keeps Attach")
        XCTAssertTrue(attach.isEnabled)
        capture("queued-edit-attach")
        attach.tap()
        let photos = app.navigationBars["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        let image = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), "Seed the simulator photo library before running")
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        photos.buttons["Done"].tap()
        let staged = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")).firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: 10))
        capture("queued-edit-staged")
        app.buttons["composer-send"].tap()
        // The text-only row now has the image, and the draft is back as it was.
        XCTAssertTrue(app.buttons["Preview image"].waitForExistence(timeout: 10))
        XCTAssertFalse(staged.exists)
        capture("queued-edit-saved")
    }

    /// Open Attachments on the second, text-only queued message.
    private func openAttachments(_ app: XCUIApplication) {
        let more = app.buttons.matching(identifier: "More queue actions")
        XCTAssertTrue(more.element(boundBy: 1).waitForExistence(timeout: 10))
        more.element(boundBy: 1).tap()
        let attachments = app.buttons["Attachments"]
        XCTAssertTrue(attachments.waitForExistence(timeout: 5))
        attachments.tap()
        XCTAssertTrue(app.staticTexts["queued-attachments-title"].waitForExistence(timeout: 5))
    }

    /// RGBA bytes of a screen region, for comparing the + button's pixels.
    private func pixels(_ shot: XCUIScreenshot, _ rect: CGRect, screenWidth: CGFloat) -> [UInt8] {
        guard let cg = shot.image.cgImage else { return [] }
        let scale = CGFloat(cg.width) / screenWidth
        guard let region = cg.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                  width: rect.width * scale, height: rect.height * scale))
        else { return [] }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        let context = CGContext(data: &bytes, width: region.width, height: region.height, bitsPerComponent: 8,
                                bytesPerRow: region.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        return bytes
    }

    private func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
    }

    private func assertOrderedMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let camera = app.buttons["Camera"], photos = app.buttons["Photos"], files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(camera.exists && photos.exists, file: file, line: line)
        XCTAssertLessThan(camera.frame.minY, photos.frame.minY, "Camera comes first", file: file, line: line)
        XCTAssertLessThan(photos.frame.minY, files.frame.minY, "then Photos, then Files", file: file, line: line)
    }

    private func dismissMenu(_ app: XCUIApplication) {
        // The open menu covers the title; tap the empty sheet beside it, under
        // the confirm control.
        let confirm = app.buttons["queued-attachments-confirm"].frame
        let add = app.buttons["queued-attachments-add"].frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: confirm.midX, dy: add.maxY + 24)).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Files"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        // Let the close transition finish before measuring.
        Thread.sleep(forTimeInterval: 0.8)
    }

    func testAttachmentToolbarAndOrderedCameraMenu() {
        let app = launchQueue()
        openAttachments(app)
        let title = app.staticTexts["queued-attachments-title"]
        let confirm = app.buttons["queued-attachments-confirm"]
        let add = app.buttons["queued-attachments-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.label, "Close", "an unchanged editor offers X, not a checkmark")
        XCTAssertEqual(app.staticTexts["queued-attachments-message"].label, "Then review keyboard navigation.")
        Thread.sleep(forTimeInterval: 0.8)
        capture("queued-attachments-editor")

        let width = app.frame.width
        let addFrame = add.frame, titleFrame = title.frame, confirmFrame = confirm.frame
        // A circle; the system may scale a floating sheet slightly, so no fixed size.
        XCTAssertEqual(addFrame.width, addFrame.height, accuracy: 0.5)
        XCTAssertGreaterThan(addFrame.width, 40)
        XCTAssertEqual(titleFrame.midX, width / 2, accuracy: 1, "the title is centered")
        let before = pixels(XCUIScreen.main.screenshot(), addFrame, screenWidth: width)

        for cycle in 0..<3 {
            add.tap()
            assertOrderedMenu(app)
            if cycle == 0 { capture("queued-attachments-menu") }
            dismissMenu(app)
            XCTAssertEqual(add.frame, addFrame, "the + control must not move (cycle \(cycle))")
            XCTAssertEqual(title.frame, titleFrame, "the title must not move (cycle \(cycle))")
            XCTAssertEqual(confirm.frame, confirmFrame, "the confirm control must not move (cycle \(cycle))")
            let after = pixels(XCUIScreen.main.screenshot(), addFrame, screenWidth: width)
            XCTAssertLessThan(meanDifference(before, after), 2, "the + button must render the same (cycle \(cycle))")
        }

        // Files, cancelled, then the menu again.
        add.tap()
        assertOrderedMenu(app)
        app.buttons["Files"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the file browser opens")
        cancel.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(add.frame, addFrame)
        XCTAssertLessThan(meanDifference(before, pixels(XCUIScreen.main.screenshot(), addFrame, screenWidth: width)), 2)
        add.tap()
        assertOrderedMenu(app)
        dismissMenu(app)
        XCTAssertEqual(add.frame, addFrame)

        // Landscape keeps the header symmetric.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.frame.midX, app.frame.width / 2, accuracy: 1)
        add.tap()
        assertOrderedMenu(app)
        dismissMenu(app)
        capture("queued-attachments-landscape")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)

        // Closing without changes leaves the queue as it was.
        confirm.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2) && title.isHittable)
        XCTAssertTrue(app.staticTexts["Then review keyboard navigation."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 QUEUED"].exists)
    }

    /// Needs an image in the simulator's photo library (`xcrun simctl addmedia`).
    func testQueuedAttachmentFromPhotosStaysOnItsRow() throws {
        let app = launchQueue()
        openAttachments(app)
        app.buttons["queued-attachments-add"].tap()
        assertOrderedMenu(app)
        app.buttons["Photos"].tap()
        let photos = app.navigationBars["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        let image = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard image.waitForExistence(timeout: 10) else {
            throw XCTSkip("Seed the simulator photo library before running")
        }
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        photos.buttons["Done"].tap()

        let thumb = app.buttons["queued-attachment-0"]
        XCTAssertTrue(thumb.waitForExistence(timeout: 10))
        let confirm = app.buttons["queued-attachments-confirm"]
        XCTAssertEqual(confirm.label, "Save attachments")
        Thread.sleep(forTimeInterval: 0.8)
        capture("queued-attachments-staged")

        // Remove, then add again: the checkmark follows the change.
        app.buttons["Remove attachment 1"].tap()
        XCTAssertEqual(confirm.label, "Close")
        app.buttons["queued-attachments-add"].tap()
        app.buttons["Photos"].tap()
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        photos.buttons["Done"].tap()
        XCTAssertTrue(thumb.waitForExistence(timeout: 10))
        confirm.tap()

        // The second row keeps its text and its slot, now with an image; the
        // queue still holds both messages and nothing was sent.
        XCTAssertTrue(app.staticTexts["2 QUEUED"].waitForExistence(timeout: 5))
        let rowImage = app.buttons["Preview image"]
        XCTAssertTrue(rowImage.waitForExistence(timeout: 5))
        let rowText = app.staticTexts["Then review keyboard navigation."]
        XCTAssertTrue(rowText.exists)
        XCTAssertGreaterThan(rowText.frame.minY, app.staticTexts["Check the narrow layout."].frame.minY)
        XCTAssertEqual(rowImage.frame.midY, rowText.frame.midY, accuracy: 22)
        Thread.sleep(forTimeInterval: 0.8)
        capture("queued-attachments-saved")
    }
}
