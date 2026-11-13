// Agent commands use the desktop's ListCommands catalog and canonical
// harness-invoke links. Typing or pasting slash text never selects a command.
import Foundation
import Markdown

struct ComposerCommand: Decodable, Identifiable, Hashable {
    let name: String
    var description: String? = nil
    var inputHint: String? = nil
    /// Local UI identity is never accepted from an agent's catalog payload.
    var workspaceCommand: ComposerWorkspaceCommand? = nil
    var id: String { name }

    private enum CodingKeys: String, CodingKey { case name, description, inputHint }
}

struct ComposerCommandContext: Hashable {
    let deviceId: String
    let harness: String
    var chatId: String? = nil
    var spaceId: String? = nil
    var path: String? = nil

    var params: [String: Any] {
        var result: [String: Any] = ["harness": harness]
        if let chatId { result["chatId"] = chatId }
        if let spaceId { result["spaceId"] = spaceId }
        if let path { result["path"] = path }
        return result
    }
}

struct ComposerCommandReference: Codable, Equatable {
    let name: String

    var link: String? {
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        // serde serializes Invocation::Command in this exact order. The host
        // rejects otherwise-equivalent JSON that is not canonical.
        struct Wire: Encodable { let kind = "command"; let name: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Wire(name: name)) else { return nil }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let label = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "`", with: "\\`")
        return "[/\(label)](harness-invoke:\(hex))"
    }

    init(name: String) { self.name = name }

    static func decode(_ destination: String) -> Self? {
        let prefix = "harness-invoke:"
        guard destination.hasPrefix(prefix) else { return nil }
        let hex = Array(destination.dropFirst(prefix.count).utf8)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for offset in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(bytes: hex[offset...offset + 1], encoding: .utf8) ?? "", radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        struct Wire: Decodable { let kind: String; let name: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(bytes)), wire.kind == "command" else {
            return nil
        }
        return Self(name: wire.name)
    }
}

struct ComposerCommandToken {
    let range: NSRange
    let reference: ComposerCommandReference
}

struct ComposerCommandQuery: Equatable {
    let range: NSRange
    let query: String
}

enum ComposerCommandText {
    static func links(in text: String) -> [ComposerCommandToken] {
        guard text.contains("harness-invoke:") else { return [] }
        var result: [ComposerCommandToken] = []
        func visit(_ node: Markup) {
            if node is Markdown.Image || node is CodeBlock || node is InlineCode { return }
            if let link = node as? Markdown.Link, let destination = link.destination,
               let reference = ComposerCommandReference.decode(destination),
               let range = sourceRange(node, in: text), let swiftRange = Range(range, in: text),
               let canonical = reference.link {
                let source = String(text[swiftRange])
                if source == canonical || source == canonical.replacingOccurrences(of: "\\`", with: "`") {
                    result.append(ComposerCommandToken(range: range, reference: reference))
                }
                return
            }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: text))
        return result
    }

    static func visibleText(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for token in links(in: text).reversed() {
            result.replaceCharacters(in: token.range, with: "/\(token.reference.name)")
        }
        return result as String
    }

    static func query(in text: String, selection: NSRange) -> ComposerCommandQuery? {
        guard selection.length == 0, let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let start = text[..<caret].lastIndex(where: { $0.isWhitespace || "([{>".contains($0) })
            .map { text.index(after: $0) } ?? text.startIndex
        guard start < caret, text[start] == "/" else { return nil }
        let nameStart = text.index(after: start)
        let query = String(text[nameStart..<caret])
        guard query.allSatisfy(nameCharacter) else { return nil }
        var end = caret
        while end < text.endIndex, nameCharacter(text[end]) { end = text.index(after: end) }
        guard end == text.endIndex || text[end] != "/" else { return nil }
        // Markdown supplies code/link/image boundaries; do not discover a
        // command inside an example, URL, image description, or existing link.
        let candidate = NSRange(start..<end, in: text)
        var blocked = false
        func visit(_ node: Markup) {
            if node is CodeBlock || node is InlineCode || node is Markdown.Link
                || node is Markdown.Image || node is HTMLBlock {
                if let range = sourceRange(node, in: text), NSIntersectionRange(range, candidate).length > 0 {
                    blocked = true
                }
                return
            }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: text))
        guard !blocked else { return nil }
        return ComposerCommandQuery(range: candidate, query: query)
    }

    static func replacementRange(in text: String, query: ComposerCommandQuery, name: String) -> NSRange {
        guard let token = Range(query.range, in: text) else { return query.range }
        let nameStart = text.index(after: token.lowerBound)
        let caret = text.index(nameStart, offsetBy: query.query.count, limitedBy: token.upperBound) ?? token.upperBound
        var end = caret
        var next = caret
        while next < token.upperBound {
            let after = text.index(after: next)
            let fragment = String(text[nameStart..<after])
            guard name.localizedCaseInsensitiveContains(fragment) else { break }
            if text[next].isLetter || text[next].isNumber { end = after }
            next = after
        }
        return NSRange(token.lowerBound..<end, in: text)
    }

    private static func nameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "-_:.".contains(character)
    }

    private static func sourceRange(_ node: Markup, in text: String) -> NSRange? {
        guard let range = node.range else { return nil }
        // swift-markdown columns count UTF-8 bytes, UIKit ranges UTF-16 units.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        func index(_ location: SourceLocation) -> String.Index? {
            guard location.line > 0, location.line <= lines.count else { return nil }
            let offset = lines.prefix(location.line - 1).reduce(0) { $0 + $1.utf8.count + 1 }
                + location.column - 1
            guard offset >= 0, offset <= text.utf8.count else { return nil }
            let utf8 = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
            return String.Index(utf8, within: text)
        }
        guard let start = index(range.lowerBound), let end = index(range.upperBound), start <= end else { return nil }
        return NSRange(start..<end, in: text)
    }
}
