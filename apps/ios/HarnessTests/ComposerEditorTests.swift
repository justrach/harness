import SwiftUI
import XCTest
@testable import Harness

@MainActor
final class ComposerEditorTests: XCTestCase {
    func testSendingMarkedTextClearsNativeStorageWithoutLosingFocusOrNextDraft() async {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let input = UITextView(frame: CGRect(x: 20, y: 100, width: 300, height: 100))
        host.view.addSubview(input)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let editor = ComposerEditorController()
        editor.view = input
        input.delegate = editor
        var draft = ""
        editor.textChanged = { draft = $0 }
        input.becomeFirstResponder()
        for prompt in ["hellp", "你好 👋🏽", "First line\nSecond line"] {
            input.setMarkedText(prompt, selectedRange: NSRange(location: prompt.utf16.count, length: 0))
            editor.commit()
            XCTAssertEqual(draft, prompt)
            XCTAssertNil(input.markedTextRange)
            draft = ""
            editor.apply(text: draft)
            XCTAssertEqual(input.text, "")
            XCTAssertTrue(input.isFirstResponder)
            // UIKit may deliver a queued change notification after clearing.
            editor.textViewDidChange(input)
            XCTAssertEqual(draft, "")
            input.insertText("Next draft")
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(draft, "Next draft")
            XCTAssertEqual(input.text, "Next draft")
            editor.apply(text: "")
        }
    }

    func testPastedImagesKeepTheirBytesAndStageAsAttachments() throws {
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("composer-paste-test"),
                                                    create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let png = try XCTUnwrap(image.pngData())
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        // A screenshot (PNG) and a Photos copy (JPEG) arrive as-is, one item each.
        pasteboard.items = [["public.png": png], ["public.jpeg": jpeg]]
        XCTAssertEqual(ComposerTextView.imageData(from: pasteboard), [png, jpeg])

        let (staged, failed) = StagedAttachment.stage(images: [png, jpeg, Data("not an image".utf8)])
        XCTAssertEqual(staged.map { ($0.name as NSString).pathExtension }, ["png", "jpg"])
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(StagedAttachment.failureMessage(failed),
                       "One image couldn't be attached (unsupported or over 24 MB).")
        XCTAssertNil(StagedAttachment.failureMessage(0))
    }
}
