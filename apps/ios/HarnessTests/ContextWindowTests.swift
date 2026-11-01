import XCTest
import Loro
@testable import Harness

/// The context ring's card: the reported total split across what fills it. Ports the desktop's
/// `context_window` tests; parts go through the sync decoder, so `outputBytes` and the compaction record on the
/// chip's input are covered too.
@MainActor
final class ContextWindowTests: XCTestCase {
    private typealias Slot = ContextWindow.Slot

    private func entry(_ role: MessageRole, _ parts: [[String: Any]]) -> MessageEntry {
        MessageEntry(id: "m", role: role, parts: parts.map { SessionStore.partFrom(.fromJSON($0))! },
                     createdAt: 0, deviceId: "d")
    }

    private func text(_ n: Int) -> [String: Any] {
        ["id": "t", "kind": "text", "text": String(repeating: "x", count: n)]
    }

    private func tool(_ call: [String: Any], bytes: Int, resolved: Bool = true) -> [String: Any] {
        var json: [String: Any] = ["id": "tool", "kind": "tool", "call": call, "outputBytes": bytes]
        if resolved { json["isError"] = false }
        return json
    }

    private func compaction(bytes: Int, resolved: Bool) -> [String: Any] {
        tool(["kind": "unknown", "name": "Compact context"], bytes: bytes, resolved: resolved)
    }

    private func sealed(before: Int, after: Int, item: Int? = nil, resolved: Bool) -> [String: Any] {
        var input: [String: Any] = ["kind": "opaque", "tokensBefore": before]
        if resolved { input["tokensAfter"] = after }
        if let item { input["itemTokens"] = item }
        return tool(["kind": "unknown", "name": "Compact context", "input": input], bytes: 0, resolved: resolved)
    }

    private func usage(_ tokens: Int, freed: Int = 0) -> ContextUsage {
        ContextUsage(tokens: tokens, window: 200_000, savings: ContextSavings(compactedTokens: freed))
    }

    private func items(_ b: ContextWindow.Breakdown) -> [String] { b.items.map { "\($0.0):\($0.1)" } }

    func testTheMeterIsReadFromTheDocsMeta() throws {
        let doc = LoroDoc()
        XCTAssertNil(SessionStore.contextUsage(from: doc))
        try doc.getMap(id: "meta").insert(
            key: "contextUsage",
            v: #"{"tokens":150000,"window":200000,"savings":{"handleBytes":4000,"compactedTokens":10}}"#)
        let usage = try XCTUnwrap(SessionStore.contextUsage(from: doc))
        XCTAssertEqual(usage.tokens, 150_000)
        XCTAssertEqual(usage.window, 200_000)
        XCTAssertEqual(usage.fraction, 0.75)
        XCTAssertEqual(usage.savings, ContextSavings(handleBytes: 4_000, compactedTokens: 10))
        XCTAssertEqual(usage.savings?.keptOutTokens, 1_010)
    }

    func testItNeedsAReportedWindow() {
        XCTAssertNil(ContextWindow.breakdown(usage: nil, transcript: []))
        XCTAssertNil(ContextWindow.breakdown(usage: ContextUsage(tokens: 10, window: 0), transcript: []))
        XCTAssertFalse(ContextUsage(tokens: 10).hasWindow)
    }

    func testFoldedToolOutputCountsWhereItBelongs() {
        let transcript = [entry(.assistant, [tool(["kind": "exec", "command": "cargo test"], bytes: 40_000)])]
        let b = ContextWindow.breakdown(usage: usage(50_000), transcript: transcript)!
        XCTAssertTrue(items(b).contains("commands:10000"), "\(items(b))")
    }

    func testItSplitsTheTranscriptAndKeepsTheReportedTotal() {
        let transcript = [
            entry(.user, [text(4_000)]),
            entry(.assistant, [
                text(4_000),
                tool(["kind": "readFile", "path": "a"], bytes: 40_000),
                tool(["kind": "exec", "command": "ls"], bytes: 8_000),
            ]),
        ]
        let b = ContextWindow.breakdown(usage: usage(30_000), transcript: transcript)!
        XCTAssertEqual(items(b), ["history:2000", "files:10000", "commands:2000", "system:16000"])
        XCTAssertEqual(b.items.reduce(0) { $0 + $1.1 }, 30_000)
        XCTAssertFalse(b.compacted || b.compacting)
        XCTAssertEqual(ContextWindow.statusLine(b), "170k free of 200k")
    }

    func testAnEstimateOverTheMeterIsScaledIntoIt() {
        let transcript = [entry(.assistant, [text(40_000), tool(["kind": "readFile", "path": "a"], bytes: 40_000)])]
        let b = ContextWindow.breakdown(usage: usage(10_000), transcript: transcript)!
        XCTAssertEqual(items(b), ["history:5000", "files:5000"])
    }

    func testCompactionReplacesOlderChatWithItsSummary() {
        var transcript = [
            entry(.user, [text(160_000)]),
            entry(.assistant, [tool(["kind": "readFile", "path": "a"], bytes: 80_000)]),
            entry(.assistant, [compaction(bytes: 0, resolved: false)]),
        ]
        let running = ContextWindow.breakdown(usage: usage(90_000), transcript: transcript)!
        XCTAssertTrue(running.compacting && !running.compacted)
        XCTAssertEqual(items(running).first, "history:40000")
        XCTAssertEqual(ContextWindow.statusLine(running), "Summarizing older chat to free up space")

        transcript[2] = entry(.assistant, [compaction(bytes: 16_000, resolved: true)])
        transcript.append(entry(.user, [text(400)]))
        let done = ContextWindow.breakdown(usage: usage(20_000, freed: 70_000), transcript: transcript)!
        XCTAssertTrue(done.compacted && !done.compacting)
        XCTAssertEqual(items(done), ["history:4000", "recent:100", "system:15900"])
        XCTAssertEqual(done.history, .summary)
        XCTAssertEqual(Slot.history.label(done.history), "Chat summary")
        XCTAssertEqual(ContextWindow.statusLine(done), "Older chat summarized, 70k freed so far")
    }

    func testAnOpaqueCompactionIsASealedBlockSizedWithoutContents() {
        var transcript = [
            entry(.user, [text(40_000)]),
            entry(.assistant, [tool(["kind": "readFile", "path": "a"], bytes: 40_000)]),
            entry(.assistant, [sealed(before: 50_000, after: 0, resolved: false)]),
        ]
        let running = ContextWindow.breakdown(usage: usage(50_000), transcript: transcript)!
        XCTAssertTrue(running.compacting && running.pending == .sealed)
        XCTAssertEqual(ContextWindow.statusLine(running), "Compacting older chat into a sealed item")

        // 20k of the 50k came from the transcript, so 30k is system share; 34k after the compaction leaves
        // ~4k for the sealed item.
        transcript[2] = entry(.assistant, [sealed(before: 50_000, after: 34_000, resolved: true)])
        transcript.append(entry(.user, [text(400)]))
        let done = ContextWindow.breakdown(usage: usage(34_100), transcript: transcript)!
        XCTAssertEqual(done.history, .sealed)
        XCTAssertTrue(done.sealedEstimated && !done.compacting)
        XCTAssertEqual(items(done), ["history:4000", "recent:100", "system:30000"])
        XCTAssertEqual(Slot.history.label(done.history), "Compacted context")
        XCTAssertEqual(done.freed, 16_000)
        XCTAssertEqual(ContextWindow.statusLine(done), "Older chat sealed, 16k freed so far")

        // A size the agent reports wins over the estimate.
        transcript[2] = entry(.assistant, [sealed(before: 50_000, after: 34_000, item: 2_500, resolved: true)])
        let reported = ContextWindow.breakdown(usage: usage(34_100), transcript: transcript)!
        XCTAssertFalse(reported.sealedEstimated)
        XCTAssertEqual(items(reported).first, "history:2500")
    }

    func testALaterSummaryReplacesAnEarlierSealedBlock() {
        let transcript = [
            entry(.user, [text(8_000)]),
            entry(.assistant, [sealed(before: 10_000, after: 6_000, item: 1_000, resolved: true)]),
            entry(.user, [text(8_000)]),
            entry(.assistant, [compaction(bytes: 2_000, resolved: true)]),
        ]
        let b = ContextWindow.breakdown(usage: usage(5_000), transcript: transcript)!
        XCTAssertEqual(b.history, .summary)
        XCTAssertEqual(items(b), ["history:500", "system:4500"])
        XCTAssertEqual(b.freed, 4_000)
    }

    func testSegmentsNeverOverflowAndSmallSlotsStayVisible() {
        let full = ContextWindow.Breakdown(tokens: 200_000, window: 200_000,
                                           items: [(.history, 199_900), (.files, 100)])
        XCTAssertEqual(ContextWindow.segmentCounts(full).reduce(0) { $0 + $1.1 }, ContextWindow.segments)
        let small = ContextWindow.Breakdown(tokens: 100, window: 200_000, items: [(.files, 100)])
        let counts = ContextWindow.segmentCounts(small)
        XCTAssertEqual(counts.map(\.0), [.files])
        XCTAssertEqual(counts.map(\.1), [1])
    }

    func testSavedSegmentsSplitTheMeterAndLeaveTheCacheOut() {
        let savings = ContextSavings(handleBytes: 100_000, compactedTokens: 77_000, cacheReadTokens: 40_000)
        // Cache reads were in the context, only cheaper: not saved.
        XCTAssertEqual(savings.keptOutTokens, 102_000)
        let parts = ContextWindow.savedSegments([(.inContext, 51_000), (.files, savings.handleTokens),
                                                 (.compaction, savings.compactedTokens)])
        XCTAssertEqual(parts.map(\.part), [.inContext, .files, .compaction])
        XCTAssertEqual(parts.map(\.count), [21, 10, 31])
        // A tiny part still shows, and empty parts drop out.
        let tiny = ContextWindow.savedSegments([(.inContext, 1_000_000), (.files, 10), (.compaction, 0)])
        XCTAssertEqual(tiny.count, 2)
        XCTAssertEqual(tiny[1].count, 1)
        XCTAssertEqual(tiny.reduce(0) { $0 + $1.count }, ContextWindow.segments)
        XCTAssertTrue(ContextWindow.savedSegments([(.inContext, 0), (.files, 0), (.compaction, 0)]).isEmpty)
    }

    func testCountsReadLikeTheDesktop() {
        XCTAssertEqual(ContextWindow.compactCount(999), "999")
        XCTAssertEqual(ContextWindow.compactCount(1_200), "1.2k")
        XCTAssertEqual(ContextWindow.compactCount(34_567), "34k")
        XCTAssertEqual(ContextWindow.compactCount(1_500_000), "1.5M")
        XCTAssertEqual(ContextWindow.withSeparators(1_234_567), "1,234,567")
        XCTAssertEqual(ContextWindow.details(ContextUsage(tokens: 150_000, window: 200_000)),
                       "150,000 / 200,000 tokens\n50,000 tokens remaining")
        XCTAssertEqual(ContextWindow.details(nil), "Context usage not reported by this harness yet")
    }

    func testTheRingWarnsAsTheWindowFills() {
        XCTAssertEqual(ContextRing.color(0.5), Theme.textMuted)
        XCTAssertEqual(ContextRing.color(0.75), Theme.warning)
        XCTAssertEqual(ContextRing.color(0.95), Theme.danger)
        XCTAssertEqual(ContextRing.color(nil), Theme.textFaint)
    }
}
