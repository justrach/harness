//! The prompt rail (crates/ui/src/rail.rs, `MessageRail`): at the
//! transcript's left edge a tick per prompt of the open chat, a compact
//! stack in the middle of its height. The prompt being read brightens;
//! under the pointer a tick grows and a card shows the prompt and the
//! opening of its reply; a click glides the transcript to that prompt.
//! Shown from two prompts on, where the column is 768 points or wider.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const tr = @import("transcript.zig");
const rows_st = @import("view_settings_accounts_rows.zig").st;

/// `RAIL_MIN_CONTAINER_WIDTH`, 48rem.
pub const min_container_w: f32 = 768;
/// `TICK_SLOT`, `TICK_GAP`, `RAIL_V_MARGIN`, `MAX_RAIL_TICKS`.
pub const tick_slot: f32 = 10;
pub const tick_gap: f32 = 3;
pub const v_margin: f32 = 24;
pub const max_ticks: usize = 12;
/// `PREVIEW_PROMPT_CHARS`, `PREVIEW_REPLY_CHARS`.
pub const prompt_chars = 160;
pub const reply_chars = 200;
/// `OWN_SEND_TOP_INSET_PX` (`TITLEBAR_HEIGHT + 10`) from a list that starts
/// under the title bar: here, where the transcript starts, 10.
const read_inset: f32 = 10;
/// `SCROLL_GLIDE`: 500 ms, CSS's ease-in-out.
const glide_s: f64 = 0.5;

/// What the rail keeps between frames (`rail_hover`, the glide's task).
pub const State = struct {
    hover: ?usize = null,
    glide: ?Glide = null,
    /// The hover card's height as last laid out, to centre it on its tick.
    card_h: f32 = 0,
};

/// `scroll_to_row`'s glide: the scroll box `box` from `from` to `to`.
pub const Glide = struct { box: u64, from: f32, to: f32, start: f64, at: f32 };

/// A prompt: its entry and its row's top as last laid out (window
/// coordinates), null before it was.
pub const Tick = struct { entry: usize, top: ?f32 };

/// `[start, end)` of the ticks a bucket stands for.
pub const Bucket = struct { start: usize, end: usize };

/// `rail_visible`.
pub fn visible(container_w: f32) bool {
    return container_w >= min_container_w;
}

/// `rail_capacity`: tick slots in a rail `height` tall, one at least.
pub fn capacity(height: f32) usize {
    const usable = @max(height - 2 * v_margin, tick_slot);
    return @max(1, @as(usize, @intFromFloat(@floor((usable + tick_gap) / (tick_slot + tick_gap)))));
}

/// `rail_slots`: what fits, no more than `MAX_RAIL_TICKS`.
pub fn slots(height: f32) usize {
    return @min(capacity(height), max_ticks);
}

/// `tick_buckets`: `n` ticks as at most `cap` even buckets (each a tick
/// while they fit), into `out`.
pub fn buckets(out: []Bucket, n: usize, cap: usize) []Bucket {
    if (n == 0) return out[0..0];
    const k = @min(std.math.clamp(cap, 1, n), out.len);
    for (out[0..k], 0..) |*b, i| b.* = .{ .start = i * n / k, .end = (i + 1) * n / k };
    return out[0..k];
}

/// `bucket_of`.
pub fn bucketOf(bs: []const Bucket, ix: usize) ?usize {
    for (bs, 0..) |b, i| if (ix >= b.start and ix < b.end) return i;
    return null;
}

/// `active_tick` as the rail reads it: glued to the end, the last prompt
/// (the list's top then is past its rows); else the last whose row starts
/// at or above the reading line, the first before any does.
pub fn activeTick(ticks: []const Tick, read_line: f32, glued: bool) ?usize {
    if (ticks.len == 0) return null;
    if (glued) return ticks.len - 1;
    var i = ticks.len;
    while (i > 0) {
        i -= 1;
        if (ticks[i].top) |top| if (top <= read_line + 0.5) return i;
    }
    return 0;
}

/// `truncate_preview`: whitespace runs as one space, cut to `max` chars
/// with an ellipsis.
pub fn truncatePreview(arena: std.mem.Allocator, text: []const u8, max: usize) []const u8 {
    var flat: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var cut_at: usize = 0; // bytes of the first `max - 1` chars
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\x0b\x0c");
    outer: while (it.next()) |word| {
        if (count > 0) {
            flat.append(arena, ' ') catch return text;
            count += 1;
            if (count == max - 1) cut_at = flat.items.len;
            if (count > max) break;
        }
        var v = std.unicode.Utf8View.init(word) catch std.unicode.Utf8View.initUnchecked(word);
        var cps = v.iterator();
        while (cps.nextCodepointSlice()) |cp| {
            flat.appendSlice(arena, cp) catch return text;
            count += 1;
            if (count == max - 1) cut_at = flat.items.len;
            if (count > max) break :outer;
        }
    }
    if (count <= max) return flat.items;
    const cut = std.mem.trimEnd(u8, flat.items[0..cut_at], " ");
    return std.fmt.allocPrint(arena, "{s}…", .{cut}) catch cut;
}

/// `user_text`: the prompt's text, or what it attached.
pub fn userText(arena: std.mem.Allocator, e: *const tr.Entry) []const u8 {
    var text: std.ArrayList(u8) = .empty;
    var images: usize = 0;
    for (e.parts.items) |*p| switch (p.kind) {
        .text => {
            if (text.items.len > 0) text.appendSlice(arena, "\n\n") catch {};
            text.appendSlice(arena, p.text.items) catch {};
        },
        .image => images += 1,
        else => {},
    };
    if (std.mem.trim(u8, text.items, " \t\r\n").len > 0 or images == 0) return text.items;
    if (images == 1) return "Attached image";
    return std.fmt.allocPrint(arena, "{d} attached images", .{images}) catch "Attached images";
}

/// `first_reply_text`: the first text with something in it of the first
/// reply after entry `ix`.
pub fn firstReply(entries: []const tr.Entry, ix: usize) ?[]const u8 {
    for (entries[ix + 1 ..]) |*e| if (e.role == .assistant) {
        for (e.parts.items) |*p| if (p.kind == .text and std.mem.trim(u8, p.text.items, " \t\r\n").len > 0) return p.text.items;
        return null;
    };
    return null;
}

/// Moves a glide on a frame, before the scroll box `box` is laid out; a
/// reader's wheel (the offset not where the glide left it) stops it.
pub fn step(c: *ui.Context, st: *State) void {
    const g = &(st.glide orelse return);
    const now = c.scroll.get(g.box) orelse g.at;
    if (@abs(now - g.at) > 0.5) {
        st.glide = null;
        return;
    }
    const t: f32 = if (c.reduced_motion) 1 else @floatCast(@min(1, (c.time - g.start) / glide_s));
    const e = ui.motion.Easing.css_ease_in_out.sample(t)[0];
    const v = g.from + (g.to - g.from) * e;
    c.scroll.put(c.gpa, g.box, v) catch {};
    g.at = v;
    if (t >= 1) st.glide = null else c.animationFrame();
}

/// The rail over the transcript `t` whose scroll box is `box` and whose
/// prompts are `ticks`, in the box now open: the column the transcript
/// fills (`render_rail`'s absolute overlay, `left(16)`, its full height).
pub fn rail(c: *ui.Context, k: theme.Colors, st: *State, t: *const tr.Transcript, ticks: []const Tick, box: u64, container_w: f32) void {
    // A minimap of one exchange is noise (`marks.length < 2`).
    if (!visible(container_w) or ticks.len < 2) {
        st.hover = null;
        return;
    }
    const parent = c.stack.items[c.stack.items.len - 1];
    const area = c.rects.get(c.node(parent).id);
    const view = c.rects.get(box);
    const glued = c.scroll_follow.get(box) orelse true;
    const read_line = if (view) |v| v.y + read_inset else 0;
    const active = activeTick(ticks, read_line, glued);
    var buf: [max_ticks]Bucket = undefined;
    const height = if (area) |r| r.h else 0;
    const bs = buckets(&buf, ticks.len, slots(if (height > 0) height else 600));
    const active_bucket = if (active) |a| bucketOf(bs, a) else null;
    if (st.hover) |h| if (h >= bs.len) {
        st.hover = null;
    };

    const col = ui.div(c).absolute().offset(16, 0).w(26).hFull().column().itemsStart().justifyCenter().gap(tick_gap);
    var hovered: ?usize = null;
    var hovered_rect: ?ui.Rect = null;
    for (bs, 0..) |b, ix| {
        ui.key(c, c.print("rail-tick-{d}", .{ix}));
        const slot = ui.div(c).row().wFull().h(tick_slot).itemsCenter();
        const it = slot.interaction();
        const is_hovered = it.hovered;
        // Only hover grows the tick; the one being read just brightens.
        const lit = is_hovered or active_bucket == ix;
        _ = c.leaf(.{ .width = .{ .px = if (is_hovered) 20 else 12 }, .height = .{ .px = 2 }, .radius = 1, .background = if (lit) k.text.alpha(0.8) else k.ink(0.16) }, .none, null);
        slot.end();
        if (is_hovered) {
            hovered = ix;
            hovered_rect = it.rect;
        }
        if (it.clicked) glideTo(c, st, ticks[representative(b, active)], box, if (area) |r| r.y else 0);
    }
    col.end();
    st.hover = hovered;
    const ix = hovered orelse return;
    const at = hovered_rect orelse return;
    card(c, k, st, t, ticks, bs[ix], active, at);
}

/// A bucket's prompt: the one being read when it's in it, else its first.
fn representative(b: Bucket, active: ?usize) usize {
    if (active) |a| if (a >= b.start and a < b.end) return a;
    return b.start;
}

/// `scroll_to_row`: the prompt's row to the top of the column, gliding.
fn glideTo(c: *ui.Context, st: *State, tick: Tick, box: u64, column_top: f32) void {
    const top = tick.top orelse return;
    const from = c.scroll.get(box) orelse 0;
    var to = @max(0, from + top - column_top);
    if (c.scroll_max.get(box)) |m| to = @min(to, m);
    st.glide = .{ .box = box, .from = from, .to = to, .start = c.time, .at = from };
    step(c, st);
}

/// The hover card (`popover_card`, 280 wide): the prompt, its reply's
/// opening, and how many prompts a bucket stands for; its left edge 26
/// points past the tick's slot, centred on it, kept 8 inside the window.
fn card(c: *ui.Context, k: theme.Colors, st: *State, t: *const tr.Transcript, ticks: []const Tick, b: Bucket, active: ?usize, at: ui.Rect) void {
    const entries = t.entries.items;
    const tick = ticks[representative(b, active)];
    const e = &entries[tick.entry];
    const prompt = truncatePreview(c.alloc(), userText(c.alloc(), e), prompt_chars);
    const reply = if (firstReply(entries, tick.entry)) |r| truncatePreview(c.alloc(), r, reply_chars) else null;
    const w: f32 = 280;
    const x = std.math.clamp(at.x + 26, 8, @max(8, c.size.w - w - 8));
    const y = std.math.clamp(at.y + at.h / 2 - st.card_h / 2, 8, @max(8, c.size.h - st.card_h - 8));
    ui.key(c, "rail-card");
    const box = @import("view_kit.zig").shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(8).gap(6)
        .bg(k.composer).border(k.border).borderW(1).rounded(12));
    ui.text(c, prompt, rows_st(c, 12, .{ .wrap = true, .color = k.text }));
    if (reply) |r| ui.text(c, r, rows_st(c, 11, .{ .wrap = true, .color = k.muted }));
    if (b.end - b.start > 1) ui.text(c, c.print("{d} prompts", .{b.end - b.start}), rows_st(c, 10, .{ .color = k.muted }));
    box.end();
    if (c.rects.get(c.node(box.index).id)) |r| if (r.h != st.card_h) {
        st.card_h = r.h;
        c.animationFrame();
    };
}

test "capacity and slots: what fits, at most twelve" {
    try std.testing.expectEqual(@as(usize, 64), capacity(880));
    try std.testing.expectEqual(@as(usize, 1), capacity(0));
    try std.testing.expectEqual(max_ticks, slots(880));
    try std.testing.expect(slots(100) < max_ticks);
}

test "buckets: a tick each while they fit, even buckets past that" {
    var buf: [max_ticks]Bucket = undefined;
    const one = buckets(&buf, 5, 12);
    try std.testing.expectEqual(@as(usize, 5), one.len);
    for (one, 0..) |b, i| try std.testing.expectEqual(Bucket{ .start = i, .end = i + 1 }, b);
    const many = buckets(&buf, 100, 8);
    try std.testing.expectEqual(@as(usize, 8), many.len);
    try std.testing.expectEqual(@as(usize, 100), many[7].end);
    for (many) |b| try std.testing.expect(b.end - b.start == 12 or b.end - b.start == 13);
    try std.testing.expectEqual(@as(?usize, 7), bucketOf(many, 99));
}

test "the active tick: the last prompt glued to the end, else the one being read" {
    const ticks = [_]Tick{ .{ .entry = 0, .top = -400 }, .{ .entry = 2, .top = 90 }, .{ .entry = 4, .top = 600 } };
    try std.testing.expectEqual(@as(?usize, 2), activeTick(&ticks, 48, true));
    try std.testing.expectEqual(@as(?usize, 0), activeTick(&ticks, 48, false));
    try std.testing.expectEqual(@as(?usize, 1), activeTick(&ticks, 100, false));
    const later = [_]Tick{ .{ .entry = 0, .top = 200 }, .{ .entry = 1, .top = 300 } };
    try std.testing.expectEqual(@as(?usize, 0), activeTick(&later, 48, false));
}

test "a preview's whitespace collapses and a long one is cut with an ellipsis" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("tidy the notes", truncatePreview(a, "  tidy\n\nthe   notes ", 160));
    try std.testing.expectEqualStrings("abcd…", truncatePreview(a, "abcdefgh", 5));
    try std.testing.expectEqualStrings("ab…", truncatePreview(a, "ab cdefgh", 4));
    try std.testing.expectEqualStrings("abcde", truncatePreview(a, "abcde", 5));
}
