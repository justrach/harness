//! The file explorer, the window's rightmost column (crates/ui/src/files/*):
//! a search box and the show-all toggle, then the chat's checkout as a tree
//! (folders open in place, 14 points of indent a level), names coloured by
//! git: added green, modified amber, renamed accent, deleted red. A file
//! opens in a tab of the surface pane.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const file_icons = @import("file_icons.zig");
const kit = @import("view_kit.zig");
const tip_quick = @import("view_tooltip.zig").quick;
const panels = @import("app_panels.zig");
const files = @import("app_files.zig");
const App = @import("app.zig").App;

pub const width: f32 = 286;

pub fn explorer(c: *ui.Context, a: *App, k: theme.Colors) void {
    const col = ui.div(c).column().w(width).hFull().bg(if (k.frosted) k.panel else k.shell).clip();
    defer col.end();
    _ = c.leaf(.{ .height = .{ .px = 38 } }, .none, null);
    toolbar(c, a, k);
    const q = std.mem.trim(u8, a.panels.search.text(), " ");
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .top = 4, .bottom = 12 } });
    defer ui.end(c);
    if (q.len > 0) return results(c, a, k);
    level(c, a, k, "", 0);
}

fn toolbar(c: *ui.Context, a: *App, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    {
        const bar = ui.div(c).row().wFull().h(38).px(8).gap(4).itemsCenter().bg(k.ink(0.015));
        defer bar.end();
        {
            const field = ui.div(c).row().grow().h(24).px(8).gap(6).itemsCenter().rounded(6).bg(k.ink(0.035)).hover(k.ink(0.055));
            defer field.end();
            icons.icon(c, .magnifer, 12, k.faint, 0);
            const r = ui.textField(c, &a.panels.search, .{ .placeholder = "Search files", .width = .fill, .bare = true, .size = 11 });
            if (r.changed) files.search(a);
        }
        const on = a.panels.show_all;
        if (kit.iconButton(c, k, if (on) .eye else .@"eye-closed", .{ .icon = 14, .on = on, .color = if (on) k.text else k.muted, .tip = .{
            .text = if (on) "Hide hidden and ignored files" else "Show all files (even hidden)",
            .delay = tip_quick,
            .look = .file,
        } }))
            files.setShowAll(a, !on);
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}

fn level(c: *ui.Context, a: *App, k: theme.Colors, dir: []const u8, depth: u32) void {
    const listing = a.panels.listings.get(dir) orelse return status(c, k, "Loading…", depth);
    if (listing.loading) return status(c, k, "Loading…", depth);
    if (listing.err) |e| return status(c, k, c.print("{s} — Retry", .{e}), depth);
    if (listing.entries.len == 0) return status(c, k, "Empty folder", depth);
    for (listing.entries) |e| {
        ui.key(c, c.print("f-{s}", .{e.path}));
        row(c, a, k, e, depth);
        if (e.dir and a.panels.expanded.contains(e.path)) level(c, a, k, e.path, depth + 1);
    }
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, e: panels.Entry, depth: u32) void {
    const selected = if (a.panels.selected) |s| std.mem.eql(u8, s, e.path) else false;
    var r = ui.div(c).row().wFull().h(27).pl(8 + @as(f32, @floatFromInt(depth)) * 14).pr(8).gap(4).itemsCenter();
    r = if (selected) r.bg(k.wash(0.12)) else r.hover(k.wash(0.055));
    const git = if (e.dir) files.dirKind(a, e.path) else a.panels.git.get(e.path);
    if (e.ignored and git == null) r = r.opacity(0.52);
    defer r.end();
    if (r.clicked()) {
        if (e.dir) files.toggleDir(a, e.path) else files.openFile(a, e.path);
    }
    {
        const slot = ui.div(c).row().size(14, 14).center();
        defer slot.end();
        if (e.dir) icons.icon(c, if (a.panels.expanded.contains(e.path)) .@"alt-arrow-down" else .@"alt-arrow-right", 11, k.faint, 0);
    }
    file_icons.icon(c, e.path, e.dir, k.dark, 14);
    const color = if (git) |g| gitColor(k, g) else if (selected) k.text else k.muted;
    kit.fadeText(c, e.name, .{ .size = 11.5, .color = color }, width - 8 - @as(f32, @floatFromInt(depth)) * 14 - 8 - 36);
}

pub fn gitColor(k: theme.Colors, g: panels.GitKind) ui.Color {
    return switch (g) {
        .added => k.success,
        .modified => k.warning,
        .renamed => k.accent,
        .deleted => k.danger,
    };
}

fn status(c: *ui.Context, k: theme.Colors, text: []const u8, depth: u32) void {
    const r = ui.div(c).row().wFull().h(27).pl(8 + @as(f32, @floatFromInt(depth + 1)) * 14).itemsCenter();
    defer r.end();
    ui.text(c, text, .{ .size = 10.5, .color = k.faint });
}

fn results(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.panels;
    if (p.searching) return status(c, k, "Searching…", 0);
    if (p.results.len == 0) return status(c, k, "No files found.", 0);
    if (p.results.len >= 200) status(c, k, "Showing the first 200 matches", 0);
    for (p.results) |e| {
        ui.key(c, c.print("s-{s}", .{e.path}));
        var r = ui.div(c).row().wFull().h(27).px(8).gap(6).itemsCenter().hover(k.wash(0.055));
        defer r.end();
        if (r.clicked()) {
            if (e.dir) files.toggleDir(a, e.path) else files.openFile(a, e.path);
        }
        file_icons.icon(c, e.path, e.dir, k.dark, 14);
        ui.text(c, e.name, .{ .size = 11.5, .color = k.text });
        kit.fadeText(c, std.fs.path.dirname(e.path) orelse "", .{ .size = 10.5, .color = k.faint }, width - 140);
    }
}
