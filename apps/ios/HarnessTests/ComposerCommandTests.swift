import XCTest
@testable import Harness

/// The desktop invocation decoder runs the same command-only vectors.
final class ComposerCommandTests: XCTestCase {
    private struct Vectors: Decodable {
        let encode: [Encoding]
        let cases: [TextCase]
    }

    private struct Encoding: Decodable {
        let name: String
        let link: String?
    }

    private struct TextCase: Decodable {
        let id: String
        let text: String
        let visibleText: String
        let commands: [Token]
    }

    private struct Token: Decodable {
        let name: String
        let source: String
        let utf16Location: Int
        let utf16Length: Int
    }

    private func vectors() throws -> Vectors {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/parity/vectors/composer-commands.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    @MainActor
    func testGraffDemoIncludesTheCompleteAgentCatalogNotTwoExamples() async throws {
        let model = AppModel()
        model.demo = DemoDataset.standard()
        let commands = try await model.listCommands(ComposerCommandContext(deviceId: "dev-mac", harness: "graff"))
        XCTAssertGreaterThanOrEqual(commands.count, 70, "The simulator must exercise the full advertised catalog")
        let names = Set(commands.map(\.name))
        for name in ["goal", "goals", "model", "models", "review", "plan", "compact", "effort",
                     "tools", "jobs", "usage", "cost", "schedule", "mcp", "workspace", "help"] {
            XCTAssertTrue(names.contains(name), "Missing /\(name)")
        }
        XCTAssertEqual(names.count, commands.count, "Do not duplicate or truncate provider commands")
    }

    func testCommandEncodingMatchesSharedVectors() throws {
        for item in try vectors().encode {
            XCTAssertEqual(ComposerCommandReference(name: item.name).link, item.link,
                           String(reflecting: item.name))
        }
    }

    func testCommandLinksAndVisibleTextMatchSharedVectors() throws {
        for item in try vectors().cases {
            XCTAssertEqual(ComposerCommandText.visibleText(item.text), item.visibleText, item.id)
            let links = ComposerCommandText.links(in: item.text)
            XCTAssertEqual(links.count, item.commands.count, item.id)
            for (actual, expected) in zip(links, item.commands) {
                XCTAssertEqual(actual.reference.name, expected.name, item.id)
                XCTAssertEqual(actual.range,
                               NSRange(location: expected.utf16Location, length: expected.utf16Length),
                               item.id)
                XCTAssertEqual((item.text as NSString).substring(with: actual.range), expected.source,
                               item.id)
            }
        }
    }

    /// A marker records a caret in synthetic text; UIKit selections are UTF-16 offsets.
    private func caret(_ marked: String) throws -> (text: String, selection: NSRange) {
        let marker = try XCTUnwrap(marked.range(of: "|"))
        let location = marked[..<marker.lowerBound].utf16.count
        var text = marked
        text.removeSubrange(marker)
        return (text, NSRange(location: location, length: 0))
    }

    func testCompletionQueryUsesUTF16AfterEmoji() throws {
        let input = try caret("👋🏽 /go|")
        let query = try XCTUnwrap(ComposerCommandText.query(in: input.text, selection: input.selection))
        XCTAssertEqual(query.query, "go")
        XCTAssertEqual(query.range, NSRange(location: "👋🏽 ".utf16.count, length: 3))
        let range = ComposerCommandText.replacementRange(in: input.text, query: query, name: "goal")
        XCTAssertEqual(range, query.range)
        let link = try XCTUnwrap(ComposerCommandReference(name: "goal").link)
        let replaced = (input.text as NSString).replacingCharacters(in: range, with: link)
        XCTAssertEqual(ComposerCommandText.visibleText(replaced), "👋🏽 /goal")
    }

    func testCompletionRejectsSlashInCodePathsAndLinks() throws {
        for marked in [
            "`/go|`", "```\n/go|\n```", "    /go|",
            "src/go|", "/tmp/go|", "https://example.invalid/go|",
            "[/go|](https://example.invalid)", "[example](https://example.invalid/go|)",
            "![/go|](example.png)",
        ] {
            let input = try caret(marked)
            XCTAssertNil(ComposerCommandText.query(in: input.text, selection: input.selection), marked)
        }
    }

    func testCompletionReplacesMatchingSuffixWithoutDuplicatingIt() throws {
        let input = try caret("/co|mpact keep these arguments")
        let query = try XCTUnwrap(ComposerCommandText.query(in: input.text, selection: input.selection))
        XCTAssertEqual(query.query, "co")
        XCTAssertEqual(query.range, NSRange(location: 0, length: 8))
        let range = ComposerCommandText.replacementRange(in: input.text, query: query, name: "compact")
        XCTAssertEqual(range, NSRange(location: 0, length: 8))
        let link = try XCTUnwrap(ComposerCommandReference(name: "compact").link)
        let replaced = (input.text as NSString).replacingCharacters(in: range, with: link)
        XCTAssertEqual(ComposerCommandText.visibleText(replaced), "/compact keep these arguments")
    }

    func testCompletionPreservesNonmatchingGoalArgumentSuffix() throws {
        let input = try caret("/goal|prompt")
        let query = try XCTUnwrap(ComposerCommandText.query(in: input.text, selection: input.selection))
        XCTAssertEqual(query.query, "goal")
        XCTAssertEqual(query.range, NSRange(location: 0, length: 11))
        let range = ComposerCommandText.replacementRange(in: input.text, query: query, name: "goal")
        XCTAssertEqual(range, NSRange(location: 0, length: 5))
        let link = try XCTUnwrap(ComposerCommandReference(name: "goal").link)
        let replaced = (input.text as NSString).replacingCharacters(in: range, with: link + " ")
        XCTAssertEqual(ComposerCommandText.visibleText(replaced), "/goal prompt")
    }
}
