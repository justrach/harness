import SwiftUI
import XCTest
@testable import Harness

@MainActor
final class TextSelectionTests: XCTestCase {
    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private func mount<V: View>(_ content: V, width: CGFloat = 350) async -> (UIWindow, UIHostingController<V>) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        return (window, host)
    }

    func testEveryMarkdownTextBlockSupportsNativeRangeSelection() async throws {
        let runs = [InlineRun(text: "Select words 👩🏽‍💻 and café\non another line", style: .plain)]
        let blocks: [MDBlock] = [
            .paragraph(runs), .heading(level: 2, runs),
            .blockquote([.paragraph(runs)]),
            .list(orderedStart: nil, items: [MDListItem(checked: nil, children: [.paragraph(runs)])]),
            .table(header: [runs], rows: [[runs]], align: [.left]),
            .codeBlock(language: "swift", code: "let first = 1\n\nlet second = 2"),
        ]
        for block in blocks {
            let (window, host) = await mount(MarkdownBlockView(block: block))
            defer { window.isHidden = true; window.rootViewController = nil }
            let views = textViews(in: host.view)
            XCTAssertFalse(views.isEmpty, "No native text selection in \(block)")
            for view in views {
                XCTAssertTrue(view.isSelectable)
                XCTAssertFalse(view.isEditable)
                XCTAssertFalse(view.isScrollEnabled, "The transcript, not its text, owns vertical scrolling")
                XCTAssertGreaterThan(view.bounds.height, 0)
                let expected = (view.text as NSString).range(of: block.isCode ? "first = 1\n\nlet second" : "words 👩🏽‍💻 and café\non")
                XCTAssertNotEqual(expected.location, NSNotFound)
                view.selectedRange = expected
                view.copy(nil)
                XCTAssertEqual(UIPasteboard.general.string, (view.text as NSString).substring(with: expected))
            }
        }
    }

    func testPaintUpdatesAndAppendsPreserveUTF16Selection() async throws {
        let source = "Keep 👩🏽‍💻 café selected"
        let (window, host) = await mount(SelectableText(text: NSAttributedString(string: source)))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        let range = (source as NSString).range(of: "👩🏽‍💻 café")
        view.selectedRange = range
        let repaint = NSAttributedString(string: source, attributes: [.foregroundColor: UIColor.red])
        SelectableText.update(repaint, in: view)
        XCTAssertEqual(view.selectedRange, range)
        SelectableText.update(repaint, in: view)
        XCTAssertEqual(view.selectedRange, range)
        SelectableText.update(NSAttributedString(string: source + " while streaming"), in: view)
        XCTAssertEqual(view.selectedRange, range)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "👩🏽‍💻 café")
    }

    func testStreamingCompletionKeepsNativeViewAndSelection() async throws {
        let block = MDBlock.paragraph([InlineRun(text: "Keep this passage selected", style: .plain)])
        let row = TranscriptRow(id: "reply#t0.0", version: 1, turnStart: false,
                                kind: .markdown(block: block, streaming: true), entryId: "reply",
                                timestamp: nil, partKey: "reply#t0")
        let veils = VeilStore()
        let (window, host) = await mount(MarkdownRowView(row: row, block: block, streaming: true, veils: veils))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        let range = (view.text as NSString).range(of: "this passage")
        view.selectedRange = range
        host.rootView = MarkdownRowView(row: row, block: block, streaming: false, veils: veils)
        try? await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        XCTAssertTrue(textViews(in: host.view).first === view)
        XCTAssertEqual(view.selectedRange, range)
    }

    func testInlineStylesLinksAndHardBreaksKeepTheirTextAndRanges() {
        let runs = [
            InlineRun(text: "👋 ", style: .plain),
            InlineRun(text: "a link", style: InlineStyle(bold: true, link: "https://example.com")),
            InlineRun(text: "\nlet café = 1", style: InlineStyle(code: true)),
        ]
        let text = runs.selectableAttributed()
        XCTAssertEqual(text.string, "👋 a link\nlet café = 1")
        let linkRange = (text.string as NSString).range(of: "a link")
        XCTAssertEqual(text.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
        let codeRange = (text.string as NSString).range(of: "let café")
        XCTAssertNotNil(text.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil))
        XCTAssertNotNil(text.attribute(.font, at: codeRange.location, effectiveRange: nil))
    }
}

private extension MDBlock {
    var isCode: Bool {
        if case .codeBlock = self { return true }
        return false
    }
}
