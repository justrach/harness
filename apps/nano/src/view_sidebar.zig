//! The conversation sidebar from shell.rs/spaces.rs: project filter first,
//! then session lists and a compact 44-point account/create footer. Panel
//! conversation tabs belong to the instrument strip, not this column.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const rules = @import("rules.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;

const builtin = @import("builtin");

pub const star_github_url = "https://github.com/justrach/codegraff";

/// "No sessions yet": GPUI's default line (φ), up to a device pixel.
const empty_line = kit.measured(12 * 1.618);

pub const width: f32 = @import("settings.zig").sidebar_default;

pub fn widthOf(a: *const App) f32 {
    return a.settings.sidebarWidth();
}
fn cardInnerW(a: *const App) f32 {
    return if (a.settings.uiMode() == .zen) widthOf(a) - @import("panel_chrome.zig").zen_gutter * 1.5 else widthOf(a);
}
pub const titlebar_h: f32 = 38;

pub fn sidebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const zen = a.settings.uiMode() == .zen;
    if (zen) {
        const chrome = @import("panel_chrome.zig");
        const panel_chrome = @import("view_panel_chrome.zig");
        const side = ui.div(c).column().w(widthOf(a)).hFull();
        defer side.end();
        sidebarTitlebar(c, a, k);
        ui.div(c).h(chrome.top_pad).end();
        const wrap = ui.div(c).column().wFull().grow().h(0).pl(chrome.zen_gutter).pr(chrome.zen_gutter / 2.0).pb(chrome.zen_gutter);
        defer wrap.end();
        ui.key(c, "zen-sidebar-card");
        const card = panel_chrome.zenSidebar(c, k).wFull().grow().h(0).pt(6).clip();
        defer card.end();
        zenNavRows(c, a, k);
        filterRow(c, a, k);
        const search = @import("view_sidebar_search.zig");
        search.controls(c, a, k);
        var archived_count = a.view.cached_archived_count;
        if (!search.results(c, a, k)) {
            openWorkspaces(c, a, k);
            archived_count = lists(c, a, k);
        }
        @import("view_bots.zig").group(c, a, k);
        zenFooter(c, a, k, archived_count);
        return;
    }
    // The edge is drawn over its last column (view.zig), as the GPUI app's.
    const side = ui.div(c).column().w(widthOf(a)).hFull().bg(k.sidebar);
    defer side.end();
    sidebarTitlebar(c, a, k);
    const search = @import("view_sidebar_search.zig");
    filterRow(c, a, k);
    // The session search's field, and its results in the lists' place
    // while it filters (view_sidebar_search.zig).
    search.controls(c, a, k);
    if (!search.results(c, a, k)) {
        openWorkspaces(c, a, k);
        _ = lists(c, a, k);
    }
    // Contacts, not chats in a folder: shown on every project filter.
    @import("view_bots.zig").group(c, a, k);
    footer(c, a, k);
}

pub fn navHistoryControls(c: *ui.Context, a: *App, k: theme.Colors) void {
    {
        ui.key(c, "sidebar-nav-back");
        if (a.canGoBack()) {
            if (kit.iconButton(c, k, .@"arrow-left", .{ .size = 24, .radius = 6, .icon = 15, .color = k.muted, .tip = .{ .text = "Go back", .delay = tip.quick } }))
                a.goBack();
        } else {
            const disabled = tip.on(ui.div(c).row().size(24, 24).center().rounded(6), k, .{ .text = "Go back", .delay = tip.quick });
            icons.icon(c, .@"arrow-left", 15, k.muted.alpha(0.32), 0);
            disabled.end();
        }
    }
    ui.div(c).w(2).end();
    {
        ui.key(c, "sidebar-nav-forward");
        if (a.canGoForward()) {
            if (kit.iconButton(c, k, .@"arrow-right", .{ .size = 24, .radius = 6, .icon = 15, .color = k.muted, .tip = .{ .text = "Go forward", .delay = tip.quick } }))
                a.goForward();
        } else {
            const disabled = tip.on(ui.div(c).row().size(24, 24).center().rounded(6), k, .{ .text = "Go forward", .delay = tip.quick });
            icons.icon(c, .@"arrow-right", 15, k.muted.alpha(0.32), 0);
            disabled.end();
        }
    }
}

fn sidebarTitlebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const zen = a.settings.uiMode() == .zen;
    const menus = @import("view_sidebar_menus.zig");
    const side_w = widthOf(a);
    const layout = if (zen) @import("motion_rules.zig").zenSidebarTitlebarLayout(side_w) else @import("motion_rules.zig").sidebarTitlebarLayout(side_w);
    const group_gap: f32 = if (side_w >= 240) 8 else 4;
    const right_margin: f32 = if (zen) 10 else if (side_w >= 240) 8 else 4;
    const bar = ui.div(c).row().wFull().h(titlebar_h).pt(4).pl(layout.back_x).pr(right_margin).itemsCenter();
    defer bar.end();
    navHistoryControls(c, a, k);
    ui.div(c).w(group_gap).end();
    if (!zen) {
        ui.key(c, "sidebar-titlebar-new-session");
        if (kit.iconButton(c, k, .plus, .{ .size = 24, .radius = 6, .icon = 16, .color = k.muted, .tip = .{ .text = "New session", .delay = tip.quick } }))
            a.newWorkspaceSession();
    }
    ui.spacer(c);
    {
        ui.key(c, "sidebar-view-options");
        const more = tip.on(ui.div(c).row(), k, .{ .text = if (a.view.more_menu) "" else "Sidebar view options", .delay = tip.quick });
        defer more.end();
        if (kit.iconButton(c, k, .@"more-horizontal", .{ .size = 24, .radius = 6, .icon = 16, .color = k.muted, .on = a.view.more_menu }))
            if (a.view.more_menu) menus.close(a) else menus.openView(a);
        if (c.rects.get(c.node(more.index).id)) |r| a.view.more_anchor = r;
    }
}

const SessionTab = struct {
    ws: usize,
    pane: ?usize = null,
    tab: ?usize = null,
    chat_id: ?[]const u8 = null,
    active: bool = false,
    flat: bool = false,
};

const OpenSession = struct {
    ws: usize,
    title_chat_id: ?[]const u8 = null,
    active: bool = false,
    tabs: []const SessionTab,
};

/// Open workspace sessions (`⊞`) and all of their corresponding tabs nested
/// underneath each session at the top of the ⌘B sidebar.
pub fn openWorkspaces(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.settings.hierarchyProfile().shows_open_workspaces_tree) return;
    var sessions: std.ArrayList(OpenSession) = .empty;
    for (a.tabs.items.items, 0..) |id, ws| {
        if (a.tabs.items.items.len > 1) {
            if (a.view.filter) |filter| if (a.findSpace(filter) != null) {
                const project = a.workspaceProject(ws) orelse continue;
                if (!std.mem.eql(u8, project, filter)) continue;
            };
        }
        var stabs: std.ArrayList(SessionTab) = .empty;
        const active_cid: ?[]const u8 = if (ws == a.tabs.active) a.selected else id;
        var title_cid: ?[]const u8 = active_cid;
        if (a.tabs.splits.items[ws]) |split| {
            for (0..split.panes.items.len) |pane_ix| {
                const g = &split.groups[pane_ix];
                const pane_cid = if (ws == a.tabs.active and pane_ix == split.focus)
                    a.selected
                else if (pane_ix == split.focus)
                    id
                else
                    split.panes.items[pane_ix];
                if (split.panes.items.len > 1 and title_cid == null and pane_cid != null) title_cid = pane_cid;
                if (g.items.items.len > 1) {
                    for (0..g.items.items.len) |pt_ix| {
                        const cid = if (pt_ix == g.active) pane_cid else g.items.items[pt_ix].chat;
                        if (split.panes.items.len > 1 and title_cid == null and cid != null) title_cid = cid;
                        stabs.append(c.alloc(), .{
                            .ws = ws,
                            .pane = pane_ix,
                            .tab = pt_ix,
                            .chat_id = cid,
                            .active = ws == a.tabs.active and pane_ix == split.focus and pt_ix == g.active,
                        }) catch return;
                    }
                } else {
                    stabs.append(c.alloc(), .{
                        .ws = ws,
                        .pane = pane_ix,
                        .chat_id = pane_cid,
                        .active = ws == a.tabs.active and pane_ix == split.focus,
                    }) catch return;
                }
            }
        } else {
            stabs.append(c.alloc(), .{
                .ws = ws,
                .chat_id = active_cid,
                .active = ws == a.tabs.active,
            }) catch return;
        }
        if (a.tabs.items.items.len == 1 and stabs.items.len <= 1) continue;
        sessions.append(c.alloc(), .{
            .ws = ws,
            .title_chat_id = title_cid,
            .active = ws == a.tabs.active,
            .tabs = stabs.items,
        }) catch return;
    }
    if (sessions.items.len == 0) return;
    ui.key(c, "sidebar-open-workspaces");
    const list = ui.div(c).column().wFull().maxH(260).px(8).pt(6).gap(2).scrollY();
    c.node(list.index).style.scroll_edge_fade = 12;
    defer list.end();
    for (sessions.items, 0..) |sess, idx| {
        const title = if (sess.title_chat_id) |chat_id| (if (a.findChat(chat_id)) |chat| chatLabel(chat) else "New session") else "New session";
        const multi_tabs = sess.tabs.len > 1;
        {
            ui.key(c, c.print("workspace-session-{d}", .{idx}));
            const row_mot = ui.motion.frame(c, .{
                .initial = .{ .opacity = 0 },
                .target = .{ .opacity = 1 },
                .transition = .{ .tween = .{ .duration = 0.14, .ease = .linear } },
            });
            var row = ui.div(c).row().wFull().h(32).px(8).gap(7).itemsCenter().rounded(7).control().motion(row_mot);
            if (sess.active and !multi_tabs) {
                row = row.bg(k.selected);
            } else if (sess.active and multi_tabs) {
                row = row.bg(k.ink(if (k.dark) 0.07 else 0.04)).hover(k.hover.alpha(0.45));
            } else {
                row = row.hover(k.hover.alpha(0.45));
            }
            defer row.end();
            const hovered = row.hovered();
            var closed = false;
            {
                const mark = ui.div(c).row().size(20, 20).center();
                defer mark.end();
                if (hovered and !multi_tabs and sessions.items.len > 1) {
                    const close_btn = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.12));
                    defer close_btn.end();
                    if (close_btn.clicked()) {
                        closed = true;
                        @import("view_tab_strip.zig").queue(a, .{ .close_global_tab = sess.ws });
                    }
                    icons.icon(c, .close, 12, k.muted, 0);
                } else {
                    openChatMark(c, a, k, sess.title_chat_id, sess.active, 14);
                }
            }
            const badge_room: f32 = if (multi_tabs) 28 else 0;
            kit.ellipsisText(c, title, .{ .size = 13, .weight = if (multi_tabs) theme.ui_medium_weight else .regular, .line_height = kit.measured(13 * 1.618), .color = k.text }, @max(0, widthOf(a) - 2 * 8 - 2 * 8 - 20 - 7 - 22 - 7 - badge_room));
            if (multi_tabs) {
                const spacer = ui.div(c).row().grow();
                spacer.end();
                const pill = ui.div(c).row().h(18).minW(18).px(5).center().rounded(9).bg(k.ink(if (k.dark) 0.12 else 0.07));
                defer pill.end();
                ui.text(c, c.print("{d}", .{sess.tabs.len}), .{ .size = 10.5, .weight = theme.ui_medium_weight, .color = k.muted });
            }
            if (!closed and row.clicked()) {
                if (sess.ws != a.tabs.active) a.showTab(sess.ws);
            }
        }
        if (multi_tabs) {
            const tree = ui.div(c).column().wFull().pl(16).pr(2).pt(1).pb(3).gap(1);
            defer tree.end();
            for (sess.tabs, 0..) |t, t_ix| {
                const tab_title = if (t.chat_id) |cid| (if (a.findChat(cid)) |chat| chatLabel(chat) else "New tab") else "New tab";
                ui.key(c, c.print("workspace-session-{d}-tab-{d}", .{ idx, t_ix }));
                const tab_mot = ui.motion.frame(c, .{
                    .initial = .{ .opacity = 0 },
                    .target = .{ .opacity = 1 },
                    .transition = .{ .tween = .{ .duration = 0.12, .ease = .linear } },
                    .delay = ui.motion.stagger(t_ix, 0.02),
                });
                const trow_wrap = ui.div(c).row().wFull().h(28).itemsCenter().motion(tab_mot);
                defer trow_wrap.end();
                // Vertical tree guide rail connecting the tab to its parent Session.
                const rail = ui.div(c).row().w(10).hFull().center();
                ui.div(c).size(1.5, if (t_ix + 1 == sess.tabs.len) 18 else 28).rounded(1).bg(if (t.active) k.text.alpha(0.55) else k.border_strong.alpha(0.65)).end();
                rail.end();
                var trow = ui.div(c).row().grow().w(0).h(28).px(7).gap(6).itemsCenter().rounded(6).control();
                if (t.active) {
                    trow = trow.bg(k.selected);
                } else {
                    trow = trow.hover(k.hover.alpha(0.45));
                }
                defer trow.end();
                const thovered = trow.hovered();
                var tclosed = false;
                {
                    const tmark = ui.div(c).row().size(18, 18).center();
                    defer tmark.end();
                    if (thovered) {
                        const close_btn = ui.div(c).row().size(16, 16).center().rounded(4).hover(k.wash(0.12));
                        defer close_btn.end();
                        if (close_btn.clicked()) {
                            tclosed = true;
                            if (t.flat) {
                                @import("view_tab_strip.zig").queue(a, .{ .close_global_tab = t.tab orelse 0 });
                            } else {
                                if (t.ws != a.tabs.active) a.showTab(t.ws);
                                if (t.tab) |pt| {
                                    @import("view_tab_strip.zig").queue(a, .{ .close_panel_tab = .{ .pane = t.pane orelse 0, .tab = pt } });
                                } else if (t.pane) |p| {
                                    @import("view_tab_strip.zig").queue(a, .{ .close = .{ .chat = p } });
                                }
                            }
                        }
                        icons.icon(c, .close, 11, k.muted, 0);
                    } else {
                        openChatMark(c, a, k, t.chat_id, t.active, 13);
                    }
                }
                kit.ellipsisText(c, tab_title, .{ .size = 12.5, .line_height = kit.measured(12.5 * 1.5), .color = if (t.active) k.text else k.muted }, @max(0, widthOf(a) - 16 - 16 - 10 - 14 - 18 - 6 - 18));
                if (!tclosed and trow.clicked()) {
                    if (t.flat) {
                        a.showTab(t.tab orelse 0);
                    } else {
                        if (t.ws != a.tabs.active) a.showTab(t.ws);
                        if (t.pane) |p| {
                            a.focusPane(p);
                            a.view.strip.focused = .{ .chat = p };
                        }
                        if (t.tab) |pt| a.showPaneTab(pt);
                    }
                }
            }
        }
    }
}

/// Open panes identify the agent that owns the chat, not a generic chat or
/// workspace glyph. Keep the ordinary conversation list's status slot separate.
fn openChatMark(c: *ui.Context, a: *const App, k: theme.Colors, chat_id: ?[]const u8, active: bool, size: f32) void {
    const chat = if (chat_id) |id| a.findChat(id) else null;
    const mark = icons.harnessMark(if (chat) |ch| ch.harness orelse "graff" else a.new_harness);
    icons.icon(c, mark.name, size, mark.brand orelse if (active) k.text else k.muted, 0);
}

fn zenNavRows(c: *ui.Context, a: *App, k: theme.Colors) void {
    const mac = builtin.os.tag == .macos;
    const box = ui.div(c).column().wFull().px(8).pt(8).pb(4).gap(2);
    defer box.end();

    {
        ui.key(c, "zen-nav-new-chat");
        const row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(7).hover(k.hover).control();
        const clicked = row.clicked();
        const hot = row.hovered();
        {
            defer row.end();
            icons.icon(c, .plus, 15, if (hot) k.text else k.muted, 0);
            ui.text(c, "New chat", .{ .size = 13, .line_height = 17, .weight = theme.ui_medium_weight, .color = k.text.alpha(if (hot) 0.98 else 0.88) });
            ui.spacer(c);
            ui.text(c, if (mac) "⌘N" else "Ctrl+N", .{ .size = 11, .line_height = 14, .color = k.faint });
        }
        if (clicked) a.newWorkspaceSession();
    }

    {
        const searching = a.view.search.open;
        ui.key(c, "zen-nav-search");
        var row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(7).hover(k.hover).control();
        if (searching) row = row.bg(k.selected);
        const clicked = row.clicked();
        const hot = row.hovered();
        if (c.rects.get(c.node(row.index).id)) |r| a.view.search_anchor = r;
        {
            defer row.end();
            icons.icon(c, .magnifer, 15, if (searching or hot) k.text else k.muted, 0);
            ui.text(c, "Search", .{ .size = 13, .line_height = 17, .weight = theme.ui_medium_weight, .color = k.text.alpha(if (searching or hot) 0.98 else 0.88) });
            ui.spacer(c);
            ui.text(c, if (mac) "⌘K" else "Ctrl+K", .{ .size = 11, .line_height = 14, .color = k.faint });
        }
        if (clicked) @import("view_sidebar_search.zig").toggle(a);
    }

    {
        ui.key(c, "zen-nav-pull-requests");
        const row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(7).hover(k.hover).control();
        const clicked = row.clicked();
        const hot = row.hovered();
        {
            defer row.end();
            icons.icon(c, .@"pull-request", 15, if (hot) k.text else k.muted, 0);
            ui.text(c, "Pull requests", .{ .size = 13, .line_height = 17, .weight = theme.ui_medium_weight, .color = k.text.alpha(if (hot) 0.98 else 0.88) });
        }
        if (clicked) {
            const gh = @import("app_github_repository.zig");
            gh.bind(a);
            @import("app_git.zig").open(a, .github);
            gh.show(a);
        }
    }
}

fn filterRow(c: *ui.Context, a: *App, k: theme.Colors) void {
    const menus = @import("view_sidebar_menus.zig");
    if (a.settings.uiMode() == .zen) {
        const row = ui.div(c).row().wFull().px(10).pt(4).pb(6).itemsCenter();
        defer row.end();
        const rest_bg = k.ink(if (k.dark) 0.065 else 0.045);
        const base = ui.div(c).row().h(26).px(8).gap(6).itemsCenter().rounded(7)
            .border(k.border.alpha(0.55)).borderW(1).clip().control();
        const lh = kit.listenerHover(&a.view.hovers, base.bg(if (a.view.filter_menu) k.hover else rest_bg), k.hover);
        const t = lh.div;
        const clicked = t.clicked();
        if (c.rects.get(c.node(t.index).id)) |r| a.view.filter_anchor = r;
        {
            defer t.end();
            const color = if (lh.hovered or a.view.filter_menu) k.text else k.text.alpha(0.86);
            const max_room = @max(60, widthOf(a) - 86);
            if (a.findSpace(a.view.filter)) |s| {
                const icon_slot = ui.div(c).row().size(15, 15).center();
                badge(c, a, k, s.id, lh.hovered or a.view.filter_menu);
                icon_slot.end();
                kit.ellipsisText(c, s.name, .{ .size = 12.5, .line_height = 16, .weight = theme.ui_medium_weight, .color = color }, max_room);
            } else {
                icons.icon(c, .folder, 14, if (lh.hovered or a.view.filter_menu) k.text.alpha(0.88) else k.muted.alpha(0.85), 14);
                ui.text(c, "All projects", .{ .size = 12.5, .line_height = 16, .weight = theme.ui_medium_weight, .color = color });
            }
            icons.icon(c, .@"alt-arrow-down", 10, k.muted, 0);
        }
        if (clicked) if (a.view.filter_menu) menus.close(a) else menus.openProjects(a);
        return;
    }
    const row = ui.div(c).row().wFull().px(8).pt(6).pb(4).itemsCenter();
    defer row.end();
    const rest_bg = k.ink(if (k.dark) 0.055 else 0.042);
    const base = ui.div(c).row().grow().w(0).h(29).px(8).gap(8).itemsCenter().rounded(8).clip();
    const lh = kit.listenerHover(&a.view.hovers, base.bg(if (a.view.filter_menu) k.hover else rest_bg), k.hover);
    const t = lh.div;
    defer t.end();
    if (t.clicked()) if (a.view.filter_menu) menus.close(a) else menus.openProjects(a);
    if (c.rects.get(c.node(t.index).id)) |r| a.view.filter_anchor = r;
    const color = if (lh.hovered or a.view.filter_menu) k.text else k.text.alpha(0.88);
    const room = @max(0, widthOf(a) - 16 - 16 - 16 - 8);
    if (a.findSpace(a.view.filter)) |s| {
        const icon_slot = ui.div(c).row().size(16, 16).center();
        badge(c, a, k, s.id, lh.hovered or a.view.filter_menu);
        icon_slot.end();
        const tag = c.print("@ {s}", .{a.deviceName(s.device_id)});
        const off = !menus.online(a, s.device_id, a.nowMs());
        const tag_w = @min(c.text.width(tag, .{ .size = 10 }), room / 2);
        const name_w = @min(c.text.width(s.name, .{ .size = 13, .weight = theme.ui_medium_weight }), @max(0, room - tag_w - 6 - (if (off) @as(f32, 18) else 0)));
        const box = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip();
        defer box.end();
        kit.fadeText(c, s.name, .{ .size = 13, .weight = theme.ui_medium_weight, .color = color }, name_w);
        kit.fadeText(c, tag, .{ .size = 10, .color = k.muted.alpha(0.45) }, tag_w);
        if (off) icons.icon(c, .@"wifi-off", 12, k.warning.alpha(0.8), 0);
    } else {
        icons.icon(c, .folder, 15, if (lh.hovered or a.view.filter_menu) k.text.alpha(0.85) else k.muted.alpha(0.85), 16);
        const label = ui.div(c).row().grow().w(0).clip();
        defer label.end();
        kit.fadeText(c, "All projects", .{ .size = 13, .weight = theme.ui_medium_weight, .color = color }, room);
    }
}

const RowLookup = struct {
    spaces: std.StringHashMapUnmanaged(workspace.Space) = .empty,
    use_spaces: bool = false,
    sessions: std.StringHashMapUnmanaged(workspace.Session) = .empty,
    use_sessions: bool = false,
    chats: std.StringHashMapUnmanaged(usize) = .empty,
    use_chats: bool = false,

    fn init(gpa: std.mem.Allocator, a: *const App) RowLookup {
        var out: RowLookup = .{};
        if (a.spaces.items.len > 4) {
            out.use_spaces = true;
            out.spaces.ensureTotalCapacity(gpa, @intCast(a.spaces.items.len)) catch {};
            for (a.spaces.items) |sp| out.spaces.put(gpa, sp.id, sp) catch {};
        }
        if (a.sessions.items.len > 4) {
            out.use_sessions = true;
            out.sessions.ensureTotalCapacity(gpa, @intCast(a.sessions.items.len)) catch {};
            for (a.sessions.items) |s| out.sessions.put(gpa, s.chat_id, s) catch {};
        }
        if (a.chats.items.len > 4 and a.settings.pins.items.len > 0) {
            out.use_chats = true;
            out.chats.ensureTotalCapacity(gpa, @intCast(a.chats.items.len)) catch {};
            for (a.chats.items, 0..) |ch, i| out.chats.put(gpa, ch.id, i) catch {};
        }
        return out;
    }

    fn findSpace(l: *const RowLookup, a: *const App, id: ?[]const u8) ?workspace.Space {
        const want = id orelse return null;
        if (l.use_spaces) return l.spaces.get(want);
        return a.findSpace(want);
    }

    fn sessionOf(l: *const RowLookup, a: *const App, id: []const u8) ?workspace.Session {
        if (l.use_sessions) return l.sessions.get(id);
        return workspace.sessionOf(a.sessions.items, id);
    }

    fn findChat(l: *const RowLookup, a: *const App, id: []const u8) ?workspace.Chat {
        if (l.use_chats) {
            const ix = l.chats.get(id) orelse return null;
            return if (ix < a.chats.items.len) a.chats.items[ix] else null;
        }
        return a.findChat(id);
    }

    fn markOf(l: *const RowLookup, a: *const App, ch: workspace.Chat, now: i64) workspace.Mark {
        if (@import("app_question.zig").needsInput(a, ch.id)) return .awaiting_input;
        return workspace.markOf(ch, l.sessionOf(a, ch.id), now);
    }
};

fn listedWith(a: *const App, chat: workspace.Chat, lk: *const RowLookup, filter_space: ?[]const u8) bool {
    if (chat.parent_chat_id != null) return false;
    if (a.bots.ofChat(chat.id) != null) return false;
    if (chat.space_id) |sid| if (lk.findSpace(a, sid) == null) return false;
    if (filter_space) |f| if (chat.space_id == null or !std.mem.eql(u8, chat.space_id.?, f)) return false;
    return true;
}

/// The rows the lists show: top-level chats in a project that still
/// exists (or none), narrowed by the project filter. (The session search
/// shows its own results in their place: view_sidebar_search.zig.)
pub fn listed(a: *const App, chat: workspace.Chat) bool {
    if (chat.parent_chat_id != null) return false;
    // A bot's standing chat is its row in the Bots group, not a second one here.
    if (a.bots.ofChat(chat.id) != null) return false;
    if (chat.space_id) |sid| if (a.findSpace(sid) == null) return false;
    // A filter on a project that's gone shows them all, as its label does.
    if (a.view.filter) |f| if (a.findSpace(f) != null) if (chat.space_id == null or !std.mem.eql(u8, chat.space_id.?, f)) return false;
    return true;
}

/// The pins this list shows, in pin order: listed and not archived.
pub fn visiblePins(a: *const App, gpa: std.mem.Allocator) []const []const u8 {
    const lk = RowLookup.init(gpa, a);
    return visiblePinsWith(a, gpa, &lk);
}

fn visiblePinsWith(a: *const App, gpa: std.mem.Allocator, lk: *const RowLookup) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (a.settings.pins.items.len == 0) return out.items;
    const filter_space: ?[]const u8 = if (a.view.filter) |f| (if (lk.findSpace(a, f) != null) f else null) else null;
    const last_activity = a.settings.lastActivity();
    const now = a.nowMs();
    for (a.settings.pins.items) |id| if (lk.findChat(a, id)) |ch| if (!ch.archived and listedWith(a, ch, lk, filter_space) and last_activity.matches(ch.timeMs(), now)) out.append(gpa, id) catch {};
    return out.items;
}

fn pinned(pins: []const []const u8, id: []const u8) ?usize {
    for (pins, 0..) |p, i| if (std.mem.eql(u8, p, id)) return i;
    return null;
}

/// A row's slot: its 29 points and the 2 between rows.
pub const row_slot: f32 = 38 + 2;

const Window = struct {
    top: f32,
    bottom: f32,
    y: f32,
    eager: bool = false,
};

// One leaf per omitted run, including its internal gaps only. The parent
// supplies the boundary gaps just as it does for the original rows.
const Rows = struct {
    height: f32 = 0,
    count: usize = 0,

    fn include(self: *Rows, c: *ui.Context, window: *Window, height: f32) bool {
        const visible = window.eager or (window.y + height >= window.top and window.y <= window.bottom);
        window.y += height + 2;
        if (visible) {
            self.flush(c);
        } else {
            self.height += height + 2;
            self.count += 1;
        }
        return visible;
    }

    fn flush(self: *Rows, c: *ui.Context) void {
        if (self.count == 0) return;
        _ = c.leaf(.{ .height = .{ .px = self.height - 2 } }, .none, null);
        self.* = .{};
    }
};

const ChatItem = struct {
    listed: bool = false,
    pinned: bool = false,
    row_h: f32 = 30,
    group_key: []const u8 = "",
};

fn prepareItems(
    gpa: std.mem.Allocator,
    a: *const App,
    pins: []const []const u8,
    grouped: bool,
    by: Grouping,
    lk: *const RowLookup,
) []const ChatItem {
    const out = gpa.alloc(ChatItem, a.chats.items.len) catch return &.{};
    const filter_space: ?[]const u8 = if (a.view.filter) |f| (if (lk.findSpace(a, f) != null) f else null) else null;
    const last_activity = a.settings.lastActivity();
    const l = Look.of(a);
    const show_updated = a.settings.get(.sidebar_show_updated);
    const zen = a.settings.uiMode() == .zen;
    var pin_set: std.StringHashMapUnmanaged(void) = .empty;
    if (pins.len > 4) {
        pin_set.ensureTotalCapacity(gpa, @intCast(pins.len)) catch {};
        for (pins) |pid| pin_set.put(gpa, pid, {}) catch {};
    }
    for (a.chats.items, 0..) |ch, idx| {
        // A subagent's chat, or a bot's standing chat (its row is in the
        // Bots group): not a session row.
        if (ch.parent_chat_id != null or a.bots.ofChat(ch.id) != null) {
            out[idx] = .{};
            continue;
        }
        if (ch.space_id) |sid| if (lk.findSpace(a, sid) == null) {
            out[idx] = .{};
            continue;
        };
        if (filter_space) |f| if (ch.space_id == null or !std.mem.eql(u8, ch.space_id.?, f)) {
            out[idx] = .{};
            continue;
        };
        const row_h = if (zen) @as(f32, 30) else contextHeight(l.label, l.branch and ch.branch != null, show_updated, l.harness or l.icon);
        const is_pinned = !ch.archived and (if (pins.len > 4) pin_set.contains(ch.id) else pinned(pins, ch.id) != null);
        if (!ch.archived and !is_pinned and last_activity != .all) {
            const sess = lk.sessionOf(a, ch.id);
            const mark = workspace.markOf(ch, sess, by.now);
            if (mark != .working and mark != .awaiting_input and !last_activity.matches(ch.timeMs(), by.now)) {
                out[idx] = .{};
                continue;
            }
        }
        var gkey: []const u8 = "";
        if (grouped and !ch.archived and !is_pinned) {
            const sess = lk.sessionOf(a, ch.id);
            const mark = workspace.markOf(ch, sess, by.now);
            gkey = if (mark == .awaiting_input or mark == .errored)
                "needs"
            else switch (by.org) {
                .by_status => workspace.statusGroup(mark, ch.timeMs(), by.now, by.offset).key(),
                .by_project => ch.space_id orelse (std.fmt.allocPrint(gpa, "home:{s}", .{ch.device_id orelse ""}) catch ""),
                else => ch.device_id orelse "",
            };
        }
        out[idx] = .{ .listed = true, .pinned = is_pinned, .row_h = row_h, .group_key = gkey };
    }
    return out;
}

const ListStats = struct {
    total_height: f32,
    active: usize,
    archived: usize,
    regular_full_h: f32,
    archived_full_h: f32,
};

// Single-pass accumulation for viewport bounds, disclosure reveal heights,
// and Zen footer archived count without rescanning `a.chats.items`.
fn measureList(
    c: *ui.Context,
    a: *const App,
    pins: []const []const u8,
    items: []const ChatItem,
    grouped: bool,
    by: Grouping,
    lk: *const RowLookup,
) ListStats {
    var height: f32 = 4;
    if (pins.len > 0) {
        height += 30;
        if (a.view.pinned_open) {
            height += 6;
            for (pins) |id| if (lk.findChat(a, id)) |ch| {
                height += rowHeight(a, ch) + 2;
            };
        }
        if (!grouped) height += 12;
    }
    var active: usize = 0;
    var archived: usize = 0;
    var regular_full_h: f32 = 0;
    var archived_full_h: f32 = 0;
    var keys: std.StringHashMapUnmanaged(bool) = .empty;
    for (a.chats.items, items) |ch, it| if (it.listed) {
        if (ch.archived) {
            if (archived < a.view.archived_limit) archived_full_h += it.row_h + 2;
            archived += 1;
        } else if (!it.pinned) {
            active += 1;
            regular_full_h += it.row_h + 2;
            if (grouped) {
                const key = it.group_key;
                const entry = keys.getOrPut(c.alloc(), key) catch continue;
                if (!entry.found_existing) {
                    const open = a.view.groupOpen(c.print("{s}:{s}", .{ by.prefix(), key }), true);
                    entry.value_ptr.* = open;
                    height += if (open) @as(f32, 46) else 44;
                }
                if (entry.value_ptr.*) height += it.row_h + 2;
            } else if (a.view.sessions_open) height += it.row_h + 2;
        }
    };
    const show_more_h: f32 = if (archived > a.view.archived_limit) (if (a.settings.get(.sidebar_compact)) @as(f32, 29) else 36) + 2 else 0;
    if (regular_full_h >= 2) regular_full_h -= 2;
    var archive_panel_h = archived_full_h;
    if (archive_panel_h >= 2) archive_panel_h -= 2;
    archive_panel_h += show_more_h;
    if (active == 0 and pins.len == 0) {
        height += 8 + c.text.lineHeight(.{ .size = 12 });
    } else if (!grouped and active > 0) height += 30 + (if (a.view.sessions_open) @as(f32, 2) else 0);
    const zen = a.settings.uiMode() == .zen;
    const arch_open = if (zen) a.view.zen_archived_open else a.view.archived_open;
    const inline_archived = !zen or arch_open;
    if (inline_archived and archived > 0 and a.settings.get(.sidebar_show_archived)) {
        height += 6 + 30;
        if (arch_open) {
            height += 2 + archived_full_h + show_more_h;
        }
    }
    return .{
        .total_height = height + 6,
        .active = active,
        .archived = archived,
        .regular_full_h = regular_full_h,
        .archived_full_h = archive_panel_h,
    };
}

/// Equal-work indexed Zen preparation pass for sidebar performance benchmarks.
pub fn zenIndexPass(a: *const App, gpa: std.mem.Allocator) struct { listed: usize, archived: usize, active_marks: usize } {
    const lk = RowLookup.init(gpa, a);
    const pins = visiblePinsWith(a, gpa, &lk);
    const items = prepareItems(gpa, a, pins, false, .{ .org = .in_one_list, .now = a.nowMs() }, &lk);
    var listed_n: usize = 0;
    var archived_n: usize = 0;
    var marks_n: usize = 0;
    const now = a.nowMs();
    for (a.chats.items, items) |ch, it| if (it.listed) {
        listed_n += 1;
        if (ch.archived) {
            archived_n += 1;
        } else if (marks_n < 32) {
            if (lk.markOf(a, ch, now) != .idle) marks_n += 1;
        }
    };
    return .{ .listed = listed_n, .archived = archived_n, .active_marks = marks_n };
}

fn lists(c: *ui.Context, a: *App, k: theme.Colors) usize {
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 8 }, .gap = 2 });
    defer ui.end(c);
    const scroll = c.stack.items[c.stack.items.len - 1];
    // Read the current offset on every rebuild: wheel input can change it
    // between builds before layout. A window-height bound also covers the
    // first layout and a resize without relying on stale viewport rectangles.
    const offset = c.scroll.get(c.node(scroll).id) orelse 0;
    const overscan: f32 = if (a.view.sidebar_tween != null) 0 else 128;
    var window: Window = .{ .top = @max(0, offset - overscan), .bottom = offset + c.size.h + overscan, .y = 4 };
    const drag = @import("view_drag.zig");
    const moving = drag.moving(a);
    window.eager = moving != null;
    const target = drag.sidebarTarget(a);
    const gpa = c.alloc();
    const lk = RowLookup.init(gpa, a);
    const pins = visiblePinsWith(a, gpa, &lk);
    const by = Grouping.of(a);
    const grouped = by.org != .in_one_list;
    const items = prepareItems(gpa, a, pins, grouped, by, &lk);
    const stats = measureList(c, a, pins, items, grouped, by, &lk);
    a.view.cached_archived_count = stats.archived;
    if (!window.eager) {
        const bounded = @min(offset, @max(0, stats.total_height - c.size.h));
        window.top = @max(0, bounded - overscan);
        window.bottom = bounded + c.size.h + overscan;
    }
    const source_pin = if (moving) |id| pinned(pins, id) else null;
    const active = stats.active;
    const archived = stats.archived;
    const regular_full_h = stats.regular_full_h;
    const archived_full_h = stats.archived_full_h;
    // Pinned, while there are pins or a session is being dragged.
    if (pins.len > 0 or moving != null) {
        a.view.pin_header = rectOf(c, sectionAt(c, k, "Pinned", pins.len, &a.view.pinned_open));
        const pin_disc = trackDisclosure(c, a, "pinned", a.view.pinned_open);
        window.y += 30;
        if (pin_disc.visible(a.view.pinned_open)) {
            window.y += 2;
            var pin_full_h: f32 = 6;
            for (pins) |pid| if (lk.findChat(a, pid)) |pch| {
                pin_full_h += rowHeight(a, pch) + 2;
            };
            if (pins.len > 0 and pin_full_h >= 2) pin_full_h -= 2;
            const animating = pin_disc.animating and moving == null;
            const clip_box = if (animating)
                ui.div(c).column().wFull().h(pin_full_h * pin_disc.reveal).clip().opacity(@import("motion_rules.zig").disclosureOpacity(pin_disc.reveal))
            else
                null;
            defer if (clip_box) |cb| cb.end();
            var rows: Rows = .{};
            var body = ui.div(c).column().wFull().pt(2).pb(4).gap(2);
            if (animating) body = body.offset(0, -3 * (1 - pin_disc.reveal));
            defer body.end();
            a.view.pin_rows = if (a.view.pinned_open) rectOf(c, body) else null;
            const gap_at: ?usize = if (target) |t| switch (t) {
                .pinned => |i| if (source_pin == null) i else null,
                .regular => null,
            } else null;
            for (pins, 0..) |id, ix| {
                const ch = lk.findChat(a, id) orelse continue;
                // Rows give way: toward the held row's place among them, or
                // apart for one coming from Sessions.
                var dy: f32 = 0;
                if (source_pin) |from| {
                    if (target) |t| if (t == .pinned) {
                        dy = @as(f32, @floatFromInt(@import("pins.zig").slideOffset(ix, from, @min(t.pinned, pins.len - 1)))) * row_slot;
                    };
                    if (target != null and target.? == .regular and ix > from) dy = -row_slot;
                } else if (gap_at) |g| {
                    if (ix >= g) dy = row_slot;
                }
                const held = source_pin != null and source_pin.? == ix;
                if (rows.include(c, &window, rowHeight(a, ch))) slotRow(c, a, k, ch, dy, held, &lk);
            }
            rows.flush(c);
            window.y += 4;
            // Room for the row coming in.
            if (gap_at != null) _ = c.leaf(.{ .height = .{ .px = row_slot - 2 } }, .none, null);
            if (pins.len == 0 and gap_at == null) _ = c.leaf(.{ .height = .{ .px = 0 } }, .none, null);
        } else a.view.pin_rows = null;
        // Groups bring their own 12 above them.
        if (!grouped) {
            _ = c.leaf(.{ .height = .{ .px = 12 - 2 } }, .none, null);
            window.y += 12;
        }
    } else {
        a.view.pin_header = null;
        a.view.pin_rows = null;
    }
    if (grouped) {
        // Grouped or not, an empty list says so.
        if (active == 0 and pins.len == 0 and moving == null) {
            a.view.sessions_header = null;
            a.view.session_rows = null;
            const empty = ui.div(c).row().px(8).pb(8);
            defer empty.end();
            ui.text(c, "No sessions yet", .{ .size = 12, .line_height = empty_line, .color = k.faint });
            window.y += 8 + empty_line;
        } else groups(c, a, k, items, by, moving, &window, &lk);
    } else regular: {
        // GPUI has no Sessions disclosure when the regular list is empty.
        // A drag still needs that section as its drop target.
        if (active == 0 and moving == null) {
            a.view.sessions_header = null;
            a.view.session_rows = null;
            if (pins.len == 0) {
                const empty = ui.div(c).row().px(8).pb(8);
                defer empty.end();
                ui.text(c, "No sessions yet", .{ .size = 12, .line_height = empty_line, .color = k.faint });
                window.y += 8 + empty_line;
            }
            break :regular;
        }
        const sess_title = if (a.settings.uiMode() == .zen) "Activity" else "Sessions";
        a.view.sessions_header = rectOf(c, sectionAt(c, k, sess_title, active, &a.view.sessions_open));
        const sess_disc = trackDisclosure(c, a, "sessions", a.view.sessions_open);
        window.y += 30;
        if (!sess_disc.visible(a.view.sessions_open)) {
            a.view.session_rows = null;
            break :regular;
        }
        // SIDEBAR_DISCLOSURE_BODY_INSET: 4 under the header, the list's 2 twice.
        _ = c.leaf(.{ .height = .{ .px = 0 } }, .none, null);
        const animating = sess_disc.animating and moving == null;
        const clip_box = if (animating)
            ui.div(c).column().wFull().h(regular_full_h * sess_disc.reveal).clip().opacity(@import("motion_rules.zig").disclosureOpacity(sess_disc.reveal))
        else
            null;
        defer if (clip_box) |cb| cb.end();
        var body = ui.div(c).column().wFull().gap(2);
        if (animating) body = body.offset(0, -3 * (1 - sess_disc.reveal));
        defer body.end();
        a.view.session_rows = if (a.view.sessions_open) rectOf(c, body) else null;
        window.y += 2;
        var rows: Rows = .{};
        const unpinning = source_pin != null and target != null and target.? == .regular;
        for (a.chats.items, items) |ch, it| if (it.listed and !ch.archived and !it.pinned) {
            const held = moving != null and std.mem.eql(u8, moving.?, ch.id);
            // Dragged to the pins, a session's row leaves the list.
            if (held and target != null and target.? == .pinned) continue;
            if (rows.include(c, &window, it.row_h)) slotRow(c, a, k, ch, 0, held, &lk);
        };
        rows.flush(c);
        // An empty body still has its outer gap.
        if (active == 0) window.y += if (pins.len == 0) 12 + c.text.lineHeight(.{ .size = 12 }) + 2 else @as(f32, 2);
        if (unpinning) _ = c.leaf(.{ .height = .{ .px = row_slot - 2 } }, .none, null);
        if (active == 0 and moving != null) {
            // While a session is dragged, an empty list takes it back.
            const e = ui.div(c).row().wFull().h(48).px(10).itemsCenter();
            defer e.end();
            ui.text(c, "Drop here to unpin", .{ .size = 12, .line_height = 12 * 1.618, .color = k.muted });
        } else if (active == 0 and pins.len == 0) {
            const e = ui.div(c).row().px(8).py(6);
            defer e.end();
            ui.text(c, "No sessions yet", .{ .size = 12, .line_height = empty_line, .color = k.faint });
        }
    }
    // Show › Archived off, or Zen keeps Archived pinned to the bottom until opened.
    const zen = a.settings.uiMode() == .zen;
    const arch_flag = if (zen) &a.view.zen_archived_open else &a.view.archived_open;
    if (archived == 0 or !a.settings.get(.sidebar_show_archived) or (zen and !arch_flag.*)) return archived;
    // 6 under the list above: its 4, and the gap.
    _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
    window.y += 6 + 30;
    _ = section(c, k, "Archived", archived, arch_flag);
    const arch_disc = trackDisclosure(c, a, "archived", arch_flag.*);
    if (arch_disc.visible(arch_flag.*)) {
        // SIDEBAR_DISCLOSURE_BODY_INSET: 4 under the header, the list's 2 twice.
        _ = c.leaf(.{ .height = .{ .px = 0 } }, .none, null);
        const animating = arch_disc.animating and moving == null;
        const clip_box = if (animating)
            ui.div(c).column().wFull().h(archived_full_h * arch_disc.reveal).clip().opacity(@import("motion_rules.zig").disclosureOpacity(arch_disc.reveal))
        else
            null;
        defer if (clip_box) |cb| cb.end();
        const body = if (animating)
            ui.div(c).column().wFull().gap(2).offset(0, -3 * (1 - arch_disc.reveal))
        else
            null;
        defer if (body) |b| b.end();
        window.y += 2;
        var rows: Rows = .{};
        var shown: usize = 0;
        for (a.chats.items, items) |ch, it| if (it.listed and ch.archived) {
            if (shown == a.view.archived_limit) break;
            if (rows.include(c, &window, it.row_h)) sessionRowWith(c, a, k, ch, &lk);
            shown += 1;
        };
        rows.flush(c);
        if (archived > shown) {
            // A row's height (36, or a compact row's 29), 2 under the last
            // row; 25 more at a time.
            const more = ui.div(c).row().wFull().h(if (a.settings.get(.sidebar_compact)) 29 else 36).px(8).gap(10).itemsCenter().rounded(6).hover(k.hover);
            defer more.end();
            if (more.clicked()) a.view.archived_limit += 25;
            const color = if (more.hovered()) k.text else k.muted.alpha(0.55);
            icons.icon(c, .plus, 14, color, 0);
            ui.text(c, c.print("Show {d} more", .{@min(archived - shown, 25)}), .{ .size = 13, .line_height = 13 * 1.618, .color = color });
        }
    }
    return archived;
}

/// By status, by project or by device (`sidebar_organization`): a
/// disclosure for each, in the order their newest sessions come; this
/// device's first, and "Needs you" above "Today" above "Earlier".
fn groups(c: *ui.Context, a: *App, k: theme.Colors, items: []const ChatItem, by: Grouping, moving: ?[]const u8, window: *Window, lk: *const RowLookup) void {
    const by_project = by.org == .by_project;
    const gpa = c.alloc();
    var index = @import("sidebar_groups.zig").Index.build(gpa, a.chats.items, items) catch return;
    index.order(by.org, a.device_id);
    a.view.sessions_header = null;
    a.view.session_rows = null;
    var omitted: Rows = .{};
    for (index.groups.items) |group| {
        const key = group.key;
        const count = group.count;
        const height = group.height;
        const collapse = c.print("{s}:{s}", .{ by.prefix(), key });
        var open = a.view.groupOpen(collapse, true);
        const extent: f32 = 14 + 28 + (if (open) 4 + @max(0, height - 2) else @as(f32, 0));
        const start = window.y;
        if (!omitted.include(c, window, extent)) continue;
        ui.key(c, c.print("group-{s}", .{key}));
        // Keep the existing group/body hierarchy and ID-based keys.
        const box = ui.div(c).column().wFull().pt(14);
        defer box.end();
        const label = if (std.mem.eql(u8, key, "needs"))
            "Needs you"
        else if (by.org == .by_status)
            workspace.StatusGroup.fromKey(key).?.label()
        else if (by_project)
            (if (std.mem.startsWith(u8, key, "home:")) "~" else if (lk.findSpace(a, key)) |sp| sp.name else "?")
        else
            a.deviceName(key);
        {
            const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter();
            defer h.end();
            const color = if (k.is_harp) k.muted else k.muted.alpha(0.5);
            ui.text(c, if (open) label else c.print("{s} ({d})", .{ label, count }), .{ .size = 11.5, .weight = theme.ui_medium_weight, .color = color });
            ui.spacer(c);
            icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 12, color, 0);
            var create = false;
            if (by_project and !std.mem.startsWith(u8, key, "home:") and !std.mem.eql(u8, key, "needs")) {
                ui.key(c, "project-group-new-session");
                const add = tip.on(ui.div(c).size(20, 20).center().rounded(4).hover(k.hover), k, .{ .text = "New session in this project" });
                defer add.end();
                if (h.hovered()) icons.icon(c, .plus, 13, k.muted, 0);
                create = add.clicked();
            }
            if (create) {
                a.newWorkspaceSession();
                a.select(null, key);
                a.new_no_project = false;
            } else if (h.clicked()) {
                a.view.toggleGroup(a.gpa, collapse, true);
                open = a.view.groupOpen(collapse, true);
            }
        }
        const grp_disc = trackDisclosure(c, a, collapse, open);
        if (!grp_disc.visible(open)) continue;
        const full_grp_h = 4 + @max(0, height - 2);
        const grp_anim = grp_disc.animating and moving == null;
        const clip_box = if (grp_anim)
            ui.div(c).column().wFull().h(full_grp_h * grp_disc.reveal).clip().opacity(@import("motion_rules.zig").disclosureOpacity(grp_disc.reveal))
        else
            null;
        defer if (clip_box) |cb| cb.end();
        var body = ui.div(c).column().wFull().pt(4).gap(2);
        if (grp_anim) body = body.offset(0, -3 * (1 - grp_disc.reveal));
        defer body.end();
        var inside = window.*;
        inside.y = start + 14 + 28 + 4;
        var rows: Rows = .{};
        var member: ?usize = group.first;
        while (member) |i| : (member = index.next[i]) {
            const ch = a.chats.items[i];
            const held = moving != null and std.mem.eql(u8, moving.?, ch.id);
            if (rows.include(c, &inside, items[i].row_h)) slotRow(c, a, k, ch, 0, held, lk);
        }
        rows.flush(c);
    }
    omitted.flush(c);
}

/// Active sessions in the exact order the sidebar renders them (Pinned, then
/// grouped or regular non-archived sessions). Used by Jump to session 1..9
/// and Next/Previous session when fewer than two tabs are open.
pub fn visibleSessionIds(c: *ui.Context, a: *App) []const []const u8 {
    const gpa = c.alloc();
    var out: std.ArrayList([]const u8) = .empty;
    const lk = RowLookup.init(gpa, a);
    const pins = visiblePinsWith(a, gpa, &lk);
    const by = Grouping.of(a);
    const grouped = by.org != .in_one_list;
    const items = prepareItems(gpa, a, pins, grouped, by, &lk);
    if (pins.len > 0 and a.view.pinned_open) {
        for (pins) |id| {
            if (lk.findChat(a, id) != null) out.append(gpa, id) catch {};
        }
    }
    if (grouped) {
        var index = @import("sidebar_groups.zig").Index.build(gpa, a.chats.items, items) catch return out.items;
        index.order(by.org, a.device_id);
        for (index.groups.items) |group| {
            const collapse = c.print("{s}:{s}", .{ by.prefix(), group.key });
            if (!a.view.groupOpen(collapse, true)) continue;
            var member: ?usize = group.first;
            while (member) |i| : (member = index.next[i]) out.append(gpa, a.chats.items[i].id) catch {};
        }
    } else if (a.view.sessions_open) {
        for (a.chats.items, items) |ch, it| if (it.listed and !ch.archived and !it.pinned) {
            out.append(gpa, ch.id) catch {};
        };
    }
    return out.items;
}

/// How the lists group this frame: the organization, and for "By status"
/// the clock and the local zone it reads "Today" by.
const Grouping = struct {
    org: @import("settings.zig").Organization,
    now: i64 = 0,
    offset: i64 = 0,

    fn of(a: *App) Grouping {
        const profile = a.settings.hierarchyProfile();
        const org = if (profile.flat_session_list) .in_one_list else a.settings.organization();
        const now = a.nowMs();
        if (org != .by_status) return .{ .org = org, .now = now };
        return .{ .org = org, .now = now, .offset = workspace.utcOffsetSeconds(now) };
    }

    /// The collapse key's prefix, as GPUI saves it.
    fn prefix(g: Grouping) []const u8 {
        return switch (g.org) {
            .by_status => "status",
            .by_project => "project",
            .by_device => "device",
            .in_one_list => "list",
        };
    }
};

/// A session's group: its status section, its project (or its device's
/// home), or its device.
fn groupKey(c: *ui.Context, a: *App, ch: workspace.Chat, by: Grouping) []const u8 {
    const mark = workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), by.now);
    if (mark == .awaiting_input or mark == .errored) return "needs";
    return switch (by.org) {
        .by_status => workspace.statusGroup(workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), by.now), ch.timeMs(), by.now, by.offset).key(),
        .by_project => ch.space_id orelse c.print("home:{s}", .{ch.device_id orelse ""}),
        else => ch.device_id orelse "",
    };
}

/// A row, moved `dy` while rows give way; the held one keeps its place
/// empty, drawn instead under the pointer.
fn slotRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, dy: f32, held: bool, lk: ?*const RowLookup) void {
    ui.key(c, c.print("slot-{s}", .{ch.id}));
    var w = ui.div(c).column().wFull().offset(0, dy);
    if (held) w = w.opacity(0);
    defer w.end();
    sessionRowWith(c, a, k, ch, lk);
}

fn rectOf(c: *ui.Context, d: ui.Div) ?ui.Rect {
    return c.rects.get(c.node(d.index).id);
}

const disclosure_duration: f64 = 0.18;

const DisclosureState = struct {
    reveal: f32,
    animating: bool,

    fn visible(d: DisclosureState, open: bool) bool {
        return open or d.reveal > 0.005;
    }
};

fn trackDisclosure(c: *ui.Context, a: *App, key: []const u8, open: bool) DisclosureState {
    const target: f32 = if (open) 1 else 0;
    if (a.view.disclosures.getPtr(key)) |tw| {
        if (@abs(tw.to - target) > 0.001) {
            const cur = tw.sample(c.time, c.reduced_motion);
            tw.* = .{ .from = cur, .to = target, .start = c.time, .duration = disclosure_duration };
        }
        const anim = tw.animating(c.time, c.reduced_motion);
        if (anim) c.animationFrame();
        return .{ .reveal = tw.sample(c.time, c.reduced_motion), .animating = anim };
    }
    if (a.gpa.dupe(u8, key)) |owned| {
        a.view.disclosures.put(a.gpa, owned, .{
            .from = target,
            .to = target,
            .start = c.time - 1.0,
            .duration = disclosure_duration,
        }) catch a.gpa.free(owned);
    } else |_| {}
    return .{ .reveal = target, .animating = false };
}

/// `section` that hands back its header, for its place as a drop target.
fn sectionAt(c: *ui.Context, k: theme.Colors, label: []const u8, count: usize, open: *bool) ui.Div {
    ui.key(c, label);
    const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(8).hover(k.hover.alpha(0.35));
    if (h.clicked()) open.* = !open.*;
    const color = if (k.is_harp) k.muted else k.muted.alpha(0.55);
    ui.text(c, if (open.*) label else c.print("{s} ({d})", .{ label, count }), .{ .size = 11.5, .weight = theme.ui_medium_weight, .color = color });
    ui.spacer(c);
    icons.icon(c, if (open.*) .@"alt-arrow-down" else .@"alt-arrow-right", 12, color, 0);
    h.end();
    return h;
}

/// A disclosure header ("Sessions", "Archived (12)" when shut); true while open.
fn section(c: *ui.Context, k: theme.Colors, label: []const u8, count: usize, open: *bool) bool {
    ui.key(c, label);
    const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(8).hover(k.hover.alpha(0.35));
    defer h.end();
    if (h.clicked()) open.* = !open.*;
    const color = if (k.is_harp) k.muted else k.muted.alpha(0.55);
    ui.text(c, if (open.*) label else c.print("{s} ({d})", .{ label, count }), .{ .size = 11.5, .weight = theme.ui_medium_weight, .color = color });
    ui.spacer(c);
    icons.icon(c, if (open.*) .@"alt-arrow-down" else .@"alt-arrow-right", 12, color, 0);
    return open.*;
}

/// What the ⋯ menu's Show and Compact ask of every row.
const Look = struct {
    compact: bool,
    harness: bool,
    icon: bool,
    label: bool,
    branch: bool,

    fn of(a: *const App) Look {
        const s = &a.settings;
        const tech = s.hierarchyProfile().shows_row_tech_badges;
        return .{
            .compact = s.get(.sidebar_compact),
            .harness = s.get(.sidebar_show_harness),
            .icon = s.get(.sidebar_show_project_icon),
            .label = tech and s.get(.sidebar_show_project_label),
            .branch = tech and s.get(.sidebar_show_branch),
        };
    }

    /// The marks before a compact row's title, and their gaps.
    fn marksW(l: Look) f32 {
        return 13 + 4 + (if (l.harness) @as(f32, 17) else 0) + (if (l.icon) @as(f32, 17) else 0);
    }
};

/// Desktop reserves a38px slot when context is enabled, even though its
/// compact renderer keeps the marks, title and timestamp on one line.
pub fn rowHeight(a: *const App, ch: workspace.Chat) f32 {
    if (a.settings.uiMode() == .zen) return 30;
    const l = Look.of(a);
    return contextHeight(l.label, l.branch and ch.branch != null, a.settings.get(.sidebar_show_updated), l.harness or l.icon);
}

pub fn contextHeight(project: bool, branch: bool, updated: bool, identity: bool) f32 {
    return if (project or branch or updated or identity) 38 else 30;
}

pub fn rowPreview(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat) void {
    const l = Look.of(a);
    if (!l.compact) {
        const r = ui.div(c).column().wFull().h(rowHeight(a, ch)).px(8).py(6).gap(2);
        defer r.end();
        return expandedLines(c, a, k, ch, l, false, false);
    }
    const r = ui.div(c).row().wFull().h(rowHeight(a, ch)).px(8).pt(6).pb(5).gap(4).itemsCenter();
    defer r.end();
    const now = a.nowMs();
    statusSlot(c, k, rowMark(a, ch));
    marks(c, a, k, ch, l, false);
    const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
    const title_w = widthOf(a) - 16 - 16 - l.marksW() - 4 - 6 - c.text.width(time, .{ .size = 11 });
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = k.text.alpha(0.8) }), title_w);
    }
    const tm = ui.div(c).row().pl(6);
    defer tm.end();
    ui.text(c, time, .{ .size = 11, .color = k.subline });
}

/// The harness's mark and the project's monogram, as Show has them.
fn marks(c: *ui.Context, a: *const App, k: theme.Colors, ch: workspace.Chat, l: Look, lit: bool) void {
    marksWith(c, a, k, ch, l, lit, a.findSpace(ch.space_id));
}

fn marksWith(c: *ui.Context, a: *const App, k: theme.Colors, ch: workspace.Chat, l: Look, lit: bool, space: ?workspace.Space) void {
    const muted = ch.archived and !lit;
    if (l.harness) {
        const mark = icons.harnessMark(ch.harness orelse "graff");
        icons.icon(c, mark.name, 13, (mark.brand orelse k.subline).alpha(if (muted) 0.4 else 0.8), 13);
    }
    if (l.icon) {
        // `project_icon_frame`: the project and its device on hover.
        const b = tip.project(c, ui.div(c).row().opacity(if (muted) 0.4 else 1), k, if (space) |sp| sp.name else "Home", a.deviceName(ch.device_id));
        defer b.end();
        badgeWith(c, k, space, lit);
    }
}

/// On another device: the compact row's corner says so.
fn remote(a: *const App, ch: workspace.Chat) bool {
    const mine = a.device_id orelse return false;
    const dev = ch.device_id orelse return false;
    return !std.mem.eql(u8, mine, dev);
}

/// "project @ device" (`sidebar_chat_data`): "~" for no project, and no
/// device when it isn't known.
fn folderLabelWith(c: *ui.Context, a: *const App, ch: workspace.Chat, space: ?workspace.Space) []const u8 {
    const project = if (space) |s| s.name else if (ch.space_id == null) "~" else "?";
    const dev = ch.device_id orelse return project;
    if (a.device_id) |local| if (std.mem.eql(u8, local, dev)) return project;
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, dev)) return c.print("{s} @ {s}", .{ project, d.name });
    return project;
}

/// The expanded row's lines: "project @ device" with the status or time,
/// the marks and title, then the branch.
fn expandedLines(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, l: Look, lit: bool, hovered: bool) void {
    expandedLinesWith(c, a, k, ch, l, lit, hovered, rowMark(a, ch), a.findSpace(ch.space_id));
}

fn expandedLinesWith(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, l: Look, lit: bool, hovered: bool, mark_state: workspace.Mark, space: ?workspace.Space) void {
    const inner = widthOf(a) - 16 - 16;
    const subline = k.subline;
    var archive = false;
    if (l.label) {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        const corner_w = cornerWidthWith(c, a, ch, hovered, mark_state);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, folderLabelWith(c, a, ch, space), .{ .size = 11, .line_height = 14, .color = subline }, inner - 8 - corner_w);
        }
        archive = cornerWith(c, a, k, ch, hovered, k.subline, mark_state);
    }
    {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        marksWith(c, a, k, ch, l, lit, space);
        const marks_w = (if (l.harness) @as(f32, 21) else 0) + (if (l.icon) @as(f32, 21) else 0);
        const corner_w = if (l.label) 0 else cornerWidthWith(c, a, ch, hovered, mark_state) + 8;
        const tc = if (lit) k.text else if (ch.archived) k.text.alpha(0.55) else k.text.alpha(0.8);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = tc }), inner - marks_w - corner_w);
        }
        if (!l.label) archive = cornerWith(c, a, k, ch, hovered, k.subline, mark_state);
    }
    if (l.branch) if (ch.branch) |b| {
        const line = ui.div(c).row().wFull().gap(4).itemsCenter();
        defer line.end();
        icons.icon(c, .@"git-branch", 11, subline, 0);
        kit.fadeText(c, b, .{ .size = 11, .line_height = 14, .color = subline }, inner - 15);
    };
    if (archive) a.setArchived(ch.id, !ch.archived);
}

fn cornerWidth(c: *ui.Context, a: *const App, ch: workspace.Chat, hovered: bool) f32 {
    return cornerWidthWith(c, a, ch, hovered, rowMark(a, ch));
}

fn cornerWidthWith(c: *ui.Context, a: *const App, ch: workspace.Chat, hovered: bool, mark_state: workspace.Mark) f32 {
    const st: ui.TextStyle = .{ .size = 10, .weight = theme.ui_medium_weight };
    if (hovered) return 4 + 11 + 4 + c.text.width(if (ch.archived) "Unarchive" else "Archive", st);
    const word = statusWord(mark_state);
    if (word) |w| return 6 + 4 + c.text.width(w, st);
    return c.text.width(rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, a.nowMs(), ch.timeMs()), st);
}

/// A transcript-owned question remains visible after the live session's
/// 45-second status expires, including while a different pane is active.
pub fn rowMark(a: *const App, ch: workspace.Chat) workspace.Mark {
    if (@import("app_question.zig").needsInput(a, ch.id)) return .awaiting_input;
    return workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), a.nowMs());
}

fn statusWord(mark: workspace.Mark) ?[]const u8 {
    return switch (mark) {
        .working => "Working",
        .awaiting_input => "Input",
        .errored => "Failed",
        .completed => "Done",
        .idle => null,
    };
}

/// The expanded row's corner: its status in words, or how long ago;
/// Archive under the pointer (true when clicked).
fn corner(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, hovered: bool) bool {
    return cornerIn(c, a, k, ch, hovered, k.subline);
}

/// `corner` with the time in `subline`: a search result's is the muted
/// text itself, the sidebar's half of it.
fn cornerIn(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, hovered: bool, subline: ui.Color) bool {
    return cornerWith(c, a, k, ch, hovered, subline, rowMark(a, ch));
}

fn cornerWith(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, hovered: bool, subline: ui.Color, mark: workspace.Mark) bool {
    const box = ui.div(c).row().h(14).itemsCenter();
    defer box.end();
    if (hovered) {
        const b = ui.div(c).row().h(18).px(4).gap(4).itemsCenter().rounded(5).bg(k.wash(0.10)).hover(k.wash(0.18)).offset(4, 0);
        defer b.end();
        icons.icon(c, if (ch.archived) .@"archive-up-minimalistic" else .@"archive-minimalistic", 11, k.muted, 0);
        ui.text(c, if (ch.archived) "Unarchive" else "Archive", .{ .size = 10, .color = k.muted });
        return b.clicked();
    }
    if (statusWord(mark)) |word| {
        const color = switch (mark) {
            .completed => k.success.alpha(0.9),
            .awaiting_input => k.accent,
            .errored => k.danger,
            else => k.muted,
        };
        const g = ui.div(c).row().gap(4).itemsCenter();
        defer g.end();
        switch (mark) {
            .working => kit.snake(c, k),
            .completed => icons.icon(c, .check, 11, color, 0),
            else => kit.dot(c, 6, color),
        }
        ui.text(c, word, .{ .size = 10, .weight = theme.ui_medium_weight, .color = color });
        return false;
    }
    ui.text(c, rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, a.nowMs(), ch.timeMs()), .{ .size = 10, .weight = theme.ui_medium_weight, .color = subline });
    return false;
}

/// A session as a search shows it (`render_chat_row` with `search_query`):
/// never compact, "project @ device" over the agent's mark and the title,
/// both with the query's words washed, everything at full strength, 10
/// round; the branch (and the pull request's badge) on a third line when
/// given. `inner` is the room inside its 8-point sides. What the pointer
/// did to it comes back.
pub const SearchRow = struct {
    folder: []const u8,
    lit: bool,
    query: []const u8,
    inner: f32,
    branch: ?[]const u8 = null,
    pr: ?struct { @import("change_requests.zig").Summary, @import("change_requests.zig").Provenance } = null,
    /// The sidebar search follows the lists' compact setting; the command
    /// palette always shows the two-line row.
    follow_compact: bool = false,
};

pub const SearchHit = struct { clicked: bool = false, pressed: bool = false };

pub fn searchRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, o: SearchRow) SearchHit {
    // The sidebar's own row (`render_chat_row`): compact, a result is one
    // line like the lists', its title lit where it matches.
    if (o.follow_compact and a.settings.get(.sidebar_compact)) return compactSearchRow(c, a, k, ch, o);
    const meta: f32 = if (o.pr != null) 16 else if (o.branch != null) 14 else 0;
    const h: f32 = if (meta == 0) 45 else 47 + meta;
    var r = ui.div(c).column().wFull().h(h).px(8).py(6).gap(2).rounded(10).clip();
    r = if (o.lit) r.bg(k.selected) else r.hover(k.hover);
    defer r.end();
    const hovered = r.hovered() and !@import("view_drag.zig").dragging(a);
    const subline = k.muted;
    var archive = false;
    {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        const corner_w = cornerWidth(c, a, ch, hovered);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.highlightText(c, k, o.folder, .{ .size = 11, .line_height = 14, .color = subline }, o.inner - 8 - corner_w, o.query);
        }
        archive = cornerIn(c, a, k, ch, hovered, subline);
    }
    {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        var marks_w: f32 = 0;
        if (a.settings.get(.sidebar_show_harness)) {
            const mark = icons.harnessMark(ch.harness orelse "graff");
            icons.icon(c, mark.name, 13, (mark.brand orelse subline).alpha(0.8), 13);
            marks_w = 13 + 8;
        }
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.highlightText(c, k, if (ch.title) |x| firstLine(x) else "New session", kit.style(c, 13, 17, .{ .color = k.text }), o.inner - marks_w, o.query);
    }
    if (meta > 0) {
        const line = ui.div(c).row().wFull().gap(4).itemsCenter();
        defer line.end();
        var room = o.inner;
        if (o.pr) |pr| room -= c.text.width(@import("change_requests.zig").model(c.alloc(), pr[0]).number, .{ .size = 10, .weight = .medium, .mono = true }) + 8 + 4;
        if (o.branch) |b| {
            icons.icon(c, .@"git-branch", 11, subline, 0);
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.highlightText(c, k, b, .{ .size = 11, .line_height = 14, .color = subline }, room - 15, o.query);
        } else ui.spacer(c);
        if (o.pr) |pr| @import("view_change_requests.zig").badgeQuery(c, k, pr[0], pr[1], .sidebar, true, o.query);
    }
    if (archive) {
        a.setArchived(ch.id, !ch.archived);
        return .{};
    }
    const it = r.interaction();
    return .{ .clicked = r.clicked(), .pressed = it.pressed and c.input.pressed };
}

/// A compact result: the status, the marks, the title with the query lit,
/// and how long ago (the archive control and menu under the pointer).
fn compactSearchRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, o: SearchRow) SearchHit {
    const l = Look.of(a);
    var r = ui.div(c).row().wFull().h(rowHeight(a, ch)).px(8).pt(6).pb(5).gap(4).itemsCenter().rounded(8).clip();
    r = if (o.lit) r.bg(k.selected) else r.hover(k.hover);
    defer r.end();
    const hovered = r.hovered() and !@import("view_drag.zig").dragging(a);
    const now = a.nowMs();
    statusSlot(c, k, rowMark(a, ch));
    marks(c, a, k, ch, l, o.lit or hovered);
    const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
    const time_w = if (hovered) 18 else c.text.width(time, .{ .size = 11 });
    const far = remote(a, ch);
    const title_w = o.inner - l.marksW() - 4 - 6 - time_w - (if (hovered or far) @as(f32, 22) else 0);
    const tc = if (o.lit or hovered) k.text else if (ch.archived) k.text.alpha(0.55) else k.text.alpha(0.8);
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.highlightText(c, k, chatLabel(ch), kit.style(c, 13, 17, .{ .color = tc }), @max(24, title_w), o.query);
    }
    var archive = false;
    if (hovered) {
        const b = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
        defer b.end();
        if (b.clicked()) archive = true;
        icons.icon(c, if (ch.archived) .@"archive-up-minimalistic" else .@"archive-minimalistic", 13, k.muted, 0);
    } else if (far) {
        const b = ui.div(c).row().size(18, 14).center();
        defer b.end();
        icons.icon(c, .@"remote-server", 13, k.muted.alpha(0.5), 0);
    }
    {
        const tm = ui.div(c).row().pl(6);
        defer tm.end();
        if (!hovered) ui.text(c, time, .{ .size = 11, .color = k.subline });
    }
    if (archive) {
        a.setArchived(ch.id, !ch.archived);
        return .{};
    }
    const it = r.interaction();
    return .{ .clicked = r.clicked(), .pressed = it.pressed and c.input.pressed };
}

/// The inline note (`sidebar-notice`): danger-edged, a click dismisses it;
/// a timed one goes on its own.
fn notice(c: *ui.Context, a: *App, k: theme.Colors) void {
    const v = &a.view;
    if (v.sidebar_notice_len == 0) return;
    if (v.sidebar_notice_until) |t| {
        if (c.time >= t) {
            v.sidebar_notice_len = 0;
            v.sidebar_notice_until = null;
            return;
        }
        c.frameIn(@floatCast(t - c.time));
    }
    const box = ui.div(c).column().wFull().px(8).pb(8);
    defer box.end();
    ui.key(c, "sidebar-notice");
    const s = ui.div(c).column().wFull().px(8).py(4).rounded(6).border(k.danger).borderW(1);
    defer s.end();
    const w = ui.div(c).column().w(widthOf(a) - 16 - 16 - 2);
    defer w.end();
    ui.text(c, v.sidebar_notice[0..v.sidebar_notice_len], .{ .size = 11, .wrap = true, .color = k.danger });
    if (s.clicked()) {
        v.sidebar_notice_len = 0;
        v.sidebar_notice_until = null;
    }
}

fn sessionRowWith(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, lk: ?*const RowLookup) void {
    ui.key(c, c.print("row-{s}", .{ch.id}));
    const zen = a.settings.uiMode() == .zen;
    const selected = a.selected != null and std.mem.eql(u8, a.selected.?, ch.id);
    const l = Look.of(a);
    // 6 above an 18-point line, as `render_chat_row`'s `py(6)` column.
    var r = ui.div(c).column().wFull().h(rowHeight(a, ch)).px(8).py(if (zen) @as(f32, 5) else 6).gap(2).rounded(if (zen) @as(f32, 7) else 8).clip();
    // Hovered as GPUI's row is (its `hover_listener`): by the pointer's
    // moves, so its menu opening under a still pointer leaves it hovered.
    const now = a.nowMs();
    const mark_state = if (lk) |lkp| lkp.markOf(a, ch, now) else rowMark(a, ch);
    const sp = if (lk) |lkp| lkp.findSpace(a, ch.space_id) else a.findSpace(ch.space_id);
    const waiting = mark_state == .awaiting_input;
    if (waiting) r = r.border(k.accent.alpha(0.5)).borderW(1).bg(k.accent.alpha(0.08));
    const lh = kit.listenerHover(&a.view.hovers, if (selected) r.bg(k.selected) else r, if (selected) k.selected else if (waiting) k.accent.alpha(0.13) else k.hover);
    r = lh.div;
    defer r.end();
    // No hover while a session is dragged over the rows.
    const hovered = lh.hovered and !@import("view_drag.zig").dragging(a);
    var archive = false;
    var menu = false;
    if (zen) {
        const line = ui.div(c).row().wFull().h(20).gap(6).itemsCenter();
        defer line.end();
        {
            const lead = ui.div(c).row().size(14, 14).center();
            defer lead.end();
            switch (mark_state) {
                .working => kit.snake(c, k),
                .awaiting_input => kit.dot(c, 7, k.accent),
                .errored => kit.dot(c, 7, k.danger),
                else => {
                    const hm = icons.harnessMark(ch.harness orelse "graff");
                    icons.icon(c, hm.name, 13, (hm.brand orelse k.muted).alpha(if (ch.archived and !selected and !hovered) 0.45 else 0.88), 0);
                },
            }
        }
        zenMonogramWith(c, k, ch, sp, 16);
        const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
        const time_w = if (hovered) @as(f32, 40) else c.text.width(time, .{ .size = 11 }) + 4;
        const far = remote(a, ch);
        const title_w = @max(24, cardInnerW(a) - 8 - 16 - 16 - 14 - 16 - 12 - time_w - (if (!hovered and far) @as(f32, 18) else 0));
        const tc = if (selected or hovered) k.text else if (ch.archived) k.text.alpha(0.55) else k.text.alpha(0.84);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = tc }), title_w);
        }
        if (hovered) {
            const b = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
            defer b.end();
            if (b.clicked()) archive = true;
            icons.icon(c, if (ch.archived) .@"archive-up-minimalistic" else .@"archive-minimalistic", 13, k.muted, 0);
            const m = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
            defer m.end();
            if (m.clicked()) menu = true;
            icons.icon(c, .@"more-horizontal", 13, k.muted, 0);
        } else {
            if (far) {
                const b = ui.div(c).row().size(14, 14).center();
                defer b.end();
                icons.icon(c, .@"remote-server", 12, k.muted.alpha(0.5), 0);
            }
            const tm = ui.div(c).row().pl(4);
            defer tm.end();
            ui.text(c, time, .{ .size = 11, .color = k.subline });
        }
    } else if (!l.compact) {
        expandedLinesWith(c, a, k, ch, l, selected or hovered, hovered, mark_state, sp);
    } else {
        const line = ui.div(c).row().wFull().h(18).gap(4).itemsCenter();
        defer line.end();
        statusSlot(c, k, mark_state);
        marksWith(c, a, k, ch, l, selected or hovered, sp);
        // In the frame's memory: the text is drawn after this returns.
        const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
        const time_w = if (hovered) 18 else c.text.width(time, .{ .size = 11 });
        const far = remote(a, ch);
        const title_w = widthOf(a) - 16 - 16 - l.marksW() - 4 - 6 - time_w - (if (hovered or far) @as(f32, 22) else 0);
        const tc = if (selected or hovered) k.text else if (ch.archived) k.text.alpha(0.55) else k.text.alpha(0.8);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = tc }), title_w);
        }
        if (hovered) {
            // The archive control takes the remote slot while the pointer is here.
            const b = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
            defer b.end();
            if (b.clicked()) archive = true;
            icons.icon(c, if (ch.archived) .@"archive-up-minimalistic" else .@"archive-minimalistic", 13, k.muted, 0);
        } else if (far) {
            const b = ui.div(c).row().size(18, 14).center();
            defer b.end();
            icons.icon(c, .@"remote-server", 13, k.muted.alpha(0.5), 0);
        }
        {
            const tm = ui.div(c).row().pl(6);
            defer tm.end();
            if (hovered) {
                // The session menu (`{row}-menu`): opens where it's clicked.
                const m = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
                defer m.end();
                if (m.clicked()) menu = true;
                icons.icon(c, .@"more-horizontal", 13, k.muted, 0);
            } else {
                ui.text(c, time, .{ .size = 11, .color = k.subline });
            }
        }
    }
    // A right-click opens the same menu where it's clicked.
    if (kit.secondaryClicked(r)) menu = true;
    if (archive) return a.setArchived(ch.id, !ch.archived);
    if (menu) return @import("view_chat_menu.zig").open(a, ch.id, c.input.mouse);
    // Pressed, it may be dragged onto the chat to split it; a release that
    // ends a drag isn't a click.
    const drag = @import("view_drag.zig");
    const it = r.interaction();
    if (it.pressed and c.input.pressed) drag.press(c, a, ch.id, it.rect);
    if (r.clicked() and !drag.dragging(a)) {
        // A Bots page sits in the chat's place: its own row brings it back.
        if (selected) @import("bots.zig").close(a) else a.openChatInTab(ch.id);
    }
}

fn statusSlot(c: *ui.Context, k: theme.Colors, mark: workspace.Mark) void {
    const s = ui.div(c).row().size(13, 13).center();
    defer s.end();
    switch (mark) {
        .working => kit.snake(c, k),
        .completed => icons.icon(c, .check, 11, k.success.alpha(0.9), 0),
        .awaiting_input => kit.dot(c, 6, k.accent.alpha(0.6)),
        .errored => kit.dot(c, 6, k.danger.alpha(0.65)),
        .idle => kit.dot(c, 6, k.ink(0.14)),
    }
}

pub fn zenMonogram(c: *ui.Context, a: *const App, k: theme.Colors, ch: workspace.Chat, size: f32) void {
    zenMonogramWith(c, k, ch, a.findSpace(ch.space_id), size);
}

fn zenMonogramWith(c: *ui.Context, k: theme.Colors, ch: workspace.Chat, space: ?workspace.Space, size: f32) void {
    const seed = if (space) |s| s.name else chatLabel(ch);
    const path = if (space) |s| s.path else ch.cwd;
    const m = rules.monogram(seed, path, true);
    const bg = m.color.alpha(if (k.dark) 0.88 else 0.92);
    const tile = ui.div(c).row().size(size, size).center().rounded(4).bg(bg);
    defer tile.end();
    ui.text(c, c.print("{c}", .{m.letter}), .{
        .size = @max(8.5, size * 0.58),
        .line_height = size,
        .weight = .bold,
        .mono = true,
        .color = ui.Color.white,
    });
}

/// The project's monogram tile (`project_icon.rs`).
pub fn badge(c: *ui.Context, a: *const App, k: theme.Colors, space_id: ?[]const u8, lit: bool) void {
    badgeWith(c, k, a.findSpace(space_id), lit);
}

fn badgeWith(c: *ui.Context, k: theme.Colors, space: ?workspace.Space, lit: bool) void {
    const m = rules.monogram(if (space) |s| s.name else "Home", if (space) |s| s.path else null, k.dark);
    // The project's own tone (`project_icon::monogram`), its letter's
    // lightness raised (lowered, in light) when the row is lit.
    const tile = ui.div(c).row().size(13, 13).center().rounded(3).bg(m.color.alpha(if (lit) 0.24 else 0.08));
    defer tile.end();
    const letter = if (lit) rules.shiftLightness(m.color, if (k.dark) 0.12 else -0.10, 0.15, 0.95) else m.color.alpha(0.85);
    ui.text(c, c.print("{c}", .{m.letter}), .{ .size = 9, .weight = .medium, .mono = true, .color = letter });
}

/// A chat's name: its title, else its first prompt, else "New session".
pub fn chatLabel(ch: workspace.Chat) []const u8 {
    if (ch.title) |t| if (t.len > 0) return firstLine(t);
    if (ch.preview) |p| if (p.len > 0) return firstLine(p);
    return "New session";
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn zenFooter(c: *ui.Context, a: *App, k: theme.Colors, archived_count: usize) void {
    notice(c, a, k);
    if (a.offscreen or a.window != null)
        @import("view_sandbox_strip.zig").computers(c, a, k)
    else
        @import("view_sandbox_strip.zig").strip(c, a, k, 0);

    if (a.settings.get(.sidebar_show_archived) and !a.view.zen_archived_open and archived_count > 0) {
        const wrap = ui.div(c).column().wFull().px(8).pt(2).pb(2);
        defer wrap.end();
        ui.key(c, "zen-archived-footer");
        const ar = ui.div(c).row().wFull().h(28).px(8).itemsCenter().rounded(7).hover(k.hover).control();
        const clicked = ar.clicked();
        {
            defer ar.end();
            ui.text(c, "Archived", .{ .size = 12, .line_height = 16, .color = k.muted });
            ui.spacer(c);
            ui.text(c, c.print("{d}", .{archived_count}), .{ .size = 11.5, .line_height = 16, .mono = true, .color = k.faint });
        }
        if (clicked) {
            a.view.zen_archived_open = true;
            a.redraw();
        }
    }

    @import("view_account_notice.zig").strip(c, a, k);

    if (!a.settings.get(.star_banner_dismissed)) {
        const wrap = ui.div(c).column().wFull().px(8).pt(4).pb(2);
        defer wrap.end();
        const cg = theme.builtin(k.dark);
        const star_bg = cg.accent.alpha(if (k.dark) 0.13 else 0.10);
        const star_hover = cg.accent.alpha(if (k.dark) 0.20 else 0.16);
        const star_border = cg.accent.alpha(if (k.dark) 0.24 else 0.20);
        const star_fg = if (k.dark) cg.glyph[0] else cg.glyph[2];
        ui.key(c, "star-banner");
        const banner = ui.div(c).row().wFull().h(30).pl(10).pr(4).gap(6).itemsCenter().rounded(8)
            .bg(star_bg).hover(star_hover).border(star_border).borderW(1);
        const rclick = kit.secondaryClicked(banner);
        var open_clicked = false;
        var dismiss_clicked = false;
        {
            defer banner.end();
            {
                ui.key(c, "star-banner-open");
                const open_btn = tip.on(ui.div(c).row().grow().w(0).hFull().gap(7).itemsCenter().control(), k, .{
                    .text = "Star justrach/codegraff on GitHub",
                    .delay = tip.quick,
                });
                open_clicked = open_btn.clicked();
                defer open_btn.end();
                icons.icon(c, .@"star-bold", 13, star_fg, 0);
                ui.text(c, "Star on GitHub", .{ .size = 12, .line_height = 16, .weight = theme.ui_medium_weight, .color = star_fg });
            }
            {
                ui.key(c, "star-banner-dismiss");
                const close_btn = tip.on(ui.div(c).row().size(20, 20).center().rounded(5).hover(k.ink(0.10)).control(), k, .{
                    .text = "Dismiss",
                    .delay = tip.quick,
                });
                dismiss_clicked = close_btn.clicked();
                defer close_btn.end();
                icons.icon(c, .close, 10, star_fg.alpha(0.75), 0);
            }
        }
        if (rclick) {
            a.view.star_menu = true;
            a.view.star_menu_pos = c.input.mouse;
            a.redraw();
        } else if (dismiss_clicked) {
            a.settings.set(.star_banner_dismissed, true);
            a.view.star_menu = false;
            a.redraw();
        } else if (open_clicked) {
            a.openExternalUrl(star_github_url);
            a.settings.set(.star_banner_dismissed, true);
            a.view.star_menu = false;
            a.redraw();
        }
    }

    const row = ui.div(c).row().wFull().h(38).px(7).pt(2).pb(4).gap(3).itemsCenter();
    defer row.end();
    {
        const account = @import("app_account.zig");
        const m = account.menu(a.account.scope, a.account.user, a.account.codegraff);
        const signed_in = a.account.user != null;
        const has_identity = signed_in or a.account.codegraff.signed_in;
        const label = if (m.name) |n|
            n
        else if (signed_in)
            m.line
        else if (a.account.codegraff.signed_in)
            (a.account.codegraff.who orelse "Codegraff")
        else if (a.account.scope == .development)
            "Development"
        else
            "Sign in";
        ui.key(c, "sidebar-account-row");
        const btn = tip.on(
            ui.div(c).row().grow().w(0).h(30).px(5).gap(8).itemsCenter().rounded(7).hover(k.hover).control(),
            k,
            .{ .text = c.print("Account: {s} (click for card, right-click for menu)", .{label}), .delay = tip.quick },
        );
        const clicked = btn.clicked();
        const rclick = kit.secondaryClicked(btn);
        if (c.rects.get(c.node(btn.index).id)) |r| a.view.account_anchor = r;
        {
            defer btn.end();
            const drew_avatar = if (a.account.avatar_bytes) |bytes|
                bytes.len > 0 and ui.image(c, .{
                    .key = "sidebar-account-avatar",
                    .source = .{ .encoded = bytes },
                    .box = .{ .w = 20, .h = 20 },
                    .radius = 10,
                })
            else
                false;
            if (!drew_avatar) renderFallbackAvatar(c, k, label, has_identity);
            const label_room = @max(44, cardInnerW(a) - 159);
            kit.ellipsisText(c, label, .{
                .size = 12.5,
                .line_height = 17,
                .weight = theme.ui_medium_weight,
                .color = k.text.alpha(0.92),
            }, label_room);
        }
        if (clicked) {
            a.settings.setSection(.account);
            @import("view_settings.zig").open(a);
        } else if (rclick) {
            a.view.account_menu = !a.view.account_menu;
            if (a.view.account_menu) account.refresh(a);
            a.redraw();
        }
    }
    sidebarThemeButton(c, a, k);
    {
        const dev = a.settings.uiMode() == .developer;
        ui.key(c, "sidebar-ui-mode-pill");
        var pill = tip.on(
            ui.div(c).row().h(26).px(6).gap(4).itemsCenter().rounded(6)
                .bg(if (dev) k.ink(0.08) else .transparent)
                .border(if (dev) k.muted.alpha(0.35) else k.muted.alpha(0.22)).borderW(1)
                .hover(k.hover),
            k,
            .{ .text = "Click to switch Zen / Developer mode (⇧⌘M) · Right-click to customize", .delay = tip.quick },
        );
        const pill_clicked = pill.clicked();
        const pill_rclick = kit.secondaryClicked(pill);
        {
            defer pill.end();
            icons.icon(c, if (dev) .terminal else .@"magic-stick-3", 12, if (dev) k.text else k.muted, 0);
            ui.text(c, if (dev) "Dev" else "Zen", .{ .size = 11, .line_height = 14, .weight = if (dev) .semibold else theme.ui_medium_weight, .color = if (dev) k.text else k.muted });
        }
        if (pill_clicked) {
            a.settings.toggleUiMode();
            a.redraw();
        } else if (pill_rclick) {
            @import("view_sidebar_menus.zig").openView(a);
            a.redraw();
        }
    }
    {
        ui.key(c, "sidebar-settings-button");
        const gear = tip.on(
            ui.div(c).row().size(26, 26).center().rounded(7).hover(k.hover).control(),
            k,
            .{ .text = "Settings (⌘,)", .delay = tip.quick },
        );
        const clicked = gear.clicked();
        const rclick = kit.secondaryClicked(gear);
        const hot = gear.hovered();
        if (c.rects.get(c.node(gear.index).id)) |r| a.view.more_anchor = a.view.more_anchor orelse r;
        {
            defer gear.end();
            icons.icon(c, .@"settings-minimalistic", 16, if (hot) k.text else k.muted, 0);
        }
        if (clicked) {
            @import("view_settings.zig").open(a);
        } else if (rclick) {
            @import("view_sidebar_menus.zig").openView(a);
            a.redraw();
        }
    }
}

fn sidebarThemeButton(c: *ui.Context, a: *App, k: theme.Colors) void {
    const appearance = @import("view_settings_appearance.zig");
    const sys = appearance.isSystemDefault(a);
    const glyph: icons.Name = if (sys) .monitor else if (k.dark) .moon else .sun;
    ui.key(c, "sidebar-theme-button");
    const btn = tip.on(
        ui.div(c).row().size(24, 24).center().rounded(6).hover(k.hover).control(),
        k,
        .{ .text = "Click to switch theme · Right-click for Default system theme", .delay = tip.quick },
    );
    const clicked = btn.clicked();
    const rclick = kit.secondaryClicked(btn);
    const hot = btn.hovered();
    {
        defer btn.end();
        icons.icon(c, glyph, 14, if (sys) k.accent else if (hot) k.text else k.muted, 0);
    }
    if (clicked) {
        appearance.toggleLightDark(a);
    } else if (rclick) {
        appearance.applySystemDefault(a);
    }
}

fn renderFallbackAvatar(c: *ui.Context, k: theme.Colors, label: []const u8, has_identity: bool) void {
    const account = @import("app_account.zig");
    if (has_identity) {
        const av = ui.div(c).row().size(20, 20).center().roundedFull().bg(k.accent);
        defer av.end();
        ui.text(c, c.print("{c}", .{account.initial(label)}), .{
            .size = 10.5,
            .line_height = 14,
            .weight = .semibold,
            .mono = true,
            .color = k.onAccent(),
        });
    } else {
        const badge_box = ui.div(c).row().size(20, 20).center().roundedFull().bg(k.accent_wash).border(k.accent.alpha(0.35)).borderW(1);
        defer badge_box.end();
        icons.icon(c, .@"user-rounded", 12, k.accent, 0);
    }
}

fn footer(c: *ui.Context, a: *App, k: theme.Colors) void {
    notice(c, a, k);
    if (a.offscreen or a.window != null)
        @import("view_sandbox_strip.zig").computers(c, a, k)
    else
        @import("view_sandbox_strip.zig").strip(c, a, k, 0);
    @import("view_updates.zig").sidebarFooterRows(c, a, k);
    @import("view_account_notice.zig").strip(c, a, k);
    const f = ui.div(c).row().wFull().h(44).px(10).itemsCenter();
    defer f.end();
    {
        // The desktop's footer is avatar-only; identity stays in its
        // accessible tooltip and in the menu, not inside the avatar's row.
        const account = @import("app_account.zig");
        const m = account.menu(a.account.scope, a.account.user, a.account.codegraff);
        const display = m.name orelse m.line;
        ui.key(c, "user-menu");
        var b = ui.div(c).row().size(21, 21).center().roundedFull();
        b = if (a.view.account_menu) b.bg(k.hover) else b.hover(k.hover);
        b = tip.on(b, k, .{ .text = c.print("Account menu: {s}", .{display}) });
        defer b.end();
        if (b.clicked()) {
            a.view.account_menu = !a.view.account_menu;
            if (a.view.account_menu) account.refresh(a);
        }
        if (c.rects.get(c.node(b.index).id)) |r| a.view.account_anchor = r;
        const av = ui.div(c).row().size(13, 13).center().roundedFull().bg(k.text);
        defer av.end();
        ui.text(c, c.print("{c}", .{account.initial(display)}), .{ .size = 9, .line_height = 13, .weight = .semibold, .mono = true, .color = k.shell });
    }
    ui.div(c).w(6).end();
    {
        const searching = a.view.search.open;
        ui.key(c, "sidebar-search-trigger");
        const search_wrap = tip.on(ui.div(c).row(), k, .{ .text = "Search sessions", .delay = tip.quick });
        defer search_wrap.end();
        if (kit.iconButton(c, k, .magnifer, .{ .size = 24, .radius = 6, .icon = 15, .color = k.muted, .on = searching }))
            @import("view_sidebar_search.zig").toggle(a);
        if (c.rects.get(c.node(search_wrap.index).id)) |r| a.view.search_anchor = r;
    }
    ui.spacer(c);
    {
        const dev = a.settings.uiMode() == .developer;
        ui.key(c, "sidebar-ui-mode-pill");
        var pill = tip.on(
            ui.div(c).row().h(26).px(8).gap(5).itemsCenter().rounded(6)
                .bg(if (dev) k.ink(0.08) else .transparent)
                .border(if (dev) k.muted.alpha(0.35) else k.muted.alpha(0.22)).borderW(1)
                .hover(k.hover),
            k,
            .{ .text = "Click to switch Zen / Developer mode (⇧⌘M) · Right-click to customize", .delay = tip.quick },
        );
        defer pill.end();
        icons.icon(c, if (dev) .terminal else .@"magic-stick-3", 13, if (dev) k.text else k.muted, 0);
        ui.text(c, if (dev) "Dev" else "Zen", .{ .size = 11.5, .line_height = 14, .weight = if (dev) .semibold else theme.ui_medium_weight, .color = if (dev) k.text else k.muted });
        if (pill.clicked()) {
            a.settings.toggleUiMode();
            a.redraw();
        } else if (kit.secondaryClicked(pill)) {
            @import("view_sidebar_menus.zig").openView(a);
            a.redraw();
        }
    }
    ui.div(c).w(6).end();
    {
        ui.key(c, "chat-history");
        const history = tip.on(ui.div(c).row().size(26, 26).center().rounded(6).hover(k.hover), k, .{ .text = "Chat history", .delay = tip.quick });
        defer history.end();
        icons.icon(c, .@"clock-circle", 16, k.muted, 0);
        if (history.clicked()) @import("view_palette.zig").toggle(a, .chat_history);
    }
    ui.div(c).w(6).end();
    ui.key(c, "sidebar-session-create");
    const b = tip.on(ui.div(c).row().size(26, 26).center().rounded(6).border(k.muted.alpha(0.45)).borderW(1).hover(k.hover), k, .{ .text = "New workspace", .delay = tip.quick });
    defer b.end();
    icons.icon(c, .plus, 16, k.muted, 0);
    if (b.clicked()) a.newWorkspaceSession();
}
