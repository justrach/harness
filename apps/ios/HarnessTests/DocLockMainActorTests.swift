import XCTest
import Loro
@testable import Harness

/// A slow import holds the doc's lock, so a main-actor call into the same doc
/// waits for it however far off the main thread the import runs. Build 63's
/// 0x8BADF00D: the main thread stuck in `containsFrontier` -> `oplogVv` while a
/// Task.detached import rebuilt a long text (`build_full_crdt_tracker`).
final class DocLockMainActorTests: XCTestCase {
    /// A phone doc holding `ops` scattered edits, one op of its own the host
    /// never saw, and the row whose import makes Loro rebuild the whole text.
    private func slowImportFixture(ops: Int = 2_000_000) throws -> (phone: LoroDoc, row: Data, frontier: Data) {
        let host = LoroDoc()
        try host.setPeerId(peer: 1)
        let phone = LoroDoc()
        try phone.setPeerId(peer: 2)
        try phone.getList(id: "commands").push(v: "steer")
        phone.commit()
        let text = host.getText(id: "reply")
        var seed: UInt32 = 12345
        for n in 0..<ops {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            try text.insert(pos: seed % (UInt32(n) + 1), s: "x")
            if n % 64 == 0 { host.commit() }
        }
        host.commit()
        _ = try phone.importWith(bytes: host.export(mode: .updates(from: VersionVector())), origin: "remote")
        let before = host.oplogVv()
        try text.pushStr(s: "tail")
        host.commit()
        return (phone, try host.export(mode: .updates(from: before)), host.oplogVv().encode())
    }

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private func config() -> AppConfig {
        AppConfig(edgeURL: URL(string: "http://localhost:1")!, mode: .dev,
                  userId: "u", orgId: "o", deviceId: "phone",
                  deviceName: "phone", tokens: nil, devBearer: "u@o")
    }

    /// The main actor's longest wait while `body` runs: a 10 ms heartbeat that
    /// can only tick when the main actor is free.
    @MainActor
    private func longestGap(during body: () async throws -> Void) async rethrows -> Double {
        var last = now()
        var longest = 0.0
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let tick = now()
                longest = max(longest, tick - last)
                last = tick
            }
        }
        // Let the heartbeat start before the body can hold the main actor.
        try? await Task.sleep(for: .milliseconds(30))
        try await body()
        try? await Task.sleep(for: .milliseconds(30))
        beat.cancel()
        return longest
    }

    /// A store on a long chat, an import of `row` under way that holds its doc.
    @MainActor
    private func storeOnALongChat(_ doc: LoroDoc) throws -> SessionStore {
        let id = "doc-lock-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(at: DocDisk.chat2URL(for: id)) }
        let store = SessionStore(chatId: id, config: config())
        _ = try store.doc.importWith(bytes: doc.export(mode: .updates(from: VersionVector())), origin: "remote")
        store.start(holdDial: true)
        return store
    }

    /// Sending while a reply streams in: the import holds the doc, and neither
    /// the send nor the send-state read the view makes may wait for it. The send
    /// still lands, and on disk, once the doc is free.
    @MainActor
    func testSendingLeavesTheMainActorFreeDuringASlowImport() async throws {
        let (doc, row, _) = try slowImportFixture()
        let store = try storeOnALongChat(doc)
        defer { store.stop() }
        var lasted = 0.0
        let longest = await longestGap {
            let started = now()
            let importing = Task { @MainActor in _ = await store.importRemote(row) }
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(store.docIsBusy, "the import must be under way for this to mean anything")
            store.sendSteer(prompt: "sent while a reply streams")
            XCTAssertEqual(store.undeliverableSends(now: nowMs()), [], "the send has not failed")
            await importing.value
            lasted = now() - started
            for _ in 0..<3000 {
                if !store.docIsBusy, !store.outbox.isEmpty, DocDisk.chat2HasPendingOutbox(id: store.chatId) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        print("send during import: longest main-actor gap \(longest)s of an import lasting \(lasted)s")
        XCTAssertGreaterThan(lasted, 0.5, "the import must be slow for this to mean anything")
        XCTAssertLessThan(longest * 5, lasted, "the main actor waited for the import")
        let check = LoroDoc()
        let loaded = try XCTUnwrap(DocDisk.loadChat2(into: check, id: store.chatId))
        XCTAssertEqual(loaded.outbox.map(\.batchId), store.outbox.map(\.batchId))
        XCTAssertFalse(loaded.outbox.isEmpty, "the command's batch is on disk")
        let saidPrompt = (check.getList(id: "commands").getDeepValue().listValue ?? []).contains {
            $0.mapValue?["payload"]?.mapValue?["prompt"]?.stringValue == "sent while a reply streams"
        }
        XCTAssertTrue(saidPrompt, "the command is in the saved doc")
    }

    /// Each row from the room dirties the saver again, and on a long chat that
    /// happens before an export can finish, so the saver is never clean while a
    /// reply streams. A send must still reach the room, and only once it is saved.
    @MainActor
    func testASendReachesTheRoomWhileRowsKeepArriving() async throws {
        let (doc, _, _) = try slowImportFixture()
        let id = "doc-lock-admit-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: DocDisk.chat2URL(for: id)) }
        let rows = (0..<600).map { (batchId: "row-\($0)", bytes: Data([1])) }
        XCTAssertTrue(DocDisk.saveChat2(doc: LoroDoc(), id: id, cursor: 7, verified: true, outbox: rows))
        let store = SessionStore(chatId: id, config: config())
        _ = try store.doc.importWith(bytes: doc.export(mode: .updates(from: VersionVector())), origin: "remote")
        store.start()
        store.updateRoomGen(2)
        defer { store.stop() }
        let baseline = Set(store.outbox.map(\.batchId))
        store.sendSteer(prompt: "sent while a reply streams")
        var sent: Set<String> = []
        for row in rows {
            // Retiring a batch pokes the saver, as a row from the room does.
            store.retirePush(batchId: row.batchId)
            try await Task.sleep(for: .milliseconds(5))
            sent = Set(store.outbox.map(\.batchId)).subtracting(baseline)
            if !sent.isEmpty, sent.isSubset(of: store.admittedBatchIDs) { break }
        }
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent.isSubset(of: store.admittedBatchIDs), "the send waited for a quiet room")
        let loaded = try XCTUnwrap(DocDisk.loadChat2(into: LoroDoc(), id: id))
        XCTAssertTrue(sent.isSubset(of: Set(loaded.outbox.map(\.batchId))), "admitted before it was saved")
    }

    /// Queueing a message, moving it and taking one out, all during that import:
    /// the queue shows each at once, and the doc agrees once it is free.
    @MainActor
    func testTheQueueLeavesTheMainActorFreeDuringASlowImport() async throws {
        let (doc, row, _) = try slowImportFixture()
        let store = try storeOnALongChat(doc)
        defer { store.stop() }
        store.enqueueMessage(text: "first")
        store.enqueueMessage(text: "gone")
        store.refreshQueue()
        var lasted = 0.0
        let longest = await longestGap {
            let started = now()
            let importing = Task { @MainActor in _ = await store.importRemote(row) }
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(store.docIsBusy, "the import must be under way for this to mean anything")
            let added = store.enqueueMessage(text: "second")
            XCTAssertNotNil(added)
            XCTAssertEqual(store.queue.map(\.text), ["first", "gone", "second"])
            store.moveQueued(id: try! XCTUnwrap(added), to: 0)
            XCTAssertEqual(store.queue.map(\.text), ["second", "first", "gone"])
            let goneId = store.queue[2].id
            let removed = await store.performQueueAction(id: goneId, action: .remove) { _, _ in
                QueueActionReply(removed: true)
            }
            XCTAssertTrue(removed)
            XCTAssertEqual(store.queue.map(\.text), ["second", "first"])
            await importing.value
            lasted = now() - started
            for _ in 0..<3000 where store.docIsBusy { try? await Task.sleep(for: .milliseconds(10)) }
        }
        print("queue during import: longest main-actor gap \(longest)s of an import lasting \(lasted)s")
        XCTAssertGreaterThan(lasted, 0.5, "the import must be slow for this to mean anything")
        XCTAssertLessThan(longest * 5, lasted, "the main actor waited for the import")
        store.refreshQueue()
        XCTAssertEqual(store.queue.map(\.text), ["second", "first"])
    }

    /// Launch preloads up to a dozen chats on the main actor. Attaching the
    /// projection's subscriber before the load made Loro build an event for the
    /// chat's whole history there, which grows much faster than the chat does.
    @MainActor
    func testOpeningALongChatLeavesTheMainActorFree() async throws {
        let (doc, _, _) = try slowImportFixture(ops: 150_000)
        let id = "doc-lock-open-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: DocDisk.chat2URL(for: id)) }
        XCTAssertTrue(DocDisk.saveChat2(doc: doc, id: id, cursor: 7, verified: true))
        let store = SessionStore(chatId: id, config: config())
        defer { store.stop() }
        let longest = await longestGap {
            store.start(holdDial: true)
            for _ in 0..<300 where store.docIsBusy { try? await Task.sleep(for: .milliseconds(10)) }
        }
        print("open a long chat: longest main-actor gap \(longest)s")
        XCTAssertGreaterThan(store.snapshotBytes, 0, "the chat loaded")
        XCTAssertLessThan(longest, 0.25, "the main actor did the work of opening the chat")
    }

    /// What was typed into the chat after it was opened still reaches the
    /// projection: loading ahead of the subscriber loses no change after it.
    @MainActor
    func testAChatOpenedFromDiskStillProjectsLaterChanges() async throws {
        let id = "doc-lock-project-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: DocDisk.chat2URL(for: id)) }
        let host = LoroDoc()
        try host.setPeerId(peer: 1)
        let messages = host.getList(id: "messages")
        let map = try messages.pushContainer(child: LoroMap())
        try map.insert(key: "id", v: "m1")
        try map.insert(key: "role", v: "assistant")
        let parts = try map.insertContainer(key: "parts", child: LoroList())
        let part = try parts.pushContainer(child: LoroMap())
        try part.insert(key: "id", v: "p1")
        try part.insert(key: "kind", v: "text")
        try part.insert(key: "text", v: "before")
        host.commit()
        XCTAssertTrue(DocDisk.saveChat2(doc: host, id: id, cursor: 7, verified: true))
        let saved = host.oplogVv()
        let store = SessionStore(chatId: id, config: config())
        store.attachView()
        store.start(holdDial: true)
        defer { store.stop() }
        let text = { () -> String? in
            guard case .text(_, let text)? = store.entries.first?.parts.first else { return nil }
            return text
        }
        for _ in 0..<300 where text() != "before" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(text(), "before")
        try part.insert(key: "text", v: "after")
        host.commit()
        _ = await store.importRemote(try host.export(mode: .updates(from: saved)))
        store.project()
        for _ in 0..<300 where text() != "after" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(text(), "after", "the memo missed a change")
    }

    /// While a slow import holds the doc, checking a frontier must leave the
    /// main actor free: it answers a heartbeat throughout.
    @MainActor
    func testCheckingAFrontierLeavesTheMainActorFreeDuringASlowImport() async throws {
        let (doc, row, frontier) = try slowImportFixture()
        let started = now()
        let importing = Task.detached(priority: .userInitiated) { () -> Double in
            _ = try? doc.importWith(bytes: row, origin: "remote")
            return Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        }
        var last = now()
        var longest = 0.0
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let tick = now()
                longest = max(longest, tick - last)
                last = tick
            }
        }
        // Let the import take the doc's lock.
        try await Task.sleep(for: .milliseconds(100))
        let contained = await SessionStore.frontierContained(frontier, in: doc)
        let ended = await importing.value
        try await Task.sleep(for: .milliseconds(30))
        beat.cancel()
        let lasted = ended - started
        print("frontier check: longest main-actor gap \(longest)s of an import lasting \(lasted)s")
        XCTAssertGreaterThan(lasted, 0.5, "the import must be slow for this to mean anything")
        XCTAssertLessThan(longest * 5, lasted, "the main actor waited for the import")
        XCTAssertTrue(contained, "the check runs once the import has landed the frontier")
    }
}
