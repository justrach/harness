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

/// "No sessions yet": GPUI's default line (φ), up to a device pixel.
const empty_line = kit.measured(12 * 1.618);

pub const width: f32 = @import("settings.zig").sidebar_default;

pub fn widthOf(a: *const App) f32 {
    return a.settings.sidebarWidth();
}
pub const titlebar_h: f32 = 38;

pub fn sidebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    // The edge is drawn over its last column (view.zig), as the GPUI app's.
    const side = ui.div(c).column().w(widthOf(a)).hFull().bg(k.sidebar).pt(titlebar_h);
    defer side.end();
    const search = @import("view_sidebar_search.zig");
    filterRow(c, a, k);
    // The session search's field, and its results in the lists' place
    // while it filters (view_sidebar_search.zig).
    search.controls(c, a, k);
    if (!search.results(c, a, k)) {
        openWorkspaces(c, a, k);
        lists(c, a, k);
    }
    footer(c, a, k);
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
fn openWorkspaces(c: *ui.Context, a: *App, k: theme.Colors) void {
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
        const singleton = if (a.tabs.splits.items[ws]) |split|
            split.panes.items.len == 1 and split.groups[0].items.items.len == 1
        else
            true;
        if (singleton) if (id) |chat_id| if (a.findChat(chat_id)) |chat| {
            if (!chat.archived and listed(a, chat)) continue;
        };
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
    defer list.end();
    for (sessions.items, 0..) |sess, idx| {
        const title = if (sess.title_chat_id) |chat_id| (if (a.findChat(chat_id)) |chat| chatLabel(chat) else "New session") else "New session";
        const multi_tabs = sess.tabs.len > 1;
        {
            ui.key(c, c.print("workspace-session-{d}", .{idx}));
            var row = ui.div(c).row().wFull().h(32).px(8).gap(7).itemsCenter().rounded(7).clip().control();
            if (sess.active and !multi_tabs) {
                row = row.bg(if (k.is_harp) k.active else k.selected);
                if (k.is_harp) row = row.border(k.border_strong).borderW(0.5).shadows(&.{.{ .color = .{ .a = if (k.dark) 0.16 else 0.06 }, .blur = 2, .y = 1 }});
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
                    icons.icon(c, .widget, 14, if (sess.active) k.text else k.muted, 0);
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
                const trow_wrap = ui.div(c).row().wFull().h(28).itemsCenter();
                defer trow_wrap.end();
                // Vertical tree guide rail connecting the tab to its parent Session.
                const rail = ui.div(c).row().w(10).hFull().center();
                ui.div(c).size(1.5, if (t_ix + 1 == sess.tabs.len) 18 else 28).rounded(1).bg(if (t.active) k.text.alpha(0.55) else k.border_strong.alpha(0.65)).end();
                rail.end();
                var trow = ui.div(c).row().grow().w(0).h(28).px(7).gap(6).itemsCenter().rounded(6).clip().control();
                if (t.active) {
                    trow = trow.bg(if (k.is_harp) k.active else k.selected);
                    if (k.is_harp) trow = trow.border(k.border_strong).borderW(0.5).shadows(&.{.{ .color = .{ .a = if (k.dark) 0.16 else 0.06 }, .blur = 2, .y = 1 }});
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
                        icons.icon(c, .@"chat-round-line", 13, if (t.active) k.text else k.muted, 0);
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

fn filterRow(c: *ui.Context, a: *App, k: theme.Colors) void {
    const menus = @import("view_sidebar_menus.zig");
    const row = ui.div(c).row().wFull().px(8).pt(8).pb(4).gap(4).itemsCenter();
    defer row.end();
    {
        const base = ui.div(c).row().grow().w(0).h(29).px(8).gap(8).itemsCenter().rounded(8).clip();
        // Hovered as GPUI's trigger is (its `hover_listener`): by the
        // pointer's moves, not the keys.
        const lh = kit.listenerHover(&a.view.hovers, if (a.view.filter_menu) base.bg(k.hover) else base, k.hover);
        const t = lh.div;
        defer t.end();
        if (t.clicked()) if (a.view.filter_menu) menus.close(a) else menus.openProjects(a);
        if (c.rects.get(c.node(t.index).id)) |r| a.view.filter_anchor = r;
        const color = if (lh.hovered) k.text else k.text.alpha(0.8);
        // The trigger less its insets, icon, chevron and gaps.
        const room = widthOf(a) - 16 - 2 * 30 - 24 - 3 * 4 - 16 - 14 - 8;
        if (a.findSpace(a.view.filter)) |s| {
            // The project, "@ device" after it, and the offline mark.
            const tag = c.print("@ {s}", .{a.deviceName(s.device_id)});
            const off = !menus.online(a, s.device_id, a.nowMs());
            const tag_w = @min(c.text.width(tag, .{ .size = 10 }), room / 2);
            const name_w = @min(c.text.width(s.name, .{ .size = 13, .weight = theme.ui_medium_weight }), room - tag_w - 6 - (if (off) @as(f32, 18) else 0));
            const box = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip();
            defer box.end();
            kit.fadeText(c, s.name, .{ .size = 13, .weight = theme.ui_medium_weight, .color = color }, name_w);
            kit.fadeText(c, tag, .{ .size = 10, .color = k.muted.alpha(0.45) }, tag_w);
            if (off) icons.icon(c, .@"wifi-off", 12, k.warning.alpha(0.8), 0);
        } else {
            const label = ui.div(c).row().grow().w(0).clip();
            defer label.end();
            kit.fadeText(c, "All projects", .{ .size = 13, .weight = theme.ui_medium_weight, .color = color }, room);
        }
        icons.icon(c, .@"alt-arrow-down", 14, k.muted.alpha(0.6), 0);
    }
    // The magnifier, muted, on a wash while the search is open
    // (`render_sidebar_search_trigger`).
    const searching = a.view.search.open;
    if (kit.iconButton(c, k, .magnifer, .{ .size = 30, .radius = 8, .icon = 16, .color = k.muted, .on = searching }))
        @import("view_sidebar_search.zig").toggle(a);
    {
        const more = tip.on(ui.div(c).row(), k, .{ .text = "Sidebar view options", .delay = tip.quick });
        defer more.end();
        if (kit.iconButton(c, k, .@"more-horizontal", .{ .size = 30, .radius = 8, .icon = 16, .color = k.muted.alpha(0.6), .on = a.view.more_menu }))
            if (a.view.more_menu) menus.close(a) else menus.openView(a);
        if (c.rects.get(c.node(more.index).id)) |r| a.view.more_anchor = r;
    }
    {
        ui.key(c, "sidebar-overview");
        const overview = tip.on(ui.div(c).row().size(24, 24).center().rounded(6).hover(k.hover), k, .{ .text = "All sessions" });
        defer overview.end();
        icons.icon(c, .widget, 16, k.muted, 0);
        if (overview.clicked()) @import("view_sessions.zig").open(a);
    }
}

/// The rows the lists show: top-level chats in a project that still
/// exists (or none), narrowed by the project filter. (The session search
/// shows its own results in their place: view_sidebar_search.zig.)
fn listed(a: *const App, chat: workspace.Chat) bool {
    if (chat.parent_chat_id != null) return false;
    if (chat.space_id) |sid| if (a.findSpace(sid) == null) return false;
    // A filter on a project that's gone shows them all, as its label does.
    if (a.view.filter) |f| if (a.findSpace(f) != null) if (chat.space_id == null or !std.mem.eql(u8, chat.space_id.?, f)) return false;
    return true;
}

/// The pins this list shows, in pin order: listed and not archived.
pub fn visiblePins(a: *const App, gpa: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (a.settings.pins.items) |id| if (a.findChat(id)) |ch| if (!ch.archived and listed(a, ch)) out.append(gpa, id) catch {};
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

fn prepareItems(c: *ui.Context, a: *App, pins: []const []const u8, grouped: bool, by: Grouping) []const ChatItem {
    const gpa = c.alloc();
    const out = gpa.alloc(ChatItem, a.chats.items.len) catch return &.{};
    const filter_space: ?[]const u8 = if (a.view.filter) |f| (if (a.findSpace(f) != null) f else null) else null;
    const l = Look.of(a);
    const show_updated = a.settings.get(.sidebar_show_updated);
    var session_map: std.StringHashMapUnmanaged(workspace.Session) = .empty;
    if (grouped and a.sessions.items.len > 8) {
        session_map.ensureTotalCapacity(gpa, @intCast(a.sessions.items.len)) catch {};
        for (a.sessions.items) |s| session_map.put(gpa, s.chat_id, s) catch {};
    }
    for (a.chats.items, 0..) |ch, idx| {
        if (ch.parent_chat_id != null) {
            out[idx] = .{};
            continue;
        }
        if (ch.space_id) |sid| if (a.findSpace(sid) == null) {
            out[idx] = .{};
            continue;
        };
        if (filter_space) |f| if (ch.space_id == null or !std.mem.eql(u8, ch.space_id.?, f)) {
            out[idx] = .{};
            continue;
        };
        const row_h = contextHeight(l.label, l.branch and ch.branch != null, show_updated, l.harness or l.icon);
        const is_pinned = !ch.archived and pinned(pins, ch.id) != null;
        var gkey: []const u8 = "";
        if (grouped and !ch.archived and !is_pinned) {
            const sess = if (a.sessions.items.len > 8) session_map.get(ch.id) else workspace.sessionOf(a.sessions.items, ch.id);
            const mark = workspace.markOf(ch, sess, by.now);
            gkey = if (mark == .awaiting_input or mark == .errored)
                "needs"
            else switch (by.org) {
                .by_status => workspace.statusGroup(mark, ch.timeMs(), by.now, by.offset).key(),
                .by_project => ch.space_id orelse c.print("home:{s}", .{ch.device_id orelse ""}),
                else => ch.device_id orelse "",
            };
        }
        out[idx] = .{ .listed = true, .pinned = is_pinned, .row_h = row_h, .group_key = gkey };
    }
    return out;
}

// The input offset may overshoot the end before layout clamps it. Bound
// the build window against the complete content, not the previous frame's
// rows; otherwise an immediate jump to the bottom can produce a blank frame.
fn contentHeight(c: *ui.Context, a: *App, pins: []const []const u8, items: []const ChatItem, grouped: bool, by: Grouping) f32 {
    var height: f32 = 4;
    if (pins.len > 0) {
        height += 30;
        if (a.view.pinned_open) {
            height += 6;
            for (pins) |id| if (a.findChat(id)) |ch| {
                height += rowHeight(a, ch) + 2;
            };
        }
        if (!grouped) height += 12;
    }
    var active: usize = 0;
    var archived: usize = 0;
    var archive_height: f32 = 0;
    var keys: std.StringHashMapUnmanaged(bool) = .empty;
    for (a.chats.items, items) |ch, it| if (it.listed) {
        if (ch.archived) {
            if (archived < a.view.archived_limit) archive_height += it.row_h + 2;
            archived += 1;
        } else if (!it.pinned) {
            active += 1;
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
    if (active == 0 and pins.len == 0) {
        height += 8 + c.text.lineHeight(.{ .size = 12 });
    } else if (!grouped and active > 0) height += 30 + (if (a.view.sessions_open) @as(f32, 2) else 0);
    if (archived > 0 and a.settings.get(.sidebar_show_archived)) {
        height += 6 + 30;
        if (a.view.archived_open) {
            height += 2 + archive_height;
            if (archived > a.view.archived_limit) height += (if (a.settings.get(.sidebar_compact)) @as(f32, 29) else 36) + 2;
        }
    }
    return height + 6; // Bottom padding, less the trailing parent gap.
}

fn lists(c: *ui.Context, a: *App, k: theme.Colors) void {
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
    const pins = visiblePins(a, c.alloc());
    const grouped = a.settings.organization() != .in_one_list;
    const by = Grouping.of(a);
    const items = prepareItems(c, a, pins, grouped, by);
    if (!window.eager) {
        const bounded = @min(offset, @max(0, contentHeight(c, a, pins, items, grouped, by) - c.size.h));
        window.top = @max(0, bounded - overscan);
        window.bottom = bounded + c.size.h + overscan;
    }
    const source_pin = if (moving) |id| pinned(pins, id) else null;
    var active: usize = 0;
    var archived: usize = 0;
    for (a.chats.items, items) |ch, it| if (it.listed) {
        if (ch.archived) archived += 1 else if (!it.pinned) active += 1;
    };
    // Pinned, while there are pins or a session is being dragged.
    if (pins.len > 0 or moving != null) {
        a.view.pin_header = rectOf(c, sectionAt(c, k, "Pinned", pins.len, &a.view.pinned_open));
        window.y += 30;
        if (a.view.pinned_open) {
            window.y += 2;
            var rows: Rows = .{};
            const body = ui.div(c).column().wFull().pt(2).pb(4).gap(2);
            defer body.end();
            a.view.pin_rows = rectOf(c, body);
            const gap_at: ?usize = if (target) |t| switch (t) {
                .pinned => |i| if (source_pin == null) i else null,
                .regular => null,
            } else null;
            for (pins, 0..) |id, ix| {
                const ch = a.findChat(id) orelse continue;
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
                if (rows.include(c, &window, rowHeight(a, ch))) slotRow(c, a, k, ch, dy, held);
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
        } else groups(c, a, k, items, by, moving, &window);
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
        a.view.sessions_header = rectOf(c, sectionAt(c, k, "Sessions", active, &a.view.sessions_open));
        window.y += 30;
        if (!a.view.sessions_open) {
            a.view.session_rows = null;
            break :regular;
        }
        // SIDEBAR_DISCLOSURE_BODY_INSET: 4 under the header, the list's 2 twice.
        _ = c.leaf(.{ .height = .{ .px = 0 } }, .none, null);
        const body = ui.div(c).column().wFull().gap(2);
        defer body.end();
        a.view.session_rows = rectOf(c, body);
        window.y += 2;
        var rows: Rows = .{};
        const unpinning = source_pin != null and target != null and target.? == .regular;
        for (a.chats.items, items) |ch, it| if (it.listed and !ch.archived and !it.pinned) {
            const held = moving != null and std.mem.eql(u8, moving.?, ch.id);
            // Dragged to the pins, a session's row leaves the list.
            if (held and target != null and target.? == .pinned) continue;
            if (rows.include(c, &window, it.row_h)) slotRow(c, a, k, ch, 0, held);
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
    // Show › Archived off: no shelf.
    if (archived == 0 or !a.settings.get(.sidebar_show_archived)) return;
    // 6 under the list above: its 4, and the gap.
    _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
    window.y += 6 + 30;
    if (section(c, k, "Archived", archived, &a.view.archived_open)) {
        // SIDEBAR_DISCLOSURE_BODY_INSET: 4 under the header, the list's 2 twice.
        _ = c.leaf(.{ .height = .{ .px = 0 } }, .none, null);
        window.y += 2;
        var rows: Rows = .{};
        var shown: usize = 0;
        for (a.chats.items, items) |ch, it| if (it.listed and ch.archived) {
            if (shown == a.view.archived_limit) break;
            if (rows.include(c, &window, it.row_h)) sessionRow(c, a, k, ch);
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
}

/// By status, by project or by device (`sidebar_organization`): a
/// disclosure for each, in the order their newest sessions come; this
/// device's first, and "Needs you" above "Today" above "Earlier".
fn groups(c: *ui.Context, a: *App, k: theme.Colors, items: []const ChatItem, by: Grouping, moving: ?[]const u8, window: *Window) void {
    const by_project = by.org == .by_project;
    const gpa = c.alloc();
    var keys: std.ArrayList([]const u8) = .empty;
    for (a.chats.items, items) |ch, it| if (it.listed and !ch.archived and !it.pinned) {
        const key = it.group_key;
        for (keys.items) |have| {
            if (std.mem.eql(u8, have, key)) break;
        } else keys.append(gpa, key) catch {};
    };
    if (by.org == .by_status) std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return @backingInt(workspace.StatusGroup.fromKey(x).?) < @backingInt(workspace.StatusGroup.fromKey(y).?);
        }
    }.lt);
    if (by.org == .by_device) if (a.device_id) |me| for (keys.items, 0..) |key, i| if (std.mem.eql(u8, key, me)) {
        std.mem.copyBackwards([]const u8, keys.items[1 .. i + 1], keys.items[0..i]);
        keys.items[0] = me;
        break;
    };
    // Attention escapes project/device grouping and always comes first.
    for (keys.items, 0..) |key, i| if (std.mem.eql(u8, key, "needs")) {
        std.mem.copyBackwards([]const u8, keys.items[1 .. i + 1], keys.items[0..i]);
        keys.items[0] = key;
        break;
    };
    a.view.sessions_header = null;
    a.view.session_rows = null;
    var omitted: Rows = .{};
    for (keys.items) |key| {
        var count: usize = 0;
        var height: f32 = 0;
        for (a.chats.items, items) |ch, it| if (it.listed and !ch.archived and !it.pinned and std.mem.eql(u8, it.group_key, key)) {
            count += 1;
            height += it.row_h + 2;
        };
        const collapse = c.print("{s}:{s}", .{ by.prefix(), key });
        const open = a.view.groupOpen(collapse, true);
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
            (if (std.mem.startsWith(u8, key, "home:")) "~" else if (a.findSpace(key)) |sp| sp.name else "?")
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
            } else if (h.clicked()) a.view.toggleGroup(a.gpa, collapse, true);
        }
        if (!open) continue;
        const body = ui.div(c).column().wFull().pt(4).gap(2);
        defer body.end();
        var inside = window.*;
        inside.y = start + 14 + 28 + 4;
        var rows: Rows = .{};
        for (a.chats.items, items) |ch, it| if (it.listed and !ch.archived and !it.pinned and std.mem.eql(u8, it.group_key, key)) {
            const held = moving != null and std.mem.eql(u8, moving.?, ch.id);
            if (rows.include(c, &inside, it.row_h)) slotRow(c, a, k, ch, 0, held);
        };
        rows.flush(c);
    }
    omitted.flush(c);
}

/// How the lists group this frame: the organization, and for "By status"
/// the clock and the local zone it reads "Today" by.
const Grouping = struct {
    org: @import("settings.zig").Organization,
    now: i64 = 0,
    offset: i64 = 0,

    fn of(a: *App) Grouping {
        const org = a.settings.organization();
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
fn slotRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, dy: f32, held: bool) void {
    ui.key(c, c.print("slot-{s}", .{ch.id}));
    var w = ui.div(c).column().wFull().offset(0, dy);
    if (held) w = w.opacity(0);
    defer w.end();
    sessionRow(c, a, k, ch);
}

fn rectOf(c: *ui.Context, d: ui.Div) ?ui.Rect {
    return c.rects.get(c.node(d.index).id);
}

/// `section` that hands back its header, for its place as a drop target.
fn sectionAt(c: *ui.Context, k: theme.Colors, label: []const u8, count: usize, open: *bool) ui.Div {
    ui.key(c, label);
    const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(8);
    if (h.clicked()) open.* = !open.*;
    const color = if (k.is_harp) k.muted else k.muted.alpha(0.5);
    ui.text(c, if (open.*) label else c.print("{s} ({d})", .{ label, count }), .{ .size = 11.5, .weight = theme.ui_medium_weight, .color = color });
    ui.spacer(c);
    icons.icon(c, if (open.*) .@"alt-arrow-down" else .@"alt-arrow-right", 12, color, 0);
    h.end();
    return h;
}

/// A disclosure header ("Sessions", "Archived (12)" when shut); true while open.
fn section(c: *ui.Context, k: theme.Colors, label: []const u8, count: usize, open: *bool) bool {
    ui.key(c, label);
    const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(8);
    defer h.end();
    if (h.clicked()) open.* = !open.*;
    const color = if (k.is_harp) k.muted else k.muted.alpha(0.5);
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
        return .{
            .compact = s.get(.sidebar_compact),
            .harness = s.get(.sidebar_show_harness),
            .icon = s.get(.sidebar_show_project_icon),
            .label = s.get(.sidebar_show_project_label),
            .branch = s.get(.sidebar_show_branch),
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
    statusSlot(c, k, workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now));
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
    const muted = ch.archived and !lit;
    if (l.harness) {
        const mark = icons.harnessMark(ch.harness orelse "graff");
        icons.icon(c, mark.name, 13, (mark.brand orelse k.subline).alpha(if (muted) 0.4 else 0.8), 13);
    }
    if (l.icon) {
        // `project_icon_frame`: the project and its device on hover.
        const space = a.findSpace(ch.space_id);
        const b = tip.project(c, ui.div(c).row().opacity(if (muted) 0.4 else 1), k, if (space) |sp| sp.name else "Home", a.deviceName(ch.device_id));
        defer b.end();
        badge(c, a, k, ch.space_id, lit);
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
fn folderLabel(c: *ui.Context, a: *const App, ch: workspace.Chat) []const u8 {
    const project = if (a.findSpace(ch.space_id)) |s| s.name else if (ch.space_id == null) "~" else "?";
    const dev = ch.device_id orelse return project;
    if (a.device_id) |local| if (std.mem.eql(u8, local, dev)) return project;
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, dev)) return c.print("{s} @ {s}", .{ project, d.name });
    return project;
}

/// The expanded row's lines: "project @ device" with the status or time,
/// the marks and title, then the branch.
fn expandedLines(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, l: Look, lit: bool, hovered: bool) void {
    const inner = widthOf(a) - 16 - 16;
    const subline = k.subline;
    var archive = false;
    if (l.label) {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        const corner_w = cornerWidth(c, a, ch, hovered);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, folderLabel(c, a, ch), .{ .size = 11, .line_height = 14, .color = subline }, inner - 8 - corner_w);
        }
        archive = corner(c, a, k, ch, hovered);
    }
    {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        marks(c, a, k, ch, l, lit);
        const marks_w = (if (l.harness) @as(f32, 21) else 0) + (if (l.icon) @as(f32, 21) else 0);
        const corner_w = if (l.label) 0 else cornerWidth(c, a, ch, hovered) + 8;
        const tc = if (lit) k.text else if (ch.archived) k.text.alpha(0.55) else k.text.alpha(0.8);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = tc }), inner - marks_w - corner_w);
        }
        if (!l.label) archive = corner(c, a, k, ch, hovered);
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
    const st: ui.TextStyle = .{ .size = 10, .weight = theme.ui_medium_weight };
    if (hovered) return 4 + 11 + 4 + c.text.width(if (ch.archived) "Unarchive" else "Archive", st);
    const word = statusWord(workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), a.nowMs()));
    if (word) |w| return 6 + 4 + c.text.width(w, st);
    return c.text.width(rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, a.nowMs(), ch.timeMs()), st);
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
    const box = ui.div(c).row().h(14).itemsCenter();
    defer box.end();
    if (hovered) {
        const b = ui.div(c).row().h(18).px(4).gap(4).itemsCenter().rounded(5).bg(k.wash(0.10)).hover(k.wash(0.18)).offset(4, 0);
        defer b.end();
        icons.icon(c, if (ch.archived) .@"archive-up-minimalistic" else .@"archive-minimalistic", 11, k.muted, 0);
        ui.text(c, if (ch.archived) "Unarchive" else "Archive", .{ .size = 10, .color = k.muted });
        return b.clicked();
    }
    const now = a.nowMs();
    const mark = workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now);
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
    ui.text(c, rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs()), .{ .size = 10, .weight = theme.ui_medium_weight, .color = subline });
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
    statusSlot(c, k, workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now));
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

fn sessionRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat) void {
    ui.key(c, c.print("row-{s}", .{ch.id}));
    const selected = a.selected != null and std.mem.eql(u8, a.selected.?, ch.id);
    const l = Look.of(a);
    // 6 above an 18-point line, as `render_chat_row`'s `py(6)` column.
    var r = if (l.compact)
        ui.div(c).column().wFull().h(rowHeight(a, ch)).px(8).py(6).gap(2).rounded(8).clip()
    else
        ui.div(c).column().wFull().h(rowHeight(a, ch)).px(8).py(6).gap(2).rounded(8).clip();
    // Hovered as GPUI's row is (its `hover_listener`): by the pointer's
    // moves, so its menu opening under a still pointer leaves it hovered.
    const lh = kit.listenerHover(&a.view.hovers, if (selected) r.bg(k.selected) else r, if (selected) k.selected else k.hover);
    r = lh.div;
    defer r.end();
    // No hover while a session is dragged over the rows.
    const hovered = lh.hovered and !@import("view_drag.zig").dragging(a);
    var archive = false;
    var menu = false;
    const now = a.nowMs();
    if (!l.compact) {
        expandedLines(c, a, k, ch, l, selected or hovered, hovered);
    } else {
        const line = ui.div(c).row().wFull().h(18).gap(4).itemsCenter();
        defer line.end();
        statusSlot(c, k, workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now));
        marks(c, a, k, ch, l, selected or hovered);
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
    if (r.clicked() and !selected and !drag.dragging(a)) a.openChatInTab(ch.id);
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

/// The project's monogram tile (`project_icon.rs`).
pub fn badge(c: *ui.Context, a: *const App, k: theme.Colors, space_id: ?[]const u8, lit: bool) void {
    const space = a.findSpace(space_id);
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

fn footer(c: *ui.Context, a: *App, k: theme.Colors) void {
    notice(c, a, k);
    if (a.offscreen or a.window != null)
        @import("view_sandbox_strip.zig").computers(c, a, k)
    else
        @import("view_sandbox_strip.zig").strip(c, a, k, 0);
    @import("view_updates.zig").sidebarFooterRows(c, a, k);
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
    ui.spacer(c);
    @import("view_sessions.zig").historyButton(c, a, k);
    ui.div(c).w(6).end();
    ui.key(c, "sidebar-session-create");
    const b = tip.on(ui.div(c).row().size(26, 26).center().rounded(6).border(k.muted.alpha(0.45)).borderW(1).hover(k.hover), k, .{ .text = "New session" });
    defer b.end();
    icons.icon(c, .plus, 16, k.muted, 0);
    if (b.clicked()) a.newWorkspaceSession();
}
