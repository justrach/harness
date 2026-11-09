//! What fills the selected chat's context, for the composer's usage ring
//! and the card it opens (crates/ui/src/context_window.rs, context_usage.rs).
//!
//! The total and the window are the agent's own meter; nothing here
//! replaces them. The split between chat, files, commands and the rest is
//! estimated from the transcript since its last compaction, at 4 bytes a
//! token, and scaled down when it would pass the reported total. What the
//! transcript can't account for (system prompt, tool schemas, images) is
//! "System & other". A readable compaction becomes "Chat summary"; an
//! opaque provider item a sealed "Compacted context" block, size only.
const std = @import("std");
const tr = @import("transcript.zig");

/// Segments across the full window, each 4 wide with 2 between.
pub const segments: usize = 62;
pub const segment_w: f32 = 4;
pub const segment_h: f32 = 16;
pub const segment_gap: f32 = 2;
/// The bar's width, which sets the card's content width.
pub const bar_width: f32 = @as(f32, @floatFromInt(segments)) * (segment_w + segment_gap) - segment_gap;
const bytes_per_token: u64 = 4;

/// What the oldest block of the context holds.
pub const History = enum {
    /// The conversation itself: nothing compacted yet.
    chat,
    /// A readable summary replaced the older chat.
    summary,
    /// An opaque provider item replaced it; its contents are sealed.
    sealed,

    fn of(m: tr.Compaction) History {
        return if (m.opaque_item) .sealed else .summary;
    }
};

/// One kind of thing in the context, in the order the bar draws them.
pub const Slot = enum {
    history,
    recent,
    files,
    commands,
    search,
    tools,
    system,

    pub const all = std.enums.values(Slot);

    pub fn label(s: Slot, h: History) []const u8 {
        return switch (s) {
            .history => switch (h) {
                .chat => "Chat history",
                .summary => "Chat summary",
                .sealed => "Compacted context",
            },
            .recent => "Recent chat",
            .files => "Files",
            .commands => "Commands",
            .search => "Search & web",
            .tools => "Other tools",
            .system => "System & other",
        };
    }

    /// Its hex, or null for the theme's faint text (System & other).
    pub fn hex(s: Slot, h: History) ?u24 {
        return switch (s) {
            .history => switch (h) {
                .chat => 0xFFB020,
                .summary => 0x4C8DF6,
                .sealed => 0x7D8BA3,
            },
            .recent => 0xF7C873,
            .files => 0x7C5CFF,
            .commands => 0x5BC0EB,
            .search => 0xF368E0,
            .tools => 0x9B59B6,
            .system => null,
        };
    }
};

/// What the context holds right now.
pub const Breakdown = struct {
    tokens: u64,
    window: u64,
    history: History = .chat,
    /// A compaction is running now, and what kind it said it was.
    compacting: bool = false,
    pending: History = .summary,
    /// Tokens freed by compaction: graff's own count, else the chips'.
    freed: u64 = 0,
    /// The sealed block's size is an estimate, not the agent's count.
    sealed_estimated: bool = false,
    /// Tokens per slot, in `Slot.all` order; they sum to `tokens`.
    items: [Slot.all.len]u64 = @splat(0),

    pub fn compacted(b: Breakdown) bool {
        return b.history != .chat;
    }
};

fn toolSlot(kind: tr.ToolKind) Slot {
    return switch (kind) {
        .readFile, .writeFile, .editFile, .applyPatch => .files,
        .exec => .commands,
        .search, .glob, .webFetch, .webSearch => .search,
        else => .tools,
    };
}

fn outputLen(p: tr.Part) u64 {
    return p.output_bytes orelse p.output.len;
}

fn tokensOf(bytes: u64) u64 {
    return std.math.divCeil(u64, bytes, bytes_per_token) catch 0;
}

/// The split of the reported context across slots (`breakdown`): null
/// when the agent reports no window to measure against. Each finished
/// compaction is a boundary; the per-slot counts restart there.
pub fn breakdown(tokens_in: ?u64, window_in: ?u64, savings: ?tr.Savings, entries: []const tr.Entry) ?Breakdown {
    const window = window_in orelse return null;
    if (window == 0) return null;
    const tokens = tokens_in orelse 0;
    var bytes: [Slot.all.len]u64 = @splat(0);
    var history: History = .chat;
    var history_tokens: u64 = 0;
    var compacting = false;
    var pending: History = .summary;
    var chip_freed: u64 = 0;
    var sealed_estimated = false;
    for (entries) |e| for (e.parts.items) |p| {
        if (p.kind == .tool) {
            if (p.compaction) |m| {
                if (!p.resolved) {
                    compacting = true;
                    pending = History.of(m);
                    continue;
                }
                compacting = false;
                var before_total: u64 = history_tokens;
                for (bytes) |b| before_total += tokensOf(b);
                const kind = History.of(m);
                if (m.item_tokens) |n| {
                    history_tokens = n;
                } else if (kind == .sealed) {
                    // After, less what the transcript couldn't account for
                    // before: the system share is the same either side.
                    if (m.tokens_before != null and m.tokens_after != null) {
                        sealed_estimated = true;
                        history_tokens = m.tokens_after.? -| (m.tokens_before.? -| before_total);
                    } else {
                        sealed_estimated = false;
                        history_tokens = 0;
                    }
                } else history_tokens = tokensOf(outputLen(p));
                if (kind != .sealed or m.item_tokens != null) sealed_estimated = false;
                chip_freed += m.freed() orelse 0;
                history = kind;
                bytes = @splat(0);
                continue;
            }
            bytes[@intFromEnum(toolSlot(p.tool))] += outputLen(p);
        } else if (p.kind == .text and (e.role == .user or e.role == .assistant)) {
            bytes[@intFromEnum(@as(Slot, if (history == .chat) .history else .recent))] += p.text.items.len;
        }
    };
    var est: [Slot.all.len]u64 = undefined;
    for (bytes, &est) |b, *v| v.* = tokensOf(b);
    if (history != .chat) est[@intFromEnum(Slot.history)] += history_tokens;
    var sum: u64 = 0;
    for (est) |v| sum += v;
    if (sum > tokens) {
        // The meter is the truth: scale the estimate into it.
        for (&est) |*v| v.* = @intCast(@as(u128, v.*) * tokens / @max(sum, 1));
    }
    var accounted: u64 = 0;
    for (est) |v| accounted += v;
    est[@intFromEnum(Slot.system)] += tokens -| accounted;
    const graff_freed = if (savings) |s| s.compacted_tokens else 0;
    return .{
        .tokens = tokens,
        .window = window,
        .history = history,
        .compacting = compacting,
        .pending = pending,
        .freed = if (graff_freed > 0) graff_freed else chip_freed,
        .sealed_estimated = sealed_estimated and history == .sealed,
        .items = est,
    };
}

/// Segments each slot fills, in bar order (`segment_counts`). A slot with
/// tokens gets at least one; the total never passes `segments`.
pub fn segmentCounts(b: Breakdown) [Slot.all.len]usize {
    const window: f32 = @floatFromInt(@max(b.window, 1));
    var left: usize = segments;
    var out: [Slot.all.len]usize = @splat(0);
    for (b.items, &out) |t, *n| {
        if (t == 0) continue;
        const wanted: usize = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(t)) / window * @as(f32, @floatFromInt(segments)))));
        n.* = @min(wanted, left);
        left -= n.*;
    }
    return out;
}

/// One decimal, rounded half to even as Rust's `{:.1}` does.
fn tenths(n: u64, unit: u64) u64 {
    const step = unit / 10;
    var q = n / step;
    const r = n % step;
    if (r * 2 > step or (r * 2 == step and q % 2 == 1)) q += 1;
    return q;
}

/// 1.2k, 34k, 1.5M (`compact_count`).
pub fn compactCount(buf: []u8, n: u64) []const u8 {
    if (n < 1_000) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
    if (n < 10_000) {
        const t = tenths(n, 1_000);
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ t / 10, t % 10 }) catch "";
    }
    if (n < 1_000_000) return std.fmt.bufPrint(buf, "{d}k", .{n / 1_000}) catch "";
    const t = tenths(n, 1_000_000);
    return std.fmt.bufPrint(buf, "{d}.{d}M", .{ t / 10, t % 10 }) catch "";
}

/// 5,417 (`with_separators`).
pub fn withSeparators(buf: []u8, n: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{n}) catch return "";
    var i: usize = 0;
    for (d, 0..) |ch, at| {
        if (at > 0 and (d.len - at) % 3 == 0) {
            if (i >= buf.len) return buf[0..i];
            buf[i] = ',';
            i += 1;
        }
        if (i >= buf.len) return buf[0..i];
        buf[i] = ch;
        i += 1;
    }
    return buf[0..i];
}

/// The status line under the legend, without a transition in flight
/// (`status_line(b, b)`).
pub fn statusLine(a: std.mem.Allocator, b: Breakdown) []const u8 {
    var x: [16]u8 = undefined;
    var y: [16]u8 = undefined;
    if (b.compacting) return if (b.pending == .sealed) "Compacting older chat into a sealed item" else "Summarizing older chat to free up space";
    if (b.compacted() and b.freed > 0) return std.fmt.allocPrint(a, "Older chat {s}, {s} freed so far", .{ if (b.history == .sealed) "sealed" else "summarized", compactCount(&x, b.freed) }) catch "";
    return std.fmt.allocPrint(a, "{s} free of {s}", .{ compactCount(&x, b.window -| b.tokens), compactCount(&y, b.window) }) catch "";
}

/// The card's numbers under the bar (`details`).
pub fn details(a: std.mem.Allocator, tokens: ?u64, window: ?u64) []const u8 {
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    var z: [32]u8 = undefined;
    const w = window orelse 0;
    if (tokens) |t| {
        if (w > 0) return std.fmt.allocPrint(a, "{s} / {s} tokens\n{s} tokens remaining", .{ withSeparators(&x, t), withSeparators(&y, w), withSeparators(&z, w -| t) }) catch "";
        return std.fmt.allocPrint(a, "{s} tokens used\nContext limit not reported", .{withSeparators(&x, t)}) catch "";
    }
    if (w > 0) return std.fmt.allocPrint(a, "{s} token capacity\nWaiting for context usage", .{withSeparators(&x, w)}) catch "";
    return "Context usage not reported by this harness yet";
}

/// The ring's fill, when there's a total to measure (`ContextUsage::fraction`).
pub fn fraction(tokens: ?u64, window: ?u64) ?f32 {
    const w = window orelse return null;
    if (w == 0) return null;
    return @as(f32, @floatFromInt(tokens orelse return null)) / @as(f32, @floatFromInt(w));
}

/// Live prompt cache hit rate percentage (0..100) for the context window card.
/// Uses the latest turn's cache-read delta over that turn's input tokens when
/// available so the percentage updates dynamically on every model turn, falling
/// back to the snapshot's `cache_read_tokens` vs `tokens` when opening a chat.
pub fn promptCachePercent(tokens: ?u64, savings: ?tr.Savings, turn_cache_read: ?u64, turn_input: ?u64) ?u64 {
    if (savings == null and tokens == null) return null;
    const tok = tokens orelse 0;
    if (turn_cache_read != null and turn_input != null and turn_input.? > 0) {
        const c = turn_cache_read.?;
        const inp = @max(turn_input.?, c);
        return @min(100, (c * 100 + inp / 2) / inp);
    }
    const c = if (savings) |s| s.cache_read_tokens else if (tok > 0) @as(u64, 0) else return null;
    if (c == 0 or tok == 0) return 0;
    if (c <= tok) return @min(100, (c * 100 + tok / 2) / tok);
    return @min(100, (c * 100 + (c + tok) / 2) / (c + tok));
}

/// The three parts of graff's savings meter: what the context holds now,
/// then what graff kept out of it. Cache reads stay out.
pub const SavedPart = enum {
    in_context,
    files,
    compaction,

    pub fn label(p: SavedPart) []const u8 {
        return switch (p) {
            .in_context => "In context",
            .files => "Tool output",
            .compaction => "Compaction",
        };
    }

    pub fn detail(p: SavedPart, a: std.mem.Allocator, tokens: u64) []const u8 {
        var b: [32]u8 = undefined;
        const n = withSeparators(&b, tokens);
        return switch (p) {
            .in_context => std.fmt.allocPrint(a, "{s} tokens in context now", .{n}),
            .files => std.fmt.allocPrint(a, "~{s} tokens of tool output kept in files", .{n}),
            .compaction => std.fmt.allocPrint(a, "{s} tokens freed by compaction", .{n}),
        } catch "";
    }
};

pub const Saved = struct { part: SavedPart, count: usize, tokens: u64 };

pub const SavedParts = struct {
    items: [3]Saved = undefined,
    len: usize = 0,

    pub fn slice(s: *const SavedParts) []const Saved {
        return s.items[0..s.len];
    }
};

/// How many of the meter's segments each part gets (`saved_segments`): a
/// part that holds anything keeps one; the largest absorbs the rounding.
pub fn savedSegments(parts: [3]struct { SavedPart, u64 }) SavedParts {
    var out: SavedParts = .{};
    var total: u64 = 0;
    for (parts) |p| total += p[1];
    if (total == 0) return out;
    var used: usize = 0;
    for (parts) |p| if (p[1] > 0) {
        const share: usize = @intFromFloat(@round(@as(f64, @floatFromInt(p[1])) / @as(f64, @floatFromInt(total)) * @as(f64, @floatFromInt(segments))));
        out.items[out.len] = .{ .part = p[0], .count = @max(share, 1), .tokens = p[1] };
        out.len += 1;
        used += @max(share, 1);
    };
    var largest: usize = 0;
    for (out.items[0..out.len], 0..) |s, i| if (s.count > out.items[largest].count) {
        largest = i;
    };
    const l = &out.items[largest];
    l.count = @max((l.count + segments) -| used, 1);
    return out;
}

const testing = std.testing;

fn textPart(gpa: std.mem.Allocator, n: usize) !tr.Part {
    var p: tr.Part = .{ .id = try gpa.dupe(u8, "t"), .kind = .text };
    try p.text.appendNTimes(gpa, 'x', n);
    return p;
}

fn toolPart(gpa: std.mem.Allocator, kind: tr.ToolKind, bytes: u64) !tr.Part {
    return .{ .id = try gpa.dupe(u8, "k"), .kind = .tool, .tool = kind, .output_bytes = bytes, .resolved = true };
}

fn compactionPart(gpa: std.mem.Allocator, m: tr.Compaction, bytes: u64, resolved: bool) !tr.Part {
    return .{ .id = try gpa.dupe(u8, "c"), .kind = .tool, .compaction = m, .output_bytes = bytes, .resolved = resolved };
}

fn entryOf(gpa: std.mem.Allocator, role: tr.Role, parts: []const tr.Part) !tr.Entry {
    var e: tr.Entry = .{ .id = try gpa.dupe(u8, "e"), .role = role, .status = .complete };
    try e.parts.appendSlice(gpa, parts);
    return e;
}

test "needs a reported window (needs_a_reported_window, indicator_needs_a_reported_window)" {
    try testing.expect(breakdown(1_200, null, null, &.{}) == null);
    try testing.expect(breakdown(1_200, 0, null, &.{}) == null);
    try testing.expect(breakdown(null, 200_000, null, &.{}) != null);
}

test "splits the transcript and keeps the reported total (splits_the_transcript_and_keeps_the_reported_total)" {
    const gpa = testing.allocator;
    var entries = [_]tr.Entry{
        try entryOf(gpa, .user, &.{try textPart(gpa, 4_000)}),
        try entryOf(gpa, .assistant, &.{ try toolPart(gpa, .readFile, 8_000), try toolPart(gpa, .exec, 2_000), try toolPart(gpa, .webSearch, 400), try toolPart(gpa, .mcp, 400) }),
    };
    defer for (&entries) |*e| e.deinit(gpa);
    const b = breakdown(10_000, 200_000, null, &entries).?;
    try testing.expectEqual(@as(u64, 1_000), b.items[@intFromEnum(Slot.history)]);
    try testing.expectEqual(@as(u64, 2_000), b.items[@intFromEnum(Slot.files)]);
    try testing.expectEqual(@as(u64, 500), b.items[@intFromEnum(Slot.commands)]);
    try testing.expectEqual(@as(u64, 100), b.items[@intFromEnum(Slot.search)]);
    try testing.expectEqual(@as(u64, 100), b.items[@intFromEnum(Slot.tools)]);
    try testing.expectEqual(@as(u64, 6_300), b.items[@intFromEnum(Slot.system)]);
    var sum: u64 = 0;
    for (b.items) |v| sum += v;
    try testing.expectEqual(@as(u64, 10_000), sum);
}

test "an estimate over the meter is scaled into it (an_estimate_over_the_meter_is_scaled_into_it)" {
    const gpa = testing.allocator;
    var entries = [_]tr.Entry{try entryOf(gpa, .assistant, &.{try toolPart(gpa, .readFile, 40_000)})};
    defer for (&entries) |*e| e.deinit(gpa);
    const b = breakdown(1_000, 200_000, null, &entries).?;
    try testing.expectEqual(@as(u64, 1_000), b.items[@intFromEnum(Slot.files)]);
    try testing.expectEqual(@as(u64, 0), b.items[@intFromEnum(Slot.system)]);
}

test "compaction replaces older chat with its summary; a sealed block is sized without contents" {
    const gpa = testing.allocator;
    var entries = [_]tr.Entry{
        try entryOf(gpa, .user, &.{try textPart(gpa, 40_000)}),
        try entryOf(gpa, .assistant, &.{try compactionPart(gpa, .{ .tokens_before = 30_000, .tokens_after = 4_000 }, 2_000, true)}),
        try entryOf(gpa, .user, &.{try textPart(gpa, 400)}),
    };
    defer for (&entries) |*e| e.deinit(gpa);
    const b = breakdown(5_000, 200_000, null, &entries).?;
    try testing.expectEqual(History.summary, b.history);
    try testing.expectEqual(@as(u64, 500), b.items[@intFromEnum(Slot.history)]);
    try testing.expectEqual(@as(u64, 100), b.items[@intFromEnum(Slot.recent)]);
    try testing.expectEqual(@as(u64, 26_000), b.freed);
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try testing.expectEqualStrings("Older chat summarized, 26k freed so far", statusLine(fba.allocator(), b));
    // Opaque: after (4k) less what the transcript couldn't account for
    // before (12k less 10k of chat) = 2k; with an item count, the agent's.
    entries[1].parts.items[0].compaction = .{ .opaque_item = true, .tokens_before = 12_000, .tokens_after = 4_000 };
    const s = breakdown(5_000, 200_000, null, &entries).?;
    try testing.expectEqual(History.sealed, s.history);
    try testing.expect(s.sealed_estimated);
    try testing.expectEqual(@as(u64, 2_000), s.items[@intFromEnum(Slot.history)]);
    entries[1].parts.items[0].compaction.?.item_tokens = 1_500;
    const r = breakdown(5_000, 200_000, null, &entries).?;
    try testing.expect(!r.sealed_estimated);
    try testing.expectEqual(@as(u64, 1_500), r.items[@intFromEnum(Slot.history)]);
    // A running one says so.
    entries[1].parts.items[0].resolved = false;
    const running = breakdown(5_000, 200_000, null, &entries).?;
    try testing.expect(running.compacting);
    fba.reset();
    try testing.expectEqualStrings("Compacting older chat into a sealed item", statusLine(fba.allocator(), running));
}

test "segments never overflow and small slots stay visible (segments_never_overflow_and_small_slots_stay_visible)" {
    var b: Breakdown = .{ .tokens = 200_000, .window = 200_000 };
    b.items[@intFromEnum(Slot.history)] = 1;
    b.items[@intFromEnum(Slot.system)] = 199_999;
    const counts = segmentCounts(b);
    try testing.expectEqual(@as(usize, 1), counts[@intFromEnum(Slot.history)]);
    var sum: usize = 0;
    for (counts) |n| sum += n;
    try testing.expect(sum <= segments);
}

test "counts read as GPUI's (compact_count, with_separators, details)" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("999", compactCount(&b, 999));
    try testing.expectEqualStrings("1.2k", compactCount(&b, 1_250));
    try testing.expectEqualStrings("34k", compactCount(&b, 34_999));
    try testing.expectEqualStrings("1.5M", compactCount(&b, 1_500_000));
    try testing.expectEqualStrings("0", withSeparators(&b, 0));
    try testing.expectEqualStrings("5,417", withSeparators(&b, 5417));
    try testing.expectEqualStrings("1,048,576", withSeparators(&b, 1_048_576));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("5,417 / 1,048,576 tokens\n1,043,159 tokens remaining", details(a, 5417, 1_048_576));
    try testing.expectEqualStrings("250 / 200 tokens\n0 tokens remaining", details(a, 250, 200));
    try testing.expect(std.mem.indexOf(u8, details(a, 10, 0), "limit not reported") != null);
    try testing.expect(std.mem.indexOf(u8, details(a, null, null), "not reported") != null);
    try testing.expectEqualStrings("160k free of 200k", statusLine(a, .{ .tokens = 40_000, .window = 200_000 }));
}

test "saved segments split the meter and leave the cache out (saved_segments_split_the_meter_and_leave_the_cache_out)" {
    const parts = savedSegments(.{ .{ .in_context, 40_000 }, .{ .files, 24_000 }, .{ .compaction, 78_000 } });
    var sum: usize = 0;
    for (parts.slice()) |p| sum += p.count;
    try testing.expectEqual(segments, sum);
    try testing.expectEqual(SavedPart.compaction, parts.slice()[2].part);
    const only = savedSegments(.{ .{ .in_context, 40_000 }, .{ .files, 0 }, .{ .compaction, 0 } });
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqual(segments, only.slice()[0].count);
    const s: tr.Savings = .{ .handle_bytes = 96_000, .compacted_tokens = 78_000, .cache_read_tokens = 500_000 };
    try testing.expectEqual(@as(u64, 102_000), s.keptOut());
}
