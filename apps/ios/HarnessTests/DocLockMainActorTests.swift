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
