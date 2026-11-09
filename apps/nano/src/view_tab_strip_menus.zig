//! Panel menus live below their slot, including tabs hidden by a split.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const strip = @import("view_tab_strip.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const rules = @import("rules.zig");

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    const menu = a.view.strip.menu orelse return;
    const anchor = (if (menu == .device) a.view.strip.device_anchor orelse a.view.strip.anchor else a.view.strip.anchor) orelse ui.Rect{ .x = a.view.sidebar_width + 16, .y = 5, .w = 100, .h = 32 };
    if (a.view.strip.focus_menu) {
        if (menu != .folder) c.focus = 0;
        a.view.strip.focus_menu = false;
    }
    a.view.strip.rows = 0;
    defer a.view.strip.activate = false;
    const target = a.view.strip.target;
    if (menu == .folder) return folderMenu(c, a, k, anchor);
    const width: f32 = @import("strip_folder_search.zig").menu_width;
    const x = rules.snapToWindow(anchor.x, width, c.size.w, 8);
    const est_h: f32 = if (menu == .device)
        @min(220, @as(f32, @floatFromInt(@max(1, 1 + a.devices.items.len))) * 34 + 12)
    else
        220;
    const y = if (c.size.h - (anchor.y + anchor.h) < est_h + 14 and anchor.y > est_h + 14)
        @max(8, anchor.y - est_h - 6)
    else
        @min(anchor.y + anchor.h + 4, @max(8, c.size.h - est_h));
    {
        const scrim_top = @import("motion_rules.zig").scrimTop(false, @import("panel_chrome.zig").header_height);
        const scrim = ui.div(c).fixed().offset(0, scrim_top).size(c.size.w, @max(0, c.size.h - scrim_top)).layer(4);
        defer scrim.end();
        if (scrim.clicked()) {
            a.view.strip.menu = null;
            return;
        }
    }
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(width).maxH(@max(0, c.size.h - y - 8)).column().p(5).gap(2).bg(k.overlay.alpha(1)).border(k.border).borderW(1).rounded(12).layer(5).scrollY()));
    defer card.end();
    if (menu == .device) {
        const id = strip.device(a, target);
        const editable = target == .chat;
        if (!editable) {
            ui.text(c, strip.deviceLabel(a, id), .{ .size = 13, .color = k.text });
            ui.text(c, "A session's computer can't be changed.", .{ .size = 12, .color = k.muted, .wrap = true });
            return;
        }
        const local = a.device_id orelse "local";
        {
            const selected = if (id) |have| std.mem.eql(u8, have, local) else true;
            if (row(c, a, k, .monitor, @import("strip_device.zig").localLabel(), selected)) strip.queueDevice(a, target, local);
        }
        for (a.devices.items) |dev| {
            if (std.mem.eql(u8, local, dev.id)) continue;
            const selected = if (id) |have| std.mem.eql(u8, have, dev.id) else false;
            // This is a real execution target, even with no folders. Its ID
            // is parked with this draft and sent in CreateChat, never swapped
            // into the app's own machine identity or inferred from a folder.
            if (row(c, a, k, .monitor, strip.deviceLabel(a, dev.id), selected)) strip.queueDevice(a, target, dev.id);
        }
        return;
    }
    if (menu == .history) {
        for (a.tabs.items.items, 0..) |id, ix| {
            const title = if (id) |chat| (if (a.findChat(chat)) |ch| @import("view_sidebar.zig").chatLabel(ch) else "Conversation") else "New tab";
            if (row(c, a, k, .@"chat-round-line", title, ix == a.tabs.active)) strip.queue(a, .{ .global_tab = ix });
        }
        separator(c, k);
        if (row(c, a, k, .plus, "New tab", false)) strip.queue(a, .{ .new = strip.active(a) });
        return;
    }
    switch (target) {
        .chat => |pane| {
            if (a.tabs.layout()) |s| {
                if (pane >= s.panes.items.len) {
                    a.view.strip.menu = null;
                    return;
                }
                const group = &s.groups[pane];
                if (group.count() > 1) {
                    for (group.items.items, 0..) |tab, ix| {
                        const id = if (ix == group.active) strip.chatId(a, pane) else tab.chat;
                        const title = if (id) |chat| (if (a.findChat(chat)) |ch| @import("view_sidebar.zig").chatLabel(ch) else "Conversation") else "New tab";
                        if (row(c, a, k, .@"chat-round-line", title, ix == group.active)) strip.queue(a, .{ .panel_tab = .{ .pane = pane, .tab = ix } });
                    }
                    separator(c, k);
                }
            } else if (a.tabs.items.items.len > 1) {
                for (a.tabs.items.items, 0..) |id, ix| {
                    const title = if (id) |chat| (if (a.findChat(chat)) |ch| @import("view_sidebar.zig").chatLabel(ch) else "Conversation") else "New tab";
                    if (row(c, a, k, .@"chat-round-line", title, ix == a.tabs.active)) strip.queue(a, .{ .global_tab = ix });
                }
                separator(c, k);
            }
        },
        .host => {
            for (a.panels.tabs.items, 0..) |tab, ix| {
                if (tab.agent) |agent| if (!agent.belongsTo(a.selected)) continue;
                if (tab.browser) |browser| if (!browser.belongsTo(a.selected)) continue;
                if (row(c, a, k, if (tab.kind == .browser) .globe else .document, strip.hostTitle(a, tab), ix == a.panels.active)) strip.queue(a, .{ .host_tab = ix });
            }
            if (a.panels.active < a.panels.tabs.items.len) {
                if (row(c, a, k, .close, "Close tab", false)) strip.queue(a, .{ .close_host_tab = a.panels.active });
            }
            if (a.panels.tabs.items.len > 0) separator(c, k);
        },
        .files => {},
    }
    if (row(c, a, k, .plus, "New tab", false)) strip.queue(a, .{ .new = target });
    if (target == .chat) {
        if (row(c, a, k, .@"alt-arrow-right", "Split right", false)) strip.queue(a, .{ .split_right = target });
        if (row(c, a, k, .@"alt-arrow-down", "Split down", false)) strip.queue(a, .{ .split_down = target });
        if (a.tabs.layout()) |s| {
            const vertical = s.axis == .vertical;
            if (target.chat > 0) if (row(c, a, k, if (vertical) .@"alt-arrow-down" else .@"alt-arrow-left", if (vertical) "Move panel up" else "Move panel left", false)) strip.queue(a, .{ .move_left = target });
            if (target.chat + 1 < s.panes.items.len) if (row(c, a, k, if (vertical) .@"alt-arrow-down" else .@"alt-arrow-right", if (vertical) "Move panel down" else "Move panel right", false)) strip.queue(a, .{ .move_right = target });
        }
    }
    if (strip.count(a) > 1) {
        separator(c, k);
        if (row(c, a, k, .@"split-columns", if (a.view.strip.expanded != null) "Restore panels" else "Expand panel", false)) strip.queue(a, .{ .zoom = target });
        if (row(c, a, k, .close, "Close panel", false)) strip.queue(a, .{ .close = target });
    }
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, glyph: icons.Name, label: []const u8, selected: bool) bool {
    const index = a.view.strip.rows;
    a.view.strip.rows += 1;
    const box = ui.div(c).row().wFull().h(32).px(8).gap(10).itemsCenter().rounded(7).hover(k.selected).control();
    if (a.view.strip.cursor == index) _ = box.bg(k.selected);
    defer box.end();
    icons.icon(c, glyph, 16, k.muted, 0);
    kit.ellipsisText(c, label, .{ .size = 13, .color = k.text }, if (a.view.strip.footer_folder) 216 else 170);
    ui.spacer(c);
    if (selected) icons.icon(c, .check, 12, k.muted, 0);
    return box.clicked() or (a.view.strip.activate and a.view.strip.cursor == index);
}
fn separator(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}

fn folderMenu(c: *ui.Context, a: *App, k: theme.Colors, anchor: ui.Rect) void {
    const search = @import("strip_folder_search.zig");
    const state = &a.view.strip;
    const target = state.target;
    const device = strip.device(a, target);
    var matches = search.indices(c.alloc(), a.spaces.items, device, state.query.text()) catch return;
    const footer = state.footer_folder;
    const width: f32 = if (footer) 280 else search.menu_width;
    const above = @max(0, anchor.y - 14);
    const below = @max(0, c.size.h - anchor.y - anchor.h - 14);
    const flip = footer and above < 180 and below > above;
    const budget = if (footer) @min(640, if (flip) below else above) else c.size.h - 16;
    const list_budget = if (footer) std.math.clamp(budget - 152, 0, search.list_height) else search.list_height;
    const height = @min(search.height(matches.len), budget);
    const x = rules.snapToWindow(anchor.x, width, c.size.w, 8);
    const y = rules.snapToWindow(if (footer and !flip) anchor.y - height - 4 else anchor.y + anchor.h + (if (footer) @as(f32, 4) else 0), height, c.size.h, 8);
    {
        const scrim_top = @import("motion_rules.zig").scrimTop(footer, @import("panel_chrome.zig").header_height);
        const scrim = ui.div(c).fixed().offset(0, scrim_top).size(c.size.w, @max(0, c.size.h - scrim_top)).layer(4);
        defer scrim.end();
        if (scrim.clicked()) {
            state.menu = null;
            a.view.focus_composer = true;
            return;
        }
    }
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(width).maxH(@max(32, budget)).column().p(5).gap(2).bg(k.overlay.alpha(1)).border(k.border).borderW(1).rounded(12).layer(5).clip()));
    defer card.end();
    {
        ui.key(c, "panel-menu-search");
        const field = ui.div(c).row().wFull().px(10).py(6).rounded(7).bg(k.ink(0.04));
        defer field.end();
        const field_id = c.peekId(null);
        if (state.search_focus) {
            c.focus = field_id;
            state.search_focus = false;
        }
        const result = ui.textField(c, &state.query, .{ .placeholder = if (footer) "Search projects…" else "Search folders…", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 13 });
        if (result.changed) {
            matches = search.indices(c.alloc(), a.spaces.items, device, state.query.text()) catch return;
            state.cursor = if (footer) 0 else search.afterEdit(matches.len);
            state.select_current = false;
            state.reveal = true;
            if (state.search_scroll != 0) c.scroll.put(c.gpa, state.search_scroll, 0) catch {};
        }
    }
    ui.div(c).h(4).wFull().end();
    const current = strip.folder(a, target);
    if (state.select_current) {
        state.select_current = false;
        state.cursor = if (footer and a.new_no_project) matches.len + 1 else 0;
        for (matches, 0..) |space, ix| if (current) |folder| {
            if (std.mem.eql(u8, folder.name, a.spaces.items[space].name)) {
                state.cursor = ix;
                break;
            }
        };
    }
    if (matches.len == 0) {
        const empty = ui.div(c).row().wFull().px(8).py(6);
        defer empty.end();
        ui.text(c, if (footer) (if (state.query.text().len == 0) "No projects on this device." else "No projects match.") else "No folders match", .{ .size = 12, .color = k.faint });
    }
    {
        ui.key(c, "panel-menu-list");
        const visible = @min(list_budget, @as(f32, @floatFromInt(matches.len)) * 32);
        const list = ui.div(c).column().wFull().h(visible).scrollY();
        defer list.end();
        state.search_scroll = c.node(list.index).id;
        if (state.reveal and state.cursor < matches.len) {
            const was = c.scroll.get(state.search_scroll) orelse 0;
            const top = @as(f32, @floatFromInt(state.cursor)) * 32;
            const next = if (top < was) top else if (top + 32 > was + visible) top + 32 - visible else was;
            if (next != was) {
                c.scroll.put(c.gpa, state.search_scroll, @max(0, next)) catch {};
                c.changed = true;
            }
        }
        state.reveal = false;
        for (matches) |ix| {
            const space = a.spaces.items[ix];
            const selected = if (current) |folder| std.mem.eql(u8, folder.name, space.name) else false;
            if (row(c, a, k, if (selected) .check else .folder, space.name, false)) strip.queue(a, .{ .folder = .{ .panel = target, .index = ix } });
        }
    }
    separator(c, k);
    if (footer) {
        if (row(c, a, k, .plus, "New project…", false)) strip.queue(a, .{ .add_folder = target });
        if (row(c, a, k, .close, "Don't work in a project", a.new_no_project)) strip.queue(a, .{ .folder = .{ .panel = target, .index = null } });
    } else {
        if (row(c, a, k, .close, "Don't work in a project", false)) strip.queue(a, .{ .folder = .{ .panel = target, .index = null } });
        if (row(c, a, k, .plus, "New project…", false)) strip.queue(a, .{ .add_folder = target });
    }
}
