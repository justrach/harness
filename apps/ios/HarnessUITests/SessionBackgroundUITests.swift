import XCTest

/// An open session paints one background all the way to the screen edges. A different colour behind the
/// status bar or the home indicator reads as a hard black band, worst in dark mode.
@MainActor
final class SessionBackgroundUITests: XCTestCase {
    /// The first three colour bytes of the pixel at (x, y) points.
    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return []
        }
        let px = min(Int(x * image.scale), cg.width - 1), py = min(Int(y * image.scale), cg.height - 1)
        let offset = py * cg.bytesPerRow + px * (cg.bitsPerPixel / 8)
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
    }

    private func assertSameColour(_ a: [UInt8], _ b: [UInt8], _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, 3, file: file, line: line)
        XCTAssertEqual(b.count, 3, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertLessThanOrEqual(abs(Int(x) - Int(y)), 4, "\(message): \(a) vs \(b)", file: file, line: line)
        }
    }

    func testTheOpenSessionBackgroundReachesTheTopAndBottomEdgesInDarkMode() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-sethomefilter", "", "-theme.mode", "dark",
                               "-theme.dark", "harnesser-dark", "-theme.light", "harnesser-light"]
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tool group header colors")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-header"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)  // let the push settle

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "session-dark"
        attachment.lifetime = .keepAlways
        add(attachment)

        let image = screenshot.image
        let height = image.size.height
        let content = pixel(image, x: 4, y: height * 0.40)
        assertSameColour(pixel(image, x: 4, y: 8), content, "behind the status bar")
        assertSameColour(pixel(image, x: 4, y: height - 3), content, "behind the home indicator")
    }
}
