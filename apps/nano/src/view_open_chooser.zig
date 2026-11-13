//! The shared destination sheet: choose a computer, then an existing project
//! or a folder for the new tab or split. The project form uses the same sheet
//! motion when it opens.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const App = @import("app.zig").App;
const flow = @import("app_open_chooser.zig");

const DeviceRow = struct { id: ?[]const u8, label: []const u8 };

fn devices(a: *App, alloc: std.mem.Allocator) []DeviceRow {
    var out: std.ArrayList(DeviceRow) = .empty;
    const local = @import("strip_device.zig").localLabel();
    out.append(alloc, .{ .id = a.device_id, .label = local }) catch {};
    for (a.devices.items) |d| {
        if (a.device_id) |id| if (std.mem.eql(u8, id, d.id)) continue;
        out.append(alloc, .{ .id = d.id, .label = d.name }) catch {};
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

fn selectedDevice(a: *const App, id: ?[]const u8) bool {
    const chosen = flow.currentDevice(a);
    return if (chosen) |want| if (id) |have| std.mem.eql(u8, want, have) else false else id == null;
}

fn actions(a: *App, alloc: std.mem.Allocator) struct { projects: []const @import("workspace.zig").Space, total: usize } {
    const list = flow.projects(a, alloc) catch &.{};
    // Existing projects, then projectless, then the folder form.
    return .{ .projects = list, .total = list.len + 2 };
}

pub fn keys(c: *ui.Context, a: *App) bool {
    const s = &a.view.open_chooser;
    if (!s.open) return false;
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
        flow.close(a);
        return true;
    }
    const list = actions(a, c.alloc());
    s.cursor = if (list.total == 0) 0 else @min(s.cursor, list.total - 1);
    if (c.shortcut(.{ .key = ui.Shortcut.up })) s.cursor = if (s.cursor == 0) list.total - 1 else s.cursor - 1;
    if (c.shortcut(.{ .key = ui.Shortcut.down })) s.cursor = (s.cursor + 1) % list.total;
    if (c.shortcut(.{ .key = ui.Shortcut.enter })) choose(a, list.projects, s.cursor);
    return true;
}

fn choose(a: *App, projects: []const @import("workspace.zig").Space, cursor: usize) void {
    if (cursor < projects.len) {
        flow.choose(a, projects[cursor].id);
    } else if (cursor == projects.len) {
        flow.chooseProjectless(a);
    } else {
        flow.newProject(a);
    }
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.open_chooser;
    if (!s.open) return;
    ui.key(c, "open-destination-sheet");
    const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(8).bg(.{ .a = if (k.dark) 0.35 else 0.32 }).center();
    defer scrim.end();

    ui.key(c, c.print("open-destination-card-{d}", .{s.generation}));
    const reveal = ui.motion.frame(c, .{
        .initial = .{ .opacity = 0, .scale = 0.97, .y = 7 },
        .transition = .{ .tween = .{ .duration = 0.18, .ease = ui.motion.Easing.css_ease_out } },
    });
    const card = kit.shadowLg(ui.div(c).w(@min(480, @max(0, c.size.w - 32))).maxH(@max(0, c.size.h - 32)).p(20).column().gap(12).rounded(16).bg(k.overlay).border(k.border).borderW(1)).motion(reveal);
    defer card.end();
    // Keep harmless title/padding clicks on the sheet, not its scrim.
    _ = card.interaction();
    if (scrim.clicked() and !card.hovered()) {
        flow.close(a);
        return;
    }

    ui.text(c, s.intent.title(), .{ .size = 16, .weight = .semibold, .color = k.text });
    ui.text(c, if (s.intent == .new_project) "Pick a computer and the folder to work in." else "The new session starts where you choose.", .{ .size = 13, .line_height = 20, .color = k.muted, .wrap = true });

    ui.text(c, "Computer", .{ .size = 12, .weight = .medium, .color = k.muted });
    const all_devices = devices(a, c.alloc());
    {
        const list = ui.div(c).column().wFull().maxH(108).scrollY();
        defer list.end();
        for (all_devices) |d| {
            ui.key(c, c.print("destination-device-{s}", .{d.id orelse "local"}));
            var device_row = ui.div(c).row().wFull().h(32).px(8).gap(9).itemsCenter().rounded(7).hover(k.selected);
            if (selectedDevice(a, d.id)) device_row = device_row.bg(k.selected);
            const item = device_row.control();
            defer item.end();
            icons.icon(c, .monitor, 15, k.muted, 0);
            kit.ellipsisText(c, d.label, .{ .size = 13, .color = k.text }, @max(32, @min(480, c.size.w - 32) - 96));
            ui.spacer(c);
            if (selectedDevice(a, d.id)) icons.icon(c, .check, 12, k.muted, 0);
            if (item.clicked()) flow.pickDevice(a, d.id);
        }
    }

    ui.text(c, "Folder", .{ .size = 12, .weight = .medium, .color = k.muted });
    {
        const field = ui.div(c).row().wFull().px(10).py(8).rounded(8).bg(k.ink(0.04));
        defer field.end();
        ui.key(c, "destination-folder-search");
        s.field = c.peekId(null);
        if (s.focus) {
            c.focus = s.field;
            s.focus = false;
        }
        const result = ui.textField(c, &s.query, .{ .placeholder = "Search projects…", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 13 });
        if (result.changed) {
            s.cursor = 0;
            c.changed = true;
        }
    }
    const list = actions(a, c.alloc());
    {
        const rows = ui.div(c).column().wFull().maxH(208).scrollY();
        defer rows.end();
        if (list.projects.len == 0) {
            ui.text(c, "No projects on this computer yet.", .{ .size = 12, .color = k.faint });
        }
        for (list.projects, 0..) |space, ix| {
            if (row(c, a, k, .folder, space.name, ix == s.cursor)) {
                choose(a, list.projects, ix);
                return;
            }
        }
        if (row(c, a, k, .close, "Don't work in a project", s.cursor == list.projects.len)) {
            choose(a, list.projects, list.projects.len);
            return;
        }
        if (row(c, a, k, .plus, "Open a folder…", s.cursor == list.projects.len + 1)) {
            choose(a, list.projects, list.projects.len + 1);
            return;
        }
    }
    {
        const foot = ui.div(c).row().wFull().justifyEnd().gap(8);
        defer foot.end();
        const cancel = ui.div(c).row().px(12).py(7).rounded(8).hover(k.selected).control();
        defer cancel.end();
        ui.text(c, "Cancel", .{ .size = 13, .color = k.muted });
        if (cancel.clicked()) flow.close(a);
    }
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, glyph: icons.Name, label: []const u8, active: bool) bool {
    _ = a;
    ui.key(c, label);
    var box = ui.div(c).row().wFull().h(32).px(8).gap(9).itemsCenter().rounded(7).hover(k.selected);
    if (active) box = box.bg(k.selected);
    const item = box.control();
    defer item.end();
    icons.icon(c, glyph, 15, k.muted, 0);
    kit.ellipsisText(c, label, .{ .size = 13, .color = k.text }, 340);
    return item.clicked();
}
