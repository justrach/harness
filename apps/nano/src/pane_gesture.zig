//! Deferred activation belongs to the original navigation context, not an
//! array slot. This hash is stored in View.pane_press.tab (a legacy usize
//! slot); it owns no borrowed frame strings and is checked every frame.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;

pub fn context(a: *const App, c: *const ui.Context) usize {
    var h = std.hash.Wyhash.init(0x5041_4e45_5052_4553);
    h.update(std.mem.asBytes(&a.tabs.active));
    // Stable tab identity also detects closing and replacing the same slot.
    if (a.tabs.active < a.tabs.identities.items.len) h.update(std.mem.asBytes(&a.tabs.identities.items[a.tabs.active]));
    // Navigation away and back without an intervening paint still invalidates.
    h.update(std.mem.asBytes(&a.tabs.next_shown));
    text(&h, a.selected);
    text(&h, a.space);
    h.update(&.{ @intFromBool(a.new_no_project), @intFromBool(c.window_focused), @backingInt(c.input.button), @intFromBool(c.input.secondary) });
    h.update(std.mem.asBytes(&c.size));
    const zoom = a.settings.uiFontSize();
    h.update(std.mem.asBytes(&zoom));
    if (a.tabs.layout()) |s| {
        h.update(std.mem.asBytes(&s.focus));
        h.update(&.{ @backingInt(s.axis), @intFromBool(s.zoomed) });
        h.update(std.mem.sliceAsBytes(s.shares.items));
        h.update(std.mem.sliceAsBytes(s.identities[0..s.panes.items.len]));
        for (s.panes.items, s.drafts.items, s.groups[0..s.panes.items.len]) |chat, draft, group| {
            text(&h, chat);
            if (chat) |id| {
                if (a.findChat(id)) |ch| text(&h, ch.space_id);
            } else if (draft) |d| {
                text(&h, d.space);
                text(&h, d.device);
                h.update(&.{@intFromBool(d.no_project)});
            }
            h.update(std.mem.asBytes(&group.active));
        }
    }
    return @intCast(h.final());
}

fn text(h: *std.hash.Wyhash, value: ?[]const u8) void {
    if (value) |v| {
        h.update(&.{1});
        h.update(std.mem.asBytes(&v.len));
        h.update(v);
    } else h.update(&.{0});
}

pub fn observe(a: *App, c: *const ui.Context) void {
    if (a.view.pane_press) |press| {
        if (!c.window_focused or context(a, c) != press.tab) a.view.pane_press = null;
    }
}
