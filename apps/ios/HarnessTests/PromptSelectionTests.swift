import SwiftUI
import XCTest
@testable import Harness

@MainActor
final class PromptSelectionTests: XCTestCase {
    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private func mount(_ bubble: UserBubble) async -> (UIWindow, UIHostingController<UserBubble>) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 350, height: 700)
        let host = UIHostingController(rootView: bubble)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        return (window, host)
    }

    func testCollapsedSelectionNeverSplitsGraphemesOrUsesInvalidOffsets() {
        let text = "A👩🏽‍💻 café"
        let whole = NSRange(location: 0, length: text.utf16.count)
        XCTAssertEqual(SelectableText.visibleSelection(whole, in: text, limit: 3), NSRange(location: 0, length: 1))
        XCTAssertEqual(SelectableText.visibleSelection(whole, in: text, limit: Int.max), whole)
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: Int.max),
                      NSRange(location: -1, length: 2), NSRange(location: 2, length: 1)] {
            XCTAssertEqual(SelectableText.visibleSelection(range, in: text, limit: 3), NSRange(location: 0, length: 0))
        }
        let hidden = (text as NSString).range(of: "café")
        XCTAssertEqual(SelectableText.visibleSelection(hidden, in: text, limit: 1), NSRange(location: 1, length: 0))
    }

    func testSentPromptSupportsPartialNativeCopy() async throws {
        let source = "Select 👩🏽‍💻 café\nSecond paragraph to copy."
        let (window, host) = await mount(UserBubble(text: source))
        defer { window.isHidden = true; window.rootViewController = nil }
        let views = textViews(in: host.view)
        XCTAssertEqual(views.count, 1, "A sent prompt needs one native selection surface, without selectable measurement copies")
        let view = try XCTUnwrap(views.first)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.isScrollEnabled)
        let passage = "👩🏽‍💻 café\nSecond"
        view.selectedRange = (source as NSString).range(of: passage)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, passage, "Copy must contain only the selected passage")
    }

    func testCollapsedPromptClampsSelectionAndExpansionKeepsOneNativeView() async throws {
        let source = "First line\nSecond line\nThird line\nFourth line\nFifth line\nHidden sixth line\nHidden seventh line\nHidden eighth line"
        let (window, host) = await mount(UserBubble(text: source))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertEqual(view.textContainer.maximumNumberOfLines, 5)
        let collapsedHeight = view.bounds.height
        view.selectedRange = NSRange(location: 0, length: source.utf16.count)
        view.delegate?.textViewDidChangeSelection?(view)
        XCTAssertLessThanOrEqual(NSMaxRange(view.selectedRange), (source as NSString).range(of: "Hidden sixth").location,
                                 "Dragging through a collapsed prompt must not select hidden continuation text")
        view.copy(nil)
        XCTAssertFalse(UIPasteboard.general.string?.contains("Hidden sixth") ?? true)

        host.rootView = UserBubble(text: source, expanded: true)
        try? await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        XCTAssertEqual(textViews(in: host.view).count, 1)
        XCTAssertTrue(textViews(in: host.view).first === view)
        XCTAssertEqual(view.textContainer.maximumNumberOfLines, 0)
        XCTAssertGreaterThan(view.bounds.height, collapsedHeight)
        view.selectedRange = (source as NSString).range(of: "Hidden sixth line\nHidden seventh line")
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "Hidden sixth line\nHidden seventh line")
    }

    func testShortPromptKeepsContentWidthInsteadOfFillingTheBubble() async throws {
        let (window, host) = await mount(UserBubble(text: "Hi"))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertLessThan(view.bounds.width, 100, "Native selection must not make short prompts fill the transcript width")
    }
}
