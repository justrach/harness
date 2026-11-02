//! The sidebar header's two menus, as the GPUI app's (shell/spaces.rs):
//! the project filter's (`render_spaces_menu`: a search, All projects and
//! each project with its device, New project pinned under them) and the
//! view options' (`render_sidebar_view_menu`: Organize, Sort and Show, each
//! a menu of its own beside it, and Compact).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const settings = @import("settings.zig");
const workspace = @import("workspace.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;
const S = ui.Shortcut;

const phi: f32 = 1.618;
/// `popover::CARD_INSET`, and the card's 1-point border inside it.
const inset: f32 = 4;

/// What the open menus remember between frames.
pub const State = struct {
    query: ui.TextBuffer = .{},
    /// The project menu's highlighted row: its rows, then New project.
    active: usize = 0,
    focus: bool = false,
    /// The view menu's group under the pointer or keys, and the one whose
    /// menu is open beside it (Organize, Sort, Show; 3 is Compact).
    group: ?usize = null,
    open: ?usize = null,
    sub_active: ?usize = null,
    /// The project menu's height as last drawn.
    h: ?f32 = null,
    /// A project's own menu (right-clicked in the list): whose, and where.
    ctx_id: std.ArrayList(u8) = .empty,
    ctx_at: ?ui.Point = null,
    ctx_h: ?f32 = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.ctx_id.deinit(gpa);
    }
};

pub fn openProjects(a: *App) void {
    const v = &a.view;
    v.more_menu = false;
    v.filter_menu = true;
    v.menus.query.clear();
    v.menus.focus = true;
    // The highlight starts on the filter's own row.
    v.menus.active = 0;
    const rows = projectRows(a, a.gpa) catch return;
    defer a.gpa.free(rows);
    for (rows, 0..) |r, i| if (sameFilter(a, r)) {
        v.menus.active = i;
    };
}

pub fn openView(a: *App) void {
    const v = &a.view;
    v.filter_menu = false;
    v.more_menu = true;
    v.menus.group = null;
    v.menus.open = null;
    v.menus.sub_active = null;
}

pub fn close(a: *App) void {
    a.view.menus.ctx_at = null;
    a.view.filter_menu = false;
    a.view.more_menu = false;
    a.view.menus.open = null;
}

pub fn anyOpen(a: *const App) bool {
    return a.view.filter_menu or a.view.more_menu;
}

/// The keys an open menu takes first: Escape, arrows, Return.
pub fn keys(c: *ui.Context, a: *App) void {
    if (a.view.filter_menu) {
        if (c.shortcut(.{ .key = S.escape })) return close(a);
        // A project's own menu takes no keys (`space_menu`): Escape aside.
        if (a.view.menus.ctx_at != null) return;
        const rows = projectRows(a, c.alloc()) catch return;
        const m = &a.view.menus;
        if (c.shortcut(.{ .key = S.down })) m.active = rules.menuStep(m.active, rows.len + 1, 1) orelse 0;
        if (c.shortcut(.{ .key = S.up })) m.active = rules.menuStep(m.active, rows.len + 1, -1) orelse 0;
        if (c.shortcut(.{ .key = S.enter }) or c.shortcut(.{ .key = S.enter, .cmd = true }))
            activate(a, if (m.active < rows.len) rows[m.active] else .add);
    } else if (a.view.more_menu) {
        const m = &a.view.menus;
        if (c.shortcut(.{ .key = S.escape })) {
            if (m.open != null) {
                m.open = null;
                m.sub_active = null;
            } else close(a);
            return;
        }
        if (m.open) |g| {
            const n = groups[g].rows.len;
            if (c.shortcut(.{ .key = S.down })) m.sub_active = rules.menuStep(m.sub_active, n, 1);
            if (c.shortcut(.{ .key = S.up })) m.sub_active = rules.menuStep(m.sub_active, n, -1);
            if (c.shortcut(.{ .key = S.left })) {
                m.open = null;
                m.sub_active = null;
            }
            if (c.shortcut(.{ .key = S.enter })) if (m.sub_active) |i| choose(a, groups[g].rows[i]);
            return;
        }
        if (c.shortcut(.{ .key = S.down })) m.group = rules.menuStep(m.group, groups.len + 1, 1);
        if (c.shortcut(.{ .key = S.up })) m.group = rules.menuStep(m.group, groups.len + 1, -1);
        if (m.group) |g| {
            if (g == groups.len) {
                if (c.shortcut(.{ .key = S.enter }) or c.shortcut(.{ .key = ' ' })) a.settings.toggle(.sidebar_compact);
            } else if (c.shortcut(.{ .key = S.right }) or c.shortcut(.{ .key = S.enter })) {
                m.open = g;
                m.sub_active = 0;
            }
        }
    }
}

pub fn menus(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!anyOpen(a)) return;
    {
        // A press anywhere else closes them (`on_mouse_down_out`); their
        // triggers toggle them themselves.
        const trigger = if (a.view.filter_menu) a.view.filter_anchor else if (a.view.more_menu) a.view.more_anchor else null;
        if (kit.pressedOutside(c, trigger)) return close(a);
    }
    if (a.view.filter_menu) if (a.view.filter_anchor) |r| projects(c, a, k, r);
    if (a.view.filter_menu and a.view.menus.ctx_at != null) spaceMenu(c, a, k);
    if (a.view.more_menu) if (a.view.more_anchor) |r| view(c, a, k, r);
}

// The project menu.

pub const Row = union(enum) {
    all,
    space: []const u8,
    add,
};

fn sameFilter(a: *const App, r: Row) bool {
    return switch (r) {
        .all => a.view.filter == null,
        .space => |id| a.view.filter != null and std.mem.eql(u8, a.view.filter.?, id),
        .add => false,
    };
}

/// The rows under the search (`spaces_menu_rows`): All projects while it's
/// empty, then the projects it finds, best first, those on a device that's
/// online before those away.
pub fn projectRows(a: *const App, gpa: std.mem.Allocator) ![]Row {
    const q = a.view.menus.query.text();
    const Ranked = struct { rank: u8, ix: usize, online: bool };
    var found: std.ArrayList(Ranked) = .empty;
    defer found.deinit(gpa);
    const spaces = try sortedSpaces(a, gpa);
    defer gpa.free(spaces);
    const now = a.nowMs();
    for (spaces, 0..) |s, ix| if (rules.matchRank(q, s.name)) |rank|
        try found.append(gpa, .{ .rank = rank, .ix = ix, .online = online(a, s.device_id, now) });
    // Insertion, stable like std.mem.sort: a person's projects are tens, and
    // each std.mem.sort type costs the binary 12-25 KB.
    std.sort.insertion(Ranked, found.items, {}, struct {
        fn lt(_: void, x: Ranked, y: Ranked) bool {
            return if (x.rank != y.rank) x.rank < y.rank else x.ix < y.ix;
        }
    }.lt);
    var rows: std.ArrayList(Row) = .empty;
    if (std.mem.trim(u8, q, " \t").len == 0) try rows.append(gpa, .all);
    for ([_]bool{ true, false }) |want| for (found.items) |f| if (f.online == want)
        try rows.append(gpa, .{ .space = spaces[f.ix].id });
    return rows.toOwnedSlice(gpa);
}

/// By name, case aside, then id (`spaces_sorted`).
fn sortedSpaces(a: *const App, gpa: std.mem.Allocator) ![]workspace.Space {
    const out = try gpa.dupe(workspace.Space, a.spaces.items);
    std.sort.insertion(workspace.Space, out, {}, struct {
        fn lt(_: void, x: workspace.Space, y: workspace.Space) bool {
            const o = std.ascii.orderIgnoreCase(x.name, y.name);
            return if (o != .eq) o == .lt else std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);
    return out;
}

/// This device, one the workspace doesn't list, or one heard from lately
/// (`device_online`).
pub fn online(a: *const App, device: ?[]const u8, now: i64) bool {
    const id = device orelse return true;
    if (a.device_id) |me| if (std.mem.eql(u8, me, id)) return true;
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, id))
        return @import("view_settings_devices.zig").online(d.last_seen_ms, now);
    return true;
}

fn activate(a: *App, r: Row) void {
    switch (r) {
        .all => a.setSpaceFilter(null),
        .space => |id| a.setSpaceFilter(id),
        .add => {
            close(a);
            a.addFolder();
        },
    }
    close(a);
}

fn projects(c: *ui.Context, a: *App, k: theme.Colors, r: ui.Rect) void {
    const m = &a.view.menus;
    // Under the trigger, 6 below, across the header row (`anchored_menu_below`).
    const w = sidebar.width - 2 * 8;
    const h = m.h orelse 160;
    const x = rules.snapToWindow(r.x, w, c.size.w, 8);
    const y = rules.snapToWindow(r.y + r.h + 6, h, c.size.h, 8);
    ui.key(c, "spaces-menu");
    const card = card_(c, k, x, y, w);
    defer card.end();
    if (c.rects.get(c.node(card.index).id)) |cr| m.h = cr.h;
    {
        // `search_input_frame`: no icon, no border.
        // 6 above and below, 2 of them the bare field's own; the composer
        // input's own 22.75-point line (`composer.rs`).
        const f = ui.div(c).row().wFull().px(10).py(4).rounded(7).bg(k.ink(0.04));
        defer f.end();
        const at = c.nodes.items.len;
        const res = ui.textField(c, &m.query, .{ .placeholder = "Search projects…", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 13, .line_height = 22.75 });
        if (m.focus) {
            c.focus = c.node(@intCast(at)).id;
            c.changed = true;
            m.focus = false;
        }
        // Typing starts the highlight over.
        if (res.changed) m.active = 0;
    }
    _ = c.leaf(.{ .height = .{ .px = 4 - 2 } }, .none, null);
    const rows = projectRows(a, c.alloc()) catch return;
    var picked: ?Row = null;
    {
        var list_style: ui.Style = .{ .width = .fill, .max_height = 224, .direction = .column, .gap = 2 };
        if (@hasField(ui.Style, "scrollbar")) list_style.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
        ui.scroll(c, list_style);
        defer ui.end(c);
        const now = a.nowMs();
        // The away devices' caption, once, unless they start the list.
        var caption_at: ?usize = null;
        for (rows, 0..) |row, i| if (row == .space) if (a.findSpace(row.space)) |s| if (!online(a, s.device_id, now)) {
            if (i > 0) caption_at = i;
            break;
        };
        for (rows, 0..) |row, i| {
            if (caption_at == i) {
                const cap = ui.div(c).row().wFull().px(8).pt(8).pb(2);
                defer cap.end();
                ui.text(c, "Offline", .{ .size = 10, .line_height = 10 * phi, .color = k.muted });
            }
            ui.key(c, c.print("spaces-menu-row-{d}", .{i}));
            const selected = sameFilter(a, row);
            const it = menuRow(c, k, selected, i == m.active);
            defer it.end();
            if (it.clicked()) picked = row;
            // A project's own menu, where it's right-clicked.
            if (row == .space and kit.secondaryClicked(it)) {
                m.ctx_id.clearRetainingCapacity();
                m.ctx_id.appendSlice(a.gpa, row.space) catch {};
                m.ctx_at = c.input.mouse;
            }
            switch (row) {
                .all => labelWeight(c, k, "All projects", it.hovered() or selected or i == m.active, .medium),
                .space => |id| if (a.findSpace(id)) |s| {
                    const tag = c.print("@ {s}", .{a.deviceName(s.device_id)});
                    const tag_w = @min(c.text.width(tag, .{ .size = 10, .weight = .medium }), (w - 2 * (inset + 1) - 16) / 2);
                    const off = !online(a, s.device_id, now);
                    const name_w = w - 2 * (inset + 1) - 16 - 10 - tag_w - (if (off) @as(f32, 22) else 0);
                    {
                        const t = ui.div(c).row().grow().w(0).clip();
                        defer t.end();
                        kit.ellipsisText(c, s.name, .{ .size = 13, .line_height = 13 * phi, .weight = .medium, .color = if (it.hovered() or selected or i == m.active) k.text else k.text.alpha(0.9) }, name_w);
                    }
                    kit.ellipsisText(c, tag, .{ .size = 10, .line_height = 10 * phi, .weight = .medium, .color = k.muted }, tag_w + 1);
                    if (off) icons.icon(c, .@"wifi-off", 12, k.warning.alpha(0.8), 0);
                },
                .add => {},
            }
        }
    }
    // Full-bleed through the card's inset.
    {
        const d = ui.div(c).column().wFull().py(2);
        defer d.end();
        _ = c.leaf(.{ .width = .{ .px = w - 2 }, .height = .{ .px = 1 }, .background = k.border.alpha(0.6), .offset = .{ .x = -inset } }, .none, null);
    }
    {
        ui.key(c, "spaces-menu-add");
        const it = menuRow(c, k, false, m.active == rows.len);
        defer it.end();
        if (it.clicked()) picked = .add;
        icons.icon(c, .plus, 12, k.muted, 0);
        labelWeight(c, k, "New project", it.hovered() or m.active == rows.len, .medium);
    }
    if (picked) |p| activate(a, p);
}

/// A project's menu (`space_menu`): Rename… and Remove…, 170 wide at the
/// pointer, over the project menu; a press outside it closes it alone.
fn spaceMenu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const m = &a.view.menus;
    const at = m.ctx_at orelse return;
    const space = a.findSpace(m.ctx_id.items) orelse {
        m.ctx_at = null;
        return;
    };
    {
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(6);
        defer back.end();
        if (back.clicked() or kit.secondaryClicked(back)) {
            m.ctx_at = null;
            return;
        }
    }
    const w: f32 = 170;
    const h = m.ctx_h orelse 90;
    const x = rules.snapToWindow(at.x, w, c.size.w, 8);
    const y = rules.snapToWindow(at.y, h, c.size.h, 8);
    // No gap between its rows (`.flex_col()` only).
    const card = held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(7).column().p(inset + 1)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer card.end();
    kit.rememberHeight(c, card, &m.ctx_h);
    const chat_menu = @import("view_chat_menu.zig");
    {
        ui.key(c, "space-menu-rename");
        const it = menuRow(c, k, false, false);
        defer it.end();
        icons.icon(c, .pen, 16, k.muted, 0);
        label(c, k, "Rename…", it.hovered());
        if (it.clicked()) {
            m.ctx_at = null;
            return chat_menu.renameSpace(a, space);
        }
    }
    separator(c, k, w);
    {
        ui.key(c, "space-menu-delete");
        const it = menuRow(c, k, false, false);
        defer it.end();
        icons.icon(c, .@"trash-bin-minimalistic", 16, k.danger, 0);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            ui.text(c, "Remove…", .{ .size = 13, .line_height = 13 * phi, .color = k.danger });
        }
        if (it.clicked()) {
            m.ctx_at = null;
            return chat_menu.removeSpace(a, space.id);
        }
    }
}

/// `popover_card`: bordered, 12 round, the inset all round, 2 between rows.
fn card_(c: *ui.Context, k: theme.Colors, x: f32, y: f32, w: f32) ui.Div {
    return held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(inset + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
}

/// A press on a card (its inset, a separator) stays in it: only one
/// outside closes the menu (`on_mouse_down_out`).
pub fn held(d: ui.Div) ui.Div {
    _ = d.interaction();
    kit.noteCard(d.c, d);
    return d;
}

/// `menu_row_nav`: selected or under the keys, the selected wash.
fn menuRow(c: *ui.Context, k: theme.Colors, selected: bool, highlighted: bool) ui.Div {
    var r = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7);
    r = if (selected or highlighted) r.bg(k.selected) else r.hover(k.selected);
    return r;
}

fn label(c: *ui.Context, k: theme.Colors, text: []const u8, lit: bool) void {
    labelWeight(c, k, text, lit, .regular);
}

/// The project menu's: it hangs from the filter, whose medium weight GPUI's
/// rows inherit.
fn labelWeight(c: *ui.Context, k: theme.Colors, text: []const u8, lit: bool, weight: @FieldType(ui.TextStyle, "weight")) void {
    const t = ui.div(c).row().grow().w(0).clip();
    defer t.end();
    ui.text(c, text, .{ .size = 13, .line_height = 13 * phi, .weight = weight, .color = if (lit) k.text else k.text.alpha(0.9) });
}

// The view options.

pub const Choice = enum {
    by_device,
    by_project,
    in_one_list,
    last_called,
    created,
    branch,
    harness,
    project_icon,
    location,
    archived,

    fn label(ch: Choice) []const u8 {
        return switch (ch) {
            .by_device => "By device",
            .by_project => "By project",
            .in_one_list => "None",
            .last_called => "Last called",
            .created => "Created",
            .branch => "Branch",
            .harness => "Harness",
            .project_icon => "Project icon",
            .location => "Location",
            .archived => "Archived",
        };
    }

    fn icon(ch: Choice) icons.Name {
        return switch (ch) {
            .by_device => .laptop,
            .by_project, .location => .folder,
            .in_one_list => .list,
            .last_called => .@"clock-circle",
            .created => .calendar,
            .branch => .@"git-branch",
            .harness => .bot,
            .project_icon => .@"project-default",
            .archived => .@"archive-minimalistic",
        };
    }
};

const Group = struct { label: []const u8, rows: []const Choice };

const groups = [_]Group{
    .{ .label = "Organize", .rows = &.{ .by_device, .by_project, .in_one_list } },
    .{ .label = "Sort", .rows = &.{ .last_called, .created } },
    .{ .label = "Show", .rows = &.{ .branch, .harness, .project_icon, .location, .archived } },
};

pub fn chosen(a: *const App, ch: Choice) bool {
    const s = &a.settings;
    return switch (ch) {
        .by_device => s.organization() == .by_device,
        .by_project => s.organization() == .by_project,
        .in_one_list => s.organization() == .in_one_list,
        .last_called => s.sort() == .last_updated,
        .created => s.sort() == .created,
        .branch => s.get(.sidebar_show_branch),
        .harness => s.get(.sidebar_show_harness),
        .project_icon => s.get(.sidebar_show_project_icon),
        .location => s.get(.sidebar_show_project_label),
        .archived => s.get(.sidebar_show_archived),
    };
}

/// Organize and Sort pick one and close their menu; Show's switch.
pub fn choose(a: *App, ch: Choice) void {
    const s = &a.settings;
    switch (ch) {
        .by_device => s.setText("sidebarOrganization", settings.Organization.by_device.key()),
        .by_project => s.setText("sidebarOrganization", settings.Organization.by_project.key()),
        .in_one_list => s.setText("sidebarOrganization", settings.Organization.in_one_list.key()),
        .last_called => s.setText("sidebarSort", settings.Sort.last_updated.key()),
        .created => s.setText("sidebarSort", settings.Sort.created.key()),
        .branch => s.toggle(.sidebar_show_branch),
        .harness => s.toggle(.sidebar_show_harness),
        .project_icon => s.toggle(.sidebar_show_project_icon),
        .location => s.toggle(.sidebar_show_project_label),
        .archived => s.toggle(.sidebar_show_archived),
    }
    switch (ch) {
        .by_device, .by_project, .in_one_list, .last_called, .created => {
            a.view.menus.open = null;
            a.view.menus.sub_active = null;
        },
        else => {},
    }
    if (ch == .last_called or ch == .created) a.resort();
    a.redraw();
}

fn view(c: *ui.Context, a: *App, k: theme.Colors, r: ui.Rect) void {
    const m = &a.view.menus;
    // Right of the ⋯, 6 along, level with it (`anchored_menu_right`),
    // from inside the ⋯'s 1-point clear border, where GPUI hangs it.
    const w = sidebar.width - 2 * 8;
    const x = rules.snapToWindow(r.x + r.w - 1 + 6, w, c.size.w, 8);
    const y = @max(8, r.y + 1);
    ui.key(c, "sidebar-view-menu");
    const card = card_(c, k, x, y, w);
    defer card.end();
    for (groups, 0..) |g, gi| {
        if (gi == 2) separator(c, k, w);
        ui.key(c, c.print("sidebar-view-group-{d}", .{gi}));
        const open = m.open == gi;
        var row = ui.div(c).row().wFull().h(30).px(8).gap(10).itemsCenter().rounded(7);
        row = if (open or m.group == gi) row.bg(k.selected) else row.hover(k.selected);
        defer row.end();
        // Coming onto a group opens its menu; a click on the group closes
        // it until the pointer comes back.
        if (row.hovered() and m.group != gi) {
            m.group = gi;
            m.open = gi;
            m.sub_active = null;
        }
        if (row.clicked()) {
            m.group = gi;
            m.open = null;
        }
        label(c, k, g.label, row.hovered() or open);
        if (gi < 2) {
            var value: []const u8 = g.rows[0].label();
            for (g.rows) |ch| if (chosen(a, ch)) {
                value = ch.label();
                break;
            };
            ui.text(c, value, .{ .size = 13, .line_height = 13 * phi, .color = k.muted });
        }
        icons.icon(c, .@"alt-arrow-right", 12, k.muted, 0);
        if (open) if (c.rects.get(c.node(row.index).id)) |rr| submenu(c, a, k, g, rr);
    }
    separator(c, k, w);
    {
        ui.key(c, "sidebar-view-compact");
        var row = ui.div(c).row().wFull().h(30).px(8).gap(10).itemsCenter().rounded(7);
        row = if (m.group == groups.len) row.bg(k.selected) else row.hover(k.selected);
        defer row.end();
        if (row.hovered()) {
            m.group = groups.len;
            m.open = null;
        }
        if (row.clicked()) a.settings.toggle(.sidebar_compact);
        label(c, k, "Compact", row.hovered());
        toggle(c, k, a.settings.get(.sidebar_compact));
    }
}

/// A group's menu beside its row, 10 right of it (`nested_menu`), or left
/// when there isn't room.
fn submenu(c: *ui.Context, a: *App, k: theme.Colors, g: Group, row: ui.Rect) void {
    const m = &a.view.menus;
    const w: f32 = 232;
    const left = row.x + row.w + 244 > c.size.w;
    const x = if (left) row.x - inset - 6 - w else row.x + row.w + inset + 6;
    const est: f32 = 30 + @as(f32, @floatFromInt(g.rows.len)) * 35;
    const y = rules.snapToWindow(row.y, est, c.size.h, 8);
    const card = held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(6).column().p(inset + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer card.end();
    {
        // `menu_heading`: small capitals, spaced.
        const hd = ui.div(c).row().wFull().px(8).pt(6).pb(4);
        defer hd.end();
        ui.text(c, tracked(c, g.label), .{ .size = 10, .line_height = 10 * phi, .weight = .medium, .color = k.muted });
    }
    for (g.rows, 0..) |ch, i| {
        ui.key(c, c.print("sidebar-view-row-{s}", .{@tagName(ch)}));
        const on = chosen(a, ch);
        const it = menuRow(c, k, on, m.sub_active == i);
        defer it.end();
        if (it.clicked()) choose(a, ch);
        icons.icon(c, ch.icon(), 15, k.muted, 0);
        label(c, k, ch.label(), it.hovered() or on);
        const slot = ui.div(c).row().w(14);
        defer slot.end();
        if (on) icons.icon(c, .check, 14, k.muted, 0);
    }
}

/// Upper case with a hair space between letters (`tracked_upper`).
fn tracked(c: *ui.Context, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |ch, i| {
        if (i > 0) out.appendSlice(c.alloc(), "\u{200A}") catch {};
        out.append(c.alloc(), std.ascii.toUpper(ch)) catch {};
    }
    return out.items;
}

fn separator(c: *ui.Context, k: theme.Colors, w: f32) void {
    const line: ui.Color = if (k.dark) .{ .r = 1, .g = 1, .b = 1, .a = 0.07 } else .{ .a = @min(0.07 * 1.35, 0.5) };
    const box = ui.div(c).column().wFull().py(2);
    defer box.end();
    _ = c.leaf(.{ .width = .{ .px = w - 2 }, .height = .{ .px = 1 }, .background = line, .offset = .{ .x = -inset } }, .none, null);
}

/// `toggle_switch`, without its own hit box: the row takes the click.
fn toggle(c: *ui.Context, k: theme.Colors, on: bool) void {
    const track = ui.div(c).row().w(32).h(18).roundedFull().bg(if (on) k.text else k.ink(0.15)).pl(if (on) 16 else 2).itemsCenter();
    defer track.end();
    _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (on) k.on_solid else k.ink(0.7) }, .none, null);
}
