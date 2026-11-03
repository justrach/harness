//! The theme library's operations as the GPUI app runs them
//! (crates/ui/src/theme_library.rs): each on a copy of the library, saved,
//! then made the running one, and a light or dark selection whose theme
//! went falls back to the first of that appearance.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const library = @import("theme_library.zig");
const imp = @import("theme_import.zig");
const themes = @import("themes.zig");

pub const Kind = enum { reload, reveal, duplicate, unlink, remove };

/// An entry's action, kept until the rows that offered it are drawn: the
/// library they show is read again when it runs.
pub const Pending = struct {
    kind: Kind,
    id_buf: [256]u8 = undefined,
    id_len: usize = 0,

    pub fn of(kind: Kind, entry_id: []const u8) Pending {
        var p: Pending = .{ .kind = kind };
        p.id_len = @min(entry_id.len, p.id_buf.len);
        @memcpy(p.id_buf[0..p.id_len], entry_id[0..p.id_len]);
        return p;
    }

    pub fn id(p: *const Pending) []const u8 {
        return p.id_buf[0..p.id_len];
    }
};

/// Runs an entry's action; what went wrong goes in `library_error`, as the
/// GPUI page shows it under its cards. A reload's failure shows on its row.
pub fn run(a: *App, p: Pending) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    a.view.library_error.clearRetainingCapacity();
    apply(ar, a, p) catch |e| {
        if (p.kind == .reload and e != error.NotInitialized) return;
        a.view.library_error.appendSlice(a.gpa, describe(e)) catch {};
    };
    a.redraw();
}

fn apply(ar: std.mem.Allocator, a: *App, p: Pending) !void {
    const dir = a.settings.dataDir() orelse return error.NotInitialized;
    const id = p.id();
    if (p.kind == .reveal) {
        const e = for (themes.library.views(ar) catch &.{}) |e| {
            if (std.mem.eql(u8, e.id, id)) break e;
        } else return error.NoLocation;
        return nanoui.shell.showInFolder(e.path orelse return error.NoLocation);
    }
    var next = current(ar, a.io, dir);
    const result: anyerror!void = switch (p.kind) {
        .reload => library.reload(ar, a.io, &next, id),
        .duplicate => if (library.duplicateAsEditable(ar, a.io, &next, dir, id)) |_| {} else |e| e,
        .unlink => library.unlink(ar, &next, id),
        .remove => library.remove(&next, id),
        .reveal => unreachable,
    };
    // A failed reload is saved too: its row says it's using the last good
    // family, and why.
    if (p.kind != .reload) try result;
    try persist(ar, a, dir, &next);
    return result;
}

/// The library as it stands (an unreadable one is empty, as the GPUI app
/// holds it after a failed load).
fn current(ar: std.mem.Allocator, io: std.Io, dir: []const u8) library.Library {
    return library.load(ar, io, dir) catch .{};
}

fn persist(ar: std.mem.Allocator, a: *App, dir: []const u8, next: *const library.Library) !void {
    library.save(ar, a.io, dir, next) catch |e| switch (e) {
        error.TooManyEntries, error.TooManyVariants, error.LibraryTooLarge => return e,
        else => return error.SaveFailed,
    };
    themes.loadLibrary(a.io, dir);
    reconcile(a);
}

/// `reconcile_and_refresh`: a selection whose theme is gone takes the first
/// of its appearance.
pub fn reconcile(a: *App) void {
    for ([_]bool{ false, true }) |dark| {
        if (themes.find(a.settings.themeId(dark)) != null) continue;
        for (themes.all()) |v| if (v.dark == dark) {
            a.settings.setTheme(dark, v.id);
            break;
        };
    }
}

/// Installs a compilation's chosen variants; the error's words when it
/// couldn't, in `out`.
pub fn install(a: *App, c: imp.Compilation, selected: []const []const u8, link: bool, out: *std.ArrayList(u8)) bool {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    out.clearRetainingCapacity();
    const dir = a.settings.dataDir() orelse {
        out.appendSlice(a.gpa, describe(error.NotInitialized)) catch {};
        return false;
    };
    var next = current(ar, a.io, dir);
    _ = library.install(ar, &next, c, selected, link) catch |e| {
        out.appendSlice(a.gpa, describe(e)) catch {};
        return false;
    };
    persist(ar, a, dir, &next) catch |e| {
        out.appendSlice(a.gpa, describe(e)) catch {};
        return false;
    };
    a.redraw();
    return true;
}

fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.NotInitialized => "custom theme library is not initialized",
        error.SaveFailed => "could not save custom theme library",
        error.Invalid, error.Failed => library.last_error,
        else => library.message(e),
    };
}
