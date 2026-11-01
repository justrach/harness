// UIKit owns word selection, drag handles, and the edit menu. SwiftUI Text's
// iOS selection selects a whole view rather than a word/range in the output.
import SwiftUI
import UIKit

struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString
    var wraps = true
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let layout = InlineCodeLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = UITextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        view.tintColor = UIColor(Theme.accent)
        // Links keep their explicit monochrome foreground and underline.
        view.linkTextAttributes = [:]
        Self.update(text, in: view)
    }

    /// Paint-only veil/highlight updates and streamed appends must not clear a
    /// selection. Avoid assigning even equal strings: UIKit resets its edit UI.
    static func update(_ text: NSAttributedString, in view: UITextView) {
        guard !view.attributedText.isEqual(to: text) else { return }
        let selection = view.selectedRange
        let previous = view.text ?? ""
        view.attributedText = text
        if text.string.hasPrefix(previous), NSMaxRange(selection) <= text.length {
            view.selectedRange = selection
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let natural = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = wraps ? (proposal.width ?? ceil(natural.width)) : ceil(natural.width)
        let size = uiView.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        return CGSize(width: max(1, width), height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL(url) }
        }
    }
}

/// Preserve the rounded inline-code wash without changing glyph geometry.
/// Native selection backgrounds still use UIKit's unmodified drawing path.
private final class InlineCodeLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int,
                                         forCharacterRange charRange: NSRange, color: UIColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let wash = storage.attribute(.backgroundColor, at: charRange.location,
                                           effectiveRange: nil) as? UIColor,
              wash.isEqual(color) else {
            super.fillBackgroundRectArray(rectArray, count: rectCount,
                                          forCharacterRange: charRange, color: color)
            return
        }
        for index in 0..<rectCount {
            UIBezierPath(roundedRect: rectArray[index].insetBy(dx: -2, dy: 2),
                         cornerRadius: MD.inlineCodeRadius).fill()
        }
    }
}

struct SelectableMarkdownText: View {
    let runs: [InlineRun]
    var size: CGFloat = MD.textSize
    var weight: UIFont.Weight = .regular
    var lineHeight: CGFloat = MD.lineHeight
    var veil: RowVeil? = nil
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        SelectableText(text: runs.selectableAttributed(size: size * scale, weight: weight,
                                                       lineHeight: lineHeight * scale, veil: veil))
    }
}

extension [InlineRun] {
    /// A single text storage per block lets a selection cross style/link runs
    /// and soft wraps without copying markdown syntax. Ranges are UTF-16 for
    /// TextKit; veil offsets remain Swift Character offsets.
    func selectableAttributed(size: CGFloat = MD.textSize, weight: UIFont.Weight = .regular,
                              lineHeight: CGFloat = MD.lineHeight, veil: RowVeil? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        for run in self {
            var font = run.style.code ? Theme.monoUI(size - 1.5)
                : Theme.sansUI(size, weight: run.style.bold ? .semibold : weight)
            if run.style.italic, let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph,
                .foregroundColor: UIColor(run.style.code ? Theme.inlineCodeText : Theme.text),
            ]
            if run.style.code { attributes[.backgroundColor] = UIColor(Theme.inlineCodeWash) }
            if run.style.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = UIColor(Theme.textMuted)
            }
            if let link = run.style.link,
               let url = URL(string: link) ?? link.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    .flatMap({ URL(string: $0) }) {
                attributes[.link] = url
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = UIColor(Theme.textMuted)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        if let veil {
            let string = result.string
            for segment in veil.segments(totalLength: string.count) where segment.alpha < 1 {
                let lower = string.index(string.startIndex, offsetBy: segment.range.lowerBound)
                let upper = string.index(string.startIndex, offsetBy: segment.range.upperBound)
                let range = NSRange(lower..<upper, in: string)
                result.enumerateAttribute(.foregroundColor, in: range) { value, range, _ in
                    guard let color = value as? UIColor else { return }
                    result.addAttribute(.foregroundColor,
                        value: color.withAlphaComponent(color.cgColor.alpha * segment.alpha), range: range)
                }
            }
        }
        return result
    }
}
