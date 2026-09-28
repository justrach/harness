import XCTest
@testable import Harness

final class HomeFilterTests: XCTestCase {
    private func chat(_ id: String, title: String, space: String? = nil, device: String = "studio",
                      preview: String? = nil, branch: String? = nil, cwd: String? = nil) -> Chat {
        Chat(id: id, deviceId: device, title: title, archived: false, cwd: cwd, branch: branch,
             checkoutId: nil, config: nil, lastMessagePreview: preview, lastMessageAt: nil,
             createdAt: 0, spaceId: space, lastSeenAt: nil)
    }

    private lazy var chats = [
        chat("a", title: "Fix the scroll pill", space: "harness", device: "studio", branch: "fix/scroll-pill"),
        chat("b", title: "Café menu copy", space: "site", device: "laptop", preview: "Updated the hero text"),
        chat("c", title: "Refactor sync", space: "harness", device: "laptop", cwd: "/Users/me/zigrep"),
        chat("d", title: "New session", device: "studio"),
    ]

    private let indicators: [String: ChatIndicator] = [
        "a": .working, "b": .awaitingInput, "c": .completed, "d": .idle,
    ]

    private let projects = ["harness": "Harness", "site": "Website"]
    private let devices = ["studio": "Mac Studio", "laptop": "MacBook"]

    private func apply(_ query: String, _ status: HomeStatusFilter = .all) -> [String] {
        HomeFilter.apply(chats, query: query, status: status,
                         indicator: { self.indicators[$0.id] ?? .idle }) { chat in
            HomeFilter.Names(project: chat.spaceId.flatMap { self.projects[$0] },
                             device: self.devices[chat.deviceId] ?? chat.deviceId)
        }.map(\.id)
    }

    func testEmptyQueryAndAllKeepsEverythingInOrder() {
        XCTAssertEqual(apply(""), ["a", "b", "c", "d"])
        XCTAssertEqual(apply("   "), ["a", "b", "c", "d"])
    }

    func testMatchesTitlePreviewBranchAndFolder() {
        XCTAssertEqual(apply("scroll"), ["a"])
        XCTAssertEqual(apply("hero"), ["b"])
        XCTAssertEqual(apply("fix/"), ["a"])
        XCTAssertEqual(apply("zigrep"), ["c"])
    }

    func testMatchesProjectAndDeviceNamesIgnoringCaseAndAccents() {
        XCTAssertEqual(apply("harness"), ["a", "c"])
        XCTAssertEqual(apply("macbook"), ["b", "c"])
        XCTAssertEqual(apply("cafe"), ["b"])
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(apply("harness macbook"), ["c"])
        XCTAssertEqual(apply("harness website"), [])
    }

    func testStatusFilters() {
        XCTAssertEqual(apply("", .running), ["a"])
        XCTAssertEqual(apply("", .attention), ["b", "c"])
        XCTAssertEqual(apply("harness", .attention), ["c"])
    }
}
