import UIKit
import XCTest

/// Run on the Duo cover simulator, with synthetic demo sessions only.
@MainActor
final class CoverSessionDrawerUITests: XCTestCase {
    private func launch(duo: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-sethomefilter", "", "-route", "chat:chat-tabs",
                               "-phoneSplit", "off", "-foldableDevice", duo ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 10))
        return app
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Count dark glyph pixels, not a full screenshot hash: glass/shadows may vary.
    private func darkPixels(_ image: UIImage, in rect: CGRect, windowWidth: CGFloat) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(source.width) / windowWidth
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale)
        let crop = try XCTUnwrap(source.cropping(to: pixels))
        var rgba = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: crop.width,
                height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var count = 0
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            if red + green + blue < 300 { count += 1 }
        }
        return count
    }

    func testDrawerPushesWholeChatAndRestoresIt() throws {
        let app = launch()
        let toggle = app.buttons["duo-cover-toggle-sessions"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.exists)
        let closedBackX = back.frame.midX
        let closedBackY = back.frame.midY
        XCTAssertLessThan(abs(toggle.frame.midY - back.frame.midY), 100,
                          "The sessions button belongs beside Back, not at the bottom of the rail")
        let title = app.descendants(matching: .any)["session-header"].label
        screenshot("cover-drawer-collapsed")
        toggle.tap()
        XCTAssertTrue(app.textFields["cover-sessions-search"].waitForExistence(timeout: 5))
        let list = app.descendants(matching: .any)["cover-sessions-list"]
        let backdrop = app.buttons["cover-sessions-backdrop"]
        XCTAssertGreaterThanOrEqual(backdrop.frame.width, 44)
        XCTAssertLessThan(backdrop.frame.maxX, list.frame.maxX)
        screenshot("cover-drawer-expanded")
        let preview = app.images["cover-moving-page"]
        XCTAssertTrue(preview.exists)
        XCTAssertEqual(preview.frame.maxX, backdrop.frame.maxX, accuracy: 1)
        let expectedBackX = closedBackX - (app.frame.width - backdrop.frame.width)
        XCTAssertGreaterThan(try darkPixels(app.screenshot().image,
            in: CGRect(x: expectedBackX - 12, y: closedBackY - 16, width: 24, height: 32),
            windowWidth: app.frame.width), 10,
            "The native Back glyph must move left without reflowing into the top toolbar")
        backdrop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["session-header"].label, title)
        XCTAssertEqual(back.frame.midX, closedBackX, accuracy: 1)
        XCTAssertEqual(back.frame.midY, closedBackY, accuracy: 1)
        XCTAssertFalse(app.textFields["cover-sessions-search"].exists)
    }

    func testSearchAndSelectionSwitchInPlaceIncludingBackToTheOriginalSession() {
        let app = launch()
        let original = app.descendants(matching: .any)["session-header"].label
        app.buttons["duo-cover-toggle-sessions"].tap()
        let search = app.textFields["cover-sessions-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("no matching synthetic session")
        XCTAssertTrue(app.staticTexts["No matching sessions"].waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                               count: "no matching synthetic session".count))
        // Pick another synthetic demo session, then pick the original again. Back must still lead Home.
        let other = app.descendants(matching: .any)["cover-session-chat-deploy"]
        if !other.isHittable { app.swipeUp() }
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertFalse(search.exists)
        XCTAssertNotEqual(app.descendants(matching: .any)["session-header"].label, original)
        app.buttons["duo-cover-toggle-sessions"].tap()
        let row = app.descendants(matching: .any)["cover-session-chat-tabs"]
        if !row.isHittable { app.swipeDown() }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["session-header"].label, original)
        XCTAssertFalse(search.exists)
    }

    func testOrdinaryPhoneDoesNotOfferTheDrawer() {
        let app = launch(duo: false)
        XCTAssertFalse(app.buttons["duo-cover-toggle-sessions"].exists)
    }
}
