import XCTest
@testable import Harness

@MainActor
final class MessageFooterTests: XCTestCase {
    private func entry(_ parts: [MessagePart], role: MessageRole = .assistant,
                       status: MessageStatus? = .complete, timestamp: Int64 = 1_000) -> MessageEntry {
        MessageEntry(id: "message", role: role, parts: parts, createdAt: timestamp,
                     deviceId: "synthetic", status: status)
    }

    private func rows(_ entry: MessageEntry) -> [TranscriptRow] {
        var parsers: [String: IncrementalMarkdownParser] = [:]
        var completed: [String: CompletedParse] = [:]
        return TranscriptRowBuilder.rows(entries: [entry], pendingSends: [],
                                         parsers: &parsers, completed: &completed)
    }

    func testPromptCopiesAllTextWithoutAttachmentTransportMetadata() throws {
        let message = entry([
            .text(id: "t0", text: "First line.\nSecond line."),
            .text(id: "t1", text: "Last line.\n\nAttached images (local files):\n- /fixture/example.png"),
        ], role: .user)
        let row = try XCTUnwrap(rows(message).first)
        XCTAssertEqual(row.timestamp, 1_000)
        XCTAssertEqual(row.copyText, "First line.\nSecond line.\nLast line.")
    }

    func testResponseCopiesAllAuthoredPartsNotThinkingOrToolTraces() throws {
        let first = "First paragraph.  \nHard break.\n\n    indented code\n"
        let last = "## Result\n\n```swift\nlet answer = 42\n```"
        let message = entry([
            .reasoning(id: "r", text: "Private reasoning"),
            .text(id: "t0", text: first),
            .tool(id: "tool", call: RenderToolCall(tag: "exec", fields: ["command": "example"]),
                  isError: false, resolved: true),
            .text(id: "empty", text: " \n"),
            .text(id: "t1", text: last),
            .error(id: "error", message: "Not part of authored text"),
            .text(id: "tail", text: ""),
        ])
        let result = rows(message)
        XCTAssertEqual(result.filter { $0.timestamp != nil }.count, 1)
        XCTAssertEqual(result.filter { $0.copyText != nil }.count, 1)
        let footer = try XCTUnwrap(result.last)
        XCTAssertEqual(footer.id, "message#error")
        XCTAssertEqual(footer.timestamp, 1_000)
        XCTAssertEqual(footer.copyText, first + "\n\n" + last)
    }

    func testStreamingHandoffAddsFooterWithoutChangingRowIdentity() throws {
        let parts: [MessagePart] = [
            .text(id: "t0", text: "The answer."),
            .tool(id: "tool", call: RenderToolCall(tag: "exec", fields: [:]),
                  isError: false, resolved: true),
        ]
        let live = rows(entry(parts, status: .streaming))
        XCTAssertTrue(live.allSatisfy { $0.timestamp == nil && $0.copyText == nil })
        let statuses: [MessageStatus?] = [.complete, .aborted, nil]
        for status in statuses {
            let settled = rows(entry(parts, status: status))
            XCTAssertEqual(settled.map(\.id), live.map(\.id))
            XCTAssertEqual(settled.last?.copyText, "The answer.")
            XCTAssertEqual(settled.last?.timestamp, 1_000)
            XCTAssertNotEqual(settled.last?.version, live.last?.version)
        }
    }

    func testEarlierTextAndTimestampCorrectionsInvalidateTheFooterRow() {
        let parts: [MessagePart] = [.text(id: "first", text: "First."), .text(id: "last", text: "Last.")]
        let original = rows(entry(parts))
        let corrected = rows(entry([.text(id: "first", text: "Corrected."), parts[1]]))
        XCTAssertEqual(original.last?.id, corrected.last?.id)
        XCTAssertNotEqual(original.last?.version, corrected.last?.version)
        XCTAssertEqual(corrected.last?.copyText, "Corrected.\n\nLast.")
        for role in [MessageRole.user, .assistant] {
            XCTAssertNotEqual(rows(entry(parts, role: role)).last?.version,
                              rows(entry(parts, role: role, timestamp: 2_000)).last?.version)
        }
    }

    func testAttachmentAndImageOnlyMessagesHaveNoEmptyCopyButton() {
        let prompt = entry([.text(id: "t", text: "\(attachmentOnlyText)\n\nAttached images (local files):\n- /fixture/example.png")], role: .user)
        XCTAssertNotNil(rows(prompt).first?.timestamp)
        XCTAssertNil(rows(prompt).first?.copyText)
        let image = entry([.image(id: "image", reference: GeneratedImageReference(
            path: "/fixture/generated.png", name: "generated.png", mimeType: "image/png"))])
        XCTAssertNotNil(rows(image).last?.timestamp)
        XCTAssertNil(rows(image).last?.copyText)
    }

    func testCachedFooterSurvivesAnotherMessagesStreamingUpdates() {
        let cache = TranscriptBuilderCache()
        let settled = entry([.text(id: "t", text: "Settled response.")])
        var live = entry([.text(id: "t", text: "Streaming")], status: .streaming)
        live.id = "live"
        let original = cache.rows(revision: 1, entries: [settled, live], pendingSends: [])
        live.parts = [.text(id: "t", text: "Streaming update")]
        live.stamp = MessageEntry.nextStamp()
        let updated = cache.rows(revision: 2, entries: [settled, live], pendingSends: [])
        XCTAssertEqual(original.first?.version, updated.first?.version)
        XCTAssertEqual(updated.first?.copyText, "Settled response.")
        XCTAssertNil(updated.last?.timestamp)
        XCTAssertNil(updated.last?.copyText)
    }

    func testTimestampMatchesDesktopShapeAndUsesReaderTimeZone() {
        let date = ISO8601DateFormatter().date(from: "2026-11-05T10:26:00Z")!
        let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(MessageFooterView.timestampLabel(milliseconds, locale: locale,
            timeZone: TimeZone(secondsFromGMT: 0)!), "Nov 5, 10:26 AM")
        XCTAssertEqual(MessageFooterView.timestampLabel(milliseconds, locale: locale,
            timeZone: TimeZone(secondsFromGMT: -8 * 3600)!), "Nov 5, 2:26 AM")
    }
}
