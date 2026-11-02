import XCTest
@testable import Harness

/// iPhone Duo v3: the composer's one token, the diff's line numbers, the status strip, Inspect opening.
@MainActor
final class DuoV3Tests: XCTestCase {
    func testTokenJoinsPullRequestModelAndReasoning() {
        XCTAssertEqual(ComposerToken.label(pullRequest: 77, model: "GPT-5.6", reasoning: "High"), "#77 · GPT-5.6 · High")
        XCTAssertEqual(ComposerToken.label(pullRequest: nil, model: "GPT-5.6", reasoning: nil), "GPT-5.6")
        XCTAssertEqual(ComposerToken.label(pullRequest: nil, model: "Opus", reasoning: "", options: ["Fast", ""]), "Opus · Fast")
    }

    func testHunkHeaderStarts() {
        let starts = DiffNumbers.starts("@@ -212,9 +212,11 @@ fn group_header")
        XCTAssertEqual(starts?.old, 212)
        XCTAssertEqual(starts?.new, 212)
        XCTAssertEqual(DiffNumbers.starts("@@ -5 +7 @@")?.new, 7)
        XCTAssertNil(DiffNumbers.starts("not a hunk"))
    }

    func testRemovedLinesCountTheOldFileAndTheRestTheNew() {
        let hunk = DiffHunk(header: "@@ -41,3 +41,4 @@", lines: [
            DiffLine(id: 0, kind: .context, text: "a"),
            DiffLine(id: 1, kind: .removed, text: "b"),
            DiffLine(id: 2, kind: .added, text: "c"),
            DiffLine(id: 3, kind: .added, text: "d"),
            DiffLine(id: 4, kind: .context, text: "e"),
        ])
        XCTAssertEqual(DiffNumbers.numbers(hunk), [41, 42, 42, 43, 44])
    }

    func testUnreadableHeaderLeavesTheGutterEmpty() {
        let hunk = DiffHunk(header: "@@ ? @@", lines: [DiffLine(id: 0, kind: .added, text: "x")])
        XCTAssertEqual(DiffNumbers.numbers(hunk), [nil])
    }

    func testStatusStripPrefersTheRunningCommand() {
        var model = InspectModel()
        model.commands = [
            TerminalCommand(id: "1", command: "cargo build", failed: false, running: false),
            TerminalCommand(id: "2", command: "cargo test", failed: false, running: true),
        ]
        XCTAssertEqual(DuoStatusStrip.activity(model, running: true), "$ cargo test")
        model.commands[1].running = false
        model.commands[1].failed = true
        XCTAssertEqual(DuoStatusStrip.activity(model, running: false), "Failed: $ cargo test")
        XCTAssertEqual(DuoStatusStrip.activity(InspectModel(), running: true), "Working")
        XCTAssertNil(DuoStatusStrip.activity(InspectModel(), running: false))
    }

    func testOpeningAToolOpensInspect() {
        let state = InspectState()
        XCTAssertFalse(state.open, "wide starts with the list beside the chat")
        state.show(ToolItem(call: RenderToolCall(tag: "exec", fields: ["command": "ls"]), isError: false, resolved: true))
        XCTAssertTrue(state.open)
        XCTAssertEqual(state.segment, .terminal)
    }

    func testAskForChangesBumpsOnlyThatSession() {
        let focus = DuoComposerFocus()
        focus.request("a")
        focus.request("a")
        XCTAssertEqual(focus.tick("a"), 2)
        XCTAssertEqual(focus.tick("b"), 0)
    }
}
