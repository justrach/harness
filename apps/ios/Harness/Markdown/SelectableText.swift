// UIKit owns word selection, drag handles, and the edit menu. SwiftUI Text's
// iOS selection selects a whole view rather than a word/range in the output.
import SwiftUI
import UIKit

struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString
    var wraps = true
    var lineHeight: CGFloat = MD.lineHeight
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let layout = InlineCodeLayoutManager()
        layout.extraLineHeight = lineHeight
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = OutputTextView(frame: .zero, textContainer: container)
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
        context.coordinator.update(text, lineHeight: lineHeight, in: view)
    }

    /// Paint-only veil/highlight updates and streamed appends must not clear a
    /// selection. Avoid assigning even equal strings: UIKit resets its edit UI.
    @discardableResult
    static func update(_ text: NSAttributedString, in view: UITextView) -> Bool {
        guard !view.attributedText.isEqual(to: text) else { return false }
        let selection = retainedSelection(view.selectedRange, from: view.text ?? "", to: text.string)
        view.attributedText = text
        view.selectedRange = selection
        return true
    }

    /// TextKit offsets are UTF-16, whereas String.hasPrefix compares canonical
    /// Characters. Only literal appends can reuse offsets, and appending a
    /// combining mark/ZWJ must not leave a selection inside the new grapheme.
    static func retainedSelection(_ selection: NSRange, from previous: String, to text: String) -> NSRange {
        let count = previous.utf16.count
        let cleared = NSRange(location: 0, length: 0)
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= count, selection.length <= count - selection.location,
              previous.utf16.elementsEqual(text.utf16.prefix(previous.utf16.count)),
              let range = Range(selection, in: text),
              range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound),
              range.upperBound == text.endIndex || text.indices.contains(range.upperBound) else { return cleared }
        return selection
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        context.coordinator.sizeThatFits(proposal, text: text, wraps: wraps, view: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction
        private var naturalWidth: CGFloat?
        private var measurements: [CGFloat: CGSize] = [:]
        init(openURL: OpenURLAction) { self.openURL = openURL }

        func update(_ text: NSAttributedString, lineHeight: CGFloat, in view: UITextView) {
            var metricsChanged = false
            if let layout = view.layoutManager as? InlineCodeLayoutManager, layout.extraLineHeight != lineHeight {
                layout.extraLineHeight = lineHeight
                layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: view.textStorage.length),
                                        actualCharacterRange: nil)
                metricsChanged = true
            }
            if SelectableText.update(text, in: view) || metricsChanged {
                naturalWidth = nil
                measurements.removeAll(keepingCapacity: true)
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, text: NSAttributedString,
                          wraps: Bool, view: UITextView) -> CGSize {
            let proposedWidth: CGFloat
            if wraps, let width = proposal.width {
                proposedWidth = width
            } else if let cached = naturalWidth {
                proposedWidth = cached
            } else {
                let measured = ceil(text.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width)
                naturalWidth = measured
                proposedWidth = measured
            }
            let width = max(1, proposedWidth)
            if let size = measurements[width] { return size }
            // UITextView.sizeThatFits temporarily changes its live text container,
            // invalidating TextKit layout. Nested SwiftUI stacks ask for the same
            // widths many times per frame; never repeat that work for a proposal.
            let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let size = CGSize(width: width, height: ceil(fitted.height))
            // Bound resize/animation proposals without retaining transcript text.
            if measurements.count == 16 { measurements.removeAll(keepingCapacity: true) }
            measurements[width] = size
            return size
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL(url) }
        }
    }
}

private final class OutputTextView: UITextView {
    override func resignFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        let resigned = super.resignFirstResponder()
        // UIKit retains an invisible range on blur. A later long-press inside
        // it tries to manipulate that inactive selection instead of selecting
        // a new word, so no Copy menu appears while the composer owns focus.
        if wasFirstResponder && resigned { selectedRange = NSRange(location: 0, length: 0) }
        return resigned
    }
}

/// Preserve the rounded inline-code wash without changing glyph geometry.
/// Native selection backgrounds still use UIKit's unmodified drawing path.
private final class InlineCodeLayoutManager: NSLayoutManager {
    var extraLineHeight: CGFloat = MD.lineHeight

    // TextKit otherwise uses its unstyled default font for the final empty
    // line, even when preceding code lines have scaled paragraph metrics.
    override func setExtraLineFragmentRect(_ fragmentRect: CGRect, usedRect: CGRect,
                                          textContainer: NSTextContainer) {
        var fragment = fragmentRect
        var used = usedRect
        fragment.size.height = max(fragment.height, extraLineHeight)
        used.size.height = max(used.height, extraLineHeight)
        super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: textContainer)
    }

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
    var alignment: NSTextAlignment = .natural
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        SelectableText(text: runs.selectableAttributed(size: size * scale, weight: weight,
                                                       lineHeight: lineHeight * scale, veil: veil,
                                                       alignment: alignment), lineHeight: lineHeight * scale)
    }
}

extension [InlineRun] {
    /// A single text storage per block lets a selection cross style/link runs
    /// and soft wraps without copying markdown syntax. Ranges are UTF-16 for
    /// TextKit; veil offsets remain Swift Character offsets.
    func selectableAttributed(size: CGFloat = MD.textSize, weight: UIFont.Weight = .regular,
                              lineHeight: CGFloat = MD.lineHeight, veil: RowVeil? = nil,
                              alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.alignment = alignment
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
