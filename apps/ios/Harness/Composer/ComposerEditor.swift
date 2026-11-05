import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let commandWashAttribute = NSAttributedString.Key("HarnessCommandWash")

// Match crates/ui/src/composer.rs: MENTION_SIDE_PAD, INPUT_LINE_HEIGHT /
// INPUT_TEXT_SIZE, and the chip quad. The spaces belong to display projection,
// never the stored prompt. Scale the 22.75/14 line box with iOS's text size.
private enum CommandPill {
    static let sidePad = "\u{00a0}"
    static let lineHeightMultiple: CGFloat = 22.75 / 14
    static let cornerRadius: CGFloat = 5
    static let verticalInset: CGFloat = 2

    static func label(_ link: String) -> String {
        sidePad + ComposerCommandText.visibleText(link) + sidePad
    }
}

/// Paint the rounded wash across the entire padded command projection.
final class ComposerCommandLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if let textStorage, let container = textContainers.first {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            textStorage.enumerateAttribute(commandWashAttribute, in: characters) { value, range, _ in
                guard let wash = value as? UIColor else { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                wash.setFill()
                enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in
                    let chip = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: CommandPill.verticalInset)
                    UIBezierPath(roundedRect: chip, cornerRadius: CommandPill.cornerRadius).fill()
                }
            }
        }
        // Native text selection remains on top of the command wash.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

private struct ComposerEditorStyle: Equatable {
    let font: UIFont
    let text: UIColor
    let commandText: UIColor
    let commandWash: UIColor
}

/// A stable native editor keeps marked text, selection, and keyboard ownership
/// in one place. Sending commits and clears this same text storage synchronously.
@MainActor
final class ComposerEditorController: NSObject, UITextViewDelegate, UITextDropDelegate {
    weak var view: UITextView?
    var textChanged: (String) -> Void = { _ in }
    var focusChanged: (Bool) -> Void = { _ in }
    var selectionChanged: (NSRange) -> Void = { _ in }
    private static let commandAttribute = NSAttributedString.Key("HarnessSelectedCommand")
    private var applying = false
    private var style: ComposerEditorStyle?

    var lineHeight: CGFloat {
        let font = style?.font ?? view?.font ?? UIFont.preferredFont(forTextStyle: .body)
        return font.pointSize * CommandPill.lineHeightMultiple
    }
    var attachmentDraft: AttachmentDraft?

    // UITextView owns a native drop interaction which wins over SwiftUI's
    // session-wide target. Route images to attachments, never into text storage.
    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                           proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        let providers = drop.dropSession.items.map(\.itemProvider)
        guard providers.contains(where: AttachmentDraft.supports), let attachmentDraft else {
            return drop.suggestedProposal
        }
        let proposal = UITextDropProposal(operation: attachmentDraft.canImport ? .copy : .cancel)
        proposal.dropPerformer = .delegate
        proposal.dropProgressMode = .custom
        return proposal
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                           willPerformDrop drop: UITextDropRequest) {
        let providers = drop.dropSession.items.map(\.itemProvider)
        guard providers.contains(where: AttachmentDraft.supports) else { return }
        attachmentDraft?.targeted = false
        attachmentDraft?.receive(providers)
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                           dropSessionDidUpdate session: UIDropSession) {
        attachmentDraft?.targeted = session.items.contains { AttachmentDraft.supports($0.itemProvider) }
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                           dropSessionDidExit session: UIDropSession) {
        attachmentDraft?.targeted = false
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                           dropSessionDidEnd session: UIDropSession) {
        attachmentDraft?.targeted = false
    }


    func commit() {
        guard let view else { return }
        applying = true
        view.unmarkText()
        applying = false
        textChanged(serializedText)
    }

    /// The binding, draft store and queue retain canonical selection metadata;
    /// UIKit only displays the readable command label.
    var serializedText: String {
        guard let view else { return "" }
        let result = NSMutableString(string: view.text ?? "")
        var replacements: [(NSRange, String)] = []
        view.attributedText.enumerateAttribute(Self.commandAttribute,
            in: NSRange(location: 0, length: view.attributedText.length)) { value, range, _ in
                guard let link = value as? String,
                      CommandPill.label(link) == (view.text as NSString).substring(with: range) else { return }
                replacements.append((range, link))
            }
        for (range, link) in replacements.reversed() { result.replaceCharacters(in: range, with: link) }
        return result as String
    }

    var commandQuery: ComposerCommandQuery? {
        guard let view, view.markedTextRange == nil else { return nil }
        let caret = view.selectedRange.location
        if caret > 0, caret <= view.attributedText.length,
           view.attributedText.attribute(Self.commandAttribute, at: caret - 1, effectiveRange: nil) != nil {
            return nil
        }
        return ComposerCommandText.query(in: view.text ?? "", selection: view.selectedRange)
    }

    private var paragraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }

    private func plainAttributes(_ view: UITextView) -> [NSAttributedString.Key: Any] {
        let font = style?.font ?? view.font ?? UIFont.preferredFont(forTextStyle: .body)
        // TextKit adds a fixed paragraph's extra leading above its baseline.
        // Lift the glyphs by half that leading to match GPUI's centered line box.
        return [.font: font,
                .foregroundColor: style?.text ?? UIColor(Theme.text),
                .paragraphStyle: paragraphStyle,
                .baselineOffset: max(0, (lineHeight - font.lineHeight) / 2)]
    }

    private func commandAttributes(_ view: UITextView) -> [NSAttributedString.Key: Any] {
        let size = (style?.font ?? view.font ?? UIFont.preferredFont(forTextStyle: .body)).pointSize
        let font = Theme.monoUI(size)
        return [.font: font,
                .foregroundColor: style?.commandText ?? UIColor(Theme.inlineCodeText),
                commandWashAttribute: style?.commandWash ?? UIColor(Theme.inlineCodeWash),
                .paragraphStyle: paragraphStyle,
                .baselineOffset: max(0, (lineHeight - font.lineHeight) / 2)]
    }

    func updateStyle(font: UIFont) {
        let next = ComposerEditorStyle(font: font, text: UIColor(Theme.text),
                                       commandText: UIColor(Theme.inlineCodeText), commandWash: UIColor(Theme.inlineCodeWash))
        guard let view, style != next else { return }
        style = next
        applying = true
        let storage = view.textStorage
        storage.beginEditing()
        storage.addAttributes(plainAttributes(view), range: NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(Self.commandAttribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { storage.addAttributes(commandAttributes(view), range: range) }
        }
        storage.endEditing()
        view.typingAttributes = plainAttributes(view)
        view.invalidateIntrinsicContentSize()
        view.setNeedsDisplay()
        applying = false
    }

    private func attributed(_ text: String, in view: UITextView) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: plainAttributes(view))
        for token in ComposerCommandText.links(in: text).reversed() {
            guard let link = token.reference.link else { continue }
            var attributes = commandAttributes(view)
            attributes[Self.commandAttribute] = link
            result.replaceCharacters(in: token.range, with: NSAttributedString(
                string: CommandPill.label(link), attributes: attributes))
        }
        return result
    }

    func apply(text: String) {
        guard let view, serializedText != text else { return }
        applying = true
        view.unmarkText()
        view.attributedText = attributed(text, in: view)
        view.selectedRange = NSRange(location: view.attributedText.length, length: 0)
        view.typingAttributes = plainAttributes(view)
        if text.isEmpty { view.undoManager?.removeAllActions() }
        view.invalidateIntrinsicContentSize()
        applying = false
    }

    func removeCommandQuery(named name: String) {
        guard let view, let query = commandQuery else { return }
        let range = ComposerCommandText.replacementRange(in: view.text, query: query, name: name)
        applying = true
        view.textStorage.deleteCharacters(in: range)
        view.selectedRange = NSRange(location: range.location, length: 0)
        view.typingAttributes = plainAttributes(view)
        applying = false
        selectionChanged(view.selectedRange)
        textChanged(serializedText)
        view.invalidateIntrinsicContentSize()
    }

    func selectCommand(_ command: ComposerCommand, richReferences: Bool) {
        guard let view, let query = commandQuery,
              let link = ComposerCommandReference(name: command.name).link else { return }
        let range = ComposerCommandText.replacementRange(in: view.text, query: query, name: command.name)
        let suffix = (view.text as NSString).substring(from: NSMaxRange(range))
        let separator = suffix.first?.isWhitespace == true ? "" : " "
        let insertion = richReferences ? attributed(link + separator, in: view)
            : NSAttributedString(string: "/\(command.name)" + separator, attributes: plainAttributes(view))
        applying = true
        view.textStorage.replaceCharacters(in: range, with: insertion)
        let existingSpace = suffix.hasPrefix(" ") ? 1 : 0
        view.selectedRange = NSRange(location: range.location + insertion.length + existingSpace, length: 0)
        view.typingAttributes = plainAttributes(view)
        applying = false
        selectionChanged(view.selectedRange)
        textChanged(serializedText)
        view.invalidateIntrinsicContentSize()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !applying else { return }
        // Editing a selected label makes it ordinary text rather than silently
        // invoking the old command. Never extend a selection into arguments.
        var invalid: [NSRange] = []
        textView.attributedText.enumerateAttribute(Self.commandAttribute,
            in: NSRange(location: 0, length: textView.attributedText.length)) { value, range, _ in
                if let link = value as? String,
                   CommandPill.label(link) != (textView.text as NSString).substring(with: range) {
                    invalid.append(range)
                }
            }
        // Once a label is edited it is ordinary text. Remove its display-only
        // side spaces too, so they cannot leak into the resulting prompt.
        if !invalid.isEmpty {
            applying = true
            var selection = textView.selectedRange
            for range in invalid.reversed() {
                let label = (textView.text as NSString).substring(with: range)
                textView.textStorage.setAttributes(plainAttributes(textView), range: range)
                var pads: [Int] = []
                if label.hasPrefix(CommandPill.sidePad) { pads.append(range.location) }
                if label.hasSuffix(CommandPill.sidePad), range.length > 1 { pads.append(NSMaxRange(range) - 1) }
                for position in pads.sorted(by: >) {
                    textView.textStorage.deleteCharacters(in: NSRange(location: position, length: 1))
                    let start = selection.location - (selection.location > position ? 1 : 0)
                    let end = NSMaxRange(selection) - (NSMaxRange(selection) > position ? 1 : 0)
                    selection = NSRange(location: start, length: end - start)
                }
            }
            textView.selectedRange = selection
            applying = false
        }
        textView.typingAttributes = plainAttributes(textView)
        selectionChanged(textView.selectedRange)
        textChanged(serializedText)
        textView.invalidateIntrinsicContentSize()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !applying else { return }
        textView.typingAttributes = plainAttributes(textView)
        selectionChanged(textView.selectedRange)
    }

    func textViewDidBeginEditing(_ textView: UITextView) { focusChanged(true) }
    func textViewDidEndEditing(_ textView: UITextView) { focusChanged(false) }
}

final class ComposerTextView: UITextView {
    var modifiedSubmit: () -> Void = {}
    var completeCommand: (() -> Void)?
    var moveCommand: ((Int) -> Void)?
    /// Pasted images go here instead of being dropped (a UITextView only
    /// pastes text); nil while attachments aren't allowed.
    var pasteImages: (([Data]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), pasteImages != nil, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if let pasteImages, pasteboard.hasImages {
            let images = Self.imageData(from: pasteboard)
            if !images.isEmpty { pasteImages(images) }
            // Text copied alongside the image (a web page selection) still
            // lands in the box.
            if pasteboard.hasStrings { super.paste(sender) }
            return
        }
        super.paste(sender)
    }

    /// The original bytes of each copied image when a concrete format is on
    /// the pasteboard (screenshots are PNG, Photos copies JPEG/HEIC), else
    /// the decoded image re-encoded as PNG.
    static func imageData(from pasteboard: UIPasteboard) -> [Data] {
        let formats: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif]
        var images: [Data] = []
        for index in 0..<pasteboard.numberOfItems {
            let item = IndexSet(integer: index)
            let types = pasteboard.types(forItemSet: item)?.first ?? []
            guard let format = formats.first(where: { types.contains($0.identifier) }),
                  let data = pasteboard.data(forPasteboardType: format.identifier,
                                             inItemSet: item)?.first else { continue }
            images.append(data)
        }
        if images.isEmpty {
            images = (pasteboard.images ?? []).compactMap { $0.pngData() }
        }
        return images
    }
    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: "\r", modifierFlags: .command,
                                   action: #selector(submitFromKeyboard))
        command.discoverabilityTitle = "Send message or advance queue"
        command.wantsPriorityOverSystemBehavior = true
        var commands = (super.keyCommands ?? []) + [command]
        if completeCommand != nil {
            for (input, action) in [("\t", #selector(acceptCommand)),
                                    (UIKeyCommand.inputUpArrow, #selector(previousCommand)),
                                    (UIKeyCommand.inputDownArrow, #selector(nextCommand))] {
                let key = UIKeyCommand(input: input, modifierFlags: [], action: action)
                key.wantsPriorityOverSystemBehavior = true
                commands.append(key)
            }
        }
        return commands
    }
    @objc func submitFromKeyboard() { modifiedSubmit() }
    @objc func acceptCommand() { completeCommand?() }
    @objc func previousCommand() { moveCommand?(-1) }
    @objc func nextCommand() { moveCommand?(1) }
}

struct ComposerEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let maxLines: Int
    let controller: ComposerEditorController
    var attachmentDraft: AttachmentDraft? = nil
    var onModifiedSubmit: () -> Void = {}
    var onPasteImages: (([Data]) -> Void)? = nil
    var onSelectionChange: (NSRange) -> Void = { _ in }
    var onCompleteCommand: (() -> Void)? = nil
    var onMoveCommand: ((Int) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let layout = ComposerCommandLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = ComposerTextView(frame: .zero, textContainer: container)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        view.keyboardAppearance = .default
        view.accessibilityIdentifier = "composer-input"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = controller
        view.textDropDelegate = controller
        controller.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        (view as? ComposerTextView)?.modifiedSubmit = onModifiedSubmit
        (view as? ComposerTextView)?.pasteImages = onPasteImages
        (view as? ComposerTextView)?.completeCommand = onCompleteCommand
        (view as? ComposerTextView)?.moveCommand = onMoveCommand
        controller.selectionChanged = onSelectionChange
        controller.attachmentDraft = attachmentDraft
        controller.textChanged = { if text != $0 { text = $0 } }
        controller.focusChanged = { if focused != $0 { focused = $0 } }
        controller.updateStyle(font: UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(name: "Geist-Regular", size: 17) ?? .systemFont(ofSize: 17),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.uiCategory)))
        view.tintColor = UIColor(Theme.text)
        view.accessibilityLabel = placeholder
        controller.apply(text: text)
        if focused, !view.isFirstResponder { view.becomeFirstResponder() }
        else if !focused, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let line = controller.lineHeight
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(min(max(line, height), line * CGFloat(maxLines))))
    }
}

private extension DynamicTypeSize {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
