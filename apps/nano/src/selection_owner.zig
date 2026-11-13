//! Per-native-context ownership: never global, so identical row keys in
//! another window cannot steal Copy or the return-to-editor route.
const std = @import("std");
const ui = @import("nanoui").ui;
pub const State = struct {
    surface: u64 = 0,
    return_focus: u64 = 0,
    /// Only the exact deferred activation that completed this gesture may
    /// retain it through a focused/peer outlet swap.
    promoted_chat: u64 = 0,
    snapshot: u64 = 0,
    /// A view may rebuild several times in one frame; scroll only once.
    scroll_time: ?f64 = null,
};

/// Edge scrolling belongs to the original selection viewport. A stationary
/// held pointer drives bounded, time-based movement, not wheel events. The
/// 24-point edge band ramps to 900 points/second; long idle gaps cannot jump.
pub fn nextScroll(view: ui.Rect, pointer: ui.Point, at: f32, maximum: f32, seconds: f32) f32 {
    if (view.w <= 0 or view.h <= 0 or maximum <= 0 or seconds <= 0 or pointer.x < view.x or pointer.x > view.x + view.w) return at;
    const band = @min(@as(f32, 24), view.h / 2);
    const penetration = if (pointer.y < view.y + band)
        @max(@as(f32, -1), (pointer.y - view.y - band) / band)
    else if (pointer.y > view.y + view.h - band)
        @min(@as(f32, 1), (pointer.y - view.y - view.h + band) / band)
    else
        @as(f32, 0);
    return std.math.clamp(at + penetration * 900 * @min(seconds, 1.0 / 30.0), 0, maximum);
}

test "selection edge scroll rule ramps clamps and stays in its owner viewport" {
    const t = std.testing;
    const view: ui.Rect = .{ .x = 100, .y = 50, .w = 400, .h = 300 };
    try t.expectEqual(@as(f32, 215), nextScroll(view, .{ .x = 200, .y = 370 }, 200, 1000, 1.0 / 60.0));
    try t.expectEqual(@as(f32, 185), nextScroll(view, .{ .x = 200, .y = 30 }, 200, 1000, 1.0 / 60.0));
    try t.expectEqual(@as(f32, 207.5), nextScroll(view, .{ .x = 200, .y = 338 }, 200, 1000, 1.0 / 60.0));
    try t.expectEqual(@as(f32, 200), nextScroll(view, .{ .x = 200, .y = 200 }, 200, 1000, 1.0 / 60.0));
    try t.expectEqual(@as(f32, 200), nextScroll(view, .{ .x = 550, .y = 370 }, 200, 1000, 1.0 / 60.0));
    try t.expectEqual(@as(f32, 0), nextScroll(view, .{ .x = 200, .y = 30 }, 3, 1000, 1.0 / 60.0));
    try t.expectEqual(@as(f32, 1000), nextScroll(view, .{ .x = 200, .y = 370 }, 995, 1000, 1.0 / 60.0));
    try t.expectEqual(@as(f32, 230), nextScroll(view, .{ .x = 200, .y = 370 }, 200, 1000, 10));
}

/// Explicit child key under the implicit window root. The view calls this
/// only before/after building its tree; no pointer survives a memory rehash.
pub fn state(c: *ui.Context) *State {
    const depth = c.stack.items.len;
    c.stack.items.len = 1;
    defer c.stack.items.len = depth;
    const key = c.next_key;
    const integer = c.next_key_int;
    defer {
        c.next_key = key;
        c.next_key_int = integer;
    }
    ui.key(c, "window-selection-owner");
    return c.state(State, "ownership");
}
