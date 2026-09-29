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
