//! Native equivalents of popup focus containment and focus recovery. No DOM
//! dependency: stable NanoUI IDs belong to this preview and its opening image.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");

pub const State = struct {
    mounted: bool = false,
    origin: u64 = 0,
    controls: [4]u64 = @splat(0),
    count: usize = 0,

    pub fn begin(s: *State, c: *ui.Context) void {
        if (!s.mounted) {
            s.origin = c.focus;
            s.mounted = true;
            s.controls = @splat(0);
        }
        s.count = 0;
    }

    /// Context.begin may have advanced Tab through the whole workspace. Repair
    /// its boundary before any background field can handle the next input.
    pub fn keys(s: *State, c: *ui.Context) void {
        if (!s.mounted or s.count == 0) return;
        const ids = s.controls[0..s.count];
        if (std.mem.indexOfScalar(u64, ids, c.focus) == null) c.focus = if (c.input.shift) ids[ids.len - 1] else ids[0];
        if (c.input.key == .tab or c.shortcut(.{ .key = ui.Shortcut.tab, .shift = c.input.shift })) {
            const at = std.mem.indexOfScalar(u64, ids, c.focus) orelse 0;
            c.focus = ids[if (c.input.shift) (at + ids.len - 1) % ids.len else (at + 1) % ids.len];
            c.input.key = null;
            c.changed = true;
        }
    }

    pub fn restore(s: *State, c: *ui.Context) void {
        // Don't take focus back from a different pane or a newer dialog.
        const owns = c.focus == 0 or std.mem.indexOfScalar(u64, s.controls[0..s.count], c.focus) != null;
        const present = std.mem.indexOfScalar(u64, c.focusable_ids.items, s.origin) != null or std.mem.indexOfScalar(u64, c.last_focusable_ids.items, s.origin) != null;
        if (s.mounted and owns and present) c.focus = s.origin;
        s.* = .{};
    }

    pub fn button(s: *State, c: *ui.Context, k: theme.Colors, label: []const u8) bool {
        ui.key(c, label);
        const b = ui.div(c).row().h(26).px(6).itemsCenter().rounded(5).bg(k.hover).control();
        defer b.end();
        const id = c.node(b.index).id;
        if (s.controls[0] == 0) c.focus = id;
        if (s.count < s.controls.len) {
            s.controls[s.count] = id;
            s.count += 1;
        }
        const clicked = action(c, b.index, k, label);
        ui.text(c, label, .{ .size = 10.5, .color = k.text });
        return clicked;
    }
};

/// One interaction owns pointer, Enter/Space and assistive activation. Focus
/// indication follows keyboard modality, rather than painting a mouse ring.
pub fn action(c: *ui.Context, index: u32, k: theme.Colors, label: []const u8) bool {
    return @import("control_behavior.zig").activateIndex(c, index, k, label, true, false);
}
