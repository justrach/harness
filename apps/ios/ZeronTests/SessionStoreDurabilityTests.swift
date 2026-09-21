import Loro
import XCTest
@testable import Zeron

@MainActor
final class SessionStoreDurabilityTests: XCTestCase {
    private func config() -> AppConfig {
        AppConfig(edgeURL: URL(string: "http://localhost:1")!, mode: .dev,
                  userId: "u", orgId: "o", deviceId: "phone",
                  deviceName: "phone", tokens: nil, devBearer: "u@o")
    }

    func testCommitNowSavesImmediatelyAndNotifies() {
        var saves = 0
        var callbacks = 0
        let saver = DocSaver {
            saves += 1
            return true
        }
        saver.onSaved = { callbacks += 1 }
        saver.poke()

        XCTAssertTrue(saver.commitNow())
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertFalse(saver.isDirty)
    }

    func testFailedCommitStaysDirtyAndLaterFlushNotifies() {
        var shouldSucceed = false
        var callbacks = 0
        let saver = DocSaver { shouldSucceed }
        saver.onSaved = { callbacks += 1 }
        saver.poke()

        XCTAssertFalse(saver.commitNow())
        XCTAssertTrue(saver.isDirty)
        XCTAssertEqual(callbacks, 0)

        shouldSucceed = true
        saver.flush()
        XCTAssertFalse(saver.isDirty)
        XCTAssertEqual(callbacks, 1)
    }

    func testCommitAsyncWritesAndNotifies() async {
        var callbacks = 0
        var written: Data?
        let saver = DocSaver { true }
        saver.onSaved = { callbacks += 1 }
        saver.poke()

        let result = await saver.commitAsync(
            export: { Data([1, 2, 3]) },
            write: { data in
                written = data
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(written, Data([1, 2, 3]))
        XCTAssertFalse(saver.isDirty)
        XCTAssertEqual(callbacks, 1)
    }

    func testCommitAsyncDropsStaleExport() async {
        var writes = 0
        let saver = DocSaver { true }
        saver.poke()

        let result = await saver.commitAsync(
            export: {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        saver.poke()
                    }
                }
                return Data([4, 5, 6])
            },
            write: { _ in
                writes += 1
                return true
            }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(saver.isDirty)
    }

    func testCommitAsyncRetiresDebounceWhileExporting() async {
        let started = expectation(description: "detached export started")
        let gate = DispatchSemaphore(value: 0)
        var saves = 0
        var wrote = false
        let saver = DocSaver {
            saves += 1
            return true
        }
        saver.poke()

        let task = Task { @MainActor in
            await saver.commitAsync(
                export: {
                    started.fulfill()
                    gate.wait()
                    return Data([7])
                },
                write: { _ in
                    wrote = true
                    return true
                }
            )
        }

        await fulfillment(of: [started], timeout: 1)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(saves, 0)
        XCTAssertFalse(wrote)

        gate.signal()
        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertTrue(wrote)
        XCTAssertFalse(saver.isDirty)
    }

    func testRetireTimersLeavesDirtyAndCancelsDebounce() async {
        var saves = 0
        let saver = DocSaver {
            saves += 1
            return true
        }
        saver.poke()
        saver.retireTimers()

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(saver.isDirty)
        XCTAssertEqual(saves, 0)
    }

    func testCommitAsyncRetiresRetryWhileExporting() async {
        let started = expectation(description: "detached export started")
        let gate = DispatchSemaphore(value: 0)
        var saves = 0
        var shouldSucceed = false
        var wrote = false
        let saver = DocSaver {
            saves += 1
            return shouldSucceed
        }
        saver.poke()
        XCTAssertFalse(saver.commitNow())
        XCTAssertEqual(saves, 1)

        let task = Task { @MainActor in
            await saver.commitAsync(
                export: {
                    started.fulfill()
                    gate.wait()
                    return Data([8])
                },
                write: { _ in
                    wrote = true
                    return true
                }
            )
        }

        await fulfillment(of: [started], timeout: 1)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(wrote)

        shouldSucceed = true
        gate.signal()
        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertTrue(wrote)
        XCTAssertFalse(saver.isDirty)
    }

    func testAsyncFlushesRetireBothTimers() async {
        let started = expectation(description: "first detached export started")
        let gate = DispatchSemaphore(value: 0)
        var aSaves = 0
        var bSaves = 0
        var aWrote = false
        var bWrote = false
        let a = DocSaver {
            aSaves += 1
            return true
        }
        let b = DocSaver {
            bSaves += 1
            return true
        }
        a.poke()
        b.poke()
        a.retireTimers()
        b.retireTimers()

        let task = Task { @MainActor in
            _ = await a.commitAsync(
                export: {
                    started.fulfill()
                    gate.wait()
                    return Data([9])
                },
                write: { _ in
                    aWrote = true
                    return true
                }
            )
            _ = await b.commitAsync(
                export: { Data([10]) },
                write: { _ in
                    bWrote = true
                    return true
                }
            )
        }

        await fulfillment(of: [started], timeout: 1)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(aSaves, 0)
        XCTAssertEqual(bSaves, 0)

        gate.signal()
        await task.value
        XCTAssertTrue(aWrote)
        XCTAssertTrue(bWrote)
        XCTAssertFalse(a.isDirty)
        XCTAssertFalse(b.isDirty)
    }

    func testCommitAsyncDropsExportAfterNewPoke() async {
        let started = expectation(description: "detached export started")
        let gate = DispatchSemaphore(value: 0)
        var wrote = false
        let saver = DocSaver { true }
        saver.poke()

        let task = Task { @MainActor in
            await saver.commitAsync(
                export: {
                    started.fulfill()
                    gate.wait()
                    return Data([11])
                },
                write: { _ in
                    wrote = true
                    return true
                }
            )
        }

        await fulfillment(of: [started], timeout: 1)
        saver.poke()
        gate.signal()

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertFalse(wrote)
        XCTAssertTrue(saver.isDirty)
    }

    func testRealStoreAsyncFlushPersistsOutbox() async throws {
        let id = "async-flush-\(UUID().uuidString)"
        let url = DocDisk.chat2URL(for: id)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let store = SessionStore(chatId: id, config: config())
        defer { store.stop() }
        store.start(holdDial: true)
        let baseline = store.outbox.count

        try store.doc.getMap(id: "test").insert(key: "value", v: "async")
        store.doc.commit()

        for _ in 0..<20 {
            await Task.yield()
            if store.outbox.count > baseline { break }
        }
        XCTAssertEqual(store.outbox.count, baseline + 1)

        await store.flushToDiskAsync()

        let loaded = try XCTUnwrap(DocDisk.loadChat2(into: LoroDoc(), id: id))
        XCTAssertEqual(loaded.outbox.map(\.batchId), store.outbox.map(\.batchId))
    }

    func testLocalCommitIsOnDiskBeforeAdmission() async throws {
        let id = "durable-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: DocDisk.chat2URL(for: id)) }
        let store = SessionStore(chatId: id, config: config())
        store.start()
        store.updateRoomGen(2)
        let baseline = Set(store.outbox.map(\.batchId))

        try store.doc.getMap(id: "test").insert(key: "value", v: "durable")
        store.doc.commit()

        var newBatchIDs: Set<String> = []
        for _ in 0..<20 {
            await Task.yield()
            newBatchIDs = Set(store.outbox.map(\.batchId)).subtracting(baseline)
            if !newBatchIDs.isEmpty { break }
        }
        XCTAssertEqual(newBatchIDs.count, 1)
        let loaded = try XCTUnwrap(DocDisk.loadChat2(into: LoroDoc(), id: id))
        XCTAssertTrue(newBatchIDs.isSubset(of: Set(loaded.outbox.map(\.batchId))))
        XCTAssertTrue(newBatchIDs.isSubset(of: store.admittedBatchIDs))
        store.stop()
    }

    func testFailedWriteBlocksAdmissionUntilRetrySucceeds() async throws {
        let id = "durable-retry-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeron-durable-retry-\(UUID().uuidString)")
        let blocker = root.appendingPathComponent("blocker")
        let destination = blocker.appendingPathComponent("dir")
        let restoredDirectory = root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocker)
        defer {
            DocDisk.directoryOverride = nil
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: DocDisk.chat2URL(for: id))
        }
        DocDisk.directoryOverride = destination
        XCTAssertFalse(DocDisk.saveChat2(doc: LoroDoc(), id: "probe-\(id)", cursor: 0, verified: false))

        let store = SessionStore(chatId: id, config: config())
        store.start()
        store.updateRoomGen(2)
        let baselineCount = store.outbox.count
        try store.doc.getMap(id: "test").insert(key: "value", v: "retry")
        store.doc.commit()

        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.outbox.count, baselineCount + 1)
        XCTAssertTrue(store.admittedBatchIDs.isEmpty)

        DocDisk.directoryOverride = restoredDirectory
        for _ in 0..<35 {
            if !store.admittedBatchIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.admittedBatchIDs, Set(store.outbox.map(\.batchId)))
        let loaded = try XCTUnwrap(DocDisk.loadChat2(into: LoroDoc(), id: id))
        XCTAssertEqual(loaded.outbox.map(\.batchId), store.outbox.map(\.batchId))
        store.stop()
    }
}
