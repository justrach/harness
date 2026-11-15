//! One Tab stop for a short horizontal choice group. Arrow/Home/End move focus;
//! Enter/Space commit separately, so browsing focus never starts a host request.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const behavior = @import("control_behavior.zig");
const State = struct {
    ids: [3]u64 = @splat(0),
    active: usize = 0,
    selected: usize = 0,
    recover: bool = false,
};

pub fn choices(c: *ui.Context, k: theme.Colors, key: []const u8, labels: []const []const u8, selected: usize, enabled: bool, role: ui.A11yRole) ?usize {
    std.debug.assert(labels.len > 0 and labels.len <= 3 and selected < labels.len);
    ui.key(c, key);
    const group = ui.div(c).row().gap(6).itemsCenter();
    defer group.end();
    c.addA11y(group.index, .group, key, "", false, true);
    const s = c.state(State, "roving-focus");
    if (s.ids[0] == 0 or s.selected != selected or s.active >= labels.len) s.active = selected;
    s.selected = selected;
    const focused = std.mem.indexOfScalar(u64, s.ids[0..labels.len], c.focus);
    if (!enabled and focused != null) s.recover = true;
    if (enabled) {
        if (s.recover) {
            if (c.focus == 0) c.focus = s.ids[s.active];
            s.recover = false;
        }
        if (focused) |at| {
            s.active = at;
            var next = at;
            if (keyPress(c, .left, ui.Shortcut.left)) next = (at + labels.len - 1) % labels.len;
            if (keyPress(c, .right, ui.Shortcut.right)) next = (at + 1) % labels.len;
            if (keyPress(c, .home, ui.Shortcut.home)) next = 0;
            if (keyPress(c, .end, ui.Shortcut.end)) next = labels.len - 1;
            s.active = next;
            if (next != at) {
                c.focus = s.ids[next];
                c.changed = true;
            }
        }
    }
    var chosen: ?usize = null;
    for (labels, 0..) |label, i| {
        ui.key(c, label);
        const b = ui.div(c).row().h(27).px(8).itemsCenter().rounded(6).bg(if (i == selected) k.selected else .transparent).control();
        defer b.end();
        s.ids[i] = b.id();
        c.addA11y(b.index, role, label, "", i == selected, enabled);
        if (enabled) {
            _ = b.hover(k.hover);
            const interaction = c.interact(b.index, .{ .focusable = i == s.active });
            behavior.indicate(c, b, k, interaction.focused);
            if (interaction.clicked) {
                s.active = i;
                c.focus = b.id();
                chosen = i;
                c.changed = true;
            }
        }
        ui.text(c, label, .{ .size = 11.5, .color = if (enabled) k.text else k.faint });
    }
    return chosen;
}

fn keyPress(c: *ui.Context, comptime key: anytype, shortcut: u21) bool {
    if (c.input.cmd or c.input.ctrl or c.input.alt or c.input.shift) return false;
    if (c.input.key == key) {
        c.input.key = null;
        return true;
    }
    return c.shortcut(.{ .key = shortcut });
}
