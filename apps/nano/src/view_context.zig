//! The context ring at the composer footer's right (context_usage.rs
//! `render`) and the card it opens on hover (`UsageCard` over
//! context_window.rs `ContextWindowCard`): "Context reading", the count of
//! the window, a 62-segment bar split by what fills it, its legend, a
//! status line, graff's savings meter and the exact numbers. Nothing at all
//! for an agent that reports no window.
//!
//! The card is a gpui tooltip, so a window of its own laying its text out in
//! the system's font, not the theme's, with digits of one width where
//! `tabular_nums` asks.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const cw = @import("context_window.zig");
const App = @import("app.zig").App;

pub const State = struct {
    /// The pill as last laid out, which the card hangs from.
    anchor: ?ui.Rect = null,
    card: ?ui.Rect = null,
    hover_since: ?f64 = null,
    /// When the pointer left both the ring and the card.
    leave_since: ?f64 = null,
    /// Where the pointer was when the card opened: it hangs from there.
    at: ui.Point = .{ .x = 0, .y = 0 },
    open: bool = false,
    /// The savings meter's part under the pointer.
    saved_hover: ?cw.SavedPart = null,
};

/// How long the pointer rests on the ring before the card opens, and how
/// long the card stays once it has left both (gpui's tooltip show delay
/// and `HOVERABLE_TOOLTIP_HIDE_DELAY`).
const open_delay: f64 = 0.5;
const hide_delay: f64 = 0.5;

pub fn hasWindow(a: *const App) bool {
    return a.selected != null and (a.transcript.window orelse 0) > 0;
}

/// The ring and its percentage, muted until 75% (warning) and 90% (danger).
pub fn indicator(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.context;
    if (!hasWindow(a)) {
        s.anchor = null;
        return;
    }
    const f = cw.fraction(a.transcript.tokens, a.transcript.window);
    const color = if (f) |v| (if (v >= 0.9) k.danger else if (v >= 0.75) k.warning else k.muted) else k.faint;
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
    ui.text(c, pct, .{ .tabular = true, .size = 12, .line_height = 12 * 1.618, .color = color });
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
        s.saved_hover = null;
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

fn hexColor(h: u24) ui.Color {
    return ui.Color.hex(h);
}

fn slotColor(k: theme.Colors, slot: cw.Slot, h: cw.History) ui.Color {
    return if (slot.hex(h)) |x| hexColor(x) else k.faint;
}

const body: f32 = 12;
const caption: f32 = 11;
const title: f32 = 13;
const phi: f32 = 1.618;

/// The card, over everything, above the ring and ending at its right edge.
pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.context;
    if (!s.open or !hasWindow(a) or a.picker != .none) {
        s.card = null;
        return;
    }
    if (s.anchor == null) return;
    const b = cw.breakdown(a.transcript.tokens, a.transcript.window, a.transcript.savings, a.transcript.entries.items) orelse return;
    const w = cw.bar_width + 2 * 12 + 2;
    const h = if (s.card) |r| r.h else 300;
    const at = tooltipAt(s.at, .{ .w = w, .h = h }, c.size);
    ui.key(c, "context-usage-card");
    const card = kit.shadowLg(ui.div(c).fixed().offset(at.x, at.y).w(w).layer(6).column().p(12 + 1).gap(8)
        .bg(k.composer).border(k.border).borderW(1).rounded(12));
    defer card.end();
    if (c.rects.get(c.node(card.index).id)) |r| s.card = r;
    windowCard(c, a, k, b);
    // The exact numbers, a line each.
    var lines = std.mem.splitScalar(u8, cw.details(c.alloc(), a.transcript.tokens, a.transcript.window), '\n');
    const d = ui.div(c).column();
    defer d.end();
    while (lines.next()) |l| ui.text(c, l, .{ .system_font = true, .tabular = true, .size = body, .line_height = 19, .color = k.muted });
}

/// `ContextWindowCard`, settled (no transition in flight).
fn windowCard(c: *ui.Context, a: *App, k: theme.Colors, b: cw.Breakdown) void {
    const box = ui.div(c).column().w(cw.bar_width).gap(10);
    defer box.end();
    {
        const head = ui.div(c).row().wFull().itemsCenter();
        defer head.end();
        ui.text(c, "Context", .{ .system_font = true, .size = title, .line_height = title * phi, .color = k.text });
        _ = c.leaf(.{ .width = .{ .px = 4 } }, .none, null);
        ui.text(c, if (b.compacting) "compacting" else "reading", .{ .system_font = true, .size = title, .line_height = title * phi, .color = k.muted });
        ui.spacer(c);
        var x: [16]u8 = undefined;
        var y: [16]u8 = undefined;
        counter(c, k, cw.compactCount(&x, b.tokens));
        _ = c.leaf(.{ .width = .{ .px = 3 } }, .none, null);
        ui.text(c, c.print("of {s}", .{cw.compactCount(&y, b.window)}), .{ .system_font = true, .tabular = true, .size = title, .line_height = title * phi, .color = k.faint });
    }
    {
        // Each slot's segments, then the empty track.
        const bar = ui.div(c).row().gap(cw.segment_gap);
        defer bar.end();
        const counts = cw.segmentCounts(b);
        var drawn: usize = 0;
        for (cw.Slot.all, counts) |slot, n| for (0..n) |_| {
            segment(c, slotColor(k, slot, b.history), cw.segment_h);
            drawn += 1;
        };
        while (drawn < cw.segments) : (drawn += 1) segment(c, k.faint.alpha(0.22), cw.segment_h);
    }
    legend(c, k, b);
    ui.text(c, cw.statusLine(c.alloc(), b), .{ .system_font = true, .tabular = true, .size = body, .line_height = body * phi, .color = k.faint });
    if (a.transcript.savings) |sv| savingsMeter(c, a, k, sv, b);
    ui.text(c, if (b.history == .sealed) "Compacted context is sealed by the provider: size only." else "Split estimated from this chat; total reported by the agent.", .{ .system_font = true, .size = caption, .line_height = caption * phi, .color = k.faint });
}

/// The rolling counter (`rolling_count`), settled: each character a box of
/// its own, so no kerning, its width on a device pixel. The system's font has
/// no medium cut for GPUI's matcher, so `WEIGHT_STRONG` reads regular here.
fn counter(c: *ui.Context, k: theme.Colors, count: []const u8) void {
    const st: ui.TextStyle = .{ .system_font = true, .tabular = true, .size = title, .line_height = 16, .color = k.text };
    const row = ui.div(c).row().h(16).clip();
    defer row.end();
    for (count, 0..) |_, i| {
        const ch = c.alloc().dupe(u8, count[i .. i + 1]) catch return;
        const w = @ceil(c.text.width(ch, st) * c.scale) / c.scale;
        const box = ui.div(c).row().w(w).h(16);
        defer box.end();
        ui.text(c, ch, st);
    }
}

fn segment(c: *ui.Context, color: ui.Color, h: f32) void {
    _ = c.leaf(.{ .width = .{ .px = cw.segment_w }, .height = .{ .px = h }, .radius = 1.5, .background = color }, .none, null);
}

/// Two columns of what fills the context: a marker, the label, the count.
fn legend(c: *ui.Context, k: theme.Colors, b: cw.Breakdown) void {
    const col = @floor((cw.bar_width - 12) / 2);
    const box = ui.div(c).column().gap(8);
    defer box.end();
    var row: ?ui.Div = null;
    var n: usize = 0;
    for (cw.Slot.all) |slot| {
        const tokens = b.items[@intFromEnum(slot)];
        if (tokens == 0) continue;
        if (n % 2 == 0) {
            if (row) |r| r.end();
            row = ui.div(c).row().gap(12);
        }
        n += 1;
        const e = ui.div(c).row().w(col).gap(6).itemsCenter().clip();
        defer e.end();
        marker(c, if (slot == .history) b.history else .chat, slotColor(k, slot, b.history));
        const words = ui.div(c).row().gap(4).itemsCenter();
        defer words.end();
        ui.text(c, slot.label(b.history), .{ .system_font = true, .tabular = true, .size = body, .line_height = body * phi, .color = k.text });
        var buf: [16]u8 = undefined;
        ui.text(c, c.print("{s}", .{cw.compactCount(&buf, tokens)}), .{ .system_font = true, .tabular = true, .size = body, .line_height = body * phi, .color = k.faint });
    }
    if (row) |r| r.end();
}

/// A dot for live content, a block with three lines for a readable
/// summary, a padlock for a sealed item (`legend_marker`).
fn marker(c: *ui.Context, shape: cw.History, color: ui.Color) void {
    const slot = ui.div(c).row().size(10, 10).center().offset(0, 1);
    defer slot.end();
    switch (shape) {
        .chat => _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = color }, .none, null),
        .summary => {
            const blk = ui.div(c).column().size(10, 10).rounded(2).bg(color).px(2).gap(1).justifyCenter();
            defer blk.end();
            for ([_]f32{ 6, 6, 4 }) |lw| _ = c.leaf(.{ .width = .{ .px = lw }, .height = .{ .px = 1 }, .background = ui.Color.white.alpha(0.9) }, .none, null);
        },
        .sealed => {
            const lock = ui.div(c).column().itemsCenter();
            defer lock.end();
            ui.div(c).w(6).h(5).border(color).borderW(1.5).rounded(3).end();
            _ = c.leaf(.{ .width = .{ .px = 9 }, .height = .{ .px = 6 }, .radius = 1.5, .background = color, .offset = .{ .y = -2 } }, .none, null);
        },
    }
}

/// graff's savings: one number, then a meter of what's in context and
/// what graff kept out; hovering a part names its count (`savings_meter`).
fn savingsMeter(c: *ui.Context, a: *App, k: theme.Colors, sv: @import("transcript.zig").Savings, b: cw.Breakdown) void {
    const kept = sv.keptOut();
    if (kept == 0) return;
    const s = &a.view.context;
    const parts = cw.savedSegments(.{ .{ .in_context, a.transcript.tokens orelse 0 }, .{ .files, sv.handleTokens() }, .{ .compaction, sv.compacted_tokens } });
    const box = ui.div(c).column().gap(6).pt(2);
    defer box.end();
    {
        const head = ui.div(c).row().gap(4).itemsEnd();
        defer head.end();
        var buf: [16]u8 = undefined;
        ui.text(c, c.print("{s}", .{cw.compactCount(&buf, kept)}), .{ .system_font = true, .tabular = true, .size = title, .line_height = title * phi, .color = k.text });
        ui.text(c, "saved by graff", .{ .system_font = true, .tabular = true, .size = body, .line_height = title * phi, .color = k.muted });
    }
    var hovered: ?cw.SavedPart = null;
    {
        const meter = ui.div(c).row().h(8).gap(cw.segment_gap);
        defer meter.end();
        for (parts.slice()) |p| {
            const color = partColor(k, p.part, b.history);
            const dim = s.saved_hover != null and s.saved_hover.? != p.part;
            // A thin meter, a full-height target: 12 above and below.
            ui.key(c, c.print("context-saved-{s}", .{@tagName(p.part)}));
            const g = ui.div(c).row().gap(cw.segment_gap).py(12).offset(0, -12);
            defer g.end();
            if (g.hovered()) hovered = p.part;
            for (0..p.count) |_| segment(c, if (dim) color.alpha(0.35) else color, 8);
        }
    }
    if (hovered != s.saved_hover) {
        s.saved_hover = hovered;
        c.changed = true;
    }
    const line = ui.div(c).row().h(16).gap(10).itemsCenter();
    defer line.end();
    const found = if (s.saved_hover) |h| for (parts.slice()) |p| {
        if (p.part == h) break p;
    } else null else null;
    if (found) |p| {
        ui.text(c, p.part.detail(c.alloc(), p.tokens), .{ .system_font = true, .tabular = true, .size = caption, .color = k.muted });
        return;
    }
    for (parts.slice()) |p| {
        const e = ui.div(c).row().gap(5).itemsCenter();
        defer e.end();
        _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 1.5, .background = partColor(k, p.part, b.history) }, .none, null);
        ui.text(c, p.part.label(), .{ .system_font = true, .tabular = true, .size = caption, .color = k.faint });
    }
}

/// Calm tones: neutral for what's in context, the legend's own colours for
/// files and compaction (the summary blue even when sealed).
fn partColor(k: theme.Colors, p: cw.SavedPart, h: cw.History) ui.Color {
    return switch (p) {
        .in_context => k.muted.alpha(0.75),
        .files => slotColor(k, .files, h),
        .compaction => slotColor(k, .history, .summary),
    };
}
