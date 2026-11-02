// How full the session's context is, and with what. A port of the desktop's context ring and card
// (crates/ui/src/context_usage.rs, context_window.rs `breakdown`).
//
// The total and the window are the agent's own meter (`ContextUsage`), which the host writes to the chat
// doc's `meta.contextUsage` and which syncs to the phone with the doc; nothing here replaces them. The split
// between chat, files, commands and the rest is estimated from the transcript since its last compaction, at
// 4 bytes a token (tool parts' `outputBytes`), and scaled down when it would pass the reported total.
// Whatever the transcript can't account for (system prompt, tool schemas, images) is "System & other".

import Foundation

/// The agent's context meter (proto `ContextUsage`), as the doc stores it: one JSON string.
struct ContextUsage: Equatable, Decodable {
    var tokens: Int?
    var window: Int?
    /// What the agent reported keeping out of its context (graff only).
    var savings: ContextSavings?

    var fraction: Double? {
        guard let tokens, let window, window > 0 else { return nil }
        return Double(tokens) / Double(window)
    }

    /// The ring shows only with a window to measure against: an agent that never reports one gets no ring
    /// rather than a permanently empty one.
    var hasWindow: Bool { (window ?? 0) > 0 }

    static func decode(_ json: String) -> ContextUsage? {
        try? JSONDecoder().decode(ContextUsage.self, from: Data(json.utf8))
    }
}

/// graff's cumulative, measured savings (proto `ContextSavings`).
struct ContextSavings: Equatable, Decodable {
    /// Tool-result bytes kept in files instead of the conversation.
    var handleBytes = 0
    /// Context tokens freed by compaction.
    var compactedTokens = 0
    /// Input tokens the provider served from its prompt cache.
    var cacheReadTokens = 0

    init(handleBytes: Int = 0, compactedTokens: Int = 0, cacheReadTokens: Int = 0) {
        (self.handleBytes, self.compactedTokens, self.cacheReadTokens) = (handleBytes, compactedTokens, cacheReadTokens)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handleBytes = try c.decodeIfPresent(Int.self, forKey: .handleBytes) ?? 0
        compactedTokens = try c.decodeIfPresent(Int.self, forKey: .compactedTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case handleBytes, compactedTokens, cacheReadTokens }

    /// Tool-result bytes as tokens, at the usual ~4 bytes a token.
    var handleTokens: Int { handleBytes / 4 }
    /// Tokens that never had to sit in the model's context. Cache reads don't count: they were in it.
    var keptOutTokens: Int { handleTokens + compactedTokens }
}

enum ContextWindow {
    /// Segments across the full window.
    static let segments = 62
    /// Tool output is counted the way graff counts it.
    static let bytesPerToken = 4

    /// What the oldest block of the context holds.
    enum History: Equatable {
        /// The conversation itself: nothing compacted yet.
        case chat
        /// A readable summary replaced the older chat.
        case summary
        /// An opaque provider item replaced it; its contents are sealed.
        case sealed

        static func of(_ kind: String?) -> History { kind == "opaque" ? .sealed : .summary }
    }

    /// One kind of thing in the context, in the order the bar draws them.
    enum Slot: CaseIterable, Equatable {
        case history, recent, files, commands, search, tools, system

        func label(_ history: History) -> String {
            switch self {
            case .history:
                switch history {
                case .chat: "Chat history"
                case .summary: "Chat summary"
                case .sealed: "Compacted context"
                }
            case .recent: "Recent chat"
            case .files: "Files"
            case .commands: "Commands"
            case .search: "Search & web"
            case .tools: "Other tools"
            case .system: "System & other"
            }
        }

        /// The desktop's fixed hues (`Slot::color`); nil is the theme's faint text (System & other).
        func hex(_ history: History) -> UInt32? {
            switch self {
            case .history:
                switch history {
                case .chat: 0xFFB020
                case .summary: 0x4C8DF6
                case .sealed: 0x7D8BA3
                }
            case .recent: 0xF7C873
            case .files: 0x7C5CFF
            case .commands: 0x5BC0EB
            case .search: 0xF368E0
            case .tools: 0x9B59B6
            case .system: nil
            }
        }
    }

    /// What the context holds right now.
    struct Breakdown: Equatable {
        /// Reported tokens in the context, and the window.
        var tokens: Int
        var window: Int
        /// What replaced the older chat, if anything has.
        var history: History = .chat
        /// A compaction is running now, and of which kind, when it said.
        var compacting = false
        var pending: History = .summary
        /// Tokens freed by compaction, cumulative: graff's own count, or the chips' before/after meters.
        var freed = 0
        /// The sealed block's size is an estimate, not the agent's count.
        var sealedEstimated = false
        /// Non-empty slots in `Slot.allCases` order; they sum to `tokens`.
        var items: [(Slot, Int)] = []

        var compacted: Bool { history != .chat }

        static func == (a: Breakdown, b: Breakdown) -> Bool {
            a.tokens == b.tokens && a.window == b.window && a.history == b.history && a.compacting == b.compacting
                && a.pending == b.pending && a.freed == b.freed && a.sealedEstimated == b.sealedEstimated
                && a.items.map(\.0) == b.items.map(\.0) && a.items.map(\.1) == b.items.map(\.1)
        }
    }

    private static func toolSlot(_ call: RenderToolCall) -> Slot {
        switch call.tag {
        case "readFile", "writeFile", "editFile", "applyPatch": .files
        case "exec": .commands
        case "search", "glob", "webFetch", "webSearch": .search
        default: .tools
        }
    }

    private static func tokens(_ bytes: Int) -> Int { (bytes + bytesPerToken - 1) / bytesPerToken }

    /// The split of the reported context across the slots; nil with no window to measure against.
    ///
    /// One pass over the transcript. Each finished compaction is a boundary: what came before it now lives in
    /// its summary or sealed item, so the per-slot counts restart there.
    static func breakdown(usage: ContextUsage?, transcript: [MessageEntry]) -> Breakdown? {
        guard let usage, let window = usage.window, window > 0 else { return nil }
        let total = usage.tokens ?? 0
        let all = Slot.allCases
        func index(_ slot: Slot) -> Int { all.firstIndex(of: slot) ?? 0 }
        var bytes = [Int](repeating: 0, count: all.count)
        var history = History.chat
        // Tokens of the summary or sealed item standing in for older chat.
        var historyTokens = 0
        var compacting = false
        var pending = History.summary
        var chipFreed = 0
        var sealedEstimated = false
        for entry in transcript {
            for part in entry.parts {
                switch part {
                case .tool(_, let call, _, let resolved) where call.isCompaction:
                    let meta = call.compaction
                    if !resolved {
                        compacting = true
                        pending = History.of(meta?.kind)
                        continue
                    }
                    compacting = false
                    let transcriptBefore = bytes.map(tokens).reduce(0, +) + historyTokens
                    let kind = History.of(meta?.kind)
                    if let reported = meta?.itemTokens {
                        historyTokens = reported
                    } else if kind == .sealed {
                        // After minus what the transcript could not account for before: the system share is the
                        // same on both sides of the compaction.
                        if let before = meta?.tokensBefore, let after = meta?.tokensAfter {
                            sealedEstimated = true
                            historyTokens = max(0, after - max(0, before - transcriptBefore))
                        } else {
                            sealedEstimated = false
                            historyTokens = 0
                        }
                    } else {
                        historyTokens = tokens(call.outputBytes ?? 0)
                    }
                    if kind != .sealed || meta?.itemTokens != nil { sealedEstimated = false }
                    chipFreed += meta?.freed ?? 0
                    history = kind
                    bytes = [Int](repeating: 0, count: all.count)
                case .tool(_, let call, _, _):
                    bytes[index(toolSlot(call))] += call.outputBytes ?? 0
                case .text(_, let text) where entry.role == .user || entry.role == .assistant:
                    bytes[index(history == .chat ? .history : .recent)] += text.utf8.count
                default:
                    break
                }
            }
        }
        var estimated = bytes.map(tokens)
        if history != .chat { estimated[index(.history)] += historyTokens }
        let sum = estimated.reduce(0, +)
        if sum > total {
            // The meter is the truth: scale the estimate into it.
            estimated = estimated.map { Int((Double($0) * Double(total) / Double(max(sum, 1))).rounded(.down)) }
        }
        let accounted = estimated.reduce(0, +)
        estimated[index(.system)] += max(0, total - accounted)
        let graffFreed = usage.savings?.compactedTokens ?? 0
        return Breakdown(tokens: total, window: window, history: history, compacting: compacting, pending: pending,
                         freed: graffFreed > 0 ? graffFreed : chipFreed,
                         sealedEstimated: sealedEstimated && history == .sealed,
                         items: zip(all, estimated).filter { $0.1 > 0 })
    }

    /// Segments each slot fills, in bar order. A slot with tokens gets at least one; the total never passes
    /// `segments`.
    static func segmentCounts(_ breakdown: Breakdown) -> [(Slot, Int)] {
        let window = Double(max(breakdown.window, 1))
        var left = segments
        return breakdown.items.map { slot, tokens in
            let wanted = max(Int((Double(tokens) / window * Double(segments)).rounded()), 1)
            let count = min(wanted, left)
            left -= count
            return (slot, count)
        }
    }

    /// 1.2k, 34k, 1.5M.
    static func compactCount(_ n: Int) -> String {
        switch n {
        case ..<1_000: "\(n)"
        case ..<10_000: String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000: "\(n / 1_000)k"
        default: String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    /// 1,234,567.
    static func withSeparators(_ n: Int) -> String {
        let digits = String(n)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    /// The line under the legend (the desktop's `status_line` at rest).
    static func statusLine(_ b: Breakdown) -> String {
        if b.compacting {
            return b.pending == .sealed ? "Compacting older chat into a sealed item"
                : "Summarizing older chat to free up space"
        }
        if b.compacted, b.freed > 0 {
            return b.history == .sealed ? "Older chat sealed, \(compactCount(b.freed)) freed so far"
                : "Older chat summarized, \(compactCount(b.freed)) freed so far"
        }
        return "\(compactCount(max(0, b.window - b.tokens))) free of \(compactCount(b.window))"
    }

    // MARK: Savings

    /// The savings meter's parts: what the context holds now, then what graff kept out of it.
    enum SavedPart: Equatable {
        case inContext, files, compaction

        var label: String {
            switch self {
            case .inContext: "In context"
            case .files: "Tool output"
            case .compaction: "Compaction"
            }
        }
    }

    /// How many of the meter's segments each part gets, in order, scaled to in-context plus saved tokens. A
    /// part that holds anything keeps at least one; the largest absorbs the rounding.
    static func savedSegments(_ parts: [(SavedPart, Int)]) -> [(part: SavedPart, count: Int, tokens: Int)] {
        let parts = parts.filter { $0.1 > 0 }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        var out = parts.map { part, n in
            (part: part, count: max(Int((Double(n) / Double(total) * Double(segments)).rounded()), 1), tokens: n)
        }
        let used = out.reduce(0) { $0 + $1.count }
        // The last of equally large parts, as the desktop's `max_by_key` picks.
        var largest = 0
        for index in out.indices where out[index].count >= out[largest].count { largest = index }
        out[largest].count = max(out[largest].count + segments - used, 1)
        return out
    }

    /// The card's lines under the bar: used and left of the window, or what the agent did report.
    static func details(_ usage: ContextUsage?) -> String {
        let usage = usage ?? ContextUsage()
        switch (usage.tokens, usage.window) {
        case (let tokens?, let window?) where window > 0:
            return "\(withSeparators(tokens)) / \(withSeparators(window)) tokens\n"
                + "\(withSeparators(max(0, window - tokens))) tokens remaining"
        case (let tokens?, _):
            return "\(withSeparators(tokens)) tokens used\nContext limit not reported"
        case (nil, let window?) where window > 0:
            return "\(withSeparators(window)) token capacity\nWaiting for context usage"
        default:
            return "Context usage not reported by this harness yet"
        }
    }
}

/// A compaction chip's record (proto `CompactionMeta`), which rides the chip call's input.
struct CompactionMeta: Equatable {
    /// `opaque` or `summary`.
    var kind: String?
    var tokensBefore: Int?
    var tokensAfter: Int?
    var itemTokens: Int?

    /// Tokens the compaction freed, when both sides were measured.
    var freed: Int? {
        guard let tokensBefore, let tokensAfter else { return nil }
        return max(0, tokensBefore - tokensAfter)
    }
}

extension RenderToolCall {
    /// The tool's full output length in bytes (the part's `outputBytes`, else its output's length).
    var outputBytes: Int? { (fields[Self.outputBytesKey] as? Int64).map(Int.init) }

    /// A compaction chip's record; nil on other calls and on chips that recorded none.
    var compaction: CompactionMeta? {
        guard isCompaction, let kind = string(Self.compactionKindKey) else { return nil }
        func count(_ key: String) -> Int? { (fields[key] as? Int64).map(Int.init) }
        return CompactionMeta(kind: kind, tokensBefore: count("compaction.tokensBefore"),
                              tokensAfter: count("compaction.tokensAfter"), itemTokens: count("compaction.itemTokens"))
    }

    static let outputBytesKey = "part.outputBytes"
    static let compactionKindKey = "compaction.kind"
}
