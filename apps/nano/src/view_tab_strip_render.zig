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
const caption = @import("window_chrome.zig");

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.view.settings_open) return;
    const left = @max(strip.leftInset(a), a.view.chrome.leading);
    if (strip.count(a) <= 1) return single(c, a, k, left);
    var targets: [tabs.max_panes + 2]strip.Panel = undefined;
    var widths: [tabs.max_panes + 2]f32 = undefined;
    var n: usize = 0;
    const split = a.tabs.layout();
    const github = @import("app_github_repository.zig");
    const child_parent = if (strip.hasHost(a) and github.surface(a)) github.parentPane(a) else null;
    for (0..strip.chatCount(a)) |ix| {
        targets[n] = .{ .chat = ix };
        widths[n] = if (split) |s| chrome.paneSpan(a.view.chrome.chat_width, s.shares.items[ix], s.panes.items.len, true) else a.view.chrome.chat_width;
        n += 1;
        if (child_parent != null and child_parent.? == ix) {
            targets[n] = .host;
            widths[n] = a.view.chrome.host_width;
            n += 1;
        }
    }
    if (strip.hasHost(a) and child_parent == null) {
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
    const columns = in_row and chrome.columns(widths[0..n], a.view.chrome.leading, left, 8 + caption.trailing, &aligned);
    const other_tabs: usize = if (a.tabs.items.items.len > 1) a.tabs.items.items.len - 1 else 0;
    const avail_bar = @max(0, c.size.w - a.view.sidebar_width - left - caption.trailing - 8 - 32);
    const max_other_budget = if (columns)
        @max(0, @min(aligned[0] * 0.55, aligned[0] - 180))
    else
        avail_bar * 0.38;
    const other_shown: usize = if (other_tabs > 0 and max_other_budget >= 76) @min(other_tabs, @as(usize, @intFromFloat(@max(1, @floor(max_other_budget / 76))))) else 0;
    const other_pill_w: f32 = if (other_shown > 0) @min(128, @max(72, max_other_budget / @as(f32, @floatFromInt(other_shown)) - 4)) else 0;
    const other_reserve: f32 = if (other_shown > 0) @as(f32, @floatFromInt(other_shown)) * (other_pill_w + 4) else 0;
    const shared = @min(chrome.slot_max, chrome.sharedSlotRoom(@max(240, c.size.w - a.view.sidebar_width - other_reserve - caption.trailing), left, 8, n));
    ui.key(c, "instrument-strip");
    const row = ui.div(c).fixed().offset(a.view.sidebar_width, 0).w(c.size.w - a.view.sidebar_width - caption.trailing).h(chrome.titlebar_height).pt(chrome.top_pad).pl(left).pr(8).row().gap(if (columns) chrome.gutter else 4).itemsCenter().layer(2);
    defer row.end();
    for (targets[0..n], 0..) |target, ix| {
        if (columns and ix == 0 and other_shown > 0) {
            ui.key(c, "instrument-col-0");
            const col0 = ui.div(c).row().size(aligned[0], chrome.tab_height).gap(4).itemsCenter();
            defer col0.end();
            slot(c, a, k, target, ix, @max(0, aligned[0] - other_reserve));
            var rendered: usize = 0;
            for (0..a.tabs.items.items.len) |ws| {
                if (ws != a.tabs.active and rendered < other_shown) {
                    topWorkspacePill(c, a, k, ws, other_pill_w);
                    rendered += 1;
                }
            }
        } else {
            slot(c, a, k, target, ix, @max(0, if (columns) aligned[ix] else shared));
        }
    }
    if (!columns and other_shown > 0) {
        var rendered: usize = 0;
        for (0..a.tabs.items.items.len) |ws| {
            if (ws != a.tabs.active and rendered < other_shown) {
                topWorkspacePill(c, a, k, ws, other_pill_w);
                rendered += 1;
            }
        }
    }
    ui.key(c, "instrument-new-tab");
    if (kit.iconButton(c, k, .plus, .{ .icon = 14, .tip = .{ .text = "New tab", .look = .tab } })) a.newTab();
}

fn chatNeedsInput(a: *const App, id: ?[]const u8) bool {
    return if (id) |chat| @import("app_question.zig").needsInput(a, chat) else false;
}

fn workspaceNeedsInput(a: *const App, ws: usize) bool {
    if (chatNeedsInput(a, workspaceChatId(a, ws))) return true;
    if (ws < a.tabs.splits.items.len) if (a.tabs.splits.items[ws]) |s| {
        for (s.panes.items) |id| if (chatNeedsInput(a, id)) return true;
        for (&s.groups) |*g| for (g.items.items) |tab| if (chatNeedsInput(a, tab.chat)) return true;
    };
    return false;
}

fn questionMark(c: *ui.Context, k: theme.Colors, pending: bool) bool {
    if (!pending) return false;
    ui.key(c, "tab-question-attention");
    const badge = ui.div(c).size(14, 14).center().rounded(5).bg(k.warning.alpha(0.15));
    defer badge.end();
    ui.text(c, "?", .{ .size = 11, .weight = .semibold, .color = k.warning });
    return true;
}

fn workspaceChatId(a: *const App, ws: usize) ?[]const u8 {
    const primary = if (ws == a.tabs.active) a.selected else a.tabs.items.items[ws];
    if (primary != null) return primary;
    if (ws < a.tabs.splits.items.len) if (a.tabs.splits.items[ws]) |s| {
        for (s.panes.items) |p| if (p) |cid| return cid;
        for (&s.groups) |*g| for (g.items.items) |pt| if (pt.chat) |cid| return cid;
    };
    return null;
}

fn workspacePaneCount(a: *const App, ws: usize) usize {
    if (ws < a.tabs.splits.items.len) if (a.tabs.splits.items[ws]) |s| return @max(1, s.panes.items.len);
    return 1;
}

fn topWorkspacePill(c: *ui.Context, a: *App, k: theme.Colors, ws: usize, pill_w: f32) void {
    ui.key(c, c.print("top-workspace-tab-{d}", .{ws}));
    const cid = workspaceChatId(a, ws);
    const ch = if (cid) |id| a.findChat(id) else null;
    const t_name = if (ch) |v| @import("view_sidebar.zig").chatLabel(v) else "New tab";
    const panes_n = workspacePaneCount(a, ws);
    const pill = ui.div(c).row().size(pill_w, chrome.tab_height).px(8).gap(6).itemsCenter().rounded(6).bg(k.ink(if (k.dark) 0.06 else 0.04)).hover(k.hover).clip().control();
    defer pill.end();
    const pill_hot = pill.hovered();
    if (!questionMark(c, k, workspaceNeedsInput(a, ws))) icons.icon(c, if (panes_n > 1) .widget else .@"chat-round-line", 13, k.muted, 0);
    kit.ellipsisText(c, t_name, .{ .size = 11.5, .line_height = 14, .color = k.muted }, @max(0, pill_w - (if (pill_hot) @as(f32, 46) else 28)));
    var closed = false;
    if (pill_hot) {
        const spacer = ui.div(c).row().grow();
        spacer.end();
        if (kit.iconButton(c, k, .close, .{ .size = 16, .radius = 4, .icon = 10, .tip = .{ .text = "Close tab" } })) {
            closed = true;
            strip.queue(a, .{ .close_global_tab = ws });
        }
    }
    if (!closed and pill.clicked()) strip.queue(a, .{ .global_tab = ws });
}

fn slot(c: *ui.Context, a: *App, k: theme.Colors, target: strip.Panel, ix: usize, width: f32) void {
    if (target == .chat) {
        if (a.tabs.layout()) |s| {
            const pane = target.chat;
            const g = &s.groups[pane];
            const tab_n = g.count();
            if (tab_n > 1) {
                const inactive_n: f32 = @floatFromInt(tab_n - 1);
                const min_active_w: f32 = 148;
                const min_inactive_w: f32 = 72;
                if (width >= min_active_w + inactive_n * (min_inactive_w + 3)) {
                    ui.key(c, c.print("instrument-slot-group-{d}", .{ix}));
                    const group_row = ui.div(c).row().size(width, chrome.tab_height).gap(3).itemsCenter().clip();
                    defer group_row.end();
                    const group_hot = group_row.hovered();
                    const max_inactive = (width - min_active_w) / inactive_n - 3;
                    const inactive_w = @min(132, @min(max_inactive, @max(min_inactive_w, (width - 3 * inactive_n) * 0.34 / inactive_n)));
                    const active_w = @max(min_active_w, width - inactive_n * (inactive_w + 3));
                    for (0..tab_n) |t_ix| {
                        if (t_ix == g.active) {
                            slotBox(c, a, k, target, ix, active_w, group_hot);
                        } else {
                            inactiveTabPill(c, a, k, ix, pane, t_ix, g.items.items[t_ix].chat, inactive_w);
                        }
                    }
                    return;
                }
            }
        }
    }
    slotBox(c, a, k, target, ix, width, false);
}

fn inactiveTabPill(c: *ui.Context, a: *App, k: theme.Colors, slot_ix: usize, pane: usize, tab_ix: usize, chat_id: ?[]const u8, pill_w: f32) void {
    ui.key(c, c.print("instrument-slot-{d}-tab-{d}", .{ slot_ix, tab_ix }));
    const ch = if (chat_id) |cid| a.findChat(cid) else null;
    const t_name = if (ch) |v| @import("view_sidebar.zig").chatLabel(v) else "New tab";
    const pill = ui.div(c).row().size(pill_w, chrome.tab_height).px(7).gap(5).itemsCenter().rounded(6).bg(k.ink(if (k.dark) 0.06 else 0.04)).hover(k.hover).clip().control();
    defer pill.end();
    const pill_hot = pill.hovered();
    if (!questionMark(c, k, chatNeedsInput(a, chat_id))) icons.icon(c, .@"chat-round-line", 13, k.muted, 0);
    kit.ellipsisText(c, t_name, .{ .size = 11.5, .line_height = 14, .color = k.muted }, @max(0, pill_w - (if (pill_hot) @as(f32, 44) else 26)));
    var pill_closed = false;
    if (pill_hot) {
        const spacer = ui.div(c).row().grow();
        spacer.end();
        if (kit.iconButton(c, k, .close, .{ .size = 16, .radius = 4, .icon = 10, .tip = .{ .text = "Close tab" } })) {
            pill_closed = true;
            strip.queue(a, .{ .close_panel_tab = .{ .pane = pane, .tab = tab_ix } });
        }
    }
    if (!pill_closed and pill.clicked()) {
        strip.queue(a, .{ .panel_tab = .{ .pane = pane, .tab = tab_ix } });
    }
}

fn slotBox(c: *ui.Context, a: *App, k: theme.Colors, target: strip.Panel, ix: usize, width: f32, group_hot: bool) void {
    ui.key(c, c.print("instrument-slot-{d}", .{ix}));
    const on = strip.same(strip.active(a), target);
    const name = strip.title(a, target);
    const github_child = target == .host and @import("app_github_repository.zig").surface(a);
    const computer = if (github_child) c.print("↳ {s}", .{@import("app_github_repository.zig").ownerTitle(a)}) else strip.deviceLabel(a, strip.device(a, target));
    const project = strip.folder(a, target);
    var box = ui.div(c).row().size(width, chrome.tab_height).pl(7).pr(4).gap(6).itemsCenter().rounded(6).clip().control();
    box = if (on) box.bg(k.ink(if (k.dark) 0.16 else 0.10)) else box.bg(k.ink(if (k.dark) 0.06 else 0.04)).hover(k.hover);
    if (github_child) box = box.border(k.accent.alpha(0.28)).borderW(1);
    defer box.end();
    const hot = box.hovered() or group_hot;
    const show_controls = hot or c.focus == c.node(box.index).id;
    const menu_count = strip.tabCount(a, target);
    var handled = false;
    if (questionMark(c, k, if (target == .chat) chatNeedsInput(a, strip.chatId(a, target.chat)) else false)) {
        // The question remains dormant; this badge never requests focus.
    } else if (strip.attention(a, target, k)) |color| {
        const mark = ui.div(c).row().size(14, 14).center();
        defer mark.end();
        ui.div(c).size(7, 7).rounded(3.5).bg(color).end();
    } else icons.icon(c, strip.glyph(a, target), 14, k.muted, 0);
    {
        const text = ui.div(c).column().grow().w(0).clip();
        defer text.end();
        const room = @import("motion_rules.zig").slotTextRoom(width, show_controls, if (target == .chat) 1 else menu_count);
        kit.ellipsisText(c, name, .{ .size = 12, .line_height = 14, .color = if (on) k.text else k.muted }, room);
        const meta = ui.div(c).row().h(14).wFull().gap(6).itemsCenter().clip();
        defer meta.end();
        const device_editable = target == .chat;
        const dev_text_w = c.text.width(computer, .{ .size = 10 });
        const pick_text_w: ?f32 = if (project) |f| c.text.width(f.name, .{ .size = 10 }) else null;
        const pick_changeable = if (project) |f| f.changeable else false;
        const chips = @import("motion_rules.zig").slotChipWidths(room, dev_text_w, device_editable, pick_text_w, pick_changeable);
        {
            ui.key(c, "slot-device");
            var dev = ui.div(c).row().w(chips.dev_w).h(14).gap(3).itemsCenter().rounded(3).clip();
            if (device_editable) dev = dev.px(3).hover(k.ink(0.10)).control();
            defer dev.end();
            const dev_rect = c.rects.get(c.node(dev.index).id) orelse c.rects.get(c.node(box.index).id);
            if (device_editable and a.view.strip.menu == .device and strip.same(a.view.strip.target, target)) {
                if (dev_rect) |r| a.view.strip.device_anchor = r;
            }
            icons.icon(c, if (github_child) .@"split-columns" else .monitor, 10, k.muted, 0);
            kit.ellipsisText(c, computer, .{ .size = 10, .line_height = 12, .color = k.muted }, chips.dev_text_max);
            if (device_editable) {
                icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
                if (dev.clicked()) {
                    handled = true;
                    const state = &a.view.strip;
                    if (state.menu == .device and strip.same(state.target, target)) {
                        state.menu = null;
                    } else {
                        strip.queue(a, .{ .focus = target });
                        strip.open(a, .device, target, dev_rect);
                    }
                }
            }
        }
        if (project) |f| {
            ui.key(c, "slot-folder");
            var pick = ui.div(c).row().w(chips.pick_w).h(14).gap(3).itemsCenter().rounded(3).clip();
            if (f.changeable) pick = pick.px(3).hover(k.ink(0.10)).control();
            defer pick.end();
            const pick_rect = c.rects.get(c.node(pick.index).id) orelse c.rects.get(c.node(box.index).id);
            if (f.changeable and a.view.strip.menu == .folder and !a.view.strip.footer_folder and strip.same(a.view.strip.target, target)) {
                if (pick_rect) |r| a.view.strip.anchor = r;
            }
            icons.icon(c, .folder, 10, k.muted, 0);
            kit.ellipsisText(c, f.name, .{ .size = 10, .line_height = 12, .color = k.muted }, chips.pick_text_max);
            if (f.changeable) {
                icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
                strip.offerSplitFolder(c, a, target, c.rects.get(c.node(pick.index).id));
                if (pick.clicked()) {
                    handled = true;
                    const state = &a.view.strip;
                    if (state.menu == .folder and !state.footer_folder and strip.same(state.target, target)) {
                        state.menu = null;
                    } else {
                        // Focus is queued; the menu's rows read the target's draft.
                        strip.queue(a, .{ .focus = target });
                        strip.open(a, .folder, target, pick_rect);
                    }
                }
            }
        }
    }
    if (show_controls and width >= 220) {
        ui.key(c, "slot-add");
        if (kit.iconButton(c, k, .plus, .{ .size = 18, .radius = 4, .icon = 11, .tip = .{ .text = if (target == .chat) "New tab" else "New surface" } })) {
            handled = true;
            if (target == .chat) a.newTab() else strip.queue(a, .{ .new = target });
        }
    }
    if ((target != .chat and menu_count > 1) or show_controls) {
        ui.key(c, "slot-menu");
        const button = ui.div(c).row().h(18).minW(18).px(3).gap(2).center().rounded(4).hover(k.ink(0.10)).control();
        defer button.end();
        if (target != .chat and menu_count > 1) ui.text(c, c.print("{d}", .{menu_count}), .{ .size = 11, .color = k.muted });
        icons.icon(c, .@"alt-arrow-down", 11, k.muted, 0);
        if (button.clicked()) {
            handled = true;
            const state = &a.view.strip;
            if (state.menu == .panel and strip.same(state.target, target)) {
                state.menu = null;
            } else {
                strip.open(a, .panel, target, c.rects.get(c.node(button.index).id) orelse c.rects.get(c.node(box.index).id));
            }
        }
    }
    if (show_controls and width >= chrome.slot_room_for_close) {
        ui.key(c, "slot-close");
        if (kit.iconButton(c, k, .close, .{ .size = 18, .radius = 4, .icon = 11, .tip = .{ .text = "Close tab" } })) {
            handled = true;
            switch (target) {
                .chat => |pane| strip.queue(a, .{ .close_panel_tab = .{ .pane = pane, .tab = if (a.tabs.layout()) |s| s.groups[pane].active else 0 } }),
                .host => if (a.panels.active < a.panels.tabs.items.len) strip.queue(a, .{ .close_host_tab = a.panels.active }) else strip.queue(a, .{ .close = .host }),
                .files => strip.queue(a, .{ .close = .files }),
            }
        }
    }
    if (!handled and box.clicked()) strip.queue(a, .{ .focus = target });
    if (kit.secondaryClicked(box)) strip.open(a, .panel, target, c.rects.get(c.node(box.index).id));
}

pub const Selected = struct { left: f32, right: f32 };
pub fn selectedBounds(a: *const App) ?Selected {
    if (strip.count(a) != 1) return null;
    const group = if (a.tabs.layout()) |s| (if (s.groups[s.focus].count() > 1 or a.tabs.items.items.len <= 1) &s.groups[s.focus] else null) else null;
    const n = if (group) |g| g.count() else a.tabs.items.items.len;
    const selected = if (group) |g| g.active else a.tabs.active;
    const left = @max(strip.leftInset(a), a.view.chrome.leading);
    const available = @max(0, a.view.chrome.width - left - chrome.device_room - caption.trailing - 4);
    const width = chrome.tabWidth(available, n);
    const scroll = @max(0, @as(f32, @floatFromInt(selected + 1)) * (width + 3) - @max(0, available - 32));
    const start = left - a.view.chrome.leading + @as(f32, @floatFromInt(selected)) * (width + 3) - scroll;
    return .{ .left = @max(0, start), .right = @min(a.view.chrome.width, start + width) };
}

fn single(c: *ui.Context, a: *App, k: theme.Colors, left: f32) void {
    const group = if (a.tabs.layout()) |s| (if (s.groups[s.focus].count() > 1 or a.tabs.items.items.len <= 1) &s.groups[s.focus] else null) else null;
    const n = if (group) |g| g.count() else a.tabs.items.items.len;
    const selected = if (group) |g| g.active else a.tabs.active;
    const available = @max(0, a.view.chrome.width - left - chrome.device_room - caption.trailing - 4);
    const width = chrome.tabWidth(available, n);
    const scroll = @max(0, @as(f32, @floatFromInt(selected + 1)) * (width + 3) - @max(0, available - 32));
    ui.key(c, "panel-tabs");
    const lane = ui.div(c).fixed().offset(a.view.sidebar_width + left, chrome.tab_top).size(available, chrome.tab_height + chrome.tab_top).clip().layer(2);
    defer lane.end();
    const row = ui.div(c).absolute().offset(-scroll, 0).row().h(chrome.tab_height).gap(3).itemsCenter();
    defer row.end();
    for (0..n) |ix| {
        const chat = if (group) |g| (if (ix == selected) a.selected else g.items.items[ix].chat) else workspaceChatId(a, ix);
        const panes_n = if (group != null) @as(usize, 1) else workspacePaneCount(a, ix);
        const ch = if (chat) |id| a.findChat(id) else null;
        const label = if (ch) |v| @import("view_sidebar.zig").chatLabel(v) else "New tab";
        ui.key(c, c.print("panel-tab-{d}", .{ix}));
        var cap = ui.div(c).row().size(width, chrome.tab_height).px(8).gap(6).itemsCenter().rounded(6).clip().control();
        if (ix != selected) cap = cap.bg(k.ink(if (k.dark) 0.06 else 0.04)).hover(k.hover);
        defer cap.end();
        const hot = cap.hovered();
        const pending_question = if (group != null) chatNeedsInput(a, chat) else workspaceNeedsInput(a, ix);
        if (!questionMark(c, k, pending_question)) icons.icon(c, if (panes_n > 1) .widget else .@"chat-round-line", 14, if (ix == selected) k.text else k.muted, 0);
        {
            const labels = ui.div(c).column().grow().w(0).clip();
            defer labels.end();
            kit.ellipsisText(c, label, .{ .size = 12, .line_height = 14, .color = if (ix == selected) k.text else k.muted }, @max(0, width - 58));
            if (panes_n > 1) {
                const meta = ui.div(c).row().gap(6).h(12).itemsCenter();
                defer meta.end();
                kit.ellipsisText(c, c.print("{d} split panes", .{panes_n}), .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, width - 58));
            } else if (ch) |chat_row| {
                const meta = ui.div(c).row().gap(6).h(12).itemsCenter();
                defer meta.end();
                if (chat_row.branch) |branch| kit.ellipsisText(c, branch, .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, (width - 58) * 0.45));
                const mark = icons.harnessMark(chat_row.harness orelse "graff");
                icons.icon(c, mark.name, 12, mark.brand orelse k.muted, 0);
                kit.ellipsisText(c, chat_row.model orelse chat_row.harness orelse "Graff", .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, (width - 58) * 0.5 - 15));
            }
        }
        var handled = false;
        if (hot or (n > 1 and ix == selected)) {
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
    if (kit.iconButton(c, k, .plus, .{ .icon = 14, .tip = .{ .text = "New tab", .look = .tab } })) a.newTab();
    // Device is its own fixed trailing lane, never a tab's suffix.
    devicePicker(c, a, k);
}

fn devicePicker(c: *ui.Context, a: *App, k: theme.Colors) void {
    const target = strip.active(a);
    const editable = target == .chat;
    const lane = ui.div(c).fixed().offset(c.size.w - caption.trailing - chrome.device_room - 12, chrome.tab_top).size(chrome.device_room, chrome.tab_height).pl(8).row().itemsCenter().justifyEnd().layer(3);
    defer lane.end();
    ui.key(c, "panel-device-trigger");
    var box = ui.div(c).row().h(18).px(if (editable) 4 else 0).gap(3).itemsCenter().rounded(4).clip();
    if (editable) box = box.hover(k.ink(0.10)).control();
    defer box.end();
    // Once a menu opens, retain the anchor of the control actually clicked
    // (the draft footer also offers this picker).
    if (editable and a.view.strip.menu != .device) {
        if (c.rects.get(c.node(box.index).id)) |r| a.view.strip.device_anchor = r;
    }
    icons.icon(c, .monitor, 10, k.muted, 0);
    kit.ellipsisText(c, strip.deviceLabel(a, strip.device(a, target)), .{ .size = 10, .line_height = 12, .color = k.muted }, chrome.device_room - 21 - (if (editable) @as(f32, 17) else 0));
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
