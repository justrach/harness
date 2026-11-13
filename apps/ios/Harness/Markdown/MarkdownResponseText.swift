// One text storage per response: UIKit selection can cross paragraphs, lists,
// headings and code without replacing the transcript with one giant editor.
import SwiftUI
import UIKit

extension NSAttributedString.Key {
    static let responseCodeBlock = NSAttributedString.Key("HarnessResponseCodeBlock")
    static let responseQuote = NSAttributedString.Key("HarnessResponseQuote")
    static let responseRule = NSAttributedString.Key("HarnessResponseRule")
}

struct MarkdownResponseText: View {
    let blocks: [MDBlock]
    var veil: RowVeil? = nil
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @State private var highlights: [String: [[TokenSpan]]] = [:]

    var body: some View {
        let text = Self.attributed(blocks, scale: scale, highlights: highlights)
        SelectableText(text: Self.veiled(text, veil: veil), lineHeight: MD.lineHeight * scale)
            .task(id: blocks) {
                let sources = Self.codeSources(blocks)
                let colors = await Task.detached(priority: .utility) {
                    var result: [String: [[TokenSpan]]] = [:]
                    for (key, language, source) in sources {
                        result[key] = Highlighter.highlight(code: source, language: language)
                    }
                    return result
                }.value
                guard !Task.isCancelled else { return }
                highlights = colors
            }
    }

    static func attributed(_ blocks: [MDBlock], scale: CGFloat = 1,
                           highlights: [String: [[TokenSpan]]] = [:]) -> NSAttributedString {
        let builder = Builder(scale: scale, highlights: highlights)
        builder.append(blocks)
        return builder.text
    }

    private static func codeSources(_ blocks: [MDBlock]) -> [(String, HighlightLanguage, String)] {
        blocks.flatMap { block -> [(String, HighlightLanguage, String)] in
            switch block {
            case .codeBlock(let language, let code):
                guard let lang = HighlightLanguage.forTag(language) else { return [] }
                return [("\(language ?? "")\0\(code)", lang, code)]
            case .response(let children), .blockquote(let children): return codeSources(children)
            case .list(_, let items): return items.flatMap { codeSources($0.children) }
            default: return []
            }
        }
    }

    private static func veiled(_ text: NSAttributedString, veil: RowVeil?) -> NSAttributedString {
        guard let veil, veil.isFading else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let string = text.string
        for segment in veil.segments(totalLength: string.count) where segment.alpha < 1 {
            let lower = string.index(string.startIndex, offsetBy: segment.range.lowerBound)
            let upper = string.index(string.startIndex, offsetBy: segment.range.upperBound)
            result.enumerateAttribute(.foregroundColor, in: NSRange(lower..<upper, in: string)) { value, range, _ in
                guard let color = value as? UIColor else { return }
                result.addAttribute(.foregroundColor,
                    value: color.withAlphaComponent(color.cgColor.alpha * segment.alpha), range: range)
            }
        }
        return result
    }

    private final class Builder {
        let scale: CGFloat
        let highlights: [String: [[TokenSpan]]]
        let text = NSMutableAttributedString(string: "")

        init(scale: CGFloat, highlights: [String: [[TokenSpan]]]) {
            self.scale = scale
            self.highlights = highlights
        }

        func separator(_ gap: Bool) {
            guard text.length > 0 else { return }
            let attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
            text.append(NSAttributedString(string: "\n", attributes: attributes))
            if gap {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = MD.blockGap * scale
                paragraph.maximumLineHeight = MD.blockGap * scale
                text.append(NSAttributedString(string: "\n", attributes: [
                    .font: Theme.sansUI(1), .paragraphStyle: paragraph,
                ]))
            }
        }

        func append(_ blocks: [MDBlock], indent: CGFloat = 0, quote: Bool = false, gap: Bool = true) {
            for (index, block) in blocks.enumerated() {
                if index > 0 { separator(gap) }
                append(block, indent: indent, quote: quote)
            }
        }

        func prose(_ runs: [InlineRun], size: CGFloat = MD.textSize, weight: UIFont.Weight = .regular,
                   line: CGFloat = MD.lineHeight, indent: CGFloat, quote: Bool,
                   prefix: String = "", hanging: CGFloat = 0) {
            let value = NSMutableAttributedString(attributedString:
                ([InlineRun(text: prefix, style: .plain)] + runs).selectableAttributed(
                    size: size * scale, weight: weight, lineHeight: line * scale))
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = line * scale
            paragraph.firstLineHeadIndent = indent * scale
            paragraph.headIndent = (indent + hanging) * scale
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: (indent + hanging) * scale)]
            value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
            if quote {
                value.addAttributes([.foregroundColor: UIColor(Theme.textMuted), .responseQuote: true],
                                    range: NSRange(location: 0, length: value.length))
            }
            text.append(value)
        }

        func append(_ block: MDBlock, indent: CGFloat, quote: Bool) {
            switch block {
            case .response(let children): append(children, indent: indent, quote: quote)
            case .paragraph(let runs): prose(runs, indent: indent, quote: quote)
            case .heading(let level, let runs):
                let metrics = MD.headingMetrics(level)
                prose(runs, size: metrics.size, weight: .semibold, line: metrics.line, indent: indent, quote: quote)
            case .blockquote(let children): append(children, indent: indent + 14, quote: true)
            case .list(let start, let items):
                for (index, item) in items.enumerated() {
                    if index > 0 { separator(false) }
                    let marker: String
                    if let checked = item.checked { marker = checked ? "☑" : "☐" }
                    else if let start { marker = "\(start + index)." }
                    else { marker = "•" }
                    for (childIndex, child) in item.children.enumerated() {
                        if childIndex > 0 { separator(false) }
                        if childIndex == 0, case .paragraph(let runs) = child {
                            prose(runs, indent: indent, quote: quote, prefix: marker + "\t", hanging: 26)
                        } else {
                            append(child, indent: indent + 26, quote: quote)
                        }
                    }
                }
            case .codeBlock(let language, let code):
                if let language, !language.isEmpty {
                    let header = NSMutableParagraphStyle()
                    header.minimumLineHeight = 21 * scale
                    header.firstLineHeadIndent = (indent + MD.codePaddingX) * scale
                    text.append(NSAttributedString(string: language + "\n", attributes: [
                        .font: Theme.sansUI(11 * scale), .paragraphStyle: header,
                        .foregroundColor: UIColor(Theme.textMuted), .responseCodeBlock: code,
                    ]))
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = MD.codeLineHeight * scale
                paragraph.firstLineHeadIndent = (indent + MD.codePaddingX) * scale
                paragraph.headIndent = paragraph.firstLineHeadIndent
                paragraph.tailIndent = -MD.codePaddingX * scale
                // Soft wraps are visual only: copied code retains its literal
                // newlines, including empty and trailing lines.
                paragraph.lineBreakMode = .byCharWrapping
                let value = NSMutableAttributedString(string: code, attributes: [
                    .font: Theme.monoUI(MD.codeTextSize * scale), .paragraphStyle: paragraph,
                    .foregroundColor: UIColor(Theme.text.opacity(0.9)), .responseCodeBlock: code,
                ])
                let colors = highlights["\(language ?? "")\0\(code)"] ?? []
                var offset = 0
                for (lineIndex, line) in code.components(separatedBy: "\n").enumerated() {
                    for span in lineIndex < colors.count ? colors[lineIndex] : [] {
                        let chars = Array(line)
                        guard span.range.lowerBound < chars.count else { continue }
                        let upper = min(span.range.upperBound, chars.count)
                        let start = String(chars[..<span.range.lowerBound]).utf16.count
                        let length = String(chars[span.range.lowerBound..<upper]).utf16.count
                        let color: Color
                        switch span.cls {
                        case .keyword: color = Theme.tokenKeyword
                        case .stringLit: color = Theme.tokenString
                        case .number: color = Theme.tokenNumber
                        case .comment: color = Theme.textFaint
                        }
                        value.addAttribute(.foregroundColor, value: UIColor(color),
                                           range: NSRange(location: offset + start, length: length))
                    }
                    offset += line.utf16.count + 1
                }
                text.append(value)
            case .table(let header, let rows, let align):
                for (rowIndex, row) in ([header] + rows).enumerated() {
                    if rowIndex > 0 { separator(false) }
                    var runs: [InlineRun] = []
                    for (cellIndex, cell) in row.enumerated() {
                        if cellIndex > 0 { runs.append(InlineRun(text: "\t", style: .plain)) }
                        runs.append(contentsOf: cell)
                    }
                    let start = text.length
                    prose(runs, weight: rowIndex == 0 ? .bold : .regular, indent: indent, quote: quote)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.minimumLineHeight = MD.lineHeight * scale
                    paragraph.headIndent = indent * scale
                    paragraph.firstLineHeadIndent = indent * scale
                    paragraph.tabStops = (1..<max(1, row.count)).map { column in
                        let alignment: NSTextAlignment = column < align.count
                            ? (align[column] == .right ? .right : align[column] == .center ? .center : .left) : .left
                        return NSTextTab(textAlignment: alignment, location: (indent + CGFloat(column) * 120) * scale)
                    }
                    text.addAttribute(.paragraphStyle, value: paragraph,
                                      range: NSRange(location: start, length: text.length - start))
                }
            case .rule:
                // A blank separator remains text, rather than an attachment
                // that would leak an object-replacement character on Copy.
                let start = text.length
                prose([], indent: indent, quote: false, prefix: "\n")
                text.addAttribute(.responseRule, value: true, range: NSRange(location: start, length: text.length - start))
            }
        }
    }
}
