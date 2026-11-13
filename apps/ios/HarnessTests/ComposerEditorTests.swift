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

    func testExplicitCommandSelectionSurvivesArgumentsDraftRestoreAndDelivery() throws {
        let input = ComposerTextView()
        let editor = ComposerEditorController()
        editor.view = input
        input.delegate = editor
        var draft = ""
        editor.textChanged = { draft = $0 }
        editor.apply(text: "/go")
        editor.selectCommand(ComposerCommand(name: "goal"), richReferences: true)
        let link = try XCTUnwrap(ComposerCommandReference(name: "goal").link)
        XCTAssertEqual(input.text, "\u{00a0}/goal\u{00a0} ")
        XCTAssertEqual(draft, link + " ")
        input.insertText("Build a demo calculator")
        editor.textViewDidChange(input)
        editor.commit()
        XCTAssertEqual(draft, link + " Build a demo calculator")
        editor.apply(text: "")
        editor.apply(text: draft)
        XCTAssertEqual(input.text, "\u{00a0}/goal\u{00a0} Build a demo calculator")
        XCTAssertEqual(editor.serializedText, draft)

        let config = AppConfig(edgeURL: URL(string: "https://example.test")!, mode: .dev,
                               userId: "test", orgId: "test", deviceId: "phone", deviceName: "Phone")
        let workspace = WorkspaceStore(config: config)
        let id = workspace.createProjectlessChat(deviceId: "host", config: ChatConfig(harness: "graff"))
        let chat = try XCTUnwrap(workspace.chats.first)
        let store = SessionStore(chatId: id, config: config)
        store.sendRun(prompt: draft, chat: chat)
        let commands = try XCTUnwrap(store.doc.getDeepValue().mapValue?["commands"]?.listValue)
        let request = try XCTUnwrap(commands.first?.mapValue?["payload"]?.mapValue?["request"]?.mapValue)
        XCTAssertEqual(request["prompt"]?.stringValue, draft, "The host must receive explicit selection intent")
        XCTAssertNotNil(store.enqueueMessage(text: draft))
        XCTAssertEqual(store.queue.first?.text, draft)
        let lease = QueueEditLease(rowId: "row", leaseId: "lease", text: draft,
                                   baseTextHash: "hash", expiresAtMs: 60_000)
        let edit = QueueComposerEdit(lease: lease, originalDraft: draft, hasAttachments: false)
        XCTAssertEqual(edit.textToCommit(editor.serializedText), draft)
    }

    func testWorkspaceActionRemovesOnlyItsTriggerAndPreservesSelectedProviderCommands() throws {
        let input = ComposerTextView()
        let editor = ComposerEditorController()
        editor.view = input
        input.delegate = editor
        let link = try XCTUnwrap(ComposerCommandReference(name: "review").link)
        editor.apply(text: link + " keep this /settings")
        var draft = ""
        editor.textChanged = { draft = $0 }
        editor.removeCommandQuery(named: "settings")
        XCTAssertEqual(draft, link + " keep this ")
        XCTAssertEqual(editor.serializedText, draft)
        XCTAssertEqual(input.text, "\u{00a0}/review\u{00a0} keep this ")
    }

    func testLiteralSlashTextAndLegacySelectionDoNotAcquireRichIntent() {
        let input = ComposerTextView()
        let editor = ComposerEditorController()
        editor.view = input
        input.delegate = editor
        editor.apply(text: "/goal explain this as prose")
        editor.commit()
        XCTAssertEqual(editor.serializedText, "/goal explain this as prose")
        editor.apply(text: "/go")
        editor.selectCommand(ComposerCommand(name: "goal"), richReferences: false)
        XCTAssertEqual(input.text, "/goal ")
        XCTAssertEqual(editor.serializedText, "/goal ")
    }

    func testEditingASelectedCommandLabelDropsItsOldIntent() throws {
        let input = ComposerTextView()
        let editor = ComposerEditorController()
        editor.view = input
        input.delegate = editor
        editor.apply(text: try XCTUnwrap(ComposerCommandReference(name: "goal").link) + " demo")
        input.textStorage.replaceCharacters(in: NSRange(location: 2, length: 4), with: "help")
        editor.textViewDidChange(input)
        XCTAssertEqual(input.text, "/help demo")
        XCTAssertEqual(editor.serializedText, "/help demo")
    }

    func testSelectedCommandReservesDesktopPaddingAndLineBoxWithoutChangingPrompt() throws {
        let input = ComposerTextView()
        let editor = ComposerEditorController()
        editor.view = input
        input.delegate = editor
        editor.updateStyle(font: Theme.sansUI(17))
        let link = try XCTUnwrap(ComposerCommandReference(name: "goal").link)
        editor.apply(text: link + " demo")
        XCTAssertEqual(input.text, "\u{00a0}/goal\u{00a0} demo",
                       "The Mac reserves one mono nonbreaking space on BOTH sides, inside the pill")
        let paragraph = try XCTUnwrap(input.attributedText.attribute(.paragraphStyle, at: 0,
                                                                    effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.minimumLineHeight, 17 * (22.75 / 14), accuracy: 0.01,
                       "The pill needs the Mac's 1.625 line box, not UIKit's tight glyph box")
        let baseline = try XCTUnwrap(input.attributedText.attribute(.baselineOffset, at: 0,
                                                                   effectiveRange: nil) as? CGFloat)
        XCTAssertEqual(baseline, (paragraph.minimumLineHeight - Theme.monoUI(17).lineHeight) / 2,
                       accuracy: 0.01, "The extra leading must be split above and below the label")
        XCTAssertEqual(editor.serializedText, link + " demo", "Presentation padding is never prompt text")
    }

    func testCommandChipsKeepDesktopTypographyAndColorAfterAViewUpdate() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let editor = ComposerEditorController()
        let draft = try XCTUnwrap(ComposerCommandReference(name: "goal").link) + " demo"
        func content(_ placeholder: String) -> ComposerEditor {
            ComposerEditor(text: .constant(draft), focused: .constant(false), placeholder: placeholder,
                           maxLines: 7, controller: editor)
        }
        let host = UIHostingController(rootView: content("Message"))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.rootView = content("Message again")
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let input = try XCTUnwrap(editor.view)
        let attributes = input.attributedText.attributes(at: 0, effectiveRange: nil)
        let font = try XCTUnwrap(attributes[.font] as? UIFont)
        XCTAssertEqual(font.fontName, Theme.monoUI(font.pointSize).fontName,
                       "Command chips use the desktop's mono face, not the surrounding sans face")
        XCTAssertEqual(attributes[.foregroundColor] as? UIColor, UIColor(Theme.inlineCodeText),
                       "UIView updates must not turn a selected command back into black text")
        XCTAssertNil(attributes[.backgroundColor], "The wash must be rounded paint, not a square text background")
        XCTAssertEqual(String(describing: type(of: input.layoutManager)), "ComposerCommandLayoutManager")
        XCTAssertEqual(editor.serializedText, draft)
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
