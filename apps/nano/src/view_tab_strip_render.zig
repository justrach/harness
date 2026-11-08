//! Painting for the unified lane; geometry and mutations live separately.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const chrome = @import("panel_chrome.zig");
const tabs = @import("tabs.zig");
const strip = @import("view_tab_strip.zig");
const tip = @import("view_tooltip.zig");

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.view.settings_open) return;
    const left = @max(strip.leftInset(a), a.view.chrome.leading);
    if (strip.count(a) <= 1) return single(c, a, k, left);
    var targets: [tabs.max_panes + 2]strip.Panel = undefined;
    var widths: [tabs.max_panes + 2]f32 = undefined;
    var n: usize = 0;
    const split = a.tabs.layout();
    for (0..strip.chatCount(a)) |ix| {
        targets[n] = .{ .chat = ix };
        widths[n] = if (split) |s| chrome.paneSpan(a.view.chrome.chat_width, s.shares.items[ix], s.panes.items.len, true) else a.view.chrome.chat_width;
        n += 1;
    }
    if (strip.hasHost(a)) {
        targets[n] = .host;
        widths[n] = a.view.chrome.host_width;
        n += 1;
    }
    if (strip.hasFiles(a)) {
        targets[n] = .files;
        widths[n] = a.view.chrome.files_width;
        n += 1;
    }
    var aligned: [tabs.max_panes + 2]f32 = undefined;
    const in_row = (if (split) |s| s.axis == .horizontal and !s.zoomed else true) and a.view.strip.expanded == null and a.view.chrome.width <= c.size.w - a.view.chrome.x + 0.5;
    const columns = in_row and chrome.columns(widths[0..n], a.view.chrome.leading, left, 8, &aligned);
    const shared = @min(chrome.slot_max, chrome.sharedSlotRoom(c.size.w - a.view.sidebar_width, left, 8, n));
    ui.key(c, "instrument-strip");
    const row = ui.div(c).fixed().offset(a.view.sidebar_width, 0).w(c.size.w - a.view.sidebar_width).h(chrome.titlebar_height).pt(chrome.top_pad).pl(left).pr(8).row().gap(if (columns) chrome.gutter else 2).itemsCenter().layer(2);
    defer row.end();
    for (targets[0..n], 0..) |target, ix| slot(c, a, k, target, ix, @max(0, if (columns) aligned[ix] else shared));
    ui.key(c, "instrument-new-tab");
    if (kit.iconButton(c, k, .plus, .{ .icon = 14, .tip = .{ .text = "New tab", .look = .tab } })) strip.queue(a, .{ .new = strip.active(a) });
}

fn slot(c: *ui.Context, a: *App, k: theme.Colors, target: strip.Panel, ix: usize, width: f32) void {
    ui.key(c, c.print("instrument-slot-{d}", .{ix}));
    const on = strip.same(strip.active(a), target);
    const name = strip.title(a, target);
    const computer = strip.deviceLabel(a, strip.device(a, target));
    const project = strip.folder(a, target);
    const tooltip = if (project) |f| c.print("{s} · {s} · {s}", .{ name, computer, f.name }) else c.print("{s} · {s}", .{ name, computer });
    var box = ui.div(c).row().size(width, chrome.tab_height).pl(7).pr(4).gap(6).itemsCenter().rounded(6).clip().control();
    box = tip.on(if (on) box.bg(k.ink(if (k.dark) 0.16 else 0.10)) else box.hover(k.hover), k, .{ .text = tooltip, .look = .tab });
    defer box.end();
    const hot = box.hovered();
    const menu_count = strip.tabCount(a, target);
    var handled = false;
    if (strip.attention(a, target, k)) |color| {
        const mark = ui.div(c).row().size(14, 14).center();
        defer mark.end();
        ui.div(c).size(7, 7).rounded(3.5).bg(color).end();
    } else icons.icon(c, strip.glyph(a, target), 14, k.muted, 0);
    {
        const text = ui.div(c).column().grow().w(0).clip();
        defer text.end();
        const controls: f32 = 18 + (if (width >= chrome.slot_room_for_add) @as(f32, 24) else 0);
        const room = @max(0, width - 7 - 4 - 14 - 12 - controls);
        kit.ellipsisText(c, name, .{ .size = 12, .line_height = 14, .color = if (on) k.text else k.muted }, room);
        const meta = ui.div(c).row().h(12).wFull().gap(6).itemsCenter().clip();
        defer meta.end();
        // A new, unsent session can move computers from this label; its
        // project belongs to the old computer, so that choice clears it.
        const device_editable = switch (target) {
            .chat => |pane| strip.chatId(a, pane) == null,
            else => false,
        };
        const device_extra: f32 = if (device_editable) 9 else 0;
        const dev_w = (if (project != null) @min(c.text.width(computer, .{ .size = 10 }) + 13 + device_extra, room * 0.5) else room);
        {
            var dev = ui.div(c).row().w(@max(0, dev_w)).gap(3).itemsCenter().rounded(3).clip();
            if (device_editable) dev = dev.px(3).hover(k.ink(0.10)).control();
            defer dev.end();
            icons.icon(c, .monitor, 10, k.muted, 0);
            kit.ellipsisText(c, computer, .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, dev_w - 13 - device_extra));
            if (device_editable) {
                icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
                if (dev.clicked()) {
                    handled = true;
                    strip.queue(a, .{ .focus = target });
                    strip.open(a, .device, target, c.rects.get(c.node(dev.index).id));
                }
            }
        }
        if (project) |f| {
            var pick = ui.div(c).row().grow().w(0).h(14).gap(3).itemsCenter().rounded(3).clip();
            if (f.changeable) pick = pick.px(3).hover(k.ink(0.10)).control();
            defer pick.end();
            icons.icon(c, .folder, 10, k.muted, 0);
            kit.ellipsisText(c, f.name, .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, room - dev_w - 6 - 13 - (if (f.changeable) @as(f32, 18) else 0)));
            if (f.changeable) {
                icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
                strip.offerSplitFolder(c, a, target, c.rects.get(c.node(pick.index).id));
                if (pick.clicked()) {
                    handled = true;
                    // Focus is queued; the menu's rows read the target's draft.
                    strip.queue(a, .{ .focus = target });
                    strip.open(a, .folder, target, c.rects.get(c.node(pick.index).id));
                }
            }
        }
    }
    if (width >= chrome.slot_room_for_add) {
        ui.key(c, "slot-add");
        if (hot or c.focus == c.node(box.index).id) {
            if (kit.iconButton(c, k, .plus, .{ .size = 18, .radius = 4, .icon = 11, .tip = .{ .text = "New tab in this panel" } })) {
                handled = true;
                strip.queue(a, .{ .new = target });
            }
        } else ui.div(c).size(18, 18).end();
    }
    {
        ui.key(c, "slot-menu");
        const button = ui.div(c).row().h(18).minW(18).px(3).gap(2).center().rounded(4).hover(k.ink(0.10)).control();
        defer button.end();
        if (menu_count > 1) ui.text(c, c.print("{d}", .{menu_count}), .{ .size = 11, .color = k.muted });
        if (menu_count > 1 or hot) icons.icon(c, .@"alt-arrow-down", 11, k.muted, 0);
        if (button.clicked()) {
            handled = true;
            strip.open(a, .panel, target, c.rects.get(c.node(button.index).id));
        }
    }
    if (!handled and box.clicked()) strip.queue(a, .{ .focus = target });
    if (kit.secondaryClicked(box)) strip.open(a, .panel, target, c.rects.get(c.node(box.index).id));
}

pub const Selected = struct { left: f32, right: f32 };
pub fn selectedBounds(a: *const App) ?Selected {
    if (strip.count(a) != 1) return null;
    const group = if (a.tabs.layout()) |s| &s.groups[s.focus] else null;
    const n = if (group) |g| g.count() else a.tabs.items.items.len;
    const selected = if (group) |g| g.active else a.tabs.active;
    const left = @max(strip.leftInset(a), a.view.chrome.leading);
    const available = @max(0, a.view.chrome.width - left - chrome.device_room - 4);
    const width = chrome.tabWidth(available, n);
    const scroll = @max(0, @as(f32, @floatFromInt(selected + 1)) * (width + 3) - @max(0, available - 32));
    const start = left - a.view.chrome.leading + @as(f32, @floatFromInt(selected)) * (width + 3) - scroll;
    return .{ .left = @max(0, start), .right = @min(a.view.chrome.width, start + width) };
}

fn single(c: *ui.Context, a: *App, k: theme.Colors, left: f32) void {
    const group = if (a.tabs.layout()) |s| &s.groups[s.focus] else null;
    const n = if (group) |g| g.count() else a.tabs.items.items.len;
    const selected = if (group) |g| g.active else a.tabs.active;
    const available = @max(0, a.view.chrome.width - left - chrome.device_room - 4);
    const width = chrome.tabWidth(available, n);
    const scroll = @max(0, @as(f32, @floatFromInt(selected + 1)) * (width + 3) - @max(0, available - 32));
    ui.key(c, "panel-tabs");
    const lane = ui.div(c).fixed().offset(a.view.sidebar_width + left, chrome.tab_top).size(available, chrome.tab_height + chrome.tab_top).clip().layer(2);
    defer lane.end();
    const row = ui.div(c).absolute().offset(-scroll, 0).row().h(chrome.tab_height).gap(3).itemsCenter();
    defer row.end();
    for (0..n) |ix| {
        const chat = if (group) |g| (if (ix == selected) a.selected else g.items.items[ix].chat) else a.tabs.items.items[ix];
        const ch = if (chat) |id| a.findChat(id) else null;
        const label = if (ch) |v| @import("view_sidebar.zig").chatLabel(v) else "New tab";
        ui.key(c, c.print("panel-tab-{d}", .{ix}));
        const cap = ui.div(c).row().size(width, chrome.tab_height).px(8).gap(6).itemsCenter().rounded(6).hover(if (ix == selected) .transparent else k.hover).clip().control();
        defer cap.end();
        const hot = cap.hovered();
        icons.icon(c, .@"chat-round-line", 14, k.muted, 0);
        {
            const labels = ui.div(c).column().grow().w(0).clip();
            defer labels.end();
            kit.ellipsisText(c, label, .{ .size = 12, .line_height = 14, .color = if (ix == selected) k.text else k.muted }, @max(0, width - 58));
            if (hot) if (ch) |chat_row| {
                const meta = ui.div(c).row().gap(6).h(12).itemsCenter();
                defer meta.end();
                if (chat_row.branch) |branch| kit.ellipsisText(c, branch, .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, (width - 58) * 0.45));
                const mark = icons.harnessMark(chat_row.harness orelse "graff");
                icons.icon(c, mark.name, 12, mark.brand orelse k.muted, 0);
                kit.ellipsisText(c, chat_row.model orelse chat_row.harness orelse "Graff", .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, (width - 58) * 0.5 - 15));
            };
        }
        var handled = false;
        if (hot) {
            if (kit.iconButton(c, k, .close, .{ .size = 16, .radius = 4, .icon = 11, .tip = .{ .text = "Close tab" } })) {
                handled = true;
                if (group != null) {
                    // Close the selected panel tab only after promoting it.
                    strip.queue(a, .{ .close_panel_tab = .{ .pane = a.tabs.layout().?.focus, .tab = ix } });
                } else strip.queue(a, .{ .close_global_tab = ix });
            }
        } else ui.div(c).size(16, 16).end();
        if (!handled and cap.clicked() and ix != selected) {
            if (group != null) strip.queue(a, .{ .panel_tab = .{ .pane = a.tabs.layout().?.focus, .tab = ix } }) else strip.queue(a, .{ .global_tab = ix });
        }
        if (kit.secondaryClicked(cap)) strip.open(a, .panel, .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 }, c.rects.get(c.node(cap.index).id));
    }
    ui.key(c, "panel-add-tab");
    if (lane.hovered()) {
        if (kit.iconButton(c, k, .plus, .{ .icon = 14, .tip = .{ .text = "New tab in panel" } })) strip.queue(a, .{ .new = strip.active(a) });
    } else ui.div(c).size(24, 24).end();
    // Device is its own fixed trailing lane, never a tab's suffix.
    devicePicker(c, a, k);
}

fn devicePicker(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.key(c, "panel-device-trigger");
    const target = strip.active(a);
    const editable = switch (target) {
        .chat => |pane| strip.chatId(a, pane) == null,
        else => false,
    };
    var box = ui.div(c).fixed().offset(c.size.w - chrome.device_room - 12, chrome.tab_top).size(chrome.device_room, chrome.tab_height).pl(8).gap(3).row().itemsCenter().justifyEnd().rounded(4).clip().layer(3);
    if (editable) box = box.hover(k.ink(0.10)).control();
    defer box.end();
    // Once a menu opens, retain the anchor of the control actually clicked
    // (the draft footer also offers this picker).
    if (editable and a.view.strip.menu != .device) {
        if (c.rects.get(c.node(box.index).id)) |r| a.view.strip.device_anchor = r;
    }
    icons.icon(c, .monitor, 10, k.muted, 0);
    kit.ellipsisText(c, strip.deviceLabel(a, strip.device(a, target)), .{ .size = 10, .line_height = 12, .color = k.muted }, chrome.device_room - 21 - (if (editable) @as(f32, 9) else 0));
    if (editable) {
        icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
        if (box.clicked()) {
            const state = &a.view.strip;
            if (state.menu == .device and strip.same(state.target, target)) {
                state.menu = null;
            } else {
                strip.queue(a, .{ .focus = target });
                strip.open(a, .device, target, c.rects.get(c.node(box.index).id));
            }
        }
    }
}
