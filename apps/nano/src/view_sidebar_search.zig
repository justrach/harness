//! The sidebar's session search, as the GPUI app's (crates/ui/src/shell/
//! sidebar_search.rs): the magnifier beside the project filter opens a
//! field under the header (32 tall, 6 round, on the window's colour) with
//! a clear button once something's typed, and "Include archived sessions"
//! under it. While it filters, the session lists give way to the results
//! ("N results", each a search row with its match washed), in the sidebar's
//! order and project. ↑↓ move round them, Return opens one keeping the tabs
//! (an archived one stays archived); Escape clears, then closes.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const pal = @import("palette.zig");
const workspace = @import("workspace.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;
const S = ui.Shortcut;

pub const State = struct {
    open: bool = false,
    query: ui.TextBuffer = .{},
    include_archived: bool = false,
    cursor: pal.Cursor = .{},
    latch: pal.KeyLatch = .{},
    /// The field takes the keys when next drawn.
    focus: bool = false,
    /// The field, or one of its controls, had the keys in the last frame.
    field_focused: bool = false,
    control_focused: bool = false,
    /// The project filter the results were for (`project`).
    project_buf: [256]u8 = undefined,
    project_len: ?usize = null,
    /// The controls and the results' list, as last drawn.
    controls: ?ui.Rect = null,
    scroll_id: u64 = 0,
    /// The highlight was moved by the keys: scroll it into view.
    reveal: bool = false,

    fn project(s: *const State) ?[]const u8 {
        return if (s.project_len) |n| s.project_buf[0..n] else null;
    }

    fn setProject(s: *State, p: ?[]const u8) void {
        const v = p orelse {
            s.project_len = null;
            return;
        };
        const n = @min(v.len, s.project_buf.len);
        @memcpy(s.project_buf[0..n], v[0..n]);
        s.project_len = n;
    }
};

/// The magnifier: opens the search (closing the palette and the header's
/// menus), or closes it (`toggle_sidebar_search`).
pub fn toggle(a: *App) void {
    const s = &a.view.search;
    if (s.open) return close(a);
    @import("view_sidebar_menus.zig").close(a);
    @import("view_palette.zig").close(a);
    s.open = true;
    s.query.clear();
    s.include_archived = false;
    s.cursor.reset();
    s.latch.clear();
    s.focus = true;
    s.control_focused = false;
    s.setProject(a.view.filter);
    a.redraw();
}

pub fn close(a: *App) void {
    const s = &a.view.search;
    if (!s.open) return;
    s.open = false;
    s.field_focused = false;
    s.control_focused = false;
    a.redraw();
}

/// Something to search for: words typed, or the archived asked for
/// (`sidebar_search_is_filtering`).
pub fn filtering(a: *const App) bool {
    const s = &a.view.search;
    return s.open and (s.include_archived or std.mem.trim(u8, s.query.text(), " \t\n\r").len > 0);
}

/// The results' ids, in their order (`sidebar_search_ids`).
pub fn ids(a: *const App, gpa: std.mem.Allocator) ![]const []const u8 {
    const s = &a.view.search;
    if (!s.open) return &.{};
    const found = try pal.matchingChats(gpa, a.chats.items, s.query.text(), a.view.filter, s.include_archived, a.settings.sort() == .created);
    defer gpa.free(found);
    const out = try gpa.alloc([]const u8, found.len);
    for (found, 0..) |ch, i| out[i] = ch.id;
    return out;
}

/// A fresh choice, the list back at its top (`reset_sidebar_search`).
fn reset(c: ?*ui.Context, a: *App) void {
    const s = &a.view.search;
    s.cursor.reset();
    if (c) |cx| if (s.scroll_id != 0) cx.scroll.put(cx.gpa, s.scroll_id, 0) catch {};
    a.redraw();
}

/// Another project filter is another set of results (`sync_sidebar_search_scope`).
fn syncScope(c: ?*ui.Context, a: *App) void {
    const s = &a.view.search;
    const now = a.view.filter;
    const same = if (s.project()) |p| (now != null and std.mem.eql(u8, p, now.?)) else now == null;
    if (same) return;
    s.setProject(now);
    reset(c, a);
}

/// Clears the words and the archived box, the keys back in the field
/// (`clear_sidebar_search`).
fn clear(c: ?*ui.Context, a: *App) void {
    const s = &a.view.search;
    s.include_archived = false;
    s.query.clear();
    s.focus = true;
    s.control_focused = false;
    reset(c, a);
}

pub fn toggleArchived(c: ?*ui.Context, a: *App) void {
    a.view.search.include_archived = !a.view.search.include_archived;
    reset(c, a);
}

/// Whether the search holds the keys (`sidebar_search_has_focus`).
pub fn hasFocus(a: *const App) bool {
    const s = &a.view.search;
    return s.open and (s.field_focused or s.control_focused);
}

/// Its keys, while it holds them (`sidebar_search_key`): Escape clears
/// what's there, else closes; ↑↓ and Return while it filters.
pub fn keys(c: *ui.Context, a: *App) void {
    const s = &a.view.search;
    if (!hasFocus(a)) return;
    syncScope(c, a);
    if (c.shortcut(.{ .key = S.escape })) {
        // nanoui hands over presses, not releases: each is let go at once.
        defer _ = s.latch.release(S.escape);
        if (!s.latch.press(S.escape, false)) return;
        if (s.include_archived or s.query.text().len > 0) clear(c, a) else close(a);
        return;
    }
    if (!filtering(a)) return;
    const down = c.shortcut(.{ .key = S.down });
    const up = !down and c.shortcut(.{ .key = S.up });
    const enter = !down and !up and c.shortcut(.{ .key = S.enter });
    if (!down and !up and !enter) return;
    const list = ids(a, c.alloc()) catch return;
    if (down or up) {
        _ = s.cursor.reconcile(list);
        s.cursor.step(list, down);
        s.reveal = true;
        return a.redraw();
    }
    const disappeared = s.cursor.reconcile(list);
    if (disappeared) a.redraw();
    defer _ = s.latch.release(S.enter);
    if (s.latch.press(S.enter, false) and !disappeared and list.len > 0) {
        open(a, list[@min(s.cursor.active, list.len - 1)]);
    }
}

fn open(a: *App, id: []const u8) void {
    var buf: [256]u8 = undefined;
    const own = buf[0..@min(id.len, buf.len)];
    @memcpy(own, id[0..own.len]);
    a.openChatInTab(own);
}

/// The field and the archived box under the header
/// (`render_sidebar_search_controls`).
pub fn controls(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.search;
    if (!s.open) return;
    syncScope(c, a);
    ui.key(c, "sidebar-search-controls");
    const box = ui.div(c).column().wFull().px(8);
    defer box.end();
    if (c.rects.get(c.node(box.index).id)) |r| s.controls = r;
    // A press anywhere else takes the keys from its controls.
    if (c.input.pressed) if (s.controls) |r| if (!r.contains(c.input.mouse)) {
        s.control_focused = false;
    };
    const has_query = s.query.text().len > 0;
    {
        const f = ui.div(c).row().wFull().h(32).px(8).gap(6).itemsCenter().rounded(6).border(k.border).borderW(1).bg(k.shell);
        defer f.end();
        icons.icon(c, .magnifer, 14, k.muted, 0);
        {
            const t = ui.div(c).row().grow().w(0).itemsCenter();
            defer t.end();
            ui.key(c, "sidebar-search-field");
            const at = c.nodes.items.len;
            const res = ui.textField(c, &s.query, .{ .placeholder = "Search session names…", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .line_height = 22.75 });
            if (s.focus) {
                c.focus = c.node(@intCast(at)).id;
                c.changed = true;
                s.focus = false;
            }
            s.field_focused = res.focused;
            if (res.focused) s.control_focused = false;
            if (res.changed) reset(c, a);
        }
        if (has_query or s.include_archived) {
            ui.key(c, "sidebar-search-clear");
            const b = ui.div(c).row().size(18, 18).rounded(3).center().hover(k.hover);
            defer b.end();
            if (b.hovered()) c.cursor_hand = true;
            // The ✕ in the button's muted tone (GPUI's own fix: an svg
            // takes no colour from its parent).
            icons.icon(c, .close, 12, k.muted, 0);
            if (b.clicked()) clear(c, a);
        }
    }
    {
        ui.key(c, "sidebar-search-archived");
        const r = ui.div(c).row().wFull().h(28).gap(6).itemsCenter();
        defer r.end();
        if (r.hovered()) c.cursor_hand = true;
        {
            const on = s.include_archived;
            const cb = ui.div(c).row().size(12, 12).rounded(3).center().border(if (on) k.accent else k.border_strong).borderW(1);
            defer cb.end();
            if (on) icons.icon(c, .check, 10, k.accent, 0);
        }
        ui.text(c, "Include archived sessions", .{ .size = 11, .line_height = 11 * 1.618, .color = k.muted });
        if (r.clicked()) {
            s.control_focused = true;
            toggleArchived(c, a);
        }
    }
}

/// The results in the lists' place while it filters; false when it
/// doesn't (`render_sidebar_search_results`).
pub fn results(c: *ui.Context, a: *App, k: theme.Colors) bool {
    const s = &a.view.search;
    syncScope(c, a);
    if (!filtering(a)) return false;
    const found = pal.matchingChats(c.alloc(), a.chats.items, s.query.text(), a.view.filter, s.include_archived, a.settings.sort() == .created) catch return false;
    const list = c.alloc().alloc([]const u8, found.len) catch return false;
    for (found, 0..) |ch, i| list[i] = ch.id;
    _ = s.cursor.reconcile(list);
    const query = std.mem.trim(u8, s.query.text(), " \t\n\r");
    const col = ui.div(c).column().grow().wFull().h(0).px(8);
    defer col.end();
    {
        const h = ui.div(c).row().wFull().px(8).py(6);
        defer h.end();
        ui.text(c, c.print("{d} {s}", .{ found.len, if (found.len == 1) "result" else "results" }), .{ .size = 11, .line_height = 11 * 1.618, .color = k.muted });
    }
    var style: ui.Style = .{ .grow = 1, .width = .fill, .direction = .column, .gap = 2 };
    if (@hasField(ui.Style, "scrollbar")) style.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
    const at = c.nodes.items.len;
    ui.scroll(c, style);
    defer ui.end(c);
    s.scroll_id = c.node(@intCast(at)).id;
    var chosen: ?usize = null;
    for (found, 0..) |ch, i| {
        ui.key(c, c.print("sidebar-search-result-{s}", .{ch.id}));
        const w = ui.div(c).column().wFull();
        defer w.end();
        const project = if (a.findSpace(ch.space_id)) |sp| sp.name else "~";
        const device = deviceName(a, ch.device_id);
        const where = if (device) |d| c.print("{s} @ {s}", .{ project, d }) else project;
        const folder = if (ch.archived) c.print("Archived · {s}", .{where}) else where;
        const hit = sidebar.searchRow(c, a, k, ch, .{ .folder = folder, .lit = i == s.cursor.active, .query = query, .inner = sidebar.width - 16 - 16 });
        if (hit.pressed) s.cursor.pick(i, ch.id);
        if (hit.clicked) chosen = i;
        if (s.reveal and i == s.cursor.active) revealRow(c, s.scroll_id, w);
    }
    s.reveal = false;
    if (found.len == 0) {
        const e = ui.div(c).column().wFull().px(8).py(24).gap(6);
        defer e.end();
        ui.text(c, "No matching sessions", .{ .size = 12, .line_height = 12 * 1.618, .color = k.text });
        ui.text(c, "Try another name or project.", .{ .size = 12, .line_height = 12 * 1.618, .color = k.muted });
    }
    if (chosen) |i| open(a, found[i].id);
    return true;
}

fn deviceName(a: *const App, id: ?[]const u8) ?[]const u8 {
    const want = id orelse return null;
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, want)) return d.name;
    return null;
}

fn revealRow(c: *ui.Context, scroll_id: u64, d: ui.Div) void {
    const box = c.rects.get(scroll_id) orelse return;
    const r = c.rects.get(c.node(d.index).id) orelse return;
    const now = c.scroll.get(scroll_id) orelse 0;
    var to = now;
    if (r.y < box.y) to = now - (box.y - r.y) else if (r.y + r.h > box.y + box.h) to = now + (r.y + r.h - box.y - box.h);
    if (to != now) c.scroll.put(c.gpa, scroll_id, @max(0, to)) catch {};
}
