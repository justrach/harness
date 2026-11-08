//! All sessions is a workspace overview, not another project/chat list.
//! Outer Nano tabs own independent layouts; panel tabs stay inside their
//! workspace. Summaries come from actual registry previews, never invented
//! progress. The registry does not carry desktop's plan/question payloads.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const workspace = @import("workspace.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const tip = @import("view_tooltip.zig");

pub const State = struct {
    open: bool = false,
    active: usize = 0,
    keyboard: bool = false,
};

pub const Section = enum {
    needs,
    working,
    done,
    earlier,

    pub fn label(s: Section) []const u8 {
        return switch (s) {
            .needs => "Needs you",
            .working => "Working",
            .done => "Done",
            .earlier => "Earlier",
        };
    }
};

pub fn priority(mark: workspace.Mark) u8 {
    return switch (mark) {
        .awaiting_input => 0,
        .errored => 1,
        .working => 2,
        .completed => 3,
        .idle => 4,
    };
}

pub fn section(mark: workspace.Mark) Section {
    return switch (mark) {
        .awaiting_input, .errored => .needs,
        .working => .working,
        .completed => .done,
        .idle => .earlier,
    };
}

pub fn columns(width: f32) usize {
    return if (width >= 1000) 3 else if (width >= 700) 2 else 1;
}

pub fn cardWidth(width: f32) f32 {
    const n: f32 = @floatFromInt(columns(width));
    return @max(0, @floor((width - 64 - 20 * (n - 1)) / n));
}

pub const Session = struct {
    index: usize,
    title: []const u8 = "Scratchpad",
    project: ?[]const u8 = null,
    chat: ?[]const u8 = null,
    summary: []const u8 = "",
    mark: workspace.Mark = .idle,
    panels: usize = 1,
    tabs: usize = 1,
    updated: i64 = 0,
    needs: usize = 0,
    working: usize = 0,
    done: usize = 0,

    fn include(s: *Session, a: *const App, id: ?[]const u8) void {
        const ch = a.findChat(id orelse return) orelse return;
        const mark = workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), a.nowMs());
        switch (mark) {
            .awaiting_input, .errored => s.needs += 1,
            .working => s.working += 1,
            .completed => s.done += 1,
            .idle => {},
        }
        s.updated = @max(s.updated, ch.timeMs());
        // Prefer the thread needing attention; ties retain panel/tab order.
        if (s.chat == null or priority(mark) < priority(s.mark)) {
            s.chat = ch.id;
            s.mark = mark;
            s.summary = ch.preview orelse "";
            if (a.findSpace(ch.space_id)) |sp| {
                s.title = sp.name;
                s.project = sp.name;
            } else {
                s.title = "Scratchpad";
                s.project = null;
            }
        }
    }
};

/// Exactly one result per independent workspace, including unsent drafts.
/// Never group by project: two workspaces in one folder are still two cards.
pub fn sessions(a: *const App, gpa: std.mem.Allocator) ![]Session {
    const out = try gpa.alloc(Session, a.tabs.items.items.len);
    for (a.tabs.items.items, 0..) |chat, index| {
        var s: Session = .{ .index = index };
        if (a.tabs.splits.items[index]) |split| {
            s.panels = split.panes.items.len;
            s.tabs = 0;
            for (split.panes.items, 0..) |pane, ix| {
                s.include(a, if (ix == split.focus) chat else pane);
                const group = split.groups[ix];
                s.tabs += group.count();
                for (group.items.items, 0..) |tab, ti| {
                    if (ti != group.active) s.include(a, tab.chat);
                }
            }
        } else s.include(a, chat);
        if (s.chat == null) {
            const space_id = if (index == a.tabs.active)
                (if (a.newChatSpace()) |sp| sp.id else null)
            else if (a.tabs.drafts.items[index]) |draft|
                (if (draft.no_project) null else draft.space)
            else
                null;
            if (a.findSpace(space_id)) |sp| {
                s.title = sp.name;
                s.project = sp.name;
            }
        }
        out[index] = s;
    }
    std.sort.insertion(Session, out, {}, struct {
        fn lt(_: void, x: Session, y: Session) bool {
            const xs = @backingInt(section(x.mark));
            const ys = @backingInt(section(y.mark));
            return if (xs != ys) xs < ys else if (xs == @backingInt(Section.earlier) and x.updated != y.updated) x.updated > y.updated else x.index < y.index;
        }
    }.lt);
    return out;
}

pub fn open(a: *App) void {
    if (a.view.settings_open) return;
    @import("view_sidebar_menus.zig").close(a);
    @import("view_sidebar_search.zig").close(a);
    a.view.strip.menu = null;
    a.view.account_menu = false;
    a.picker = .none;
    a.view.menus.overview = .{ .open = true };
    a.view.focus_composer = false;
    a.redraw();
}

pub fn close(a: *App) void {
    if (!a.view.menus.overview.open) return;
    a.view.menus.overview.open = false;
    a.view.focus_composer = true;
    a.redraw();
}

fn activate(a: *App, s: Session) void {
    close(a);
    a.showTab(s.index);
    if (s.chat) |id| a.openChatInTab(id);
    a.redraw();
}

pub fn keys(c: *ui.Context, a: *App) void {
    const s = &a.view.menus.overview;
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) return close(a);
    const list = sessions(a, c.alloc()) catch return;
    if (list.len == 0) return;
    s.active = @min(s.active, list.len - 1);
    const right = c.shortcut(.{ .key = ui.Shortcut.right });
    const left = c.shortcut(.{ .key = ui.Shortcut.left });
    const down = c.shortcut(.{ .key = ui.Shortcut.down });
    const up = c.shortcut(.{ .key = ui.Shortcut.up });
    if (right or left or down or up) s.keyboard = true;
    const step = if (down or up) columns(c.size.w) else @as(usize, 1);
    if (right or down) s.active = @min(s.active + step, list.len - 1);
    if (left or up) s.active -|= step;
    if (c.shortcut(.{ .key = ui.Shortcut.enter })) {
        if (s.keyboard) activate(a, list[s.active]) else close(a);
    }
}

pub fn historyButton(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.key(c, "chat-history");
    const b = tip.on(ui.div(c).row().size(26, 26).center().rounded(6).hover(k.hover), k, .{ .text = "Chat history", .delay = tip.quick });
    defer b.end();
    icons.icon(c, .@"clock-circle", 16, k.muted, 0);
    if (b.clicked()) @import("view_palette.zig").toggle(a, .chat_history);
}

fn statusColor(k: theme.Colors, mark: workspace.Mark) ui.Color {
    return switch (mark) {
        .awaiting_input => k.warning,
        .errored => k.danger,
        .working => k.accent,
        .completed => k.success,
        .idle => k.muted,
    };
}

fn statusIcon(mark: workspace.Mark) icons.Name {
    return switch (mark) {
        .awaiting_input => .bell,
        .errored => .@"danger-triangle",
        .working => .refresh,
        .completed => .check,
        .idle => .@"clock-circle",
    };
}

/// A real route: the underlying composer is unmounted, so typing cannot
/// alter a hidden draft. Palette history remains a separate modal above it.
pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const list = sessions(a, c.alloc()) catch return;
    const state = &a.view.menus.overview;
    state.active = @min(state.active, list.len -| 1);
    ui.key(c, "all-sessions");
    const root = ui.div(c).column().sizeFull().bg(k.shell);
    defer root.end();
    header(c, a, k, list);
    ui.key(c, "all-sessions-scroll");
    ui.scroll(c, .{ .width = .fill, .grow = 1, .padding = .{ .left = 32, .right = 32, .top = 22, .bottom = 32 }, .gap = 26 });
    defer ui.end(c);
    for ([_]Section{ .needs, .working, .done, .earlier }) |group| {
        var count: usize = 0;
        for (list) |s| if (section(s.mark) == group) {
            count += 1;
        };
        if (count == 0) continue;
        ui.key(c, group.label());
        const block = ui.div(c).column().wFull().gap(10);
        defer block.end();
        {
            const heading = ui.div(c).row().px(3).gap(6).itemsCenter();
            defer heading.end();
            ui.text(c, group.label(), .{ .size = 12, .weight = theme.ui_medium_weight, .color = if (group == .needs) k.warning else k.muted });
            ui.text(c, c.print("{d}", .{count}), .{ .size = 12, .color = k.muted.alpha(0.7) });
        }
        if (group == .earlier) {
            const rows = ui.div(c).column().wFull().p(4).rounded(12).bg(k.pill());
            defer rows.end();
            for (list, 0..) |s, ix| if (section(s.mark) == group) earlier(c, a, k, s, ix);
        } else {
            const grid = ui.div(c).column().wFull().gap(20);
            defer grid.end();
            var col: usize = 0;
            var row: ?ui.Div = null;
            for (list, 0..) |s, ix| if (section(s.mark) == group) {
                if (col == 0) row = ui.div(c).row().wFull().gap(20);
                card(c, a, k, s, ix, cardWidth(c.size.w));
                col += 1;
                if (col == columns(c.size.w)) {
                    row.?.end();
                    row = null;
                    col = 0;
                }
            };
            if (row) |r| r.end();
        }
    }
}

fn header(c: *ui.Context, a: *App, k: theme.Colors, list: []const Session) void {
    const inset: f32 = if (@import("builtin").os.tag == .macos) 88 else 12;
    const row = ui.div(c).row().wFull().h(42).pl(inset).pr(10).gap(4).itemsCenter();
    defer row.end();
    {
        ui.key(c, "all-sessions-back");
        const back = tip.on(ui.div(c).row().h(28).px(8).gap(6).itemsCenter().rounded(6).hover(k.hover), k, .{ .text = "Back to session · Esc" });
        defer back.end();
        icons.icon(c, .@"arrow-left", 14, k.muted, 0);
        ui.text(c, "All sessions", .{ .size = 12, .color = k.muted });
        if (back.clicked()) close(a);
    }
    historyButton(c, a, k);
    ui.spacer(c);
    // Centered independently of the unequal controls on either side.
    {
        const center = ui.div(c).absolute().offset(@max(0, (c.size.w - 300) / 2) - inset, 0).size(300, 42).center();
        defer center.end();
        const summary = ui.div(c).row().h(26).px(12).gap(14).rounded(13).bg(k.hover.alpha(0.6)).itemsCenter();
        defer summary.end();
        var needs: usize = 0;
        var working: usize = 0;
        var done: usize = 0;
        for (list) |s| {
            needs += s.needs;
            working += s.working;
            done += s.done;
        }
        if (needs + working + done == 0) ui.text(c, "No tasks running", .{ .size = 11, .color = k.muted });
        const counts = [_]usize{ needs, working, done };
        const labels = [_][]const u8{ if (needs == 1) "needs you" else "need you", "working", "done" };
        const colors = [_]ui.Color{ k.warning, k.accent, k.muted };
        for (counts, labels, colors) |n, label, color| if (n > 0) {
            const item = ui.div(c).row().gap(6).itemsCenter();
            defer item.end();
            ui.div(c).size(5, 5).roundedFull().bg(color).end();
            ui.text(c, if (c.size.w >= 640) c.print("{d} {s}", .{ n, label }) else c.print("{d}", .{n}), .{ .size = 11, .color = k.muted });
        };
    }
    ui.key(c, "all-sessions-new");
    const add = tip.on(ui.div(c).row().h(28).px(8).gap(6).itemsCenter().rounded(6).hover(k.hover), k, .{ .text = "New session" });
    defer add.end();
    icons.icon(c, .plus, 14, k.muted, 0);
    if (c.size.w >= 640) ui.text(c, "New session", .{ .size = 12, .color = k.muted });
    if (add.clicked()) {
        close(a);
        a.newWorkspaceSession();
    }
}

fn card(c: *ui.Context, a: *App, k: theme.Colors, s: Session, ix: usize, width: f32) void {
    ui.key(c, c.print("overview-session-{d}", .{s.index}));
    const col = ui.div(c).column().w(width).gap(8);
    defer col.end();
    {
        const heading = ui.div(c).row().wFull().h(22).px(3).gap(8).itemsCenter().rounded(4).hover(k.hover);
        defer heading.end();
        icons.icon(c, statusIcon(s.mark), 14, statusColor(k, s.mark), 0);
        kit.ellipsisText(c, s.title, .{ .size = 13, .weight = theme.ui_medium_weight, .color = k.text }, @max(0, width - 30));
        if (heading.clicked()) activate(a, s);
    }
    {
        var sheet = kit.shadowLg(ui.div(c).column().wFull().p(16).gap(8).rounded(12).bg(k.pill()).hover(k.hover));
        c.node(sheet.index).style.min_height = if (section(s.mark) == .needs) 148 else 104;
        if (a.view.menus.overview.keyboard and ix == a.view.menus.overview.active) sheet = sheet.border(k.accent.alpha(0.55)).borderW(1);
        defer sheet.end();
        if (s.chat) |id| if (a.findChat(id)) |ch| {
            kit.ellipsisText(c, @import("view_sidebar.zig").chatLabel(ch), .{ .size = 13, .weight = theme.ui_medium_weight, .color = k.text }, @max(0, width - 32));
        };
        if (s.summary.len > 0) ui.text(c, s.summary, .{ .size = 12, .line_height = 18, .color = k.muted, .wrap = true });
        if (s.mark == .errored) ui.text(c, "Needs attention", .{ .size = 12, .color = k.danger });
        if (sheet.clicked()) activate(a, s);
    }
    metadata(c, k, s, width);
}

fn metadata(c: *ui.Context, k: theme.Colors, s: Session, width: f32) void {
    const row = ui.div(c).row().wFull().px(3).gap(6).itemsCenter();
    defer row.end();
    if (s.project) |project| kit.ellipsisText(c, project, .{ .size = 11, .color = k.muted }, @max(0, width - (if (s.panels > 1 or s.tabs > 1) @as(f32, 140) else 6)));
    if (s.panels > 1 or s.tabs > 1) {
        ui.spacer(c);
        ui.text(c, c.print("{d} {s} · {d} {s}", .{ s.panels, if (s.panels == 1) @as([]const u8, "panel") else "panels", s.tabs, if (s.tabs == 1) @as([]const u8, "tab") else "tabs" }), .{ .size = 11, .color = k.muted });
    }
}

fn earlier(c: *ui.Context, a: *App, k: theme.Colors, s: Session, ix: usize) void {
    ui.key(c, c.print("overview-earlier-{d}", .{s.index}));
    var row = ui.div(c).row().wFull().h(36).px(12).gap(14).itemsCenter().rounded(8).hover(k.hover.alpha(0.6));
    if (a.view.menus.overview.keyboard and ix == a.view.menus.overview.active) row = row.bg(k.hover);
    defer row.end();
    const chat = if (s.chat) |id| a.findChat(id) else null;
    const title = if (chat) |ch| ch.title orelse "New session" else "New session";
    const width = @max(0, c.size.w - 64);
    const wide = width >= 760;
    const title_width = @max(0, (width - 32) * 0.32);
    {
        var name = ui.div(c).row().w(title_width).clip();
        if (!wide) name = name.w(0).grow();
        defer name.end();
        kit.ellipsisText(c, title, .{ .size = 13, .color = k.text }, title_width);
    }
    if (wide) {
        const activity = ui.div(c).row().grow().w(0).clip();
        defer activity.end();
        const project_width = if (s.project) |project| @min(@ceil(c.text.width(project, .{ .size = 11 })), 160) else 0;
        kit.ellipsisText(c, if (s.summary.len > 0) s.summary else "No activity yet.", .{ .size = 13, .color = k.muted }, @max(0, width - 32 - title_width - 58 - 42 - project_width));
    }
    if (s.project) |project| kit.ellipsisText(c, project, .{ .size = 11, .color = k.muted }, 160);
    {
        const age = ui.div(c).row().w(58).justifyEnd();
        defer age.end();
        if (chat) |ch| {
            var buf: [32]u8 = undefined;
            ui.text(c, @import("rules.zig").relativeTime(&buf, a.nowMs(), ch.timeMs()), .{ .size = 11, .color = k.muted });
        }
    }
    if (row.clicked()) activate(a, s);
}
