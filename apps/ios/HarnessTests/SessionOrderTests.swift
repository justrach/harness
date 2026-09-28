import XCTest
@testable import Harness

final class SessionOrderTests: XCTestCase {
    private func chat(_ id: String, prompt: Int64?, message: Int64?, created: Int64 = 0) -> Chat {
        Chat(id: id, deviceId: "d", title: id, archived: false, cwd: nil, branch: nil, checkoutId: nil,
             config: nil, lastMessagePreview: nil, lastMessageAt: message, createdAt: created,
             spaceId: nil, lastSeenAt: nil, lastPromptAt: prompt)
    }

    func testOrdersByWhenYouLastCalledTheSessionNotByAgentReplies() {
        // "busy" was called long ago but its agent keeps replying; "fresh" was
        // called just now and hasn't answered yet.
        let busy = chat("busy", prompt: 1_000, message: 9_000)
        let fresh = chat("fresh", prompt: 5_000, message: 5_000)
        let quiet = chat("quiet", prompt: 3_000, message: 3_500)
        XCTAssertEqual(sortActive([busy, quiet, fresh]).map(\.id), ["fresh", "quiet", "busy"])
    }

    func testFallsBackForHostsWithoutThePromptStamp() {
        let old = chat("old-host", prompt: nil, message: 4_000)
        let new = chat("new-host", prompt: 3_000, message: 8_000)
        let untouched = chat("untouched", prompt: nil, message: nil, created: 3_500)
        XCTAssertEqual(sortActive([new, untouched, old]).map(\.id), ["old-host", "untouched", "new-host"])
    }

    func testPinsStayFirstInTheirOwnOrder() {
        let a = chat("a", prompt: 1, message: 1)
        let b = chat("b", prompt: 9, message: 9)
        let c = chat("c", prompt: 5, message: 5)
        XCTAssertEqual(sortPinnedFirst([a, b, c], pinnedSessionIds: ["a"]).map(\.id), ["a", "b", "c"])
    }
}
