import XCTest
@testable import Harness

final class HomeGroupingTests: XCTestCase {
    private func chat(_ id: String, space: String?, device: String) -> Chat {
        Chat(id: id, deviceId: device, title: id, archived: false, cwd: nil, branch: nil,
             checkoutId: nil, config: nil, lastMessagePreview: nil, lastMessageAt: nil,
             createdAt: 0, spaceId: space, lastSeenAt: nil)
    }

    /// Recency order, newest first (as the home list hands it over).
    private lazy var chats = [
        chat("a", space: "harness", device: "studio"),
        chat("b", space: nil, device: "laptop"),
        chat("c", space: "browse", device: "studio"),
        chat("d", space: "harness", device: "laptop"),
        chat("e", space: nil, device: "studio"),
    ]

    func testNoGroupingKeepsOneSectionInListOrder() {
        let groups = HomeGrouping.groups(chats, by: .none)
        XCTAssertEqual(groups.map(\.id), ["all"])
        XCTAssertEqual(groups[0].chats.map(\.id), ["a", "b", "c", "d", "e"])
    }

    func testProjectsInOrderOfNewestSessionWithProjectlessLast() {
        let groups = HomeGrouping.groups(chats, by: .project)
        XCTAssertEqual(groups.map(\.kind), [.project(spaceId: "harness"), .project(spaceId: "browse"),
                                            .project(spaceId: nil)])
        XCTAssertEqual(groups.map { $0.chats.map(\.id) }, [["a", "d"], ["c"], ["b", "e"]])
    }

    func testDevicesInOrderOfNewestSession() {
        let groups = HomeGrouping.groups(chats, by: .device)
        XCTAssertEqual(groups.map(\.kind), [.device(deviceId: "studio"), .device(deviceId: "laptop")])
        XCTAssertEqual(groups.map { $0.chats.map(\.id) }, [["a", "c", "e"], ["b", "d"]])
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count, "section ids are unique")
    }

    // MARK: status

    func testStatusPutsNeedsYouFirstThenTodayThenEarlier() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var rows = chats
        rows[0].lastMessageAt = nowMs - 3 * 86_400_000  // a: three days ago
        rows[1].lastMessageAt = nowMs                    // b: now, waiting on you
        rows[2].lastMessageAt = nowMs - 60_000           // c: a minute ago
        rows[3].lastMessageAt = nowMs - 5 * 86_400_000   // d: failed last week
        rows[4].lastMessageAt = nowMs - 7 * 86_400_000   // e: last week
        let indicators: [String: ChatIndicator] = ["b": .awaitingInput, "d": .errored]
        let groups = HomeGrouping.groups(rows, by: .status,
                                         indicator: { indicators[$0.id] ?? .idle }, now: now)
        XCTAssertEqual(groups.map(\.kind), [.status(key: "needs"), .status(key: "today"), .status(key: "earlier")])
        XCTAssertEqual(groups.map { $0.chats.map(\.id) }, [["b", "d"], ["c"], ["a", "e"]])
        XCTAssertEqual(HomeGrouping.statusTitle("needs"), "Needs you")
    }

    func testStatusIsTheDefaultGroupingAndPinsStillLead() {
        XCTAssertEqual(HomeGroupBy.allCases.first, .status)
        XCTAssertEqual(HomeGroupBy.status.pillTitle, "By status")
        let groups = HomeGrouping.groups(chats, by: .status, pinned: ["c"])
        XCTAssertEqual(groups.first?.kind, .pinned)
        XCTAssertFalse(groups.dropFirst().contains { $0.chats.contains { $0.id == "c" } })
    }

    func testStartersFormATwoByTwoGrid() {
        XCTAssertEqual(HomeStarter.grid(hasProject: true).map(\.count), [2, 2])
        XCTAssertFalse(HomeStarter.grid(hasProject: false).joined().contains { $0.needsProject })
        XCTAssertFalse(HomeStartHeader.title.contains("\u{2014}"))
    }

    // MARK: pinned

    func testPinnedSessionsGatherAboveTheProjectSections() {
        let groups = HomeGrouping.groups(chats, by: .project, pinned: ["d", "c"])
        XCTAssertEqual(groups.map(\.id), ["pinned", "project:harness", "project:"])
        XCTAssertEqual(groups[0].kind, .pinned)
        // Pins keep the order the list handed over; they no longer sit in their project.
        XCTAssertEqual(groups.map { $0.chats.map(\.id) }, [["c", "d"], ["a"], ["b", "e"]])
    }

    func testPinnedSessionsGatherAboveTheDeviceSections() {
        let groups = HomeGrouping.groups(chats, by: .device, pinned: ["b"])
        XCTAssertEqual(groups.map(\.id), ["pinned", "device:studio", "device:laptop"])
        XCTAssertEqual(groups.map { $0.chats.map(\.id) }, [["b"], ["a", "c", "e"], ["d"]])
    }

    func testASectionWhoseOnlySessionIsPinnedDisappears() {
        let groups = HomeGrouping.groups(chats, by: .project, pinned: ["c"])
        XCTAssertEqual(groups.map(\.id), ["pinned", "project:harness", "project:"])
        XCTAssertFalse(groups.contains { $0.kind == .project(spaceId: "browse") })
    }

    func testNoPinsMeansNoPinnedSection() {
        XCTAssertEqual(HomeGrouping.groups(chats, by: .project).map(\.id),
                       HomeGrouping.groups(chats, by: .project, pinned: []).map(\.id))
        XCTAssertFalse(HomeGrouping.groups(chats, by: .device, pinned: ["not-a-session"])
            .contains { $0.kind == .pinned })
    }

    func testUngroupedListKeepsPinsInline() {
        let groups = HomeGrouping.groups(chats, by: .none, pinned: ["d"])
        XCTAssertEqual(groups.map(\.id), ["all"])
        XCTAssertEqual(groups[0].chats.map(\.id), ["a", "b", "c", "d", "e"])
    }
}
