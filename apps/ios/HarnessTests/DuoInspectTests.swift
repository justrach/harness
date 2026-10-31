import XCTest
@testable import Harness

/// iPhone Duo lying flat: what the Inspect pane is built from, and what live data leaves stubbed.
final class DuoInspectTests: XCTestCase {
    private func entry(_ parts: [MessagePart]) -> MessageEntry {
        MessageEntry(id: "m1", role: .assistant, parts: parts, createdAt: 0, deviceId: "d")
    }

    private func tool(_ id: String, _ tag: String, _ fields: [String: AnyHashable],
                      error: Bool = false, resolved: Bool = true) -> MessagePart {
        .tool(id: id, call: RenderToolCall(tag: tag, fields: fields), isError: error, resolved: resolved)
    }

    private var entries: [MessageEntry] {
        [entry([
            tool("t1", "readFile", ["path": "crates/ui/src/a.rs"]),
            tool("t2", "editFile", ["path": "crates/ui/src/b.rs", "additions": Int64(3), "deletions": Int64(1)]),
            tool("t3", "exec", ["command": "cargo test"], error: true),
            tool("t4", "editFile", ["path": "crates/ui/src/b.rs", "additions": Int64(2)]),
            tool("t5", "exec", ["command": "cargo build"], resolved: false),
        ])]
    }

    func testLiveBuildsFilesCommandsAndTouchedTreeButNoDetails() {
        let model = InspectModel.build(entries, source: LiveInspectSource())
        XCTAssertEqual(model.files.map(\.path), ["crates/ui/src/b.rs"])
        XCTAssertEqual(model.files.first?.additions, 5)
        XCTAssertEqual(model.files.first?.deletions, 1)
        XCTAssertNil(model.files.first?.hunks, "line diffs are not synced to iOS yet")
        XCTAssertEqual(model.commands.map(\.command), ["cargo test", "cargo build"])
        XCTAssertEqual(model.commands.map(\.failed), [true, false])
        XCTAssertEqual(model.commands.map(\.running), [false, true])
        XCTAssertNil(model.commands.first?.output, "output is not synced to iOS yet")
        XCTAssertFalse(model.detailed)
        XCTAssertEqual(model.tree.map(\.path),
                       ["crates", "crates/ui", "crates/ui/src", "crates/ui/src/a.rs", "crates/ui/src/b.rs"])
        XCTAssertEqual(model.tree.last?.mark, .edited)
        XCTAssertEqual(model.tree[3].mark, .read)
        XCTAssertEqual(model.diffSummary, "1 file  +5 -1")
    }

    func testDemoSourceFillsTheStubbedDetails() {
        let model = InspectModel.build(entries, source: DemoInspectSource())
        XCTAssertNotNil(model.files.first?.hunks)
        XCTAssertNotNil(model.commands.first?.output)
        XCTAssertNil(model.commands.last?.output, "a running command has no output yet")
        XCTAssertTrue(model.detailed)
        XCTAssertTrue(model.tree.contains { $0.path == "Cargo.toml" && $0.mark == .untouched })
    }

    func testTreeListsDirectoriesBeforeFiles() {
        let rows = FileTree.rows(["z.txt": .read, "a/b.txt": .edited])
        XCTAssertEqual(rows.map(\.path), ["a", "a/b.txt", "z.txt"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
    }

    @MainActor
    func testToolRowPicksTheSegmentAndFile() {
        let state = InspectState()
        state.show(ToolItem(call: RenderToolCall(tag: "editFile", fields: ["path": "x.rs"]), isError: false, resolved: true))
        XCTAssertEqual(state.segment, .diff)
        XCTAssertEqual(state.selectedFile, "x.rs")
        state.show(ToolItem(call: RenderToolCall(tag: "exec", fields: ["command": "ls"]), isError: false, resolved: true))
        XCTAssertEqual(state.segment, .terminal)
        XCTAssertEqual(state.selectedFile, "x.rs", "the selected file survives a trip to the terminal")
    }

    @MainActor
    func testInspectStateIsKeptPerSession() {
        let a = InspectState.of("duo-test-a")
        a.segment = .files
        XCTAssertTrue(InspectState.of("duo-test-a") === a)
        XCTAssertEqual(InspectState.of("duo-test-b").segment, .diff)
    }

    func testOnlyTheFlatInnerDisplaySplits() {
        XCTAssertTrue(DuoChat.isFlat(phone: true, regularWidth: true, regularHeight: true, fold: .none))
        XCTAssertFalse(DuoChat.isFlat(phone: true, regularWidth: true, regularHeight: true,
                                      fold: .sideBySide(leading: 400, gap: 0)))
        XCTAssertFalse(DuoChat.isFlat(phone: false, regularWidth: true, regularHeight: true, fold: .none))
        XCTAssertFalse(DuoChat.isFlat(phone: true, regularWidth: false, regularHeight: true, fold: .none))
    }
}
