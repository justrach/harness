import CoreText
import UIKit
import XCTest
@testable import Harness

/// The Write page's styler: which stretches of a draft draw as headings,
/// lists, bold, code, and which characters are markdown drawn faint.
final class WriteMarkdownTests: XCTestCase {
    private func text(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    /// The text of every span with `style`, in order.
    private func styled(_ source: String, _ style: WriteStyle) -> [String] {
        WriteMarkdown.spans(source).filter { $0.style == style }.map { text(source, $0.range) }
    }

    private func markers(_ source: String) -> [String] { styled(source, .marker) }

    func testHeadingsStyleTheWholeLineAndFadeTheHashes() {
        let source = "# Renderer notes\nbody\n## Keep it short\n### Third\n#### Deeper"
        XCTAssertEqual(styled(source, .heading(1)), ["# Renderer notes"])
        XCTAssertEqual(styled(source, .heading(2)), ["## Keep it short"])
        XCTAssertEqual(styled(source, .heading(3)), ["### Third", "#### Deeper"])
        XCTAssertEqual(markers(source), ["# ", "## ", "### ", "#### "])
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        let source = "#hashtag and #1"
        XCTAssertTrue(WriteMarkdown.spans(source).isEmpty)
    }

    func testBoldItalicAndCodeKeepTheirMarkersFaint() {
        let source = "Cap it at `30s`, **never** re-encode, *maybe* later"
        XCTAssertEqual(styled(source, .code), ["30s"])
        XCTAssertEqual(styled(source, .bold), ["never"])
        XCTAssertEqual(styled(source, .italic), ["maybe"])
        XCTAssertEqual(markers(source), ["`", "`", "**", "**", "*", "*"])
    }

    func testNothingInsideCodeIsBold() {
        let source = "run `a **b** c` now"
        XCTAssertEqual(styled(source, .code), ["a **b** c"])
        XCTAssertEqual(styled(source, .bold), [])
    }

    func testListLinesHangUnderTheirText() {
        let source = "- first\n* second\n12. third\n  - nested\n-not a list"
        let items = WriteMarkdown.spans(source).compactMap { span -> (String, Int)? in
            guard case .listItem(let indent) = span.style else { return nil }
            return (text(source, span.range), indent)
        }
        XCTAssertEqual(items.map(\.0), ["- first", "* second", "12. third", "  - nested"])
        XCTAssertEqual(items.map(\.1), [2, 2, 4, 4])
        // Only the bullet is faint, and a `* ` bullet is not an italic opener.
        XCTAssertEqual(markers(source), ["-", "*", "12.", "-"])
        XCTAssertEqual(styled(source, .italic), [])
    }

    func testQuotesAndFencedCode() {
        let source = "> quoted **line**\n```\nlet x = 1\n```\nafter"
        XCTAssertEqual(styled(source, .quote), ["> quoted **line**"])
        XCTAssertEqual(styled(source, .bold), ["line"])
        XCTAssertEqual(styled(source, .codeBlock), ["let x = 1"])
        XCTAssertEqual(markers(source), ["> ", "**", "**", "```", "```"])
    }

    func testRangesAreUTF16() {
        let source = "👋 **hi**"
        XCTAssertEqual(styled(source, .bold), ["hi"])
    }

    func testWordsCountWhatAReaderWouldCount() {
        XCTAssertEqual(WriteMarkdown.wordCount(""), 0)
        XCTAssertEqual(WriteMarkdown.wordCount("# Title\n\n- one **two**\n- `3`"), 4)
        XCTAssertEqual(WriteMarkdown.wordCountLabel(1), "1 word")
        XCTAssertEqual(WriteMarkdown.wordCountLabel(214), "214 words")
    }

    /// Restyling changes attributes only: the text, and so the selection, stay.
    @MainActor
    func testStylingKeepsTheTextAndDrawsMarkersFaint() {
        let source = "# Title\nSome **bold** words"
        let storage = NSTextStorage(string: source)
        let face = WriteTypeface(serif: true, size: 18.5)
        WriteStyler.apply(storage, face: face)
        XCTAssertEqual(storage.string, source)
        let heading = storage.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertEqual(heading?.pointSize ?? 0, face.headingSize(1), accuracy: 0.01)
        XCTAssertGreaterThan(face.headingSize(1), 18.5)
        let boldAt = (source as NSString).range(of: "bold").location
        let bold = storage.attribute(.font, at: boldAt, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        let marker = storage.attribute(.foregroundColor, at: boldAt - 1, effectiveRange: nil) as? UIColor
        let word = storage.attribute(.foregroundColor, at: boldAt, effectiveRange: nil) as? UIColor
        XCTAssertEqual(rgba(marker), rgba(UIColor(Theme.textFaint)))
        XCTAssertEqual(rgba(word), rgba(UIColor(Theme.text)))
    }

    /// Geist has no italic cut, so sans italics lean the upright face.
    @MainActor
    func testSansItalicsLean() {
        let storage = NSTextStorage(string: "a *lean* word")
        WriteStyler.apply(storage, face: WriteTypeface(serif: false, size: 18.5))
        let leaning = storage.attribute(.font, at: 3, effectiveRange: nil) as? UIFont
        let upright = storage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(leaning.map { CTFontGetMatrix($0 as CTFont).c } ?? 0, 0)
        XCTAssertEqual(upright.map { CTFontGetMatrix($0 as CTFont).c } ?? 1, 0)
    }

    private func rgba(_ color: UIColor?) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }
}
