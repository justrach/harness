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

    func testRepeatedLayoutProposalsReuseNativeMeasurement() {
        let view = CountingSizingTextView()
        view.isScrollEnabled = false
        let text = [InlineRun(text: String(repeating: "Synthetic output with several words. ", count: 80),
                              style: .plain)].selectableAttributed()
        SelectableText.update(text, in: view)
        let coordinator = SelectableText.Coordinator(openURL: OpenURLAction { _ in .handled })
        let proposal = ProposedViewSize(width: 320, height: nil)
        let expected = coordinator.sizeThatFits(proposal, text: text, wraps: true, view: view)
        let calls = view.measurements
        let start = CACurrentMediaTime()
        for _ in 0..<200 {
            XCTAssertEqual(coordinator.sizeThatFits(proposal, text: text, wraps: true, view: view), expected)
        }
        let cachedTime = CACurrentMediaTime() - start
        XCTAssertEqual(view.measurements, calls, "Identical SwiftUI proposals must not invalidate live TextKit layout")

        let uncachedStart = CACurrentMediaTime()
        for _ in 0..<200 {
            _ = view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        }
        let uncachedTime = CACurrentMediaTime() - uncachedStart
        XCTAssertGreaterThan(uncachedTime, cachedTime * 5,
                             "Repeated proposals should be at least 5× cheaper than native layout")
    }

    func testMeasurementCacheTracksWidthTextFontAndNaturalSize() {
        let view = CountingSizingTextView()
        view.isScrollEnabled = false
        let coordinator = SelectableText.Coordinator(openURL: OpenURLAction { _ in .handled })
        let source = "Synthetic output wraps onto several lines at a narrow width."
        let text = [InlineRun(text: source, style: .plain)].selectableAttributed()
        coordinator.update(text, lineHeight: MD.lineHeight, in: view)
        let wide = coordinator.sizeThatFits(ProposedViewSize(width: 320, height: nil), text: text, wraps: true, view: view)
        let narrow = coordinator.sizeThatFits(ProposedViewSize(width: 80, height: nil), text: text, wraps: true, view: view)
        XCTAssertGreaterThan(narrow.height, wide.height)
        let natural = coordinator.sizeThatFits(.unspecified, text: text, wraps: true, view: view)
        XCTAssertGreaterThan(natural.width, wide.width)
        let calls = view.measurements
        XCTAssertEqual(coordinator.sizeThatFits(ProposedViewSize(width: 320, height: 1),
                                                text: text, wraps: true, view: view), wide)
        XCTAssertEqual(coordinator.sizeThatFits(ProposedViewSize(width: 80, height: nil),
                                                text: text, wraps: false, view: view), natural)
        coordinator.update(text, lineHeight: MD.lineHeight, in: view)
        _ = coordinator.sizeThatFits(.unspecified, text: text, wraps: true, view: view)
        XCTAssertEqual(view.measurements, calls, "Equal content and height-only proposals reuse cached sizes")

        for changed in [[InlineRun(text: source + source, style: .plain)].selectableAttributed(),
                        [InlineRun(text: source, style: .plain)].selectableAttributed(size: 40, lineHeight: 60)] {
            coordinator.update(changed, lineHeight: MD.lineHeight, in: view)
            let updated = coordinator.sizeThatFits(ProposedViewSize(width: 320, height: nil),
                                                   text: changed, wraps: true, view: view)
            XCTAssertGreaterThan(updated.height, wide.height, "Text and font updates must discard old heights")
            XCTAssertGreaterThan(coordinator.sizeThatFits(.unspecified, text: changed, wraps: true, view: view).width,
                                 natural.width, "Natural width must also be invalidated")
        }
        coordinator.update(NSAttributedString(string: ""), lineHeight: MD.lineHeight, in: view)
        let empty = coordinator.sizeThatFits(.unspecified, text: NSAttributedString(string: ""), wraps: true, view: view)
        XCTAssertEqual(empty.width, 1)
        XCTAssertEqual(empty.height, ceil(view.sizeThatFits(CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)).height))
    }

    func testMeasurementCacheIsBoundedDuringContinuousResizing() {
        let view = CountingSizingTextView()
        let text = NSAttributedString(string: "Synthetic resize output")
        SelectableText.update(text, in: view)
        let coordinator = SelectableText.Coordinator(openURL: OpenURLAction { _ in .handled })
        for width in 100...120 {
            _ = coordinator.sizeThatFits(ProposedViewSize(width: CGFloat(width), height: nil),
                                         text: text, wraps: true, view: view)
        }
        let calls = view.measurements
        _ = coordinator.sizeThatFits(ProposedViewSize(width: 120, height: nil), text: text, wraps: true, view: view)
        XCTAssertEqual(view.measurements, calls)
        _ = coordinator.sizeThatFits(ProposedViewSize(width: 100, height: nil), text: text, wraps: true, view: view)
        XCTAssertEqual(view.measurements, calls + 1, "Old resize proposals must be evicted")
    }

    func testLineMetricChangesInvalidateMountedMeasurementCache() async throws {
        let text = [InlineRun(text: "", style: .plain)].selectableAttributed()
        let (window, host) = await mount(SelectableText(text: text, lineHeight: 24).fixedSize(horizontal: false, vertical: true))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        let before = view.bounds.height
        host.rootView = SelectableText(text: text, lineHeight: 72).fixedSize(horizontal: false, vertical: true)
        try? await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        XCTAssertTrue(textViews(in: host.view).first === view)
        XCTAssertEqual(view.bounds.height - before, 48, accuracy: 1,
                       "The final empty line changes size even when attributed text stays equal")
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

    func testCorrectedOrShortenedTextDoesNotLeaveAStaleSelection() async throws {
        for replacement in ["Read THAT passage", "Short", ""] {
            let original = "Keep THIS passage"
            let (window, host) = await mount(SelectableText(text: NSAttributedString(string: original)))
            defer { window.isHidden = true; window.rootViewController = nil }
            let view = try XCTUnwrap(textViews(in: host.view).first)
            view.selectedRange = (original as NSString).range(of: "THIS")
            SelectableText.update(NSAttributedString(string: replacement), in: view)
            XCTAssertEqual(view.selectedRange.length, 0,
                           "A replaced row must not keep highlighting unrelated text: \(replacement)")
        }
    }

    func testBlurClearsInactiveRangeAndRepaintsDoNotStealComposerFocus() async throws {
        let original = "Keep this passage selected"
        let (window, host) = await mount(SelectableText(text: NSAttributedString(string: original)))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = (original as NSString).range(of: "this passage")
        let composer = UITextView(frame: CGRect(x: 10, y: 500, width: 300, height: 80))
        host.view.addSubview(composer)
        XCTAssertTrue(composer.becomeFirstResponder())
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
        SelectableText.update(NSAttributedString(string: original, attributes: [.foregroundColor: UIColor.red]), in: view)
        XCTAssertTrue(composer.isFirstResponder)
        SelectableText.update(NSAttributedString(string: original + " while streaming"), in: view)
        XCTAssertTrue(composer.isFirstResponder)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 0))
    }

    func testSelectionRetentionRuleRejectsInvalidAndSplitRanges() {
        let text = "👩🏽‍💻e\u{301} end"
        for range in [NSRange(location: NSNotFound, length: 0),
                      NSRange(location: 0, length: Int.max),
                      NSRange(location: -1, length: 1),
                      NSRange(location: 0, length: -1),
                      NSRange(location: text.utf16.count + 1, length: 0),
                      NSRange(location: 1, length: 1),
                      NSRange(location: 0, length: 2),
                      NSRange(location: "👩🏽‍💻".utf16.count, length: 1)] {
            XCTAssertEqual(SelectableText.retainedSelection(range, from: text, to: text + "!"),
                           NSRange(location: 0, length: 0), "Invalid/split range: \(range)")
        }
        let cursor = NSRange(location: text.utf16.count, length: 0)
        XCTAssertEqual(SelectableText.retainedSelection(cursor, from: text, to: text + "!"), cursor)
    }

    func testGraphemeExtensionPreservesASelectionEarlierInTheText() async throws {
        let original = "Keep e"
        let (window, host) = await mount(SelectableText(text: NSAttributedString(string: original)))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        let range = (original as NSString).range(of: "Keep")
        view.selectedRange = range
        SelectableText.update(NSAttributedString(string: "Keep e\u{301}"), in: view)
        XCTAssertEqual(view.selectedRange, range)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "Keep")
    }

    func testCanonicalUnicodeReplacementDoesNotReuseOldUTF16Offsets() async throws {
        // String.hasPrefix considers these canonically equal, but TextKit's
        // UTF-16 offsets differ: keeping the old range would copy "ail ".
        let original = "cafe\u{301} tail"
        let (window, host) = await mount(SelectableText(text: NSAttributedString(string: original)))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        view.selectedRange = (original as NSString).range(of: "tail")
        SelectableText.update(NSAttributedString(string: "café tail plus"), in: view)
        XCTAssertEqual(view.selectedRange.length, 0,
                       "Normalization is a replacement, not a UTF-16-preserving append")
    }

    func testAppendThatExtendsAGraphemeDoesNotSplitTheSelection() async throws {
        for (original, appended) in [("👩", "👩🏽‍💻"), ("e", "e\u{301}"), ("🇺", "🇺🇸")] {
            let (window, host) = await mount(SelectableText(text: NSAttributedString(string: original)))
            defer { window.isHidden = true; window.rootViewController = nil }
            let view = try XCTUnwrap(textViews(in: host.view).first)
            view.selectedRange = NSRange(location: 0, length: original.utf16.count)
            SelectableText.update(NSAttributedString(string: appended), in: view)
            let selection = view.selectedRange
            let selected = (appended as NSString).substring(with: selection)
            XCTAssertTrue(selection.length == 0 || selected == appended,
                          "An append must not select only part of a grapheme: \(selected)")
        }
    }

    func testSelectionAcrossMixedStylesCopiesLiteralUnicodeAndHardBreaks() async throws {
        let runs = [
            InlineRun(text: "العربية ", style: .plain),
            InlineRun(text: "bold", style: InlineStyle(bold: true)),
            InlineRun(text: "\n👩🏽‍💻 café\t", style: InlineStyle(code: true)),
            InlineRun(text: "a link", style: InlineStyle(italic: true, link: "https://example.com")),
            InlineRun(text: " 終わり", style: InlineStyle(strikethrough: true)),
        ]
        let (window, host) = await mount(SelectableMarkdownText(runs: runs))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        let expected = "bold\n👩🏽‍💻 café\ta link"
        view.selectedRange = (view.text as NSString).range(of: expected)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, expected)
        XCTAssertEqual(view.text, runs.map(\.text).joined())
    }

    func testEmptyAndWhitespaceOnlyCodePreservesEveryNewlineAndTab() async throws {
        for code in ["", "\n", "\n\n", "a\n", "a\n\n", "\t\n  \t\n", "👩🏽‍💻\t café\n"] {
            let (window, host) = await mount(CodeBlockView(language: nil, code: code))
            defer { window.isHidden = true; window.rootViewController = nil }
            let view = try XCTUnwrap(textViews(in: host.view).first)
            XCTAssertEqual(view.text, code)
            XCTAssertTrue(view.bounds.width.isFinite)
            XCTAssertTrue(view.bounds.height.isFinite)
            XCTAssertGreaterThanOrEqual(view.bounds.height, 0)
            if !code.isEmpty {
                view.selectedRange = NSRange(location: 0, length: code.utf16.count)
                view.copy(nil)
                XCTAssertEqual(UIPasteboard.general.string, code)
            }
        }
    }

    func testEmptyCodeUsesTheSameLineMetricsAsNonemptyCode() async throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            var heights: [CGFloat] = []
            for code in ["x", "", "\n", "\n\n"] {
                let (window, host) = await mount(CodeBlockView(language: nil, code: code)
                    .environment(\.dynamicTypeSize, typeSize))
                defer { window.isHidden = true; window.rootViewController = nil }
                let view = try XCTUnwrap(textViews(in: host.view).first)
                heights.append(view.bounds.height)
            }
            let line = heights[0]
            XCTAssertGreaterThan(line, 0)
            XCTAssertEqual(heights[1], line, accuracy: 1, "Empty code needs one code-height line: \(typeSize)")
            XCTAssertEqual(heights[2], line * 2, accuracy: 1, "One newline needs two lines: \(typeSize)")
            XCTAssertEqual(heights[3], line * 3, accuracy: 1, "Two newlines need three lines: \(typeSize)")
        }
    }

    func testTableAlignmentReachesNativeParagraphs() async throws {
        let header = [InlineRun(text: "A wider column", style: .plain)]
        let cell = [InlineRun(text: "x", style: .plain)]
        let block = MDBlock.table(header: [header, header, header], rows: [[cell, cell, cell]],
                                  align: [.left, .center, .right])
        let (window, host) = await mount(MarkdownBlockView(block: block))
        defer { window.isHidden = true; window.rootViewController = nil }
        let views = textViews(in: host.view)
        XCTAssertEqual(views.count, 6)
        let expected: [NSTextAlignment] = [.left, .center, .right, .left, .center, .right]
        for (view, alignment) in zip(views, expected) {
            let paragraph = try XCTUnwrap(view.attributedText.attribute(.paragraphStyle, at: 0,
                                                                       effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(paragraph.alignment, alignment)
            if view.text == "x" {
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyphs = view.layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: 1),
                                                           actualCharacterRange: nil)
                let bounds = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
                switch alignment {
                case .center: XCTAssertEqual(bounds.midX, view.bounds.midX, accuracy: 2)
                case .right: XCTAssertEqual(bounds.maxX, view.bounds.maxX, accuracy: 2)
                default: XCTAssertEqual(bounds.minX, 0, accuracy: 2)
                }
            }
        }
    }

    func testNarrowAccessibilityLayoutDoesNotClipSelectableText() async throws {
        let runs = [InlineRun(text: String(repeating: "Long 👩🏽‍💻 café output ", count: 12), style: .plain)]
        let (window, host) = await mount(SelectableMarkdownText(runs: runs)
            .environment(\.dynamicTypeSize, .accessibility3), width: 180)
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        view.layoutManager.ensureLayout(for: view.textContainer)
        let used = view.layoutManager.usedRect(for: view.textContainer)
        XCTAssertLessThanOrEqual(view.bounds.width, 181)
        XCTAssertLessThanOrEqual(used.maxY, view.bounds.height + 1)
        XCTAssertGreaterThan(view.bounds.height, 100)
        let font = try XCTUnwrap(view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(font.pointSize, MD.textSize)
    }

    func testVeilUsesCharacterOffsetsAcrossEmojiAndStyleBoundaries() {
        var now: Double = 0
        let veil = RowVeil(seededLength: 1, clock: { now })
        let runs = [InlineRun(text: "A👩🏽‍💻", style: .plain),
                    InlineRun(text: "café", style: InlineStyle(code: true))]
        veil.noteLength(6)
        let faded = runs.selectableAttributed(veil: veil)
        XCTAssertEqual(faded.string, "A👩🏽‍💻café")
        let settled = faded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! UIColor
        let emoji = faded.attribute(.foregroundColor, at: 1, effectiveRange: nil) as! UIColor
        let code = faded.attribute(.foregroundColor, at: ("A👩🏽‍💻" as NSString).length,
                                   effectiveRange: nil) as! UIColor
        XCTAssertGreaterThan(settled.cgColor.alpha, 0.9)
        XCTAssertEqual(emoji.cgColor.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(code.cgColor.alpha, 0, accuracy: 0.001)
        now = 1000
        let finished = runs.selectableAttributed(veil: veil)
        let restored = finished.attribute(.foregroundColor, at: 1, effectiveRange: nil) as! UIColor
        XCTAssertGreaterThan(restored.cgColor.alpha, 0.9)
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

private final class CountingSizingTextView: UITextView {
    var measurements = 0

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        measurements += 1
        return super.sizeThatFits(size)
    }
}

private extension MDBlock {
    var isCode: Bool {
        if case .codeBlock = self { return true }
        return false
    }
}
