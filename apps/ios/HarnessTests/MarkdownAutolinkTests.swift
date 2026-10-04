import XCTest
@testable import Harness

/// swift-markdown attaches no GFM autolink extension, so a bare URL in a reply
/// used to stay plain text and could not be tapped.
final class MarkdownAutolinkTests: XCTestCase {
    private func runs(_ source: String) -> [InlineRun] {
        guard case .paragraph(let runs)? = MarkdownParser.parse(source).first?.block else {
            XCTFail("expected one paragraph"); return []
        }
        return runs
    }

    private func links(_ source: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: runs(source).compactMap { run in run.style.link.map { (run.text, $0) } })
    }

    func testBareURLsBecomeLinks() {
        XCTAssertEqual(links("See https://github.com/justrach/harness for more."),
                       ["https://github.com/justrach/harness": "https://github.com/justrach/harness"])
        XCTAssertEqual(links("Preview at http://127.0.0.1:3777/bare and done"),
                       ["http://127.0.0.1:3777/bare": "http://127.0.0.1:3777/bare"])
    }

    func testSurroundingTextAndPunctuationStayPlain() {
        let r = runs("Open https://example.com/a, then stop.")
        XCTAssertEqual(r.map(\.text).joined(), "Open https://example.com/a, then stop.")
        XCTAssertEqual(r.filter { $0.style.link != nil }.map(\.text), ["https://example.com/a"])
    }

    func testMarkdownLinksAndCodeAreUnchanged() {
        XCTAssertEqual(links("[the docs](https://example.com/docs)"), ["the docs": "https://example.com/docs"])
        // Inside inline code a URL is literal text.
        XCTAssertTrue(links("Run `curl https://example.com/x` now").isEmpty)
    }

    func testOnlyWebSchemesAutolink() {
        XCTAssertTrue(links("Write to me@example.com or call 555-0100").isEmpty)
    }
}
