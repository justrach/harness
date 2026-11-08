//! Themed in-app New project form and device/location/folder navigator.
//! The production reference is Harness v0.2.173 spaces/project_setup.rs.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const flow = @import("app_project_setup.zig");
const paths = @import("project_paths.zig");
const rules = @import("rules.zig");
const App = @import("app.zig").App;

const Row = struct { label: []const u8, index: usize, path: ?[]const u8 = null, git: bool = false };
fn rows(a: *App, alloc: std.mem.Allocator) []const Row {
    const s = &a.view.project_setup;
    var all: std.ArrayList(Row) = .empty;
    switch (s.step) {
        .details => {},
        .devices => for (a.devices.items, 0..) |d, ix| {
            all.append(alloc, .{ .label = d.name, .index = ix }) catch {};
        },
        .locations => {
            all.append(alloc, .{ .label = "Home", .index = 0 }) catch {};
            if (s.drives) |d| for (d.value.drives, 1..) |drive, ix| {
                all.append(alloc, .{ .label = drive.name, .index = ix, .path = drive.path }) catch {};
            };
        },
        .folders => if (flow.ready(s)) |l| {
            for (l.entries, 0..) |e, ix| {
                if (e.isDir) all.append(alloc, .{ .label = e.name, .index = ix, .git = e.isRepo }) catch {};
            }
        },
    }
    var filtered: std.ArrayList(Row) = .empty;
    for (0..5) |rank| for (all.items) |row| {
        if (rules.matchRank(s.query.text(), row.label)) |r| if (r == rank) {
            filtered.append(alloc, row) catch {};
        };
    };
    return filtered.items;
}
fn activate(a: *App, row: Row) void {
    const s = &a.view.project_setup;
    switch (s.step) {
        .details => {},
        .devices => if (row.index < a.devices.items.len) {
            flow.pickDevice(a, a.devices.items[row.index]);
        },
        .locations => {
            s.preferred = null;
            s.root = row.path;
            flow.browse(a, row.path, false);
        },
        .folders => if (flow.ready(s)) |l| {
            const path = paths.child(s.arena.?.allocator(), l.path, row.label) catch return;
            flow.browse(a, path, row.git);
        },
    }
}

/// Take global shortcuts before the underlying composer or workspace does.
pub fn keys(c: *ui.Context, a: *App) bool {
    const s = &a.view.project_setup;
    if (!s.open) return false;
    if (s.busy) {
        c.focus = 0;
        return true;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
        flow.dismiss(a);
        return true;
    }
    if (s.step == .details) {
        if (c.shortcut(.{ .key = ui.Shortcut.tab, .shift = true })) cycle(c, a, true) else if (c.shortcut(.{ .key = ui.Shortcut.tab })) cycle(c, a, false);
        if (c.focus != s.field and (c.shortcut(.{ .key = ui.Shortcut.enter }) or c.shortcut(.{ .key = ' ' }))) {
            if (c.focus == s.controls[0]) flow.beginFolder(a) else if (c.focus == s.controls[1]) flow.dismiss(a) else if (c.focus == s.controls[2]) flow.submit(a);
        }
        return true;
    }
    const list = rows(a, c.alloc());
    s.active = if (list.len == 0) 0 else @min(s.active, list.len - 1);
    if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) {
        flow.useFolder(a);
        return true;
    }
    if (s.loading) return true;
    const up = c.shortcut(.{ .key = ui.Shortcut.up }) or c.shortcut(.{ .key = 'p', .ctrl = true });
    const down = c.shortcut(.{ .key = ui.Shortcut.down }) or c.shortcut(.{ .key = 'n', .ctrl = true });
    if (list.len > 0 and (up or down)) {
        s.active = if (down) (s.active + 1) % list.len else (s.active + list.len - 1) % list.len;
        s.reveal = true;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.left }) or (s.query.text().len == 0 and c.shortcut(.{ .key = 0x7f }))) {
        flow.up(a);
        return true;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.tab })) {
        if (s.step == .folders and list.len > 0) s.query.set(list[s.active].label);
        return true;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.right }) or c.shortcut(.{ .key = ui.Shortcut.enter })) {
        if (list.len > 0) activate(a, list[s.active]) else typedPath(a);
    }
    return true;
}

fn cycle(c: *ui.Context, a: *App, reverse: bool) void {
    const s = &a.view.project_setup;
    const all = [_]u64{ s.field, s.controls[0], s.controls[1], s.controls[2] };
    const ids = all[0..if (flow.canSubmit(a)) @as(usize, 4) else 3];
    var at: usize = 0;
    for (ids, 0..) |id, ix| if (id == c.focus) {
        at = ix;
        break;
    };
    c.focus = ids[if (reverse) (at + ids.len - 1) % ids.len else (at + 1) % ids.len];
    c.changed = true;
}

fn typedPath(a: *App) void {
    const s = &a.view.project_setup;
    if (s.step != .folders or !paths.valid(s.query.text())) return;
    const target = paths.resolve(s.arena.?.allocator(), s.query.text(), s.home orelse "~") catch return;
    flow.browse(a, target, false);
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.project_setup;
    if (!s.open) return;
    ui.key(c, "new-project-dialog");
    const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(8).bg(.{ .a = if (k.dark) 0.35 else 0.32 }).center();
    defer scrim.end();
    ui.key(c, c.print("new-project-dialog-{d}", .{s.generation}));
    const reveal = ui.motion.frame(c, .{
        .initial = .{ .opacity = 0, .scale = 0.97, .y = 7 },
        .transition = .{ .tween = .{ .duration = 0.18, .ease = ui.motion.Easing.css_ease_out } },
    });
    const card = kit.shadowLg(ui.div(c).w(@min(460, @max(0, c.size.w - 32))).maxH(@max(0, c.size.h - 32)).p(20).column().rounded(16).bg(k.overlay).border(k.border).borderW(1).scrollY()).motion(reveal);
    defer card.end();
    if (s.step == .details) details(c, a, k) else browser(c, a, k);
    // Match modal dismissal: outside the browser returns to the draft;
    // outside Details cancels, and nothing dismisses an in-flight create.
    if (scrim.clicked() and !card.hovered()) flow.dismiss(a);
}
fn text(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    ui.text(c, label, .{ .size = 13, .line_height = 20, .color = k.muted, .wrap = true });
}
fn gap(c: *ui.Context, h: f32) void {
    ui.div(c).h(h).wFull().end();
}

fn button(c: *ui.Context, k: theme.Colors, label: []const u8, enabled: bool, primary: bool, id: ?*u64) bool {
    ui.key(c, label);
    const b = ui.div(c).row().px(12).py(7).rounded(8).bg(if (primary) k.solid.alpha(if (enabled) 1 else 0.4) else .transparent);
    defer b.end();
    if (enabled) _ = b.hover(k.selected).control();
    if (id) |p| p.* = c.node(b.index).id;
    if (enabled) _ = kit.focusRing(c, b, k.accent, 2);
    ui.text(c, label, .{ .size = 13, .line_height = 20, .weight = .medium, .color = if (primary) k.on_solid else if (enabled) k.text else k.faint });
    return enabled and b.clicked();
}

fn details(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.project_setup;
    ui.text(c, "New project", .{ .size = 16, .weight = .semibold, .color = k.text });
    gap(c, 6);
    text(c, k, "Keep related chats together in one project.");
    gap(c, 24);
    ui.text(c, "Project name", .{ .size = 13, .weight = .medium, .color = k.text });
    gap(c, 8);
    var submit = false;
    {
        const box = ui.div(c).row().wFull().px(12).py(9).rounded(8).bg(k.ink(0.04)).border(k.border).borderW(1);
        defer box.end();
        if (s.busy) text(c, k, s.name.text()) else {
            ui.key(c, "project-name-field");
            const at = c.nodes.items.len;
            const result = ui.textField(c, &s.name, .{ .placeholder = "Project name", .placeholder_color = k.faint, .bare = true, .width = .fill, .size = 14 });
            s.field = c.node(@intCast(at)).id;
            if (s.focus) {
                c.focus = s.field;
                c.changed = true;
                s.focus = false;
            }
            submit = result.submitted;
        }
    }
    gap(c, 20);
    ui.text(c, "Working folder", .{ .size = 13, .weight = .medium, .color = k.text });
    gap(c, 8);
    if (s.folder) |f| {
        const row = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer row.end();
        icons.icon(c, .folder, 18, k.muted, 0);
        {
            const col = ui.div(c).column().grow().w(0).gap(3);
            defer col.end();
            kit.ellipsisText(c, f.path, .{ .size = 13, .color = k.text }, @max(32, @min(460, c.size.w - 32) - 170));
            text(c, k, f.device_name);
        }
        if (button(c, k, "Change…", !s.busy, false, &s.controls[0])) flow.beginFolder(a);
    } else if (button(c, k, "Add folder…", !s.busy, false, &s.controls[0])) flow.beginFolder(a);
    gap(c, 8);
    text(c, k, "New chats will work in this folder.");
    const existing = flow.existing(a);
    if (existing) |space| {
        gap(c, 12);
        text(c, k, c.print("This folder is already in “{s}”. Open that project to continue.", .{space.name}));
    }
    if (s.err) |why| {
        gap(c, 12);
        ui.text(c, why, .{ .size = 13, .color = k.danger, .wrap = true });
    }
    gap(c, 24);
    const actions = ui.div(c).row().wFull().justifyEnd().gap(8);
    defer actions.end();
    if (button(c, k, "Cancel", !s.busy, false, &s.controls[1])) {
        flow.dismiss(a);
        return;
    }
    const create = button(c, k, if (s.busy) "Creating…" else if (existing != null) "Open project" else "Create project", flow.canSubmit(a), true, &s.controls[2]);
    if (create or submit) flow.submit(a);
}

fn browser(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.project_setup;
    {
        const bar = ui.div(c).row().wFull().gap(4).itemsCenter();
        defer bar.end();
        if (button(c, k, "Back", true, false, null)) {
            flow.details(a);
            return;
        }
        if (button(c, k, "Devices", true, false, null)) {
            flow.devices(a);
            return;
        }
        if (s.device != null and s.step != .devices) {
            if (button(c, k, s.device_name, true, false, null)) {
                flow.locations(a);
                return;
            }
        }
    }
    gap(c, 8);
    ui.text(c, "Add folder", .{ .size = 15, .weight = .semibold, .color = k.text });
    if (s.step == .folders) {
        gap(c, 8);
        if (flow.ready(s)) |l| text(c, k, l.path) else if (s.requested_path) |p| text(c, k, p);
        const nav = ui.div(c).row().gap(4).wFull();
        defer nav.end();
        if (button(c, k, "Up", !s.loading, false, null)) {
            flow.up(a);
            return;
        }
        if (button(c, k, "Locations", true, false, null)) {
            flow.locations(a);
            return;
        }
    }
    gap(c, 8);
    {
        const box = ui.div(c).row().wFull().px(10).py(8).rounded(8).bg(k.ink(0.04));
        defer box.end();
        ui.key(c, "project-folder-search");
        const at = c.nodes.items.len;
        const result = ui.textField(c, &s.query, .{ .placeholder = switch (s.step) {
            .devices => "Search devices…",
            .locations => "Search locations…",
            else => "Search folders…",
        }, .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 13 });
        s.field = c.node(@intCast(at)).id;
        if (s.focus) {
            c.focus = s.field;
            c.changed = true;
            s.focus = false;
        }
        if (result.submitted and !s.loading) {
            const list = rows(a, c.alloc());
            if (list.len > 0) activate(a, list[@min(s.active, list.len - 1)]) else typedPath(a);
            return;
        }
        if (result.changed) {
            s.active = 0;
            s.reveal = true;
            if (s.scroll != 0) c.scroll.put(c.gpa, s.scroll, 0) catch {};
            if (s.step == .folders and std.mem.endsWith(u8, s.query.text(), "/")) {
                if (paths.valid(s.query.text())) {
                    typedPath(a);
                    return;
                }
                const q = s.query.text()[0 .. s.query.text().len - 1];
                if (flow.ready(s)) |l| {
                    var match: ?flow.Entry = null;
                    var count: usize = 0;
                    for (l.entries) |entry| if (entry.isDir and std.ascii.startsWithIgnoreCase(entry.name, q)) {
                        match = entry;
                        count += 1;
                        if (std.mem.eql(u8, entry.name, q)) {
                            count = 1;
                            break;
                        }
                    };
                    if (count == 1) {
                        activate(a, .{ .label = match.?.name, .index = 0, .git = match.?.isRepo });
                        return;
                    }
                }
            }
        }
    }
    gap(c, 8);
    if (s.loading) text(c, k, "Loading folders…") else {
        const list = rows(a, c.alloc());
        if (list.len == 0) text(c, k, if (s.step == .devices) "No devices match." else if (s.step == .locations) "No locations match." else "No folders match.");
        ui.key(c, "project-folder-rows");
        const col = ui.div(c).column().wFull().h(@min(224, @as(f32, @floatFromInt(list.len)) * 32)).scrollY();
        defer col.end();
        s.scroll = c.node(col.index).id;
        if (s.reveal) {
            const top = @as(f32, @floatFromInt(s.active)) * 32;
            const was = c.scroll.get(s.scroll) orelse 0;
            const next = if (top < was) top else if (top + 32 > was + 224) top + 32 - 224 else was;
            c.scroll.put(c.gpa, s.scroll, next) catch {};
            s.reveal = false;
        }
        for (list, 0..) |row, ix| {
            ui.key(c, row.label);
            const item = ui.div(c).row().wFull().h(32).px(8).gap(10).itemsCenter().rounded(7).hover(k.selected).bg(if (s.active == ix) k.selected else .transparent).control();
            defer item.end();
            icons.icon(c, if (s.step == .devices) .monitor else if (row.git) .@"git-branch" else .folder, 16, k.muted, 0);
            kit.ellipsisText(c, row.label, .{ .size = 13, .color = k.text }, @max(32, @min(460, c.size.w - 32) - 100));
            if (item.clicked()) {
                activate(a, row);
                return;
            }
        }
    }
    if (s.err) |why| {
        gap(c, 8);
        ui.text(c, why, .{ .size = 13, .color = k.danger, .wrap = true });
        if (s.step == .folders and button(c, k, "Retry", !s.loading, false, null)) {
            flow.browse(a, s.requested_path, s.git);
            return;
        }
    }
    if (flow.ready(s)) |l| if (l.truncated) {
        gap(c, 8);
        text(c, k, "Some folders are not shown. Type a path to browse directly.");
    };
    gap(c, 12);
    text(c, k, "↑↓ navigate · →/Return open · ← up · Tab complete · Esc back");
    gap(c, 12);
    const actions = ui.div(c).row().wFull().justifyEnd().gap(8);
    defer actions.end();
    if (button(c, k, "Cancel", true, false, null)) {
        flow.details(a);
        return;
    }
    if (button(c, k, "Use this folder", s.step == .folders and flow.ready(s) != null, true, null)) flow.useFolder(a);
}
