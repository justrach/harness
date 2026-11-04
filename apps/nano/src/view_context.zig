//! The context ring at the composer footer's right, and the card it opens
//! on hover: a dot matrix of the window (one dot per slice), a legend, and
//! Compact. While a compaction runs, the dots it is freeing pulse and the
//! percent rolls; when the chip resolves, the grid eases to the new counts.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const cw = @import("context_window.zig");
const App = @import("app.zig").App;

pub const Phase = enum { idle, compacting, settling };

pub const State = struct {
    /// The pill as last laid out, which the card hangs from.
    anchor: ?ui.Rect = null,
    card: ?ui.Rect = null,
    /// The dot grid as last laid out, for the hover highlight.
    grid: ?ui.Rect = null,
    hover_since: ?f64 = null,
    /// When the pointer left both the ring and the card.
    leave_since: ?f64 = null,
    /// Where the pointer was when the card opened: it hangs from there.
    at: ui.Point = .{ .x = 0, .y = 0 },
    open: bool = false,
    /// Legend or grid category under the pointer: a slot, or free.
    focus: ?Focus = null,
    /// Animation: a start time and the before/after dot counts. Tokens
    /// roll with the same clock. `frame` keeps a frame from syncing twice.
    frame: u64 = 0,
    start: f64 = 0,
    before: [cw.Slot.all.len]usize = @splat(0),
    after: [cw.Slot.all.len]usize = @splat(0),
    before_tokens: u64 = 0,
    after_tokens: u64 = 0,
    phase: Phase = .idle,
};

pub const Focus = union(enum) { slot: cw.Slot, free };

/// How long the pointer rests on the ring before the card opens, and how
/// long the card stays once it has left both (gpui's tooltip show delay
/// and `HOVERABLE_TOOLTIP_HIDE_DELAY`).
const open_delay: f64 = 0.5;
const hide_delay: f64 = 0.5;
const compact_s: f64 = 0.8;
const settle_s: f64 = 0.55;

const dot: f32 = 9;
const gap: f32 = 4;
const grid_w: f32 = @as(f32, cw.grid_cols) * (dot + gap) - gap;
const grid_h: f32 = @as(f32, cw.grid_rows) * (dot + gap) - gap;

pub fn hasWindow(a: *const App) bool {
    return a.selected != null and (a.transcript.window orelse 0) > 0;
}

/// True while a compaction is running and the inline meter is drawn.
pub fn inlineShown(a: *const App) bool {
    return a.view.context.phase == .compacting;
}

/// The ring and its percentage, muted until 75% (warning) and 90% (danger).
pub fn indicator(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.context;
    sync(c, a);
    if (!hasWindow(a)) {
        s.anchor = null;
        return;
    }
    const b = breakdown(a) orelse return;
    const used = shownTokens(s, b, c.time, c.reduced_motion);
    const f = cw.fraction(used, b.window);
    const color = if (s.phase == .compacting)
        k.accent
    else if (f) |v| (if (v >= 0.9) k.danger else if (v >= 0.75) k.warning else k.muted) else k.faint;
    ui.key(c, "context-usage");
    // A hit target at least 32 wide, the row's full height.
    const hit = ui.div(c).row().minW(32).hFull().center();
    defer hit.end();
    const hot = hit.hovered() or s.open;
    var pill = ui.div(c).row().h(24).px(6).gap(5).itemsCenter().rounded(6);
    if (hot) pill = pill.bg(k.ink(0.05));
    defer pill.end();
    if (c.rects.get(c.node(pill.index).id)) |r| s.anchor = r;
    ring(c, f, color, k.faint.alpha(0.25));
    const pct = if (f) |v| c.print("{d:.0}%", .{v * 100}) else "—";
    ui.text(c, pct, .{ .size = 12, .line_height = 12 * 1.618, .color = color });
    // Open after a rest; the card keeps itself open while the pointer is
    // over it (`hoverable`), so its meter's parts can be hovered.
    const over_card = if (s.card) |r| inside(c.input.mouse, r) else false;
    if (hit.hovered()) {
        s.leave_since = null;
        if (s.hover_since == null) s.hover_since = c.time;
        const waited = c.time - s.hover_since.?;
        if (!s.open and waited >= open_delay) {
            s.open = true;
            s.at = c.input.mouse;
            c.changed = true;
        } else if (!s.open) c.frameIn(@floatCast(open_delay - waited));
    } else if (over_card and s.open) {
        s.leave_since = null;
    } else {
        s.hover_since = null;
        if (!s.open) return;
        if (s.leave_since == null) s.leave_since = c.time;
        const gone = c.time - s.leave_since.?;
        if (gone < hide_delay) return c.frameIn(@floatCast(hide_delay - gone));
        s.open = false;
        s.leave_since = null;
        s.focus = null;
        c.changed = true;
    }
}

/// Where gpui puts a tooltip (`prepaint_tooltip`): a point below and right
/// of the pointer, else left of it, else above it, never off the window.
pub fn tooltipAt(mouse: ui.Point, size: ui.Size, window: ui.Size) ui.Point {
    var x = mouse.x + 1;
    var y = mouse.y + 1;
    if (x + size.w > window.w) x = if (mouse.x - size.w - 1 >= 0) mouse.x - size.w - 1 else @max(0, x - (x + size.w) - window.w);
    if (y + size.h > window.h) y = if (mouse.y - size.h - 1 >= 0) mouse.y - size.h - 1 else @max(0, y - (y + size.h) - window.h);
    return .{ .x = x, .y = y };
}

test "the card hangs from the pointer as gpui's tooltips do, flipping to fit" {
    const win: ui.Size = .{ .w = 1200, .h = 780 };
    const below = tooltipAt(.{ .x = 100, .y = 100 }, .{ .w = 396, .h = 300 }, win);
    try std.testing.expectEqual(@as(f32, 101), below.x);
    try std.testing.expectEqual(@as(f32, 101), below.y);
    const corner = tooltipAt(.{ .x = 1068, .y = 760 }, .{ .w = 396, .h = 300 }, win);
    try std.testing.expectEqual(@as(f32, 1068 - 396 - 1), corner.x);
    try std.testing.expectEqual(@as(f32, 760 - 300 - 1), corner.y);
}

/// Above the composer, its right edge on the ring's, so the card and its
/// Compact button clear the send button and the window's corner.
fn cardAt(anchor: ui.Rect, ceiling: f32, size: ui.Size, window: ui.Size) ui.Point {
    const margin: f32 = 12;
    var x = anchor.x + anchor.w - size.w;
    if (x + size.w > window.w - margin) x = @max(margin, window.w - margin - size.w);
    if (x < margin) x = margin;
    var y = ceiling - size.h - 8;
    if (y < margin) y = margin;
    return .{ .x = x, .y = y };
}

fn inside(p: ui.Point, r: ui.Rect) bool {
    return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
}

/// A 16-point ring: the track whole, the fill an arc from twelve o'clock.
fn ring(c: *ui.Context, fraction: ?f32, color: ui.Color, track: ui.Color) void {
    const cv = ui.canvas(c, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    const center: ui.Point = .{ .x = 8, .y = 8 };
    cv.ring(center, 6 + 0.9, 1.8, track);
    const f = std.math.clamp(fraction orelse 0, 0, 1);
    if (f <= 0) return;
    const steps: usize = @intFromFloat(@max(2, @ceil(64 * f)));
    const points = c.alloc().alloc(ui.Point, steps + 1) catch return;
    for (points, 0..) |*p, i| {
        const angle = -std.math.pi / 2.0 + std.math.tau * f * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        p.* = .{ .x = center.x + 6 * @cos(angle), .y = center.y + 6 * @sin(angle) };
    }
    cv.polyline(points, .{ .width = 1.8, .color = color });
}

fn breakdown(a: *const App) ?cw.Breakdown {
    return cw.breakdown(a.transcript.tokens, a.transcript.window, a.transcript.savings, a.transcript.entries.items);
}

fn ease(t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return x * x * (3 - 2 * x);
}

fn progress(s: *const State, time: f64) f32 {
    const dur = if (s.phase == .compacting) compact_s else settle_s;
    return ease(@floatCast((time - s.start) / dur));
}

fn sumDots(counts: [cw.Slot.all.len]usize) usize {
    var n: usize = 0;
    for (counts) |c| n += c;
    return n;
}

fn projectTokens(b: cw.Breakdown, before: [cw.Slot.all.len]usize, after: [cw.Slot.all.len]usize) u64 {
    const from = sumDots(before);
    const to = sumDots(after);
    if (from == 0 or to >= from) return b.tokens;
    return @as(u64, @intCast(@as(u128, b.tokens) * to / from));
}

/// One sync a frame: capture the grid when a compaction starts, and ease
/// to the resolved counts when it finishes. Reduced motion skips both.
fn sync(c: *ui.Context, a: *App) void {
    const s = &a.view.context;
    if (s.frame == c.frame) return;
    s.frame = c.frame;
    const b = breakdown(a) orelse {
        s.phase = .idle;
        return;
    };
    const now = cw.gridCounts(b);
    if (b.compacting) {
        if (s.phase != .compacting) {
            s.before = now;
            s.after = cw.projectCompact(now);
            s.before_tokens = b.tokens;
            s.after_tokens = projectTokens(b, s.before, s.after);
            s.start = c.time;
            s.phase = .compacting;
        }
        if (!c.reduced_motion) c.frameIn(1.0 / 30.0);
        return;
    }
    if (s.phase == .compacting) {
        if (c.reduced_motion) {
            s.phase = .idle;
            return;
        }
        s.before = shownCounts(s, b, c.time, false);
        s.before_tokens = shownTokens(s, b, c.time, false);
        s.after = now;
        s.after_tokens = b.tokens;
        s.start = c.time;
        s.phase = .settling;
    }
    if (s.phase == .settling) {
        if (c.time - s.start >= settle_s) s.phase = .idle else c.frameIn(1.0 / 30.0);
    }
}

fn shownCounts(s: *const State, b: cw.Breakdown, time: f64, reduced: bool) [cw.Slot.all.len]usize {
    if (s.phase == .idle or reduced) return cw.gridCounts(b);
    const t = progress(s, time);
    var out: [cw.Slot.all.len]usize = undefined;
    for (s.before, s.after, &out) |from, to, *n| {
        const v = @as(f32, @floatFromInt(from)) + (@as(f32, @floatFromInt(to)) - @as(f32, @floatFromInt(from))) * t;
        n.* = @intFromFloat(@max(0, @round(v)));
    }
    return out;
}

fn shownTokens(s: *const State, b: cw.Breakdown, time: f64, reduced: bool) u64 {
    if (s.phase == .idle or reduced) return b.tokens;
    const t: f64 = progress(s, time);
    const from: f64 = @floatFromInt(s.before_tokens);
    const to: f64 = @floatFromInt(s.after_tokens);
    return @intFromFloat(@max(0, @round(from + (to - from) * t)));
}

fn catAt(counts: [cw.Slot.all.len]usize, i: usize) ?cw.Slot {
    var at: usize = 0;
    for (cw.Slot.all, counts) |slot, n| {
        if (i < at + n) return slot;
        at += n;
    }
    return null;
}

fn hexColor(h: u24) ui.Color {
    return ui.Color.hex(h);
}

fn slotColor(k: theme.Colors, slot: cw.Slot, h: cw.History) ui.Color {
    // System has no hue of its own; muted still reads as filled against
    // the faint empty dots, in light and in dark.
    if (slot == .system) return k.muted;
    return if (slot.hex(h)) |x| hexColor(x) else k.faint;
}

fn countText(c: *ui.Context, n: u64) []const u8 {
    var buf: [16]u8 = undefined;
    return c.print("{s}", .{cw.compactCount(&buf, n)});
}

fn percent(tokens: u64, window: u64) u64 {
    if (window == 0) return 0;
    return (tokens * 100 + window / 2) / window;
}

fn percentText(c: *ui.Context, tokens: u64, window: u64) []const u8 {
    if (tokens > 0 and percent(tokens, window) == 0) return "<1%";
    return c.print("{d}%", .{percent(tokens, window)});
}

const body: f32 = 12;
const caption: f32 = 11;
const title: f32 = 13;
const phi: f32 = 1.618;

/// The card, over everything, hanging from the pointer that opened it.
pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.context;
    sync(c, a);
    if (!s.open or !hasWindow(a) or a.picker != .none) {
        s.card = null;
        return;
    }
    if (s.anchor == null) return;
    const b = breakdown(a) orelse return;
    const w = grid_w + 2 * 14 + 2;
    const h = if (s.card) |r| r.h else 380;
    const ceiling = if (a.view.composer_anchor) |pill| pill.y else if (s.anchor) |r| r.y else c.size.h;
    const at = if (s.anchor) |anchor| cardAt(anchor, ceiling, .{ .w = w, .h = h }, c.size) else tooltipAt(s.at, .{ .w = w, .h = h }, c.size);
    ui.key(c, "context-usage-card");
    const card = kit.shadowLg(ui.div(c).fixed().offset(at.x, at.y).w(w).layer(6).column().p(14).gap(12)
        .bg(k.composer).border(k.border).borderW(1).rounded(16));
    defer card.end();
    if (c.rects.get(c.node(card.index).id)) |r| s.card = r;
    windowCard(c, a, k, b);
}

fn windowCard(c: *ui.Context, a: *App, k: theme.Colors, b: cw.Breakdown) void {
    const s = &a.view.context;
    const reduced = c.reduced_motion;
    const counts = shownCounts(s, b, c.time, reduced);
    const used = shownTokens(s, b, c.time, reduced);
    const busy = s.phase == .compacting or b.compacting;
    {
        const head = ui.div(c).row().wFull().itemsCenter();
        defer head.end();
        ui.text(c, "Context", .{ .size = title, .line_height = title * phi, .weight = .medium, .color = k.text });
        if (busy) {
            _ = c.leaf(.{ .width = .{ .px = 6 } }, .none, null);
            ui.text(c, "compacting", .{ .size = title, .line_height = title * phi, .color = k.muted });
        }
        ui.spacer(c);
        headerFigures(c, a, k, b, used);
    }
    var hovered = s.focus;
    dotGrid(c, a, k, b, counts, &hovered);
    legend(c, a, k, b, counts, used, &hovered);
    if (!std.meta.eql(hovered, s.focus)) {
        s.focus = hovered;
        c.changed = true;
    }
    if (a.transcript.savings) |sv| {
        if (sv.keptOut() > 0) ui.text(c, c.print("{s} saved by graff", .{countText(c, sv.keptOut())}), .{ .size = caption, .line_height = caption * phi, .color = k.faint });
    }
    compactButton(c, a, k, busy);
}

fn headerFigures(c: *ui.Context, a: *App, k: theme.Colors, b: cw.Breakdown, used: u64) void {
    const s = &a.view.context;
    if (s.focus) |f| switch (f) {
        .slot => |slot| {
            const tokens = b.items[@intFromEnum(slot)];
            const name = slot.label(b.history);
            const n = countText(c, tokens);
            ui.text(c, c.print("{s}  {s}", .{ name, n }), .{ .size = body, .line_height = title * phi, .color = k.text });
            return;
        },
        .free => {
            ui.text(c, c.print("Free  {s}", .{countText(c, b.window -| b.tokens)}), .{ .size = body, .line_height = title * phi, .color = k.text });
            return;
        },
    };
    const pct = percent(used, b.window);
    const left = countText(c, used);
    const right = countText(c, b.window);
    ui.text(c, c.print("{d}% ({s} / {s})", .{ pct, left, right }), .{ .size = body, .line_height = title * phi, .weight = .medium, .color = k.text });
}

fn dotGrid(c: *ui.Context, a: *App, k: theme.Colors, b: cw.Breakdown, counts: [cw.Slot.all.len]usize, hovered: *?Focus) void {
    const s = &a.view.context;
    ui.key(c, "context-grid");
    const box = ui.div(c).row().size(grid_w, grid_h);
    defer box.end();
    if (c.rects.get(c.node(box.index).id)) |r| {
        s.grid = r;
        if (box.hovered()) {
            if (dotIndex(c.input.mouse, r)) |i| {
                hovered.* = if (catAt(counts, i)) |slot| .{ .slot = slot } else .free;
            }
        }
    }
    const from = if (s.phase == .idle or c.reduced_motion) counts else s.before;
    const to = counts;
    const t: f32 = if (s.phase == .idle or c.reduced_motion) 1 else progress(s, c.time);
    const cv = ui.canvas(c, .{ .width = .{ .px = grid_w }, .height = .{ .px = grid_h } });
    for (0..cw.grid_dots) |i| {
        const col: f32 = @floatFromInt(i % cw.grid_cols);
        const row: f32 = @floatFromInt(i / cw.grid_cols);
        const from_slot = catAt(from, i);
        const to_slot = catAt(to, i);
        var color = blend(dotFill(k, b, from_slot), dotFill(k, b, to_slot), t);
        const shown = if (t < 0.5) from_slot else to_slot;
        if (s.focus) |f| {
            if (!focusMatches(f, shown)) color.a *= 0.22;
        }
        var side = dot;
        if (s.phase == .compacting and !c.reduced_motion) if (from_slot) |slot| {
            if (cw.freedSlot(slot)) {
                const wave = @sin(@as(f32, @floatCast(c.time)) * 8 + @as(f32, @floatFromInt(i)) * 0.35);
                const pulse = 0.35 + 0.65 * (0.5 + 0.5 * wave);
                color.a *= pulse;
                side = dot * (0.72 + 0.28 * pulse);
            }
        };
        const inset = (dot - side) / 2;
        cv.rect(.{
            .x = col * (dot + gap) + inset,
            .y = row * (dot + gap) + inset,
            .w = side,
            .h = side,
        }, color, 2.5);
    }
}

fn dotIndex(mouse: ui.Point, origin: ui.Rect) ?usize {
    if (mouse.x < origin.x or mouse.y < origin.y) return null;
    const col: usize = @intFromFloat(@floor((mouse.x - origin.x) / (dot + gap)));
    const row: usize = @intFromFloat(@floor((mouse.y - origin.y) / (dot + gap)));
    if (col >= cw.grid_cols or row >= cw.grid_rows) return null;
    return row * cw.grid_cols + col;
}

fn dotFill(k: theme.Colors, b: cw.Breakdown, slot: ?cw.Slot) ui.Color {
    const s = slot orelse return k.ink(0.14);
    return slotColor(k, s, b.history);
}

fn blend(from: ui.Color, to: ui.Color, t: f32) ui.Color {
    return .{
        .r = from.r + (to.r - from.r) * t,
        .g = from.g + (to.g - from.g) * t,
        .b = from.b + (to.b - from.b) * t,
        .a = from.a + (to.a - from.a) * t,
    };
}

fn focusMatches(f: Focus, slot: ?cw.Slot) bool {
    return switch (f) {
        .free => slot == null,
        .slot => |s| if (slot) |got| s == got else false,
    };
}

fn legend(c: *ui.Context, a: *App, k: theme.Colors, b: cw.Breakdown, counts: [cw.Slot.all.len]usize, used: u64, hovered: *?Focus) void {
    const box = ui.div(c).column().wFull().gap(2);
    defer box.end();
    const rolling = a.view.context.phase != .idle and !c.reduced_motion;
    for (cw.Slot.all, counts) |slot, n| {
        const tokens = if (rolling) b.window * @as(u64, n) / cw.grid_dots else b.items[@intFromEnum(slot)];
        if (tokens == 0 and n == 0) continue;
        legendRow(c, k, slot.label(b.history), slotColor(k, slot, b.history), tokens, b.window, hovered, .{ .slot = slot });
    }
    const free = b.window -| used;
    if (free > 0 or sumDots(counts) < cw.grid_dots) {
        legendRow(c, k, "Free", k.ink(0.28), free, b.window, hovered, .free);
    }
}

fn legendRow(c: *ui.Context, k: theme.Colors, label: []const u8, color: ui.Color, tokens: u64, window: u64, hovered: *?Focus, focus: Focus) void {
    ui.key(c, c.print("context-legend-{s}", .{label}));
    var row = ui.div(c).row().wFull().h(22).px(4).gap(8).itemsCenter().rounded(6);
    const hot = row.hovered() or std.meta.eql(hovered.*, focus);
    if (hot) row = row.bg(k.ink(0.05));
    defer row.end();
    if (row.hovered()) hovered.* = focus;
    _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 2.5, .background = color }, .none, null);
    ui.text(c, label, .{ .size = body, .line_height = body * phi, .color = k.text });
    ui.spacer(c);
    ui.text(c, countText(c, tokens), .{ .size = body, .line_height = body * phi, .color = k.muted });
    {
        const pct = ui.div(c).row().w(36).justifyEnd();
        defer pct.end();
        ui.text(c, percentText(c, tokens, window), .{ .size = body, .line_height = body * phi, .color = k.faint });
    }
}

fn compactButton(c: *ui.Context, a: *App, k: theme.Colors, busy: bool) void {
    const row = ui.div(c).row().wFull().itemsCenter();
    defer row.end();
    ui.spacer(c);
    const can = !busy and a.engine.state == .connected and a.selected != null;
    ui.key(c, "context-compact");
    var btn = ui.div(c).row().h(28).px(12).itemsCenter().rounded(14);
    btn = btn.bg(if (can and btn.hovered()) k.ink(0.1) else k.ink(0.06));
    defer btn.end();
    if (can and btn.clicked()) a.sendPrompt("/compact");
    ui.text(c, if (busy) "Compacting…" else "Compact", .{ .size = body, .line_height = body * phi, .weight = .medium, .color = if (can) k.text else k.faint });
}

/// A one-row meter beside a running compaction chip, so the shrink is
/// visible without opening the card. Dots follow the card's animation.
pub fn inlineMeter(c: *ui.Context, a: *App, k: theme.Colors) void {
    sync(c, a);
    const b = breakdown(a) orelse return;
    if (a.view.context.phase != .compacting and !b.compacting) return;
    const counts = shownCounts(&a.view.context, b, c.time, c.reduced_motion);
    ui.key(c, "context-inline-meter");
    const row = ui.div(c).row().gap(6).itemsCenter();
    defer row.end();
    const slices: usize = 18;
    const cell: f32 = 6;
    const pitch: f32 = 3;
    const w = @as(f32, @floatFromInt(slices)) * (cell + pitch) - pitch;
    const cv = ui.canvas(c, .{ .width = .{ .px = w }, .height = .{ .px = cell } });
    for (0..slices) |i| {
        const at = i * cw.grid_dots / slices;
        const slot = catAt(counts, at);
        var color = dotFill(k, b, slot);
        if (a.view.context.phase == .compacting and !c.reduced_motion) if (slot) |s| {
            if (cw.freedSlot(s)) {
                const wave = @sin(@as(f32, @floatCast(c.time)) * 8 + @as(f32, @floatFromInt(i)) * 0.5);
                color.a *= 0.35 + 0.65 * (0.5 + 0.5 * wave);
            }
        };
        cv.rect(.{ .x = @as(f32, @floatFromInt(i)) * (cell + pitch), .y = 0, .w = cell, .h = cell }, color, 1.5);
    }
    ui.text(c, "compacting", .{ .size = caption, .line_height = caption * phi, .color = k.muted });
}
