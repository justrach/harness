import UIKit
import XCTest

/// Pasting an image into the composer stages it as an attachment.
@MainActor
final class ComposerPasteUITests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        // The app's own window: on an iPhone Duo, the main screen is the cover display.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func copyImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        UIPasteboard.general.image = image
    }

    private func paste(into app: XCUIApplication) {
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.tap()
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the edit menu offers Paste for a copied image")
        paste.tap()
    }

    private var staged: XCUIElementQuery {
        XCUIApplication().descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-"))
    }

    func testPastingAnImageStagesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-phoneSplit", "off", "-route", "chat:chat-tabs"]
        app.launch()
        copyImage()
        paste(into: app)
        let found = staged.firstMatch.waitForExistence(timeout: 10)
        capture(app, "composer-after-paste")
        XCTAssertTrue(found, "the pasted image is staged")
    }
}
