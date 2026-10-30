//! Dragging a session from the sidebar onto the chat splits it there, as
//! the GPUI app's (`render_split_drop_zones`, shell/chat_split.rs): while a
//! row is dragged, two targets lie over the chat, "Open to the right" down
//! its right edge and "Open below" along its foot; dropping on one opens
//! the session in a new pane that way. The row rides under the pointer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const sidebar = @import("view_sidebar.zig");
const transcript_view = @import("view_transcript.zig");
const tabs = @import("tabs.zig");
const pins = @import("pins.zig");
const App = @import("app.zig").App;

/// A row pressed: the session, where the press was, and whether the
/// pointer has gone far enough to be a drag.
pub const Drag = struct {
    id: std.ArrayList(u8) = .empty,
    origin: ui.Point = .{},
    /// The press's offset into its row, so the row rides where it was held,
    /// and the row's place then.
    grip: ui.Point = .{},
    row: ui.Rect = .{},
    active: bool = false,
    /// Where it would land in the sidebar, as of this frame.
    target: ?pins.Target = null,
    /// Let go on a target: done at the next frame's start (`update`).
    drop: ?Drop = null,

    pub const Drop = union(enum) { split: tabs.Axis, sidebar: pins.Target };

    pub fn deinit(d: *Drag, gpa: std.mem.Allocator) void {
        d.id.deinit(gpa);
    }
};

/// How far the pointer goes, held, before a press is a drag.
const threshold: f32 = 4;

/// From a session row pressed this frame.
pub fn press(c: *ui.Context, a: *App, chat_id: []const u8, row: ?ui.Rect) void {
    const d = &a.view.drag;
    d.id.clearRetainingCapacity();
    d.id.appendSlice(a.gpa, chat_id) catch return;
    d.origin = c.input.mouse;
    d.grip = if (row) |r| .{ .x = c.input.mouse.x - r.x, .y = c.input.mouse.y - r.y } else .{};
    d.row = row orelse .{};
    d.active = false;
    d.target = null;
}

/// The session being dragged, once it is a drag.
pub fn moving(a: *const App) ?[]const u8 {
    return if (a.view.drag.active) a.view.drag.id.items else null;
}

pub fn sidebarTarget(a: *const App) ?pins.Target {
    return if (a.view.drag.active) a.view.drag.target else null;
}

/// Where in the sidebar the pointer would drop it: the Pinned header (the
/// top of the pins), among the pins (after a row past its middle; a pin
/// taking the place it's over), or the Sessions header and rows (unpinned).
/// Elsewhere, nowhere (`SidebarSessionDrop`).
fn targetAt(a: *const App, p: ui.Point, from_pins: bool, pin_count: usize) ?pins.Target {
    const v = &a.view;
    if (!a.view.sidebar_open or a.view.settings_open or p.x < 0 or p.x >= v.sidebar_width) return null;
    if (v.pin_header) |r| if (r.contains(p)) return .{ .pinned = 0 };
    if (v.pin_rows) |r| if (p.y >= r.y and p.y <= r.y + @max(r.h, sidebar.row_slot)) {
        if (pin_count == 0) return .{ .pinned = 0 };
        const rel = p.y - r.y - 4;
        if (from_pins) {
            var heights: [256]f32 = undefined;
            const n = @min(pin_count, heights.len);
            @memset(heights[0..n], sidebar.row_slot - 2);
            return .{ .pinned = pins.rowDropIndex(rel, heights[0..n], 2, true) orelse 0 };
        }
        const ix: usize = @intFromFloat(@max(0, @floor(rel / sidebar.row_slot)));
        const within = rel - @as(f32, @floatFromInt(ix)) * sidebar.row_slot;
        return .{ .pinned = @min(ix + @intFromBool(within >= (sidebar.row_slot - 2) / 2), pin_count) };
    };
    if (v.sessions_header) |r| if (r.contains(p)) return .regular;
    if (v.session_rows) |r| if (p.y >= r.y - 2 and p.y <= r.y + @max(r.h, 48)) return .regular;
    return null;
}

/// Whether a session is being dragged: its row's click is the drop's.
pub fn dragging(a: *const App) bool {
    return a.view.drag.active;
}

/// Early each frame: last frame's drop done, before anything is drawn (a
/// split opens a chat, and the transcript drawn with the release would be
/// freed under the frame still laying it out); and a press becomes a drag
/// once it has moved far enough.
pub fn update(c: *ui.Context, a: *App) void {
    const d = &a.view.drag;
    if (d.drop) |drop| {
        d.drop = null;
        const id = a.gpa.dupe(u8, d.id.items) catch "";
        defer if (id.len > 0) a.gpa.free(id);
        d.id.clearRetainingCapacity();
        if (id.len > 0) switch (drop) {
            .split => |axis| a.splitOpening(axis, id),
            .sidebar => |t| dropInSidebar(a, a.gpa, id, t),
        };
        return;
    }
    if (d.id.items.len == 0) return;
    if (!d.active and c.input.down) {
        const dx = c.input.mouse.x - d.origin.x;
        const dy = c.input.mouse.y - d.origin.y;
        if (dx * dx + dy * dy >= threshold * threshold) d.active = true;
    }
    if (!d.active) return;
    const visible = sidebar.visiblePins(a, c.alloc());
    var from_pins = false;
    for (visible) |p| from_pins = from_pins or std.mem.eql(u8, p, d.id.items);
    d.target = targetAt(a, c.input.mouse, from_pins, visible.len);
}

/// Dropped in the sidebar: the pins as `pins.dropPins` has them, written
/// when they change, and the section it went to opened.
fn dropInSidebar(a: *App, gpa: std.mem.Allocator, id: []const u8, target: pins.Target) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const visible = sidebar.visiblePins(a, ar);
    const next = pins.dropPins(ar, a.settings.pins.items, visible, id, target) catch return;
    var same = next.len == a.settings.pins.items.len;
    if (same) for (next, a.settings.pins.items) |x, y| {
        same = same and std.mem.eql(u8, x, y);
    };
    if (!same) a.settings.setPins(next);
    switch (target) {
        .pinned => a.view.pinned_open = true,
        .regular => a.view.sessions_open = true,
    }
}

const Zone = struct { rect: ui.Rect, axis: tabs.Axis, label: []const u8 };

/// The targets over the chat column (`chat-drop-right`, `chat-drop-below`):
/// the right one 30% of its width below the title bar, the one below 28% of
/// its height, clear of the right one; both 8 points in.
pub fn zones(a: *const App, x0: f32, w: f32, h: f32, out: *[2]Zone) []Zone {
    var n: usize = 0;
    const right = a.tabs.canSplit(.horizontal);
    const below = a.tabs.canSplit(.vertical);
    if (right) {
        out[n] = .{ .rect = .{ .x = x0 + w - 8 - w * 0.3, .y = sidebar.titlebar_h + 8, .w = w * 0.3, .h = h - 16 - sidebar.titlebar_h }, .axis = .horizontal, .label = "Open to the right ◨" };
        n += 1;
    }
    if (below) {
        const end = if (right) x0 + w - w * 0.33 else x0 + w - 8;
        out[n] = .{ .rect = .{ .x = x0 + 8, .y = h - 8 - h * 0.28, .w = end - x0 - 8, .h = h * 0.28 }, .axis = .vertical, .label = "Open below ⬓" };
        n += 1;
    }
    return out[0..n];
}

/// Over everything, while a session is dragged: the targets, the row under
/// the pointer, and on release the split (or nothing, off the targets).
pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = &a.view.drag;
    if (d.id.items.len == 0) return;
    if (!d.active) {
        if (!c.input.down) d.id.clearRetainingCapacity();
        return;
    }
    const x0 = a.view.sidebar_width;
    var buf: [2]Zone = undefined;
    const targets = if (a.view.settings_open) buf[0..0] else zones(a, x0, transcript_view.mainWidth(c, a), c.size.h, &buf);
    var over: ?Zone = null;
    for (targets) |z| if (z.rect.contains(c.input.mouse)) {
        over = z;
    };
    for (targets) |z| {
        const hot = over != null and over.?.axis == z.axis;
        var box = ui.div(c).fixed().offset(z.rect.x, z.rect.y).size(z.rect.w, z.rect.h).layer(6).center().rounded(12)
            .border(if (hot) k.accent.alpha(0.7) else k.border).borderW(1).bg(if (hot) k.accent.alpha(0.14) else k.ink(0.02));
        // Dashed, as GPUI's, with a nanoui that dashes (justrach/nanoui#21).
        if (comptime @hasDecl(ui.Div, "dashed")) box = box.dashed();
        defer box.end();
        ui.text(c, z.label, .{ .size = 12.5, .line_height = 12.5 * 1.618, .color = if (hot) k.accent else k.muted });
    }
    ghost(c, a, k);
    if (c.input.down) {
        c.cursor = .hand;
        return;
    }
    // Released: what it was let go on is done next frame, before anything
    // is drawn; drawn now, this frame's text must outlive it.
    d.active = false;
    d.drop = if (over) |z| .{ .split = z.axis } else if (d.target) |t| .{ .sidebar = t } else null;
    d.target = null;
    if (d.drop == null) d.id.clearRetainingCapacity() else c.animating = true;
}

/// The dragged row, raised, in the sidebar's column at the pointer's
/// height where it was held (`render_moving_sidebar_session`): its own
/// place and width, `surface_raised` under a medium shadow.
fn ghost(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = &a.view.drag;
    const ch = a.findChat(d.id.items) orelse return;
    if (!a.view.sidebar_open or a.view.settings_open) return;
    const lift = ui.div(c).fixed().offset(d.row.x, c.input.mouse.y - d.grip.y).w(d.row.w).h(d.row.h).layer(7)
        .rounded(8).bg(k.raised).shadow(.{ .color = .{ .a = 0.1 }, .blur = 6, .y = 4 }).clip();
    defer lift.end();
    sidebar.rowPreview(c, a, k, ch);
}

const testing = std.testing;

test "the drop targets sit as the GPUI app's, and only where a split can go" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    var buf: [2]Zone = undefined;
    const both = zones(&a, 256, 944, 780, &buf);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectApproxEqAbs(@as(f32, 256 + 944 - 8 - 944 * 0.3), both[0].rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 38 + 8), both[0].rect.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 780 * 0.28), both[1].rect.h, 0.01);
    // Split across: only the right target is left.
    a.tabs.show("x");
    _ = try a.tabs.split(.horizontal);
    const one = zones(&a, 256, 944, 780, &buf);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(tabs.Axis.horizontal, one[0].axis);
}
