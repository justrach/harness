import XCTest
@testable import Harness

/// iPhone Duo chat: tool chips, the diff summary card's numbers, and which windows mark a Duo.
final class DuoChatTests: XCTestCase {
    private func tool(_ tag: String, _ fields: [String: AnyHashable] = [:], error: Bool = false) -> ToolItem {
        ToolItem(call: RenderToolCall(tag: tag, fields: fields), isError: error, resolved: true)
    }

    func testChipsCountByKindAndKeepFailuresSeparate() {
        let chips = ToolChips.chips([
            tool("exec", ["command": "cargo test"], error: true),
            tool("exec", ["command": "cargo build"]),
            tool("editFile", ["path": "a.rs"]),
            tool("search", ["pattern": "x"]),
        ])
        XCTAssertEqual(chips.map(\.label), ["2 runs", "1 edit", "1 search", "1 failed"])
        XCTAssertEqual(chips.last?.failed, true)
    }

    func testDiffSummaryListsEachFileOnceAndSumsCounts() {
        let summary = DiffSummary.from([
            tool("editFile", ["path": "crates/ui/a.rs", "additions": Int64(3), "deletions": Int64(1)]),
            tool("editFile", ["path": "crates/ui/a.rs", "additions": Int64(2)]),
            tool("writeFile", ["path": "crates/ui/b.rs"]),
            tool("readFile", ["path": "crates/ui/c.rs"]),
        ])
        XCTAssertEqual(summary?.files, ["crates/ui/a.rs", "crates/ui/b.rs"])
        XCTAssertEqual(summary?.additions, 5)
        XCTAssertEqual(summary?.deletions, 1)
        XCTAssertEqual(summary?.title, "2 files changed")
        XCTAssertEqual(summary?.names, "a.rs, b.rs")
    }

    func testLiveEditsWithoutCountsShowFilesOnly() {
        // The session doc keeps only each edit's path, so live groups have no line counts.
        let summary = DiffSummary.from([tool("editFile", ["path": "x.swift"])])
        XCTAssertEqual(summary?.files, ["x.swift"])
        XCTAssertNil(summary?.additions)
        XCTAssertNil(summary?.deletions)
    }

    func testNoEditsNoCard() {
        XCTAssertNil(DiffSummary.from([tool("exec", ["command": "ls"])]))
        XCTAssertNil(DiffSummary.from([tool("editFile", ["path": "x.swift"], error: true)]))
    }

    func testOnlyADuoWindowMarksTheDevice() {
        XCTAssertTrue(DuoChat.isFoldableWindow(phone: true, regularWidth: true, regularHeight: true, fold: .none))
        XCTAssertTrue(DuoChat.isFoldableWindow(phone: true, regularWidth: false, regularHeight: true,
                                               fold: .stacked(top: 400, gap: 40)))
        XCTAssertFalse(DuoChat.isFoldableWindow(phone: true, regularWidth: true, regularHeight: false, fold: .none))
        XCTAssertFalse(DuoChat.isFoldableWindow(phone: false, regularWidth: true, regularHeight: true, fold: .none))
    }

    /// Lying flat with a session open, the list stays out of the way until asked for (it was always beside
    /// the session, leaving the chat a cramped column), and Inspect always takes its place.
    func testFlatDuoKeepsTheListHiddenUntilAskedFor() {
        XCTAssertFalse(DuoChat.listBesideSession(flat: true, listShown: false, sessionOpen: true, inspectOpen: false))
        XCTAssertTrue(DuoChat.listBesideSession(flat: true, listShown: true, sessionOpen: true, inspectOpen: false))
        XCTAssertFalse(DuoChat.listBesideSession(flat: true, listShown: true, sessionOpen: true, inspectOpen: true))
        XCTAssertFalse(DuoChat.listBesideSession(flat: true, listShown: true, sessionOpen: false, inspectOpen: false))
        XCTAssertFalse(DuoChat.listBesideSession(flat: false, listShown: true, sessionOpen: true, inspectOpen: false))
    }

    /// Lying flat the session bar has a back button (and the list's toggle) before the title, so the title
    /// must leave them room; folded on the cover display it starts at the edge as before.
    func testFlatDuoTitleLeavesRoomForTheBackButtonAndListToggle() {
        let inset = { (flat: Bool, toggle: Bool, compact: Bool) in
            DuoChat.headerInset(duoChat: true, compactWidth: compact, flat: flat, listToggle: toggle,
                                chrome: 100, hitTarget: 44)
        }
        XCTAssertEqual(inset(true, true, false), 152)
        XCTAssertEqual(inset(true, false, false), 100)
        XCTAssertEqual(inset(false, false, true), 32)
        XCTAssertEqual(DuoChat.headerInset(duoChat: false, compactWidth: true, flat: false, listToggle: false,
                                           chrome: 100, hitTarget: 44), 100)
    }
}
