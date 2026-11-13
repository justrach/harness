// Write: the composer's draft on a full-height page, for messages long enough
// to want room. It edits the same text the composer holds (so the draft store
// keeps it), styles markdown as it is typed without hiding any of it, and
// sends through the composer's own send path.

import PhotosUI
import SwiftUI
import UIKit

// MARK: - The styler (pure)

/// How one stretch of the draft is drawn on the Write page.
enum WriteStyle: Equatable {
    /// A `#`, `##` or `###` line (deeper levels draw as 3).
    case heading(Int)
    /// A `- `, `* ` or `1. ` line. `indent` is the UTF-16 length of everything
    /// up to the item's text, which wrapped lines hang under.
    case listItem(indent: Int)
    case quote
    /// A line inside a ``` fence.
    case codeBlock
    case bold
    case italic
    case code
    /// Markdown syntax itself (`#`, `**`, `` ` ``, `- `, `> `): drawn faint, never hidden.
    case marker
}

struct WriteSpan: Equatable {
    let range: NSRange
    let style: WriteStyle
}

enum WriteMarkdown {
    /// The styled stretches of `text`, in UTF-16 ranges: line styles first,
    /// then inline styles, then markers, which is the order they are drawn in.
    static func spans(_ text: String) -> [WriteSpan] {
        let ns = text as NSString
        var lines: [WriteSpan] = []
        var inline: [WriteSpan] = []
        var markers: [WriteSpan] = []
        var inFence = false
        var start = 0
        while start < ns.length {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: start, length: 0))
            let line = NSRange(location: start, length: contentsEnd - start)
            start = lineEnd
            if let fence = fenceRe.firstMatch(in: text, range: line) {
                inFence.toggle()
                markers.append(WriteSpan(range: fence.range, style: .marker))
                continue
            }
            if inFence {
                if line.length > 0 { lines.append(WriteSpan(range: line, style: .codeBlock)) }
                continue
            }
            var rest = line
            if let m = headingRe.firstMatch(in: text, range: line) {
                let level = min(m.range(at: 1).length, 3)
                lines.append(WriteSpan(range: line, style: .heading(level)))
                markers.append(WriteSpan(range: m.range, style: .marker))
                rest = after(m.range, in: line)
            } else if let m = quoteRe.firstMatch(in: text, range: line) {
                lines.append(WriteSpan(range: line, style: .quote))
                markers.append(WriteSpan(range: m.range, style: .marker))
                rest = after(m.range, in: line)
            } else if let m = listRe.firstMatch(in: text, range: line) {
                lines.append(WriteSpan(range: line, style: .listItem(indent: m.range.length)))
                markers.append(WriteSpan(range: m.range(at: 2), style: .marker))
                rest = after(m.range, in: line)
            }
            styleInline(text, in: rest, styles: &inline, markers: &markers)
        }
        return lines + inline + markers
    }

    /// Words a reader would count: runs between spaces holding a letter or a
    /// digit, so bare markers (`#`, `-`, `**`) don't add to it.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    static func wordCountLabel(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count) words"
    }

    private static func styleInline(_ text: String, in range: NSRange,
                                    styles: inout [WriteSpan], markers: inout [WriteSpan]) {
        guard range.length > 0 else { return }
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        // Code first: nothing inside backticks is bold or italic.
        for (re, style, width) in [(codeRe, WriteStyle.code, 1), (boldRe, .bold, 2), (italicRe, .italic, 1)] {
            for m in re.matches(in: text, range: range) where free(m.range) {
                taken.append(m.range)
                styles.append(WriteSpan(range: NSRange(location: m.range.location + width,
                                                       length: m.range.length - 2 * width), style: style))
                markers.append(WriteSpan(range: NSRange(location: m.range.location, length: width), style: .marker))
                markers.append(WriteSpan(range: NSRange(location: NSMaxRange(m.range) - width, length: width),
                                         style: .marker))
            }
        }
    }

    private static func after(_ prefix: NSRange, in line: NSRange) -> NSRange {
        NSRange(location: NSMaxRange(prefix), length: NSMaxRange(line) - NSMaxRange(prefix))
    }

    private static let fenceRe = regex("^[ \\t]{0,3}(```|~~~).*$")
    private static let headingRe = regex("^(#{1,6})[ \\t]+")
    private static let quoteRe = regex("^[ \\t]{0,3}>[ \\t]?")
    private static let listRe = regex("^([ \\t]*)([-*+]|\\d{1,9}[.)])[ \\t]+")
    private static let codeRe = regex("`[^`]+`")
    private static let boldRe = regex("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    private static let italicRe = regex("(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

// MARK: - Drawing the spans

/// The page's typeface: New York by default, Geist from the Aa toggle.
struct WriteTypeface: Equatable {
    var serif: Bool
    var size: CGFloat

    /// A little larger than the transcript's headings (`MD`), for a page.
    func headingSize(_ level: Int) -> CGFloat {
        MD.headingMetrics(level).size * size / MD.textSize * 1.12
    }

    func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        guard serif else {
            let sans = Theme.sansUI(size, weight: bold ? .semibold : .regular)
            guard italic else { return sans }
            // Geist has no italic cut: lean the upright one.
            let lean = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            return UIFont(descriptor: UIFontDescriptor(name: sans.fontName, matrix: lean), size: size)
        }
        let system = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        var descriptor = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
        if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = slanted
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    func paragraph(for font: UIFont, headIndent: CGFloat = 0, before: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // About 1.6× the type size from one baseline to the next.
        style.lineSpacing = max(0, font.pointSize * 1.6 - font.lineHeight)
        style.paragraphSpacing = size * 0.2
        style.paragraphSpacingBefore = before
        style.headIndent = headIndent
        return style
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        let body = font(size)
        return [.font: body, .foregroundColor: UIColor(Theme.text), .paragraphStyle: paragraph(for: body)]
    }
}

@MainActor
enum WriteStyler {
    /// Restyle the whole storage from its text. Only attributes change, so the
    /// characters, and with them the caret and selection, stay where they are.
    static func apply(_ storage: NSTextStorage, face: WriteTypeface) {
        let text = storage.string
        storage.beginEditing()
        storage.setAttributes(face.bodyAttributes, range: NSRange(location: 0, length: storage.length))
        for span in WriteMarkdown.spans(text) where NSMaxRange(span.range) <= storage.length {
            draw(span, in: storage, face: face)
        }
        storage.endEditing()
    }

    private static func draw(_ span: WriteSpan, in storage: NSTextStorage, face: WriteTypeface) {
        let range = span.range
        switch span.style {
        case .heading(let level):
            let font = face.font(face.headingSize(level), bold: true)
            storage.addAttributes([.font: font,
                                   .paragraphStyle: face.paragraph(for: font, before: face.size * 0.2)],
                                  range: range)
        case .listItem(let indent):
            let body = face.font(face.size)
            let prefix = (storage.string as NSString).substring(with: NSRange(location: range.location,
                                                                              length: indent))
            let hang = ceil((prefix as NSString).size(withAttributes: [.font: body]).width)
            storage.addAttribute(.paragraphStyle, value: face.paragraph(for: body, headIndent: hang), range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: UIColor(Theme.textMuted), range: range)
            slant(range, in: storage, face: face)
        case .codeBlock:
            storage.addAttributes([.font: Theme.monoUI(face.size * 0.8),
                                   .foregroundColor: UIColor(Theme.inlineCodeText),
                                   .backgroundColor: UIColor(Theme.inlineCodeWash)], range: range)
        case .bold:
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                guard let font = value as? UIFont, !isMono(font) else { return }
                storage.addAttribute(.font, value: face.font(font.pointSize, bold: true, italic: isItalic(font)),
                                     range: run)
            }
        case .italic:
            slant(range, in: storage, face: face)
        case .code:
            storage.addAttributes([.font: Theme.monoUI(face.size * 0.86),
                                   .foregroundColor: UIColor(Theme.inlineCodeText),
                                   .backgroundColor: UIColor(Theme.inlineCodeWash)], range: range)
        case .marker:
            storage.addAttribute(.foregroundColor, value: UIColor(Theme.textFaint), range: range)
        }
    }

    private static func slant(_ range: NSRange, in storage: NSTextStorage, face: WriteTypeface) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? UIFont, !isMono(font) else { return }
            storage.addAttribute(.font, value: face.font(font.pointSize, bold: isBold(font), italic: true), range: run)
        }
    }

    private static func isBold(_ font: UIFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.traitBold) || font.fontName.contains("Bold")
    }

    private static func isItalic(_ font: UIFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.traitItalic) || CTFontGetMatrix(font as CTFont).c != 0
    }

    private static func isMono(_ font: UIFont) -> Bool {
        font.fontName.contains("Mono")
    }
}

// MARK: - The editor

/// A UITextView styled through its text storage. Unlike `ComposerEditor`, an
/// update never resets the text or the caret unless the text really changed
/// underneath it (the composer cleared it, say).
struct WriteEditor: UIViewRepresentable {
    @Binding var text: String
    var face: WriteTypeface
    var onPasteImages: (([Data]) -> Void)?
    var autoFocus = true
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 28, bottom: 40, right: 28)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "write-input"
        view.delegate = context.coordinator
        view.text = text
        context.coordinator.restyle(view)
        if autoFocus {
            DispatchQueue.main.async {
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
            }
        }
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.pasteImages = onPasteImages
        view.tintColor = UIColor(Theme.accent)
        let key = "\(face.serif)|\(face.size)|\(colorScheme)"
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            coordinator.restyle(view)
        } else if coordinator.styledKey != key {
            coordinator.restyle(view)
        }
        coordinator.styledKey = key
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WriteEditor
        var styledKey = ""

        init(_ parent: WriteEditor) { self.parent = parent }

        func restyle(_ view: UITextView) {
            // Mid-composition (marked text from a CJK keyboard), restyling
            // would break the composition; the next change catches up.
            guard view.markedTextRange == nil else { return }
            let selection = view.selectedRange
            WriteStyler.apply(view.textStorage, face: parent.face)
            if view.selectedRange != selection { view.selectedRange = selection }
            view.typingAttributes = parent.face.bodyAttributes
        }

        func textViewDidChange(_ textView: UITextView) {
            restyle(textView)
            if parent.text != textView.text { parent.text = textView.text }
        }
    }
}

// MARK: - The sheet

struct WriteSheet<Chips: View>: View {
    @Binding var text: String
    @Bindable var attachmentDraft: AttachmentDraft
    var sendLabel = "Send message"
    var busy = false
    var onSend: () -> Void
    var onPasteImages: (([Data]) -> Void)?
    @Binding var pickerItems: [PhotosPickerItem]
    @ViewBuilder var chips: Chips

    @Environment(\.dismiss) private var dismiss
    @AppStorage("write.serif") private var serif = true
    @State private var showPicker = false
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18.5

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentDraft.items.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            WriteEditor(text: $text, face: WriteTypeface(serif: serif, size: bodySize),
                        onPasteImages: onPasteImages)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            dock
        }
        .background(Theme.sessionPage(lifted: true).ignoresSafeArea())
        .themedPhotosPicker(isPresented: $showPicker, selection: $pickerItems)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
    }

    private var topBar: some View {
        ZStack {
            Text(WriteMarkdown.wordCountLabel(WriteMarkdown.wordCount(text)))
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textFaint)
                .monospacedDigit()
                .accessibilityIdentifier("write-words")
            HStack {
                Button("Done") { dismiss() }
                    .font(Theme.sans(16, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("write-done")
                Spacer()
                Button {
                    serif.toggle()
                } label: {
                    Text("Aa")
                        .font(serif ? .system(size: 17, design: .serif) : Theme.sans(16, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(serif ? "Use sans-serif type" : "Use serif type")
                .accessibilityIdentifier("write-font")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var dock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachmentDraft.items.isEmpty {
                AttachmentStripView(attachments: attachmentDraft.items) { id in
                    attachmentDraft.items.removeAll { $0.id == id }
                }
            }
            HStack(spacing: 8) {
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Attach photos")
                .accessibilityIdentifier("write-attach")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { chips }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                sendButton
            }
        }
        .padding(8)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 704)
    }

    private var sendButton: some View {
        let enabled = hasContent && !busy
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSend()
            dismiss()
        } label: {
            HStack(spacing: 5) {
                Text("Send")
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
            }
            .font(Theme.sans(15, weight: .semibold))
            .foregroundStyle(enabled ? Theme.onAccent : Theme.textFaint)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(ink(0.10)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(sendLabel)
        .accessibilityIdentifier("write-send")
    }
}
