import XCTest
@testable import Harness

/// Model thinking reaches the transcript as a "Thought process" chip in the
/// tool group around it, as on desktop (transcript.rs rows_for_entry).
final class ThoughtRowsTests: XCTestCase {
    private func rows(_ parts: [MessagePart], status: MessageStatus = .complete) -> [TranscriptRow] {
        var parsers: [String: IncrementalMarkdownParser] = [:]
        var completed: [String: CompletedParse] = [:]
        let entry = MessageEntry(id: "a", role: .assistant, parts: parts, createdAt: 1,
                                 deviceId: "mac", status: status)
        return TranscriptRowBuilder.rows(entries: [entry], pendingSends: [],
                                         parsers: &parsers, completed: &completed)
    }

    private func tools(_ row: TranscriptRow) -> [ToolItem]? {
        if case .toolGroup(let tools, _) = row.kind { return tools }
        return nil
    }

    private func exec(_ id: String) -> MessagePart {
        .tool(id: id, call: RenderToolCall(tag: "exec", fields: ["command": "ls"]), isError: false, resolved: true)
    }

    func testReasoningDecodesFromItsOwnField() {
        let part = SessionStore.partFrom(.fromJSON(["id": "r", "kind": "reasoning",
                                                    "reasoning": "weighing the plan", "text": "not this"]))
        XCTAssertEqual(part, .reasoning(id: "r", text: "weighing the plan"))
    }

    func testThoughtsJoinTheToolGroupAroundThem() throws {
        let rows = rows([.reasoning(id: "r0", text: "first"), exec("t0"),
                         .reasoning(id: "r1", text: "second"), exec("t1"),
                         .text(id: "p", text: "Done.")])
        XCTAssertEqual(rows.count, 2, "one group, then the reply")
        let group = try XCTUnwrap(tools(rows[0]))
        XCTAssertEqual(group.map(\.call.isThought), [true, false, true, false])
        XCTAssertEqual(group[0].call.chipLabel, "Thought process")
        XCTAssertEqual(group[0].call.chipDetail, "first")
        XCTAssertTrue(group.allSatisfy(\.resolved), "a settled reply has no live thought")
        XCTAssertEqual(toolGroupSummary(group), "Thought 2 times · ran 2 commands")
    }

    func testALoneThoughtIsNamedPlainlyAndBlankOnesVanish() throws {
        let lone = rows([.reasoning(id: "r", text: "just thinking"), .text(id: "p", text: "Hi")])
        XCTAssertEqual(toolGroupSummary(try XCTUnwrap(tools(lone[0]))), "Thought process")
        let blank = rows([.reasoning(id: "r", text: "  \n "), .text(id: "p", text: "Hi")])
        XCTAssertEqual(blank.count, 1)
        XCTAssertNil(tools(blank[0]))
    }

    func testTheStreamingTailThoughtIsLiveAndOpensItsGroup() throws {
        let live = rows([exec("t"), .reasoning(id: "r", text: "still going")], status: .streaming)
        guard case .toolGroup(let group, let autoOpen) = try XCTUnwrap(live.first?.kind) else {
            return XCTFail("expected a tool group")
        }
        XCTAssertTrue(autoOpen)
        XCTAssertFalse(try XCTUnwrap(group.last).resolved)
        // Once text follows, the thought is finished though the reply streams.
        let done = rows([.reasoning(id: "r", text: "done"), .text(id: "p", text: "Hi")], status: .streaming)
        XCTAssertTrue(try XCTUnwrap(tools(done[0])?.first).resolved)
    }

    func testAThoughtChangingChangesItsRowVersion() throws {
        let before = rows([.reasoning(id: "r", text: "one"), .text(id: "p", text: "Hi")])
        let after = rows([.reasoning(id: "r", text: "one two"), .text(id: "p", text: "Hi")])
        XCTAssertEqual(before[0].id, after[0].id)
        XCTAssertNotEqual(before[0].version, after[0].version)
    }

    func testThePreviewKeepsTheNewestLinesWhileLive() {
        let text = "Plan\n\nRead the file\nCheck the tests\nRun them"
        XCTAssertEqual(thoughtPreview(text, live: false), "Plan\nRead the file")
        XCTAssertEqual(thoughtPreview(text, live: true), "Check the tests\nRun them")
    }

    func testDuoChipsCountThoughtsApartFromTools() {
        let chips = ToolChips.chips([ToolItem(call: .thought("x"), isError: false, resolved: true),
                                     ToolItem(call: RenderToolCall(tag: "exec", fields: [:]), isError: false, resolved: true)])
        XCTAssertEqual(chips.map(\.label), ["Thought", "1 run"])
    }
}
