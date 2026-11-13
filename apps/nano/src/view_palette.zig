//! ⌘K's command palette, as the GPUI app's (crates/ui/src/shell/
//! command_palette.rs): over the window on a 0.35 scrim, a 560-point card
//! with the search on top, then the results (the split's other panes, the
//! actions, the chat history, other tools' conversations) in groups a rule
//! apart, and the keys' legend at the foot. ↑↓ move the highlight round,
//! Return picks, Escape (or a press outside) closes; picking a chat keeps
//! the tabs (`open_chat_in_tab`), except for `/resume`'s palette, which
//! puts it in the current tab.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const rpc = @import("rpc.zig");
const pal = @import("palette.zig");
const sidebar = @import("view_sidebar.zig");
const shortcuts = @import("shortcuts.zig");
const App = @import("app.zig").App;
const Entry = pal.Entry;
const S = ui.Shortcut;

const phi: f32 = 1.618;

/// Whether a pick keeps the tabs (⌘K) or replaces the current one
/// (`/resume`) (`PaletteNavigation`).
pub const Navigation = enum { preserve_tabs, replace_current, chat_history };

/// Other tools' conversations are asked for again on opening only after
/// this long (`EXTERNAL_REFRESH_AFTER`).
const external_refresh_ms = 60_000;

pub const State = struct {
    open: bool = false,
    navigation: Navigation = .preserve_tabs,
    query: ui.TextBuffer = .{},
    active: usize = 0,
    /// The search takes the keys when next drawn.
    focus: bool = false,
    /// The highlight was moved by the keys: scroll it into view.
    reveal: bool = false,
    enter: pal.EnterPress = .{},
    /// The results' scrolling box, as last drawn.
    scroll_id: u64 = 0,
    /// Other tools' conversations, as the engine last listed them.
    external: std.ArrayList(pal.External) = .empty,
    external_arena: ?std.heap.ArenaAllocator = null,
    external_loaded_ms: ?i64 = null,
    /// An import of them all is waiting on the engine.
    importing_all: bool = false,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        @import("text_buffer.zig").deinit(&s.query);
        s.external.deinit(gpa);
        if (s.external_arena) |*x| x.deinit();
    }
};

/// ⌘K: opens the palette, or closes it when it's open
/// (`toggle_command_palette`); `/resume` opens it to replace the current
/// tab (`toggle_resume_palette`).
pub fn toggle(a: *App, navigation: Navigation) void {
    const p = &a.view.palette;
    if (p.open and p.navigation == navigation) return close(a);
    // The session search and the header's menus give way.
    @import("view_sidebar_search.zig").close(a);
    @import("view_sidebar_menus.zig").close(a);
    p.open = true;
    p.navigation = navigation;
    p.query.clear();
    p.active = 0;
    p.focus = true;
    p.enter = .{};
    p.reveal = false;
    const stale = if (p.external_loaded_ms) |at| a.nowMs() - at >= external_refresh_ms else true;
    if (stale and navigation != .chat_history) loadExternal(a);
    a.redraw();
}

/// Closes it, the keys back to the composer (`close_command_palette`).
pub fn close(a: *App) void {
    const p = &a.view.palette;
    if (!p.open) return;
    p.open = false;
    a.view.focus_composer = true;
    a.redraw();
}

fn queryOf(c: *ui.Context, a: *const App) []const u8 {
    var buf = c.alloc().alloc(u8, 512) catch return "";
    return pal.foldBuf(buf[0..], std.mem.trim(u8, a.view.palette.query.text(), " \t\n\r"));
}

/// A split pane's chat title and project, as its card shows them (`pane_label`).
fn paneLabel(a: *const App, ix: usize) struct { title: []const u8, project: []const u8 } {
    const s = a.tabs.layout() orelse return .{ .title = "New session", .project = "" };
    const id = (if (ix == s.focus) a.tabs.current() else s.panes.items[ix]) orelse return .{ .title = "New session", .project = "" };
    const ch = a.findChat(id) orelse return .{ .title = "New session", .project = "" };
    const title = if (ch.title) |t| firstLine(t) else "Untitled session";
    return .{ .title = title, .project = if (a.findSpace(ch.space_id)) |sp| sp.name else "" };
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn isDark(a: *const App) bool {
    return a.dark orelse nanoui.isDark();
}

/// The results for the query typed, in their groups' order
/// (`command_entries`): the split's other panes, the actions, Import
/// while other tools have conversations, the chats (archived ones too, the
/// project filter and folded groups aside) newest first, then other
/// tools' conversations.
pub fn entries(a: *const App, gpa: std.mem.Allocator, query: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);
    var in_panes: std.ArrayList([]const u8) = .empty;
    defer in_panes.deinit(gpa);
    const history = a.view.palette.navigation == .chat_history;
    if (!history and !a.view.settings_open) if (a.tabs.layout()) |s| for (s.panes.items, 0..) |pane, ix| {
        if (ix == s.focus) continue;
        if (pane) |id| try in_panes.append(gpa, id);
        const l = paneLabel(a, ix);
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} {s}", .{ l.title, l.project }) catch l.title;
        if (pal.matchesQuery(query, text)) try out.append(gpa, .{ .pane = ix });
    };
    if (!history) {
        const actions = pal.actionsFor(query, isDark(a));
        try out.appendSlice(gpa, actions.slice());
    }
    const p = &a.view.palette;
    if (!history and p.external.items.len > 0 and pal.matchesQuery(query, "import conversations from other tools")) try out.append(gpa, .import_all);
    var chats: std.ArrayList(@import("workspace.zig").Chat) = .empty;
    defer chats.deinit(gpa);
    for (a.chats.items) |ch| {
        const in_pane = for (in_panes.items) |id| {
            if (std.mem.eql(u8, id, ch.id)) break true;
        } else false;
        if (in_pane) continue;
        const project = if (a.findSpace(ch.space_id)) |sp| sp.name else "~";
        const device = deviceOrEmpty(a, ch.device_id);
        var pr_buf: [512]u8 = undefined;
        const pr: []const u8 = if (@import("app_change_requests.zig").forChat(a, ch)) |x|
            std.fmt.bufPrint(&pr_buf, "#{d} {s} {s} {s}", .{ x[0].number, x[0].title, x[0].head_ref, x[0].base_ref }) catch ""
        else
            "";
        var buf: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} {s} {s} {s} {s}", .{ ch.title orelse "New session", project, device, ch.branch orelse "", pr }) catch ch.title orelse "";
        if (pal.matchesQuery(query, text)) try chats.append(gpa, ch);
    }
    @import("workspace.zig").sortChatsBy(chats.items, a.settings.sort() == .created);
    for (chats.items[0..@min(chats.items.len, pal.history_limit)]) |ch| try out.append(gpa, .{ .chat = ch.id });
    if (history) return out.toOwnedSlice(gpa);
    const limit: usize = if (query.len == 0) pal.external_idle_limit else pal.history_limit;
    var shown: usize = 0;
    for (p.external.items, 0..) |x, i| {
        if (shown == limit) break;
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} {s} {s}", .{ x.title, x.sourceLabel(), x.folder() }) catch x.title;
        if (!pal.matchesQuery(query, text)) continue;
        try out.append(gpa, .{ .external = i });
        shown += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn deviceOrEmpty(a: *const App, id: ?[]const u8) []const u8 {
    const want = id orelse return "";
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, want)) return d.name;
    return "";
}

/// What picking `e` does (`activate_command`): the theme switches with the
/// palette left open; anything else closes it first.
pub fn activate(a: *App, e: Entry) void {
    const p = &a.view.palette;
    if (e == .theme) {
        @import("view_settings_appearance.zig").setMode(a, switch (e.theme) {
            .system => .system,
            .light => .light,
            .dark => .dark,
        });
        return a.redraw();
    }
    const replace = p.navigation == .replace_current;
    close(a);
    switch (e) {
        .new_chat => if (replace) a.replaceCurrent(null) else a.newTab(),
        .new_project => @import("app_open_chooser.zig").open(a, .new_project),
        .settings => @import("view_settings.zig").open(a),
        .theme => unreachable,
        .ui_mode => |m| {
            a.settings.applyUiMode(m);
            a.redraw();
        },
        .toggle_part => |part| {
            a.settings.toggleMovingPart(part);
            a.redraw();
        },
        .external => |i| if (i < p.external.items.len) {
            const x = p.external.items[i];
            importExternal(a, &.{.{ .source = x.source, .id = x.id }});
        },
        .import_all => importExternal(a, null),
        .pane => |ix| a.focusPane(ix),
        .chat => |id| {
            // The id outlives the chat list's next update.
            var buf: [256]u8 = undefined;
            const own = buf[0..@min(id.len, buf.len)];
            @memcpy(own, id[0..own.len]);
            if (replace) a.replaceCurrent(own) else a.openChatInTab(own);
        },
    }
}

/// The palette's keys, taken before anything else sees them: ↑↓ round
/// the results, Return picks, Escape closes.
pub fn keys(c: *ui.Context, a: *App) void {
    const p = &a.view.palette;
    if (!p.open) return;
    if (c.shortcut(.{ .key = S.escape })) return close(a);
    const down = c.shortcut(.{ .key = S.down });
    const up = !down and c.shortcut(.{ .key = S.up });
    const enter = c.shortcut(.{ .key = S.enter });
    if (!down and !up and !enter) return;
    const list = entries(a, c.alloc(), queryOf(c, a)) catch return;
    if (down or up) {
        if (list.len == 0) return;
        p.active = if (down) (@min(p.active, list.len - 1) + 1) % list.len else (@min(p.active, list.len - 1) + list.len - 1) % list.len;
        p.reveal = true;
        return a.redraw();
    }
    // nanoui hands over presses, not releases or repeats: each one is a
    // fresh press, let go at once.
    defer p.enter.release();
    if (!p.enter.press(false)) return;
    // The results for the query as typed now, not as last drawn.
    if (list.len > 0) activate(a, list[@min(p.active, list.len - 1)]);
}

fn scrimColor(k: theme.Colors) ui.Color {
    return .{ .a = if (k.dark) 0.35 else 0.32 * (0.35 / 0.6) };
}

/// `hairline(0.06)`: the header's and the legend's rules.
fn hairline(k: theme.Colors) ui.Color {
    return if (k.dark) .{ .r = 1, .g = 1, .b = 1, .a = 0.06 } else .{ .a = 0.06 * 1.35 };
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.palette;
    if (!p.open) return;
    const query_text = p.query.text();
    const query = queryOf(c, a);
    const list = entries(a, c.alloc(), query) catch return;
    p.active = @min(p.active, list.len -| 1);
    const history = p.navigation == .chat_history;
    const footer = history and a.view.sidebar_open and !a.view.settings_open;
    const w = @min(if (history) @as(f32, 420) else 560, c.size.w - 32);
    ui.key(c, "command-palette-scrim");
    var scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(8);
    if (history) {
        const left = std.math.clamp(if (footer) a.settings.sidebarWidth() - 44 else 16, 16, @max(16, c.size.w - w - 16));
        scrim = scrim.column().itemsStart().pl(left);
        scrim = if (footer) scrim.justifyEnd().pb(52) else scrim.pt(50);
    } else scrim = scrim.bg(scrimColor(k)).center();
    defer scrim.end();
    if (scrim.clicked()) return close(a);
    // Its children inside its 1-point border, as GPUI lays them out.
    var card = @import("view_sidebar_menus.zig").held(ui.div(c).w(w).column().p(1).rounded(16)
        .bg(if (k.frosted) .transparent else k.composer).border(k.border).borderW(1).clip());
    if (!k.frosted) card = kit.shadowLg(card);
    defer card.end();
    if (k.frosted) frostedBackdrop(c, k);
    if (history) {
        const title = ui.div(c).row().wFull().px(16).pt(12).pb(4).gap(8).itemsCenter();
        defer title.end();
        icons.icon(c, .@"clock-circle", 16, k.muted, 0);
        {
            const label = ui.div(c).row().grow().w(0);
            defer label.end();
            ui.text(c, "Chat history", .{ .size = 14, .line_height = 14 * phi, .weight = theme.ui_medium_weight, .color = k.text });
        }
        const dismiss = ui.div(c).size(20, 20).center().rounded(5).hover(k.hover);
        defer dismiss.end();
        icons.icon(c, .close, 12, k.muted, 0);
        if (dismiss.clicked()) close(a);
    }
    header(c, a, k, w);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = hairline(k) }, .none, null);
    var picked: ?Entry = null;
    {
        const max_h = std.math.clamp(c.size.h - 180, 100, 360);
        var style: ui.Style = .{ .width = .fill, .max_height = max_h, .direction = .column, .gap = 2 };
        if (@hasField(ui.Style, "scrollbar")) style.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
        const at = c.nodes.items.len;
        ui.scroll(c, style);
        defer ui.end(c);
        const id = c.node(@intCast(at)).id;
        p.scroll_id = id;
        for (list, 0..) |e, ix| {
            ui.key(c, c.print("command-result-{d}", .{ix}));
            var wrap = ui.div(c).column().wFull();
            if (ix == 0) wrap = wrap.pt(8);
            if (ix + 1 == list.len) wrap = wrap.pb(8);
            defer wrap.end();
            if (history and ix == 0) {
                const section = ui.div(c).row().wFull().px(16).pt(6).pb(5);
                defer section.end();
                ui.text(c, "All chats", .{ .size = 11, .line_height = 11 * phi, .color = k.muted });
            }
            if (ix > 0 and list[ix - 1].section() != e.section()) {
                const sep = ui.div(c).column().wFull().py(8);
                defer sep.end();
                _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border.alpha(0.6) }, .none, null);
            }
            const content = ui.div(c).column().wFull().px(8);
            defer content.end();
            if (history) {
                if (historyRow(c, a, k, e, ix == p.active, query_text, w - 18)) picked = e;
            } else if (row(c, a, k, e, ix == p.active, query_text, w - 18)) picked = e;
            if (ix == p.active and p.reveal) reveal(c, id, wrap);
        }
        p.reveal = false;
        if (list.len == 0) {
            const empty = ui.div(c).column().wFull().py(24).px(16).gap(6).itemsCenter();
            defer empty.end();
            ui.text(c, "No results", .{ .size = 13, .line_height = 13 * phi, .color = k.text });
            ui.text(c, if (p.navigation == .chat_history) "Try a chat title, project, or device." else "Try a pane, command, chat title, project, or device.", .{ .size = 13, .line_height = 13 * phi, .color = k.muted });
        }
    }
    if (!history) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = hairline(k) }, .none, null);
        const f = ui.div(c).row().wFull().h(32).px(16).gap(12).itemsCenter();
        defer f.end();
        keyHint(c, k, "↑ ↓", "Navigate");
        keyHint(c, k, "↵", "Select");
        keyHint(c, k, "Esc", "Close");
    }
    if (picked) |e| activate(a, e);
}

/// Desktop's MENU_BLUR and composer_sidebar_tint, without Liquid Glass's
/// lens, rim or tone mapping. A plain translucent fill leaves text behind
/// the history card legible instead of blurring its backdrop.
fn frostedBackdrop(c: *ui.Context, k: theme.Colors) void {
    frostedBackdropInset(c, k, .{ .c = c, .index = 0 }, 0);
}

pub fn frostedBackdropInset(c: *ui.Context, k: theme.Colors, parent: ui.Div, inset: f32) void {
    const surfaces = @import("surface_palette.zig");
    const canvas = surfaces.flatten(k.shell, k.background);
    const target = if (k.shell.a < 1) surfaces.flatten(k.background.alpha(0.4), canvas) else k.background;
    const base = [_]f32{ canvas.r, canvas.g, canvas.b };
    const desired = [_]f32{ target.r, target.g, target.b };
    var alpha: f32 = 0.6;
    for (base, desired) |b, t| alpha = @max(alpha, if (t > b) (t - b) / @max(1 - b, std.math.floatEps(f32)) else (b - t) / @max(b, std.math.floatEps(f32)));
    var tint: [4]f32 = .{ 0, 0, 0, 0.15 };
    for (base, desired, 0..) |b, t, i| tint[i] = std.math.clamp((t - b * (1 - alpha)) / alpha, 0, 1);
    const pr = if (inset > 0) c.rects.get(c.node(parent.index).id) else null;
    if (inset > 0 and pr == null) c.changed = true;
    const cv = ui.canvas(c, .{
        .absolute = true,
        .offset = .{ .x = -inset, .y = -inset },
        .width = if (pr) |r| .{ .px = @max(0, r.w - 2) } else .fill,
        .height = if (pr) |r| .{ .px = @max(0, r.h - 2) } else .fill,
    });
    const w = if (pr) |r| @max(0, r.w - 2) else cv.size.w;
    const h = if (pr) |r| @max(0, r.h - 2) else cv.size.h;
    // Canvas exposes the renderer's Instance format (Kind.glass = 4).
    cv.shapes.append(c.alloc(), .{
        .rect = .{ 0, 0, w, h },
        .color = tint,
        .uv = .{ 0, 0, 1, 0 },
        .border_color = .{ 0, 1, 1, 1 },
        .border_width = 16,
        .radius = 15,
        .kind = 4,
    }) catch {};
}

fn historyRow(c: *ui.Context, a: *App, k: theme.Colors, e: Entry, selected: bool, query: []const u8, width: f32) bool {
    if (e != .chat) return false;
    const ch = a.findChat(e.chat) orelse return false;
    var row_ = ui.div(c).row().wFull().px(8).py(7).gap(10).itemsCenter().rounded(10);
    row_ = if (selected) row_.bg(if (k.is_harp) k.active else k.selected) else row_.hover(k.hover);
    defer row_.end();
    icons.icon(c, .@"chat-round-line", 16, k.muted, 0);
    {
        const text = ui.div(c).column().grow().w(0).gap(2);
        defer text.end();
        kit.highlightText(c, k, firstLine(ch.title orelse "New session"), .{ .size = 13, .line_height = 13 * phi, .color = if (selected or row_.hovered()) k.text else k.text.alpha(0.9) }, width - 112, query);
        const project = if (a.findSpace(ch.space_id)) |sp| sp.name else "No project";
        var time_buf: [32]u8 = undefined;
        const when = rules.relativeTime(&time_buf, a.nowMs(), ch.timeMs());
        kit.ellipsisText(c, c.print("{s} · {s}", .{ project, when }), .{ .size = 11, .line_height = 11 * phi, .color = k.muted }, width - 112);
    }
    var restore = false;
    var discard = false;
    {
        const actions = ui.div(c).row().gap(2);
        defer actions.end();
        for ([_]icons.Name{ .restart, .@"trash-bin-minimalistic" }, 0..) |glyph, ix| {
            ui.key(c, if (ix == 0) "history-restore" else "history-discard");
            const b = @import("view_tooltip.zig").on(ui.div(c).size(26, 26).center().rounded(6).hover(k.hover), k, .{ .text = if (ix == 0) "Restore conversation" else "Discard conversation" });
            defer b.end();
            icons.icon(c, glyph, 16, k.muted, 0);
            if (b.clicked()) {
                if (ix == 0) restore = true else discard = true;
            }
        }
    }
    if (discard) {
        close(a);
        @import("view_chat_menu.zig").deleteChat(a, ch.id);
        return false;
    }
    return restore or row_.clicked();
}

/// The highlighted row brought into the results' view (`scroll_to_item`),
/// from where it was last drawn.
fn reveal(c: *ui.Context, scroll_id: u64, d: ui.Div) void {
    const box = c.rects.get(scroll_id) orelse return;
    const r = c.rects.get(c.node(d.index).id) orelse return;
    const now = c.scroll.get(scroll_id) orelse 0;
    var to = now;
    if (r.y < box.y) to = now - (box.y - r.y) else if (r.y + r.h > box.y + box.h) to = now + (r.y + r.h - box.y - box.h);
    if (to != now) c.scroll.put(c.gpa, scroll_id, @max(0, to)) catch {};
}

/// The search: its glyph, the field at 14 points on the composer input's
/// 22.75-point line, and ⌘K's cap; 44 tall with its rule.
fn header(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const p = &a.view.palette;
    const h = ui.div(c).row().wFull().h(43).px(16).gap(10).itemsCenter();
    defer h.end();
    icons.icon(c, .@"palette-search", 16, k.muted, 16);
    {
        const f = ui.div(c).row().grow().w(0).itemsCenter();
        defer f.end();
        const splits = if (a.tabs.layout()) |s| s.panes.items.len > 1 else false;
        const placeholder = if (p.navigation == .chat_history) "Search chats across projects…" else if (splits) "Search open panes, commands and chats…" else "Search commands and chats…";
        ui.key(c, "command-palette-search");
        const at = c.nodes.items.len;
        const res = ui.textField(c, &p.query, .{ .placeholder = placeholder, .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .line_height = 22.75 });
        const id = c.node(@intCast(at)).id;
        // A modal search: the keys stay in it.
        if (p.focus or c.focus != id) {
            c.focus = id;
            c.changed = true;
            p.focus = false;
        }
        if (res.changed) {
            // Typing starts the highlight and the scroll over.
            p.active = 0;
            if (p.scroll_id != 0) c.scroll.put(c.gpa, p.scroll_id, 0) catch {};
        }
        // Plain Return arrives through NSTextInputClient, not the shortcut
        // path. Use the query after this event's edits, and rebuild now so
        // a theme change is painted without waiting for another input.
        if (res.submitted) {
            const list = entries(a, c.alloc(), queryOf(c, a)) catch return;
            if (list.len > 0) {
                activate(a, list[@min(p.active, list.len - 1)]);
                c.changed = true;
            }
        }
    }
    _ = w;
    if (p.navigation != .chat_history) {
        var buf: [32]u8 = undefined;
        kit.kbdHint(c, k, shortcuts.badge(&buf, "mod-k"));
    }
}

/// A legend entry: the key's cap and what it does (`command_key_hint`).
fn keyHint(c: *ui.Context, k: theme.Colors, keys_: []const u8, label: []const u8) void {
    const r = ui.div(c).row().gap(5).itemsCenter();
    defer r.end();
    kit.kbdHint(c, k, keys_);
    ui.text(c, label, .{ .size = 10, .line_height = 10 * phi, .color = k.muted });
}

/// One result, `inner` wide less its own sides; true when clicked.
fn row(c: *ui.Context, a: *App, k: theme.Colors, e: Entry, lit: bool, query: []const u8, inner: f32) bool {
    switch (e) {
        .chat => |id| {
            const ch = a.findChat(id) orelse return false;
            const project = if (a.findSpace(ch.space_id)) |sp| sp.name else if (ch.space_id == null) "~" else "?";
            const device = deviceOrEmpty(a, ch.device_id);
            const folder = if (device.len > 0) c.print("{s} @ {s}", .{ project, device }) else project;
            const branch: ?[]const u8 = if (a.settings.get(.sidebar_show_branch)) if (ch.branch) |b| (if (std.mem.trim(u8, b, " ").len > 0) std.mem.trim(u8, b, " ") else null) else null else null;
            const pr = @import("app_change_requests.zig").forChat(a, ch);
            const hit = sidebar.searchRow(c, a, k, ch, .{ .folder = folder, .lit = lit, .query = query, .inner = inner - 16, .branch = branch, .pr = if (pr) |x| .{ x[0], x[1] } else null });
            return hit.clicked;
        },
        else => {},
    }
    var r = ui.div(c).row().wFull().h(30).px(8).gap(10).itemsCenter().rounded(10);
    r = if (lit) r.bg(if (k.is_harp) k.active else k.selected) else r.hover(k.hover);
    defer r.end();
    const hot = lit or r.hovered();
    const tc = if (hot) k.text else k.text.alpha(0.9);
    const st: ui.TextStyle = .{ .size = 13, .line_height = 13 * phi, .color = tc };
    const room = inner - 16 - 16 - 10;
    switch (e) {
        .pane => |ix| {
            const l = paneLabel(a, ix);
            const s = a.tabs.layout();
            const glyph = if (s) |x| pal.paneGlyph(x.axis == .horizontal, ix, x.panes.items.len) else "▣";
            slot(c, k, glyph);
            const tail = c.text.width("Go to pane", .{ .size = 11 }) + 10;
            const proj_w = if (l.project.len > 0) @min(160, c.text.width(l.project, .{ .size = 12 })) + 10 else 0;
            {
                const t = ui.div(c).row().grow().w(0).clip();
                defer t.end();
                kit.highlightText(c, k, l.title, st, room - tail - proj_w, query);
            }
            if (l.project.len > 0) kit.ellipsisText(c, l.project, .{ .size = 12, .line_height = 12 * phi, .color = k.muted }, 160);
            ui.text(c, "Go to pane", .{ .size = 11, .line_height = 11 * phi, .color = k.muted.alpha(0.7) });
        },
        .import_all => {
            slot(c, k, "↓");
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.ellipsisText(c, c.print("Import {d} conversations from other tools", .{a.view.palette.external.items.len}), st, room);
        },
        .external => |i| {
            const x = a.view.palette.external.items[i];
            slot(c, k, "↓");
            const when = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, a.nowMs(), x.updated_ms);
            const folder = x.folder();
            const trailing = if (folder.len == 0) c.print("{s} · {s}", .{ x.sourceLabel(), when }) else c.print("{s} · {s} · {s}", .{ x.sourceLabel(), folder, when });
            const tst: ui.TextStyle = .{ .size = 11, .line_height = 11 * phi, .color = k.muted.alpha(0.7) };
            const tw = @min(260, c.text.width(trailing, tst));
            {
                const t = ui.div(c).row().grow().w(0).clip();
                defer t.end();
                kit.highlightText(c, k, firstLine(x.title), st, room - tw - 10, query);
            }
            kit.ellipsisText(c, trailing, tst, 260);
        },
        else => {
            const glyph: icons.Name = switch (e) {
                .new_chat => .@"pen-new-square",
                .new_project => .folder,
                .settings => .@"settings-minimalistic",
                .theme => |m| switch (m) {
                    .system => .monitor,
                    .light => .sun,
                    .dark => .moon,
                },
                .ui_mode => |m| switch (m) {
                    .zen => .@"magic-stick-3",
                    .developer => .terminal,
                },
                .toggle_part => .tuning,
                else => unreachable,
            };
            icons.icon(c, glyph, 16, k.muted, 0);
            var buf: [32]u8 = undefined;
            const hint: ?[]const u8 = switch (e) {
                .new_chat => shortcuts.badge(&buf, comboFor(a, "newSession")),
                .new_project => shortcuts.badge(&buf, comboFor(a, "newProject")),
                .settings => shortcuts.badge(&buf, "mod-,"),
                .ui_mode => shortcuts.badge(&buf, "mod-shift-m"),
                else => null,
            };
            {
                const t = ui.div(c).row().grow().w(0);
                defer t.end();
                kit.highlightText(c, k, e.label().?, st, room, query);
            }
            if (hint) |h| kit.kbdHint(c, k, h);
        },
    }
    if (r.hovered()) c.cursor_hand = true;
    return r.clicked();
}

/// A shortcut's combination as the keymap has it, its default when unset.
fn comboFor(a: *const App, key: []const u8) []const u8 {
    for (shortcuts.all) |sc| if (std.mem.eql(u8, sc.key, key)) {
        const combo = a.settings.combo(sc);
        return if (combo.len > 0) combo else sc.default;
    };
    return "";
}

/// A 16-point slot holding a glyph in the muted text.
fn slot(c: *ui.Context, k: theme.Colors, glyph: []const u8) void {
    const s = ui.div(c).row().w(16).center();
    defer s.end();
    ui.text(c, glyph, .{ .size = 13, .line_height = 13 * phi, .color = k.muted });
}

// Other tools' conversations.

/// Asks the engine which conversations other tools kept on this device
/// (`load_external_sessions`).
fn loadExternal(a: *App) void {
    if (a.engine.state != .connected) return;
    a.call("ExternalHistoryList", .{ .limit = 400 }, .of(App, a, onExternal));
}

fn onExternal(a: *App, _: u64, r: rpc.Reply) void {
    if (r != .ok) return;
    setExternal(a, r.ok) catch return;
    a.view.palette.external_loaded_ms = a.nowMs();
    a.redraw();
}

/// Keeps the engine's list (`ExternalSession` rows), copied.
pub fn setExternal(a: *App, v: std.json.Value) !void {
    if (v != .array) return error.Shape;
    const p = &a.view.palette;
    if (p.external_arena) |*x| x.deinit();
    p.external_arena = .init(a.gpa);
    const arena = p.external_arena.?.allocator();
    p.external.clearRetainingCapacity();
    for (v.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const str = struct {
            fn f(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
                const x = obj.get(key) orelse return null;
                return if (x == .string) x.string else null;
            }
        }.f;
        const source = str(o, "source") orelse continue;
        const id = str(o, "id") orelse continue;
        const updated: i64 = if (o.get("updatedAt")) |x| switch (x) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => 0,
        } else 0;
        try p.external.append(a.gpa, .{
            .source = try arena.dupe(u8, source),
            .id = try arena.dupe(u8, id),
            .cwd = if (str(o, "cwd")) |x| try arena.dupe(u8, x) else null,
            .title = try arena.dupe(u8, str(o, "title") orelse ""),
            .updated_ms = updated,
        });
    }
}

const Pick = struct { source: []const u8, id: []const u8 };

/// Imports the named conversations, then opens the first; or, with none
/// named, every one (`import_external`).
fn importExternal(a: *App, picks: ?[]const Pick) void {
    if (a.engine.state != .connected) return;
    a.view.palette.importing_all = picks == null;
    if (picks) |list| {
        a.call("ExternalHistoryImport", .{ .sessions = list }, .of(App, a, onImported));
    } else {
        a.setNotice("Importing conversations from other tools…");
        a.call("ExternalHistoryImport", .{}, .of(App, a, onImported));
    }
}

fn onImported(a: *App, _: u64, r: rpc.Reply) void {
    const p = &a.view.palette;
    const all = p.importing_all;
    var buf: [256]u8 = undefined;
    if (r == .err) {
        a.setNotice(std.fmt.bufPrint(&buf, "Import failed: {s}", .{r.err}) catch "Import failed");
        return a.redraw();
    }
    if (r != .ok) return;
    const v = r.ok;
    const ids: []const std.json.Value = if (v == .object) if (v.object.get("chatIds")) |x| (if (x == .array) x.array.items else &.{}) else &.{} else &.{};
    const errors: usize = if (v == .object) if (v.object.get("errors")) |x| (if (x == .array) x.array.items.len else 0) else 0 else 0;
    // Imported ones are in the sidebar now: no longer offered.
    var i: usize = 0;
    while (i < p.external.items.len) {
        const x = p.external.items[i];
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "ext-{s}-{s}", .{ x.source, x.id }) catch "";
        const gone = for (ids) |id| {
            if (id == .string and std.mem.eql(u8, id.string, name)) break true;
        } else false;
        if (gone) _ = p.external.orderedRemove(i) else i += 1;
    }
    if (all) {
        const n = ids.len;
        a.setNotice(if (n == 0 and errors == 0)
            "Nothing new to import"
        else if (errors == 0)
            std.fmt.bufPrint(&buf, "Imported {d} conversations", .{n}) catch ""
        else
            std.fmt.bufPrint(&buf, "Imported {d} conversations; {d} could not be read", .{ n, errors }) catch "");
    } else if (ids.len > 0 and ids[0] == .string) {
        a.openChat(ids[0].string, null);
    } else a.setNotice("That conversation could not be imported");
    a.redraw();
}
