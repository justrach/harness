// The Apple Watch ↔ iPhone contract (#322): the shapes both ends read, how a
// dictation joins a chat, and that each one is delivered once.

import XCTest
@testable import Harness

final class WatchLinkTests: XCTestCase {
    func testADictationRoundTripsThroughAPropertyList() throws {
        let dictation = WatchLink.Dictation(id: "d1", chatId: "c1", text: "Check the retry path", mode: .now,
                                            createdAt: 42)
        let message = WatchLink.message(.dictation, dictation)
        // WatchConnectivity only carries property lists.
        XCTAssertTrue(PropertyListSerialization.propertyList(message, isValidFor: .binary))
        XCTAssertEqual(WatchLink.kind(of: message), .dictation)
        XCTAssertEqual(WatchLink.body(WatchLink.Dictation.self, of: message, as: .dictation), dictation)
        XCTAssertNil(WatchLink.body(WatchLink.Context.self, of: message, as: .context), "a body is read as its own kind only")
        XCTAssertEqual(WatchLink.kind(of: WatchLink.hello()), .hello)
        XCTAssertNil(WatchLink.kind(of: ["kind": "something-newer"]))
    }

    func testAChatAtRestStartsATurnAndABusyOneQueuesOrSteers() {
        XCTAssertEqual(WatchLink.delivery(mode: .queue, runLive: false, canQueue: true), .run)
        XCTAssertEqual(WatchLink.delivery(mode: .now, runLive: false, canQueue: true), .run)
        XCTAssertEqual(WatchLink.delivery(mode: .queue, runLive: true, canQueue: true), .enqueue)
        XCTAssertEqual(WatchLink.delivery(mode: .now, runLive: true, canQueue: true), .steer)
        XCTAssertEqual(WatchLink.delivery(mode: .queue, runLive: true, canQueue: false), .steer,
                       "a host without the queue still gets the words")
    }

    func testOnlyWordsAreSent() {
        XCTAssertEqual(WatchLink.cleaned("  Ship it \n"), "Ship it")
        XCTAssertNil(WatchLink.cleaned(" \n\t "))
    }

    func testEachIdIsTakenOnce() {
        var seen = WatchLink.SeenIds()
        XCTAssertTrue(seen.insert("a"))
        XCTAssertFalse(seen.insert("a"), "the same dictation as a message and then as user info")
        for i in 0..<WatchLink.SeenIds.limit { _ = seen.insert("x\(i)") }
        XCTAssertEqual(seen.ids.count, WatchLink.SeenIds.limit)
        XCTAssertTrue(seen.insert("a"), "the oldest ids age out")
    }

    func testTheWatchListsTheMostRecentlyCalledChats() {
        let chats = (0..<12).map {
            WatchLink.ChatSummary(id: "c\($0)", title: "Chat \($0)", status: .idle, calledAt: Int64($0))
        }
        let recent = WatchLink.recent(chats.shuffled())
        XCTAssertEqual(recent.count, WatchLink.recentLimit)
        XCTAssertEqual(recent.first?.id, "c11")
        XCTAssertEqual(recent.last?.id, "c4")
    }

    func testReceiptsReplaceByIdAndStayBounded() {
        var receipts: [WatchLink.Receipt] = []
        receipts = WatchLink.merged(receipts, adding: .init(id: "a", state: .failed, chatId: nil, detail: "x"))
        receipts = WatchLink.merged(receipts, adding: .init(id: "a", state: .delivered, chatId: "c", detail: nil))
        XCTAssertEqual(receipts, [.init(id: "a", state: .delivered, chatId: "c", detail: nil)])
        for i in 0..<(WatchLink.receiptLimit + 5) {
            receipts = WatchLink.merged(receipts, adding: .init(id: "r\(i)", state: .delivered, chatId: nil, detail: nil))
        }
        XCTAssertEqual(receipts.count, WatchLink.receiptLimit)
        XCTAssertEqual(receipts.last?.id, "r\(WatchLink.receiptLimit + 4)")
    }

    func testReceiptsSettleTheWatchsSentRowsAndNeverUndoADelivery() {
        let sent = [
            WatchLink.Sent(id: "a", text: "one", chatTitle: "T", state: .waiting, createdAt: 1),
            WatchLink.Sent(id: "b", text: "two", chatTitle: "T", state: .waiting, createdAt: 2),
            WatchLink.Sent(id: "c", text: "three", chatTitle: "T", state: .delivered, createdAt: 3),
        ]
        let receipts: [WatchLink.Receipt] = [
            .init(id: "a", state: .delivered, chatId: "x", detail: nil),
            .init(id: "b", state: .failed, chatId: nil, detail: "None of your computers is online to start a chat."),
            .init(id: "c", state: .failed, chatId: nil, detail: "late"),
        ]
        let settled = WatchLink.applying(receipts, to: sent)
        XCTAssertEqual(settled.map(\.state), [
            .delivered, .failed("None of your computers is online to start a chat."), .delivered,
        ])
    }

    func testChatStatusesReadAsTheWatchShowsThem() {
        XCTAssertEqual(WatchBridge.status(.working), .working)
        XCTAssertEqual(WatchBridge.status(.awaitingInput), .needsInput)
        XCTAssertEqual(WatchBridge.status(.errored), .failed)
        XCTAssertEqual(WatchBridge.status(.completed), .idle)
        XCTAssertEqual(WatchBridge.status(.idle), .idle)
    }

    @MainActor
    func testTheBridgeTakesEachDictationOnce() {
        let bridge = WatchBridge.shared
        let dictation = WatchLink.Dictation(id: "once-\(UUID().uuidString)", chatId: nil, text: "hi", mode: .queue,
                                            createdAt: 1)
        XCTAssertTrue(bridge.receive(.dictation(dictation)))
        XCTAssertFalse(bridge.receive(.dictation(dictation)))
    }
}
