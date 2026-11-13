//! Streaming fade-in veil and live inline-Markdown balancer for `harness-nano`.
//!
//! Port of `crates/ui/src/markdown/veil.rs` (`Veil.swift` / `Veil.kt`), extended
//! with per-word sub-chunk staggering and live unclosed inline-mark balancing:
//!
//! 1. **Instant layout, paint-only dissolve**: streamed text commits to layout
//!    immediately so line wrapping and scroll height never jump. Newly arrived
//!    words dissolve in by multiplying a fading alpha into `ui.Span` colors.
//! 2. **Left-to-right word wave on multi-word bursts**: when a network/IPC
//!    delta delivers multiple words at once, `wordSubranges` splits the append
//!    at word boundaries and staggers each word's fade start by up to `22ms` so
//!    words flow in sequentially from left to right at 120Hz instead of flashing
//!    as a flat block.
//! 3. **Zero raw-marker flash on in-flight Markdown**: while a reply is actively
//!    streaming, `balanceStreamingMarkdown` auto-closes an unclosed trailing
//!    `` `code ``, `**bold`, or `*italic` span on the active line (and hides a
//!    bare trailing opening mark until its first glyph arrives), keeping the
//!    parsed plain text monotonically prefix-stable across chunks.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;

/// EMA seed for the inter-append gap (`VEIL_EMA_SEED_MS`).
pub const ema_seed_ms: f32 = 160.0;
/// Minimum per-chunk fade duration (`VEIL_MIN_FADE_MS`).
pub const min_fade_ms: f32 = 120.0;
/// Maximum per-chunk fade duration (`VEIL_MAX_FADE_MS`).
pub const max_fade_ms: f32 = 400.0;
/// Dissolve exponent (`VEIL_CURVE_POW`: `alpha = 1 - (1 - p)^1.6`).
pub const curve_pow: f32 = 1.6;
/// Maximum inter-append gap feeding the EMA (`VEIL_GAP_CLAMP_MS`).
pub const gap_clamp_ms: f32 = 1000.0;
/// Maximum retained row veils per window.
pub const max_row_veils: usize = 64;

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const VeilSpan = struct {
    start: usize,
    end: usize,
    alpha: f32,
};

pub const Chunk = struct {
    start: usize,
    end: usize,
    started_ms: f64,
    duration_ms: f32,
};

/// Text alpha for a fade progress `p` in `[0, 1]`: the veil dissolves as
/// `(1 - p)^1.6`, so the text shows through at `1 - veil`.
pub fn veilOpacity(p: f32) f32 {
    const clamped = std.math.clamp(p, 0.0, 1.0);
    if (clamped <= 0.0) return 0.0;
    if (clamped >= 1.0) return 1.0;
    return 1.0 - std.math.pow(f32, 1.0 - clamped, curve_pow);
}

/// Chunk fade duration for the current inter-append EMA (`clamp(ema * 3, 120, 400)`).
pub fn veilDurationMs(ema_ms: f32) f32 {
    return std.math.clamp(ema_ms * 3.0, min_fade_ms, max_fade_ms);
}

/// Fast-stream boost: 3+ chunks fading concurrently speed up by 30% each
/// (`1 + 0.3 * max(0, active_chunks - 2)`).
pub fn veilBoost(active_chunks: usize) f32 {
    return 1.0 + 0.3 * @as(f32, @floatFromInt(active_chunks -| 2));
}

/// EMA update on a new append gap (`ema * 0.7 + min(gap, 1000) * 0.3`).
pub fn veilEmaNext(ema_ms: f32, gap_ms: f32) f32 {
    return ema_ms * 0.7 + @min(@max(gap_ms, 0.0), gap_clamp_ms) * 0.3;
}

/// Longest common byte prefix of `a` and `b`, snapped back to a valid UTF-8
/// codepoint boundary in `b`.
pub fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var p: usize = 0;
    while (p < n and a[p] == b[p]) : (p += 1) {}
    while (p > 0 and p < b.len and (b[p] & 0xC0) == 0x80) : (p -= 1) {}
    return p;
}

/// Splits `text[start..end]` at word boundaries (each word + its trailing spaces)
/// into up to `buf.len` contiguous `Range`s covering `start..end` without gaps.
pub fn wordSubranges(buf: *[16]Range, text: []const u8, start: usize, end: usize) []const Range {
    if (start >= end or end > text.len) return &.{};
    var count: usize = 0;
    var i: usize = start;
    while (i < end) {
        if (count + 1 == buf.len) {
            buf[count] = .{ .start = i, .end = end };
            count += 1;
            break;
        }
        const word_start = i;
        while (i < end and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) : (i += 1) {}
        while (i < end and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') : (i += 1) {}
        while (i < end and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        while (i > word_start and i < end and (text[i] & 0xC0) == 0x80) : (i += 1) {}
        buf[count] = .{ .start = word_start, .end = i };
        count += 1;
    }
    return buf[0..count];
}

/// Per-element chunk tracker: remembers the last rendered flat text and fades
/// every newly appended suffix exactly once, staggering multi-word bursts
/// smoothly from left to right.
pub const ElemVeil = struct {
    prev: std.ArrayList(u8) = .empty,
    chunks: std.ArrayList(Chunk) = .empty,
    ema_ms: f32 = ema_seed_ms,
    last_append_ms: ?f64 = null,

    pub fn deinit(self: *ElemVeil, gpa: Allocator) void {
        self.prev.deinit(gpa);
        self.chunks.deinit(gpa);
    }

    pub fn seed(self: *ElemVeil, gpa: Allocator, text: []const u8) void {
        self.prev.clearRetainingCapacity();
        self.prev.appendSlice(gpa, text) catch {};
    }

    pub fn isFading(self: *const ElemVeil) bool {
        return self.chunks.items.len > 0;
    }

    pub fn advance(self: *ElemVeil, gpa: Allocator, arena: Allocator, text: []const u8, now_ms: f64) []const VeilSpan {
        if (!std.mem.eql(u8, text, self.prev.items)) {
            const p = commonPrefix(self.prev.items, text);
            var write_ix: usize = 0;
            for (self.chunks.items) |c| {
                const clamped_end = @min(c.end, p);
                if (c.start < clamped_end) {
                    self.chunks.items[write_ix] = .{
                        .start = c.start,
                        .end = clamped_end,
                        .started_ms = c.started_ms,
                        .duration_ms = c.duration_ms,
                    };
                    write_ix += 1;
                }
            }
            self.chunks.items.len = write_ix;

            if (text.len > p) {
                if (self.last_append_ms) |last| {
                    const gap: f32 = @floatCast(@max(0.0, now_ms - last));
                    if (gap > 0.5) self.ema_ms = veilEmaNext(self.ema_ms, gap);
                }
                self.last_append_ms = now_ms;
                const dur = veilDurationMs(self.ema_ms);
                var wbuf: [16]Range = undefined;
                const words = wordSubranges(&wbuf, text, p, text.len);
                const step_ms: f64 = if (words.len <= 1)
                    0.0
                else
                    @min(14.0, @as(f64, dur) * 0.32 / @as(f64, @floatFromInt(words.len)));
                for (words, 0..) |w, idx| {
                    self.chunks.append(gpa, .{
                        .start = w.start,
                        .end = w.end,
                        .started_ms = now_ms + @as(f64, @floatFromInt(idx)) * step_ms,
                        .duration_ms = dur,
                    }) catch break;
                }
            }
            self.prev.clearRetainingCapacity();
            self.prev.appendSlice(gpa, text) catch {};
        }

        const boost_initial = veilBoost(self.chunks.items.len);
        var keep_ix: usize = 0;
        for (self.chunks.items) |c| {
            const elapsed: f32 = if (now_ms > c.started_ms) @floatCast(now_ms - c.started_ms) else 0.0;
            if (now_ms <= c.started_ms or elapsed * boost_initial < c.duration_ms) {
                self.chunks.items[keep_ix] = c;
                keep_ix += 1;
            }
        }
        self.chunks.items.len = keep_ix;
        if (self.chunks.items.len == 0) return &.{};

        const boost = veilBoost(self.chunks.items.len);
        var out = std.ArrayList(VeilSpan).empty;
        for (self.chunks.items) |c| {
            const elapsed: f32 = if (now_ms > c.started_ms) @floatCast(now_ms - c.started_ms) else 0.0;
            const progress = std.math.clamp(elapsed * boost / c.duration_ms, 0.0, 1.0);
            out.append(arena, .{
                .start = c.start,
                .end = c.end,
                .alpha = veilOpacity(progress),
            }) catch break;
        }
        return out.items;
    }
};

/// Veil state for one streaming `.text` part, keyed by block/cell index.
pub const RowVeil = struct {
    elems: std.AutoHashMapUnmanaged(usize, ElemVeil) = .empty,
    seeding: bool = false,
    touched_ms: f64 = 0,

    pub fn deinit(self: *RowVeil, gpa: Allocator) void {
        var it = self.elems.valueIterator();
        while (it.next()) |elem| elem.deinit(gpa);
        self.elems.deinit(gpa);
    }

    pub fn finishSeeding(self: *RowVeil) void {
        self.seeding = false;
    }

    pub fn isFading(self: *const RowVeil) bool {
        var it = self.elems.valueIterator();
        while (it.next()) |elem| {
            if (elem.isFading()) return true;
        }
        return false;
    }

    pub fn advance(self: *RowVeil, gpa: Allocator, arena: Allocator, elem_ix: usize, text: []const u8, now_ms: f64) []const VeilSpan {
        self.touched_ms = now_ms;
        if (self.seeding and !self.elems.contains(elem_ix)) {
            var baseline: ElemVeil = .{};
            baseline.seed(gpa, text);
            self.elems.put(gpa, elem_ix, baseline) catch baseline.deinit(gpa);
            return &.{};
        }
        const gop = self.elems.getOrPut(gpa, elem_ix) catch return &.{};
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr.advance(gpa, arena, text, now_ms);
    }
};

/// Bounded per-window store of active `RowVeil`s.
pub const Store = struct {
    rows: std.AutoHashMapUnmanaged(u64, RowVeil) = .empty,

    pub fn deinit(self: *Store, gpa: Allocator) void {
        var it = self.rows.valueIterator();
        while (it.next()) |row| row.deinit(gpa);
        self.rows.deinit(gpa);
    }

    pub fn isFading(self: *const Store, id: u64) bool {
        const row = self.rows.getPtr(id) orelse return false;
        return row.isFading();
    }

    pub fn getOrCreate(self: *Store, gpa: Allocator, id: u64, seed_existing: bool, now_ms: f64) ?*RowVeil {
        if (self.rows.getPtr(id)) |existing| {
            existing.touched_ms = now_ms;
            return existing;
        }
        if (self.rows.count() >= max_row_veils) {
            var oldest_id: ?u64 = null;
            var oldest_ms: f64 = std.math.inf(f64);
            var it = self.rows.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.touched_ms < oldest_ms) {
                    oldest_ms = entry.value_ptr.touched_ms;
                    oldest_id = entry.key_ptr.*;
                }
            }
            if (oldest_id) |old| {
                if (self.rows.fetchRemove(old)) |kv| {
                    var removed = kv.value;
                    removed.deinit(gpa);
                }
            }
        }
        self.rows.put(gpa, id, .{ .seeding = seed_existing, .touched_ms = now_ms }) catch return null;
        return self.rows.getPtr(id);
    }

    pub fn pruneSettled(self: *Store, gpa: Allocator, id: u64) void {
        if (self.rows.getPtr(id)) |row| {
            if (!row.isFading()) {
                if (self.rows.fetchRemove(id)) |kv| {
                    var removed = kv.value;
                    removed.deinit(gpa);
                }
            }
        }
    }
};

/// Intersect `spans` with `[start, end)` and shift to local `[0, end - start)`
/// byte offsets (used for per-line code block veil rendering).
pub fn sliceSpans(arena: Allocator, spans: []const VeilSpan, start: usize, end: usize) []const VeilSpan {
    if (spans.len == 0 or start >= end) return &.{};
    var out = std.ArrayList(VeilSpan).empty;
    for (spans) |s| {
        const lo = @max(s.start, start);
        const hi = @min(s.end, end);
        if (lo < hi) {
            out.append(arena, .{
                .start = lo - start,
                .end = hi - start,
                .alpha = s.alpha,
            }) catch break;
        }
    }
    return out.items;
}

/// Multiplies `veil_spans` opacities into `spans` and uncovered plain-text
/// ranges of `0..text_len`, splitting at span boundaries while preserving all
/// font weights, italics, inline-code boxes, and exact byte lengths.
pub fn applyVeil(
    arena: Allocator,
    text_len: usize,
    spans: []const ui.Span,
    veil_spans: []const VeilSpan,
    base_color: ui.Color,
) []const ui.Span {
    if (text_len == 0 or veil_spans.len == 0) return spans;
    var any_fading = false;
    for (veil_spans) |v| {
        if (v.alpha < 0.999 and v.start < v.end and v.start < text_len) {
            any_fading = true;
            break;
        }
    }
    if (!any_fading) return spans;

    var cuts = std.ArrayList(usize).empty;
    cuts.append(arena, 0) catch return spans;
    cuts.append(arena, text_len) catch return spans;
    for (spans) |sp| {
        const s = @min(@as(usize, sp.start), text_len);
        const e = @min(@as(usize, sp.end), text_len);
        if (s > 0 and s < text_len) cuts.append(arena, s) catch return spans;
        if (e > 0 and e < text_len) cuts.append(arena, e) catch return spans;
    }
    for (veil_spans) |v| {
        const s = @min(v.start, text_len);
        const e = @min(v.end, text_len);
        if (s > 0 and s < text_len) cuts.append(arena, s) catch return spans;
        if (e > 0 and e < text_len) cuts.append(arena, e) catch return spans;
    }
    std.mem.sort(usize, cuts.items, {}, std.sort.asc(usize));

    var out = std.ArrayList(ui.Span).empty;
    var prev_cut: usize = 0;
    for (cuts.items) |cut| {
        if (cut <= prev_cut) continue;
        const s = prev_cut;
        const e = cut;
        prev_cut = cut;

        var orig: ?ui.Span = null;
        for (spans) |sp| {
            if (@as(usize, sp.start) <= s and e <= @as(usize, sp.end)) {
                orig = sp;
                break;
            }
        }
        var v_alpha: ?f32 = null;
        for (veil_spans) |v| {
            if (v.start <= s and e <= v.end and v.alpha < 0.999) {
                v_alpha = v.alpha;
                break;
            }
        }

        if (orig == null and v_alpha == null) continue;

        var piece: ui.Span = if (orig) |o| o else .{ .start = @intCast(s), .end = @intCast(e) };
        piece.start = @intCast(s);
        piece.end = @intCast(e);
        if (v_alpha) |a| {
            const c = piece.color orelse base_color;
            piece.color = c.alpha(a);
            if (piece.background) |bg| piece.background = bg.alpha(a);
        }

        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            var same = last.*;
            same.start = piece.start;
            same.end = piece.end;
            if (last.end == piece.start and std.meta.eql(same, piece)) {
                last.end = piece.end;
                continue;
            }
        }
        out.append(arena, piece) catch return spans;
    }
    return out.items;
}

/// Balances unclosed inline Markdown markers (`` ` ``, `**`, `*`) on the
/// active trailing line of a streaming message so bold/italic/inline-code
/// spans style immediately on their first glyph without raw marker flicker.
pub fn balanceStreamingMarkdown(arena: Allocator, src: []const u8) []const u8 {
    if (src.len == 0) return src;

    // Never touch an unclosed fenced code block (` ``` ` or ` ~~~ `).
    var fence_open = false;
    var fence_prefix: []const u8 = "";
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const t = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
            if (!fence_open) {
                fence_open = true;
                fence_prefix = t[0..3];
            } else if (std.mem.startsWith(u8, t, fence_prefix)) {
                fence_open = false;
            }
        }
    }
    if (fence_open) return src;

    const line_start = if (std.mem.lastIndexOfScalar(u8, src, '\n')) |nl| nl + 1 else 0;
    const last_line = src[line_start..];
    if (last_line.len == 0) return src;

    // Advance past any block-level line prefix (heading, quote, bullet/numbered list).
    const body_rel = inlineBodyOffset(last_line);
    const body = last_line[body_rel..];
    if (body.len == 0) return src;

    // Ignore horizontal rule candidates (`---`, `***`, `___`) on bare lines.
    const trimmed_body = std.mem.trim(u8, body, " \t\r");
    if (body_rel == 0 and trimmed_body.len >= 3) {
        var only_rule_chars = true;
        for (trimmed_body) |ch| {
            if (ch != '-' and ch != '*' and ch != '_' and ch != ' ') {
                only_rule_chars = false;
                break;
            }
        }
        if (only_rule_chars) return src;
    }

    // Scan `body` using the same inline rules as `markdown.zig`.
    var i: usize = 0;
    while (i < body.len) {
        const ch = body[i];
        const rest = body[i..];
        if (ch == '\\' and i + 1 < body.len) {
            i += 2;
            continue;
        }
        if (ch == '`') {
            var n: usize = 0;
            while (i + n < body.len and body[i + n] == '`') : (n += 1) {}
            const tick_mark = body[i .. i + n];
            if (std.mem.indexOf(u8, body[i + n ..], tick_mark)) |close| {
                i += n + close + n;
                continue;
            }
            const after = body[i + n ..];
            if (std.mem.trim(u8, after, " \t\r").len == 0) {
                if (i > 0 or body_rel == 0) return src[0 .. line_start + body_rel + i];
                return src;
            }
            return std.fmt.allocPrint(arena, "{s}{s}", .{ src, tick_mark }) catch src;
        }
        if (ch == '*') {
            const double = rest.len > 1 and rest[1] == '*';
            const mark = if (double) rest[0..2] else rest[0..1];
            const after = rest[mark.len..];
            if (std.mem.trim(u8, after, " \t\r").len == 0) {
                // Bare trailing `*` or `**` at the end of the line: hide until content arrives.
                if ((i > 0 or body_rel == 0) and (i == 0 or body[i - 1] == ' ' or body[i - 1] == '\t' or body[i - 1] == '(' or body[i - 1] == '[')) {
                    return src[0 .. line_start + body_rel + i];
                }
                i += mark.len;
                continue;
            }
            if (after[0] != ' ') {
                if (findClosingMark(body, i + mark.len, mark)) |close| {
                    i = close + mark.len;
                    continue;
                }
                // Unclosed `*` or `**` with content after it!
                if (double and std.mem.endsWith(u8, after, "*") and after.len >= 2 and after[after.len - 2] != ' ' and after[after.len - 2] != '\\') {
                    return std.fmt.allocPrint(arena, "{s}*", .{src}) catch src;
                }
                const trimmed = std.mem.trimEnd(u8, src, " \t\r");
                const trailing_ws = src[trimmed.len..];
                return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ trimmed, mark, trailing_ws }) catch src;
            }
        }
        i += 1;
    }
    return src;
}

fn inlineBodyOffset(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i < line.len and line[i] == '>') {
        i += 1;
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        return i;
    }
    var hashes: usize = 0;
    while (i + hashes < line.len and hashes < 6 and line[i + hashes] == '#') : (hashes += 1) {}
    if (hashes > 0 and i + hashes < line.len and line[i + hashes] == ' ') {
        return i + hashes + 1;
    }
    if (i + 1 < line.len and (line[i] == '-' or line[i] == '*' or line[i] == '+') and line[i + 1] == ' ') {
        i += 2;
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i + 4 <= line.len and (std.mem.eql(u8, line[i .. i + 4], "[ ] ") or std.mem.eql(u8, line[i .. i + 4], "[x] ") or std.mem.eql(u8, line[i .. i + 4], "[X] "))) {
            i += 4;
        }
        return i;
    }
    var digits: usize = 0;
    while (i + digits < line.len and digits < 4 and std.ascii.isDigit(line[i + digits])) : (digits += 1) {}
    if (digits > 0 and i + digits + 1 < line.len and (line[i + digits] == '.' or line[i + digits] == ')') and line[i + digits + 1] == ' ') {
        i += digits + 2;
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        return i;
    }
    return i;
}

fn findClosingMark(src: []const u8, from: usize, mark: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, src, i, mark)) |at| {
        const before_ok = at > from and src[at - 1] != ' ' and src[at - 1] != '\\';
        const doubled = mark.len == 1 and at + 1 < src.len and src[at + 1] == mark[0];
        if (before_ok and !doubled) return at;
        i = at + (if (doubled) @as(usize, 2) else 1);
    }
    return null;
}

const testing = std.testing;

test "veil constants and curve match mugen FadePainter and veil.rs" {
    try testing.expectEqual(@as(f32, 160.0), ema_seed_ms);
    try testing.expectEqual(@as(f32, 120.0), min_fade_ms);
    try testing.expectEqual(@as(f32, 400.0), max_fade_ms);
    try testing.expectEqual(@as(f32, 1.6), curve_pow);
    try testing.expectEqual(@as(f32, 400.0), veilDurationMs(160.0));
    try testing.expectEqual(@as(f32, 120.0), veilDurationMs(30.0));
    try testing.expectEqual(@as(f32, 180.0), veilDurationMs(60.0));
    try testing.expectApproxEqAbs(@as(f32, 160.0 * 0.7 + 100.0 * 0.3), veilEmaNext(160.0, 100.0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 160.0 * 0.7 + 1000.0 * 0.3), veilEmaNext(160.0, 5000.0), 1e-5);
    try testing.expectEqual(@as(f32, 1.0), veilBoost(0));
    try testing.expectEqual(@as(f32, 1.0), veilBoost(2));
    try testing.expectApproxEqAbs(@as(f32, 1.3), veilBoost(3), 1e-5);

    try testing.expectEqual(@as(f32, 0.0), veilOpacity(0.0));
    try testing.expectEqual(@as(f32, 1.0), veilOpacity(1.0));
    const mid = veilOpacity(0.5);
    try testing.expect(mid > 0.5 and mid < 1.0);
    try testing.expect(veilOpacity(0.2) < veilOpacity(0.4));
}

test "commonPrefix and wordSubranges respect UTF-8 and stagger multi-word bursts" {
    try testing.expectEqual(@as(usize, 0), commonPrefix("é", "è"));
    try testing.expectEqual(@as(usize, 2), commonPrefix("abé", "abè"));
    try testing.expectEqual(@as(usize, 4), commonPrefix("same", "same"));

    var wbuf: [16]Range = undefined;
    const text = "Repository crawler → parsers";
    const words = wordSubranges(&wbuf, text, 0, text.len);
    try testing.expectEqual(@as(usize, 4), words.len);
    try testing.expectEqualStrings("Repository ", text[words[0].start..words[0].end]);
    try testing.expectEqualStrings("crawler ", text[words[1].start..words[1].end]);
    try testing.expectEqualStrings("→ ", text[words[2].start..words[2].end]);
    try testing.expectEqualStrings("parsers", text[words[3].start..words[3].end]);
}

test "ElemVeil staggers multi-word bursts left-to-right and settles once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v: ElemVeil = .{};
    defer v.deinit(testing.allocator);

    const s0 = v.advance(testing.allocator, arena.allocator(), "one two three", 1000.0);
    try testing.expectEqual(@as(usize, 3), s0.len);
    try testing.expectEqual(@as(f32, 0.0), s0[0].alpha);
    try testing.expectEqual(@as(f32, 0.0), s0[1].alpha);
    try testing.expectEqual(@as(f32, 0.0), s0[2].alpha);

    // 55ms into the burst: word 1 is strictly ahead of word 2, which is ahead of word 3.
    const s1 = v.advance(testing.allocator, arena.allocator(), "one two three", 1055.0);
    try testing.expectEqual(@as(usize, 3), s1.len);
    try testing.expect(s1[0].alpha > s1[1].alpha);
    try testing.expect(s1[1].alpha > s1[2].alpha);
    try testing.expect(s1[2].alpha > 0.0);

    // Once settled, no spans are emitted and later appends only veil the new suffix.
    const settled = v.advance(testing.allocator, arena.allocator(), "one two three", 1600.0);
    try testing.expectEqual(@as(usize, 0), settled.len);
    try testing.expect(!v.isFading());

    const tail = v.advance(testing.allocator, arena.allocator(), "one two three four", 1700.0);
    try testing.expectEqual(@as(usize, 1), tail.len);
    try testing.expectEqual(@as(usize, 13), tail[0].start);
    try testing.expectEqual(@as(usize, 18), tail[0].end);
}

test "applyVeil preserves inline spans and multiplies fade alpha into text and backgrounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = ui.Color.hex(0xf0f0f0);
    const code_bg = ui.Color.hex(0x282828).alpha(0.5);
    const orig = [_]ui.Span{
        .{ .start = 4, .end = 8, .weight = .semibold, .mono = true, .color = ui.Color.hex(0xffb400), .background = code_bg },
    };
    const veils = [_]VeilSpan{
        .{ .start = 2, .end = 10, .alpha = 0.5 },
    };
    const out = applyVeil(arena.allocator(), 12, &orig, &veils, base);
    // [2..4] plain veiled, [4..8] code veiled, [8..10] plain veiled.
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(u32, 2), out[0].start);
    try testing.expectEqual(@as(u32, 4), out[0].end);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0].color.?.a, 1e-4);

    try testing.expectEqual(@as(u32, 4), out[1].start);
    try testing.expectEqual(@as(u32, 8), out[1].end);
    try testing.expect(out[1].mono);
    try testing.expect(out[1].weight == .semibold);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[1].color.?.a, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[1].background.?.a, 1e-4);

    try testing.expectEqual(@as(u32, 8), out[2].start);
    try testing.expectEqual(@as(u32, 10), out[2].end);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[2].color.?.a, 1e-4);
}

test "balanceStreamingMarkdown keeps parsed inline text monotonic without raw marker flash" {
    const md = @import("markdown.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pal: md.Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };

    const frames = [_]struct { raw: []const u8, expected: []const u8, bold: bool }{
        .{ .raw = "1. **I", .expected = "I", .bold = true },
        .{ .raw = "1. **Initial", .expected = "Initial", .bold = true },
        .{ .raw = "1. **Initial ", .expected = "Initial", .bold = true },
        .{ .raw = "1. **Initial MVP", .expected = "Initial MVP", .bold = true },
        .{ .raw = "1. **Initial MVP:*", .expected = "Initial MVP:", .bold = true },
        .{ .raw = "1. **Initial MVP:** CLI", .expected = "Initial MVP: CLI", .bold = true },
    };
    var prev_text: []const u8 = "";
    for (frames) |f| {
        const balanced = balanceStreamingMarkdown(arena.allocator(), f.raw);
        const blocks = md.parse(arena.allocator(), balanced, pal);
        try testing.expectEqual(@as(usize, 1), blocks.len);
        const in = blocks[0].item.text;
        try testing.expectEqualStrings(f.expected, in.text);
        try testing.expectEqual(prev_text.len, commonPrefix(prev_text, in.text));
        if (f.bold) {
            try testing.expect(in.spans.len >= 1);
            try testing.expect(in.spans[0].weight == .semibold);
        }
        prev_text = in.text;
    }

    // Inline code backtick balancing (`wiki/`).
    const code_bare = balanceStreamingMarkdown(arena.allocator(), "Markdown output under `");
    const code_bare_blocks = md.parse(arena.allocator(), code_bare, pal);
    try testing.expectEqualStrings("Markdown output under", code_bare_blocks[0].paragraph.text);

    const code_mid = balanceStreamingMarkdown(arena.allocator(), "Markdown output under `wiki/");
    const code_mid_blocks = md.parse(arena.allocator(), code_mid, pal);
    try testing.expectEqualStrings("Markdown output under wiki/", code_mid_blocks[0].paragraph.text);
    try testing.expectEqual(@as(usize, 1), code_mid_blocks[0].paragraph.spans.len);
    try testing.expect(code_mid_blocks[0].paragraph.spans[0].mono);
}
