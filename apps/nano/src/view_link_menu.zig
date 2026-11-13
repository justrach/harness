//! Conversation-owned link actions shared by Markdown and literal tool output.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const browser = @import("app_browser.zig");
const kit = @import("view_kit.zig");
const theme = @import("theme.zig");

pub const Menu = struct {
    parent: std.ArrayList(u8) = .empty,
    url: std.ArrayList(u8) = .empty,
    owner: ?browser.LinkOwner = null,
    trigger: u64 = 0,
    visible_frame: u64 = 0,
    at: ui.Point = .{},
    open: bool = false,
    selected: usize = 0,

    pub fn deinit(m: *Menu, gpa: std.mem.Allocator) void {
        m.parent.deinit(gpa);
        m.url.deinit(gpa);
    }
};

/// Seeing the same live hit target revalidates an open menu. A streamed-away
/// URL, replaced pane, hidden chat or changed project cannot leave stale actions.
pub fn track(c: *ui.Context, a: *App, parent: ?[]const u8, url: []const u8, index: u32, secondary: bool) void {
    const m = &a.view.link_menu;
    if (!secondary and !m.open) return;
    const id = parent orelse a.selected orelse return;
    const owner = browser.linkOwner(a, id, url) orelse return;
    const trigger = c.node(index).id;
    if (secondary) {
        m.open = false;
        m.parent.clearRetainingCapacity();
        m.url.clearRetainingCapacity();
        m.parent.appendSlice(a.gpa, id) catch return;
        m.url.appendSlice(a.gpa, url) catch return;
        m.owner = owner;
        m.trigger = trigger;
        m.at = c.input.mouse;
        m.open = true;
        m.selected = 0;
        c.focus = 0;
        a.view.focus_composer = false;
        c.changed = true;
    }
    if (m.open and m.trigger == trigger and std.mem.eql(u8, m.parent.items, id) and
        std.mem.eql(u8, m.url.items, url) and std.meta.eql(m.owner.?, owner)) m.visible_frame = c.frame;
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const m = &a.view.link_menu;
    if (!m.open) return;
    const owner = browser.linkOwner(a, m.parent.items, m.url.items);
    if (m.visible_frame != c.frame or owner == null or !std.meta.eql(m.owner.?, owner.?)) {
        m.open = false;
        return;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.escape }) or kit.pressedOutside(c, null)) {
        m.open = false;
        return;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.down })) m.selected = (m.selected + 1) % 3;
    if (c.shortcut(.{ .key = ui.Shortcut.up })) m.selected = (m.selected + 2) % 3;
    const rules = @import("rules.zig");
    const x = rules.snapToWindow(m.at.x, 208, c.size.w, 8);
    const y = rules.snapToWindow(m.at.y, 106, c.size.h, 8);
    ui.key(c, "transcript-link-menu");
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(208).layer(6).column().p(5).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer card.end();
    inline for (.{ "Open in Harness", "Open in browser", "Copy link" }, 0..) |label, action| {
        var row = ui.div(c).row().wFull().h(30).px(8).itemsCenter().rounded(6).hover(k.ink(0.06)).control();
        if (m.selected == action) row = row.bg(k.ink(0.04));
        defer row.end();
        ui.text(c, label, .{ .size = 13, .color = k.text });
        if (row.clicked() or (m.selected == action and c.shortcut(.{ .key = ui.Shortcut.enter }))) {
            m.open = false;
            switch (action) {
                0 => browser.openInternalLink(a, m.parent.items, m.url.items),
                1 => browser.openExternalLink(a, m.parent.items, m.url.items),
                2 => c.clipboard.write(c.clipboard.ctx, m.url.items),
                else => unreachable,
            }
        }
    }
}
