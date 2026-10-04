import XCTest
@testable import Harness

/// Split screen on a Max iPhone: where it exists, how many panes, what a new pane opens, and closing.
final class SplitScreenTests: XCTestCase {
    private func chat(_ id: String, called: Int64) -> Chat {
        Chat(id: id, deviceId: "d", title: id, archived: false, cwd: nil, branch: nil, checkoutId: nil,
             config: nil, lastMessagePreview: nil, lastMessageAt: nil, createdAt: 0,
             spaceId: nil, lastSeenAt: nil, lastPromptAt: called)
    }

    // MARK: only a Max

    func testOnlyAPhoneAtRegularWidthHasSplitScreen() {
        XCTAssertTrue(SplitScreen.isAvailable(idiom: .phone, sizeClass: .regular), "a Pro Max in landscape")
        XCTAssertFalse(SplitScreen.isAvailable(idiom: .phone, sizeClass: .compact), "every other iPhone")
        XCTAssertFalse(SplitScreen.isAvailable(idiom: .phone, sizeClass: nil))
        XCTAssertFalse(SplitScreen.isAvailable(idiom: .pad, sizeClass: .regular), "iPad keeps its sidebar")
    }

    func testTwoPanesIsTheMostThereIs() {
        XCTAssertEqual(SplitScreen.maxPanes, 2)
        var panes = SplitPanes(primary: "a", secondary: nil)
        XCTAssertTrue(panes.canAdd)
        panes.add("b")
        XCTAssertEqual(panes.count, 2)
        XCTAssertFalse(panes.canAdd, "no third pane")
        panes.add("c")
        XCTAssertEqual(panes, SplitPanes(primary: "a", secondary: "b"), "a full screen ignores another add")
    }

    // MARK: what a new pane opens

    func testANewPaneOpensTheMostRecentSessionNotAlreadyOnScreen() {
        let chats = [chat("old", called: 100), chat("newest", called: 900), chat("middle", called: 500)]
        XCTAssertEqual(SplitScreen.mostRecent(excluding: ["current"], in: chats), "newest")
        XCTAssertEqual(SplitScreen.mostRecent(excluding: ["newest"], in: chats), "middle",
                       "the one already open is skipped")
        XCTAssertEqual(SplitScreen.mostRecent(excluding: ["newest", "middle", "old"], in: chats), nil)
        XCTAssertNil(SplitScreen.mostRecent(excluding: [], in: []))
    }

    func testAddingNeverDuplicatesOrOpensNothing() {
        var panes = SplitPanes(primary: "a", secondary: nil)
        panes.add("a")
        XCTAssertNil(panes.secondary, "a session is never on screen twice")
        panes.add(nil)
        XCTAssertNil(panes.secondary, "no other session to open: nothing happens")
        var empty = SplitPanes(primary: nil, secondary: nil)
        empty.add("b")
        XCTAssertNil(empty.secondary, "nothing is open to put a session beside")
    }

    // MARK: closing

    func testClosingTheSecondPaneLeavesTheFirst() {
        var panes = SplitPanes(primary: "a", secondary: "b")
        panes.close(.secondary)
        XCTAssertEqual(panes, SplitPanes(primary: "a", secondary: nil))
        XCTAssertEqual(panes.count, 1)
    }

    func testClosingTheFirstPanePromotesTheSecond() {
        var panes = SplitPanes(primary: "a", secondary: "b")
        panes.close(.primary)
        XCTAssertEqual(panes, SplitPanes(primary: "b", secondary: nil), "one pane is always the primary")
    }

    // MARK: opening from the list

    func testOpeningFromTheListReplacesTheFirstPane() {
        var panes = SplitPanes(primary: "a", secondary: "b")
        panes.openFromList("c")
        XCTAssertEqual(panes, SplitPanes(primary: "c", secondary: "b"))
    }

    func testOpeningTheSecondPanesSessionFromTheListSwapsSoNothingShowsTwice() {
        var panes = SplitPanes(primary: "a", secondary: "b")
        panes.openFromList("b")
        XCTAssertEqual(panes, SplitPanes(primary: "b", secondary: "a"))
        XCTAssertEqual(panes.open.count, 2)
    }

    func testOpeningFromTheListWithOnePaneJustReplacesIt() {
        var panes = SplitPanes(primary: "a", secondary: nil)
        panes.openFromList("c")
        XCTAssertEqual(panes, SplitPanes(primary: "c", secondary: nil))
    }
}
