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

    /// Lying flat, `UINavigationBar` shares its row with the right-side status bar and Dynamic Island (~240pt),
    /// which evicted the session header into UIKit's `…` overflow button. Drawing the pane header strip keeps
    /// the title and folder subtitle below the status bar across the full pane width.
    func testFlatDuoUsesPaneHeaderStripInsteadOfNavigationBar() {
        XCTAssertTrue(DuoChat.usesPaneHeader(splitScreen: false, foldPaneHeader: false, flatSplit: true))
        XCTAssertTrue(DuoChat.usesPaneHeader(splitScreen: true, foldPaneHeader: false, flatSplit: false))
        XCTAssertTrue(DuoChat.usesPaneHeader(splitScreen: false, foldPaneHeader: true, flatSplit: false))
        XCTAssertFalse(DuoChat.usesPaneHeader(splitScreen: false, foldPaneHeader: false, flatSplit: false))
    }

    // MARK: Cover display (466 x 678 pt; the system's vertical bar column is an 84pt trailing inset)

    private let coverWidth: CGFloat = 466
    private let coverBarInset: CGFloat = 84

    /// The bar's column is the system's safe area; the rows inside it used to keep 20pt a side on top, a 342pt
    /// text column. Beside the bar they keep 8pt to its edge, and the scroll indicator gets the bar's gutter.
    func testCoverTranscriptTakesTheWidthBesideTheBar() {
        let insets = CoverLayout.rowInsets(barEdge: .trailing, barInset: coverBarInset)
        let safeWidth = coverWidth - coverBarInset
        XCTAssertEqual(CoverLayout.RowInsets.standard.textWidth(safeWidth: safeWidth), 342)
        XCTAssertEqual(insets.textWidth(safeWidth: safeWidth), 358)
        // The text stops short of the safe area; only the scroll indicator's gutter reaches into the column, and
        // it stays clear of the bar's controls (17pt into the column).
        XCTAssertEqual(insets.trailing - insets.bleedTrailing, CoverLayout.barSideGap)
        XCTAssertGreaterThan(insets.bleedTrailing, 0)
        XCTAssertLessThan(insets.bleedTrailing, 17)
        XCTAssertEqual(insets.bleedLeading, 0)
    }

    func testABarOnTheLeadingSideMirrorsTheInsets() {
        let insets = CoverLayout.rowInsets(barEdge: .leading, barInset: coverBarInset)
        XCTAssertEqual(insets.bleedLeading, CoverLayout.gutter)
        XCTAssertEqual(insets.leading, CoverLayout.gutter + CoverLayout.barSideGap)
        XCTAssertEqual(insets.trailing, CoverLayout.openSidePadding)
    }

    /// No bar, or an inset too narrow to be a bar column (a phone's rounded corners): 20pt a side as before.
    func testWithoutABarColumnRowsKeepTheirPadding() {
        XCTAssertEqual(CoverLayout.rowInsets(barEdge: nil, barInset: 84), .standard)
        XCTAssertEqual(CoverLayout.rowInsets(barEdge: .trailing, barInset: 0), .standard)
        XCTAssertEqual(CoverLayout.rowInsets(barEdge: .trailing, barInset: 20), .standard)
    }

    /// The SDK reports the bar's side; without it (older SDKs) a Duo at compact width with a bar-wide inset on
    /// one side only has one. A landscape iPhone has insets on both sides and no bar.
    func testBarEdgeFallsBackToTheInsetsOnlyOnADuo() {
        XCTAssertEqual(CoverLayout.barEdge(reported: .leading, duo: false, compactWidth: false,
                                           leadingInset: 0, trailingInset: 0), .leading)
        XCTAssertEqual(CoverLayout.barEdge(reported: nil, duo: true, compactWidth: true,
                                           leadingInset: 0, trailingInset: 84), .trailing)
        XCTAssertNil(CoverLayout.barEdge(reported: nil, duo: false, compactWidth: true,
                                         leadingInset: 0, trailingInset: 84))
        XCTAssertNil(CoverLayout.barEdge(reported: nil, duo: true, compactWidth: false,
                                         leadingInset: 0, trailingInset: 84))
        XCTAssertNil(CoverLayout.barEdge(reported: nil, duo: true, compactWidth: true,
                                         leadingInset: 59, trailingInset: 59))
        XCTAssertNil(CoverLayout.barEdge(reported: nil, duo: true, compactWidth: true,
                                         leadingInset: 0, trailingInset: 0))
    }

    // MARK: Popovers

    /// The context card was 398pt wide whatever the screen; the cover display leaves 382pt beside its bar, and
    /// the system centered the card in a narrower popover and cut off both edges.
    func testContextCardFitsTheCoverDisplay() {
        let available = PopoverFit.availableWidth(windowWidth: coverWidth, leadingInset: 0,
                                                  trailingInset: coverBarInset)
        XCTAssertEqual(available, 350)
        XCTAssertGreaterThan(ContextCardLayout.idealWidth, coverWidth - coverBarInset)
        let layout = ContextCardLayout.fitting(available)
        XCTAssertLessThanOrEqual(layout.width, available)
        // The bar keeps every segment, thinner.
        XCTAssertLessThanOrEqual(ContextCardLayout.barWidth(segmentWidth: layout.segmentWidth)
                                 + 2 * ContextCardLayout.padding, layout.width + 0.001)
        XCTAssertGreaterThanOrEqual(layout.segmentWidth, ContextCardLayout.minimumSegmentWidth)
        XCTAssertEqual(layout.legendColumns, 2)
    }

    func testContextCardKeepsItsWidthWhereItFitsAndReflowsWhereItDoesNot() {
        // iPhone 17 (402pt): 370 available, the ideal 398 doesn't fit either.
        XCTAssertLessThanOrEqual(ContextCardLayout.fitting(
            PopoverFit.availableWidth(windowWidth: 402, leadingInset: 0, trailingInset: 0)).width, 370)
        // iPad, or no window: the ideal card, two columns.
        let ipad = ContextCardLayout.fitting(PopoverFit.availableWidth(windowWidth: 1024, leadingInset: 0,
                                                                        trailingInset: 0))
        XCTAssertEqual(ipad, ContextCardLayout.fitting(nil))
        XCTAssertEqual(ipad.width, ContextCardLayout.idealWidth)
        XCTAssertEqual(ipad.segmentWidth, ContextCardLayout.idealSegmentWidth)
        XCTAssertEqual(ipad.legendColumns, 2)
        // Very narrow: one legend column, and never thinner segments than the floor.
        let narrow = ContextCardLayout.fitting(200)
        XCTAssertEqual(narrow.legendColumns, 1)
        XCTAssertEqual(narrow.segmentWidth, ContextCardLayout.minimumSegmentWidth, accuracy: 0.001)
    }
}
