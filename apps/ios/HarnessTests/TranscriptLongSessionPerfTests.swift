// Long-transcript performance: a 30-minute turn leaves ~1500 settled entries
// plus one streaming message of hundreds of parts. Every doc revision used to
// rebuild rows for ALL of them; these tests measure the rebuild and decode
// paths and pin the per-entry row cache and tail-window semantics.
import XCTest
import Loro
@testable import Harness

@MainActor
final class TranscriptLongSessionPerfTests: XCTestCase {

    // MARK: Synthetic session (1500 settled + 1 streaming entry, 300 parts)

    private func makeSession() -> [MessageEntry] {
        var entries: [MessageEntry] = []
        entries.reserveCapacity(1501)
        for i in 0..<750 {
            entries.append(MessageEntry(
                id: "u\(i)", role: .user,
                parts: [.text(id: "t0", text: "Turn \(i): the panel still hangs — dig in.")],
                createdAt: Int64(i * 1000), deviceId: "dev", status: .complete))

            var parts: [MessagePart] = []
            for p in 0..<(2 + i % 3) {
                parts.append(.text(id: "t\(p)", text: """
                    Paragraph \(p) of turn \(i) with a little markdown **weight** and a \
                    `code` span so the parser has real work to do.\n\nSecond block.
                    """))
            }
            for t in 0..<(3 + i % 4) {
                parts.append(.tool(id: "k\(t)",
                    call: RenderToolCall(tag: ["exec", "readFile", "editFile", "search"][t % 4],
                        fields: ["command": "cmd \(i).\(t) --flag \(String(repeating: "x", count: 40))"]),
                    isError: t % 17 == 0, resolved: true))
            }
            entries.append(MessageEntry(
                id: "a\(i)", role: .assistant, parts: parts,
                createdAt: Int64(i * 1000 + 1), deviceId: "dev", status: .complete))
        }

        var tail: [MessagePart] = []
        for p in 0..<300 {
            if p % 2 == 0 {
                tail.append(.text(id: "s\(p)", text: "Streaming prose block \(p) that keeps growing over the turn."))
            } else {
                tail.append(.tool(id: "s\(p)",
                    call: RenderToolCall(tag: "exec",
                        fields: ["command": "run-\(p)", "output": String(repeating: "output line ", count: 30)]),
                    isError: false, resolved: true))
            }
        }
        entries.append(MessageEntry(
            id: "streaming", role: .assistant, parts: tail,
            createdAt: 999_999, deviceId: "dev", status: .streaming))
        return entries
    }

    /// Append a chunk to the streaming tail's last text part, like a doc event.
    private func growTail(_ entries: inout [MessageEntry]) {
        guard let last = entries.indices.last,
              case .text(let id, let text) = entries[last].parts.last else { return }
        entries[last].parts[entries[last].parts.count - 1] = .text(id: id, text: text + " more")
        entries[last].stamp = MessageEntry.nextStamp() // what a re-decode assigns
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private func time(_ body: () -> Void) -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    // MARK: (a) Row rebuild per streamed chunk — before vs after

    func testRowRebuildPerformance() {
        var entries = makeSession()
        var revision: UInt64 = 0
        var before: [Double] = []
        var after: [Double] = []

        // Prime: both paths see a fully-built transcript once.
        var scratchParsers: [String: IncrementalMarkdownParser] = [:]
        var scratchCompleted: [String: CompletedParse] = [:]
        _ = TranscriptRowBuilder.rows(entries: entries, pendingSends: [],
                                      parsers: &scratchParsers, completed: &scratchCompleted)
        let cache = TranscriptBuilderCache()
        _ = cache.rows(revision: revision, entries: entries, pendingSends: [])

        for _ in 0..<50 {
            growTail(&entries)
            revision &+= 1
            // Before: every doc revision re-walked all 1501 entries.
            var parsers: [String: IncrementalMarkdownParser] = [:]
            var completed: [String: CompletedParse] = [:]
            before.append(time {
                _ = TranscriptRowBuilder.rows(entries: entries, pendingSends: [],
                                              parsers: &parsers, completed: &completed)
            })
            // After: the store's cache rebuilds only the re-decoded entry.
            after.append(time {
                _ = cache.rows(revision: revision, entries: entries, pendingSends: [])
            })
        }
        let beforeMs = median(before)
        let afterMs = median(after)
        print("PERF row-rebuild 1501 entries, before \(String(format: "%.2f", beforeMs)) ms -> after \(String(format: "%.2f", afterMs)) ms")
        // Loose budget: the cached path must stay well under a 60fps frame and
        // be an order of magnitude off the full rebuild. Generous for CI load.
        XCTAssertLessThan(afterMs, 20, "cached rebuild too slow")
        XCTAssertLessThan(afterMs, max(beforeMs / 3, 5), "per-entry cache should dominate the win")
    }

    // MARK: (b) Per-message decode of the streaming tail

    func testStreamingDecodeCost() {
        let doc = LoroDoc()
        let messages = doc.getList(id: "messages")
        for i in 0..<100 {
            let m = try! messages.pushContainer(child: LoroMap())
            try! m.insert(key: "id", v: "m\(i)")
            try! m.insert(key: "role", v: i % 2 == 0 ? "user" : "assistant")
            try! m.insert(key: "createdAt", v: Int64(i))
            try! m.insert(key: "deviceId", v: "dev")
            try! m.insert(key: "status", v: "complete")
            let parts = try! m.insertContainer(key: "parts", child: LoroList())
            let p = try! parts.pushContainer(child: LoroMap())
            try! p.insert(key: "id", v: "t0")
            try! p.insert(key: "kind", v: "text")
            try! p.insert(key: "text", v: "settled \(i)")
        }
        // The streaming tail: 300 parts, tool outputs a few hundred chars.
        let stream = try! messages.pushContainer(child: LoroMap())
        try! stream.insert(key: "id", v: "streaming")
        try! stream.insert(key: "role", v: "assistant")
        try! stream.insert(key: "createdAt", v: Int64(1000))
        try! stream.insert(key: "deviceId", v: "dev")
        try! stream.insert(key: "status", v: "streaming")
        let parts = try! stream.insertContainer(key: "parts", child: LoroList())
        for p in 0..<300 {
            let part = try! parts.pushContainer(child: LoroMap())
            try! part.insert(key: "id", v: "s\(p)")
            if p % 2 == 0 {
                try! part.insert(key: "kind", v: "text")
                try! part.insert(key: "text", v: "block \(p)")
            } else {
                try! part.insert(key: "kind", v: "tool")
                try! part.insert(key: "isError", v: false)
                let call = try! part.insertContainer(key: "call", child: LoroMap())
                try! call.insert(key: "kind", v: "exec")
                try! call.insert(key: "command", v: "cmd \(p)")
                try! call.insert(key: "output", v: String(repeating: "output line ", count: 30))
            }
        }
        // The last part is the growing text tail.
        let lastPart = try! parts.pushContainer(child: LoroMap())
        try! lastPart.insert(key: "id", v: "s-last")
        try! lastPart.insert(key: "kind", v: "text")
        try! lastPart.insert(key: "text", v: "growing")
        doc.commit()

        let entryCache = EntryCache()
        let subscription = doc.subscribeRoot { entryCache.observe($0) }
        _ = SessionStore.decodeEntries(from: doc, cache: entryCache)

        var samples: [Double] = []
        for tick in 0..<50 {
            try! lastPart.insert(key: "text", v: "growing" + String(repeating: " more", count: tick))
            doc.commit()
            samples.append(time { _ = SessionStore.decodeEntries(from: doc, cache: entryCache) })
        }
        subscription.detach()
        let decodeMs = median(samples)
        print("PERF streaming-message decode (300-part entry), median \(String(format: "%.2f", decodeMs)) ms")
        XCTAssertLessThan(decodeMs, 30, "cached per-message decode regressed badly")
    }

    // MARK: Per-entry cache correctness vs from-scratch build

    private func kindTag(_ row: TranscriptRow) -> String {
        switch row.kind {
        case .generatedImage: return "image"
        case .user: return "user"
        case .markdown: return "markdown"
        case .toolGroup: return "toolGroup"
        case .inputChip: return "input"
        case .errorChip: return "error"
        }
    }

    private func assertRowsEqual(_ actual: [TranscriptRow], _ expected: [TranscriptRow],
                                 _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(step): row count", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.id, e.id, "\(step): id", file: file, line: line)
            XCTAssertEqual(a.version, e.version, "\(step): version \(a.id)", file: file, line: line)
            XCTAssertEqual(kindTag(a), kindTag(e), "\(step): kind \(a.id)", file: file, line: line)
            XCTAssertEqual(a.topGap, e.topGap, "\(step): topGap \(a.id)", file: file, line: line)
            XCTAssertEqual(a.turnStart, e.turnStart, "\(step): turnStart \(a.id)", file: file, line: line)
            XCTAssertEqual(a.partKey, e.partKey, "\(step): partKey \(a.id)", file: file, line: line)
        }
    }

    private func freshRows(_ entries: [MessageEntry]) -> [TranscriptRow] {
        var parsers: [String: IncrementalMarkdownParser] = [:]
        var completed: [String: CompletedParse] = [:]
        return TranscriptRowBuilder.rows(entries: entries, pendingSends: [],
                                         parsers: &parsers, completed: &completed)
    }

    func testCachedRowsMatchFromScratchAcrossUpdates() {
        var entries = Array(makeSession().prefix(60))
        let cache = TranscriptBuilderCache()
        var revision: UInt64 = 0

        assertRowsEqual(cache.rows(revision: revision, entries: entries, pendingSends: []),
                        freshRows(entries), "initial")

        // Append to the streaming tail.
        growTail(&entries)
        revision &+= 1
        assertRowsEqual(cache.rows(revision: revision, entries: entries, pendingSends: []),
                        freshRows(entries), "tail append")

        // Settle the streaming entry.
        entries[entries.count - 1].status = .complete
        entries[entries.count - 1].stamp = MessageEntry.nextStamp()
        revision &+= 1
        assertRowsEqual(cache.rows(revision: revision, entries: entries, pendingSends: []),
                        freshRows(entries), "settle")

        // A new entry arrives.
        entries.append(MessageEntry(id: "u-new", role: .user,
            parts: [.text(id: "t0", text: "next prompt")],
            createdAt: 1_000_001, deviceId: "dev", status: .complete))
        revision &+= 1
        assertRowsEqual(cache.rows(revision: revision, entries: entries, pendingSends: []),
                        freshRows(entries), "new entry")

        // Edit a middle entry in place (new decode => new stamp).
        entries[10] = MessageEntry(id: entries[10].id, role: entries[10].role,
            parts: [.text(id: "t0", text: "edited middle text with **bold**")],
            createdAt: entries[10].createdAt, deviceId: entries[10].deviceId,
            status: entries[10].status)
        revision &+= 1
        assertRowsEqual(cache.rows(revision: revision, entries: entries, pendingSends: []),
                        freshRows(entries), "middle edit")

        // A continuation merges onto the last assistant entry.
        let rootId = entries.last!.id
        let raw = entries + [MessageEntry(id: "cont-1", role: .assistant,
            parts: [.text(id: "c0", text: "continuation tail text")],
            createdAt: 1_000_002, deviceId: "dev", status: .complete,
            continuationOf: rootId)]
        entries = SessionStore.joinContinuations(raw)
        XCTAssertTrue(entries.contains { $0.id == "cont-1" } == false)
        revision &+= 1
        assertRowsEqual(cache.rows(revision: revision, entries: entries, pendingSends: []),
                        freshRows(entries), "continuation join")
    }

    // MARK: Tail-window limit logic

    func testRowLimitGrowResetAndClamps() {
        let scroll = ScrollState()
        XCTAssertEqual(scroll.rowLimit, ScrollState.defaultRowLimit)

        let total = 950
        scroll.growRowLimit(total: total)
        XCTAssertEqual(scroll.rowLimit, ScrollState.defaultRowLimit + ScrollState.rowLimitStep)
        scroll.growRowLimit(total: total)
        scroll.growRowLimit(total: total)
        scroll.growRowLimit(total: total)
        XCTAssertEqual(scroll.rowLimit, total, "never above the transcript's row count")

        scroll.resetRowLimit()
        XCTAssertEqual(scroll.rowLimit, ScrollState.defaultRowLimit)
        scroll.growRowLimit(total: 10)
        XCTAssertEqual(scroll.rowLimit, ScrollState.defaultRowLimit,
                       "a tiny transcript never drops below the default")
    }

    func testTailWindowSuffix() {
        let scroll = ScrollState()
        var rows: [TranscriptRow] = []
        for i in 0..<500 {
            rows.append(TranscriptRow(id: "r\(i)", version: 1, turnStart: true,
                                      kind: .user(text: "x"), entryId: "e\(i)",
                                      timestamp: nil, partKey: nil))
        }
        let windowed = scroll.tailWindow(rows)
        XCTAssertEqual(windowed.count, ScrollState.defaultRowLimit)
        XCTAssertEqual(windowed.first?.id, "r\(500 - ScrollState.defaultRowLimit)")
        XCTAssertEqual(windowed.last?.id, "r499")
        scroll.rowLimit = 999
        XCTAssertEqual(scroll.tailWindow(rows).count, 500, "window never exceeds count")
    }

    // MARK: Tool-group cap helper

    func testToolGroupTailCap() {
        func tool(_ i: Int) -> ToolItem {
            ToolItem(call: RenderToolCall(tag: "exec", fields: ["command": "c\(i)"]),
                     isError: false, resolved: true)
        }
        let small = (0..<5).map(tool)
        XCTAssertEqual(toolGroupTail(small, revealAll: false).hidden, 0)
        XCTAssertEqual(toolGroupTail(small, revealAll: false).visible.count, 5)

        let big = (0..<47).map(tool)
        let capped = toolGroupTail(big, revealAll: false)
        XCTAssertEqual(capped.hidden, 27)
        XCTAssertEqual(capped.visible.count, 20)
        XCTAssertEqual(capped.visible.first?.call.string("command"), "c27",
                       "the visible tail is the LAST 20 tools")

        let revealed = toolGroupTail(big, revealAll: true)
        XCTAssertEqual(revealed.hidden, 0)
        XCTAssertEqual(revealed.visible.count, 47)
    }
}
