//! Keep `~/.harness/bin/graff` on Codegraff's latest stable release, the
//! check the GPUI app runs off its launch path, and surface lifecycle notices
//! (`GraffNotice::Updated` / `GraffNotice::Available`) to the UI.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;

const latest_url = "https://api.github.com/repos/justrach/codegraff/releases/latest";

pub fn start(a: *App) void {
    if (a.offscreen or builtin.os.tag != .macos) return;
    if (a.env) |env| {
        if (env.get("HARNESS_DEV_GRAFF_NOTICE")) |range| {
            if (std.mem.indexOf(u8, range, "..")) |sep| {
                const from = range[0..sep];
                const to = range[sep + 2 ..];
                if (to.len > 0) {
                    const home = env.get("HOME") orelse "";
                    var out_bytes: ?[]u8 = null;
                    defer if (out_bytes) |b| a.gpa.free(b);
                    if (home.len > 0) {
                        if (std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff", .{home})) |managed| {
                            defer a.gpa.free(managed);
                            out_bytes = versionOutput(a, managed);
                        } else |_| {}
                    }
                    a.updates.publishGraff(.updated, if (from.len > 0) from else null, std.mem.trimStart(u8, to, "v"), out_bytes);
                    a.redraw();
                }
            }
        }
        if (env.get("GRAFF_EXECUTABLE")) |v| if (v.len > 0) return;
    }
    const t = std.Thread.spawn(.{}, run, .{a}) catch return;
    t.detach();
}

pub fn startManual(a: *App) void {
    if (a.offscreen or builtin.os.tag != .macos) return;
    const t = std.Thread.spawn(.{}, runManual, .{a}) catch return;
    t.detach();
}

fn off(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "no");
}

fn notifyUi(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    a.redraw();
}

fn runManual(a: *App) void {
    installLatest(a, true);
}

fn run(a: *App) void {
    const auto_update = if (a.env) |env| !off(env.get("HARNESS_GRAFF_AUTO_UPDATE")) else true;
    installLatest(a, auto_update);
}

fn installLatest(a: *App, auto_update: bool) void {
    const home = if (a.env) |env| env.get("HOME") orelse return else return;
    const managed = std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff", .{home}) catch return;
    defer a.gpa.free(managed);
    const out_bytes = versionOutput(a, managed);
    defer if (out_bytes) |b| a.gpa.free(b);
    const current = if (out_bytes) |b| dotted(a.gpa, b) else null;
    defer if (current) |c| a.gpa.free(c);

    const dismissed = a.settings.text("graffNoticeDismissed");

    const tag = latestTag(a);
    defer if (tag) |t| a.gpa.free(t);

    if (tag) |t| {
        const bare_tag = std.mem.trimStart(u8, t, "v");
        const is_newer = if (current) |cur| newer(t, cur) else true;
        if (is_newer) {
            if (!auto_update) {
                a.updates.publishGraff(.available, current, bare_tag, null);
                nanoui.App.after(0, a, notifyUi);
                return;
            }
            a.updates.publishGraff(.updating, current, bare_tag, null);
            nanoui.App.after(0, a, notifyUi);
            if (downloadAndSwap(a, home, managed, t)) {
                const new_out = versionOutput(a, managed);
                defer if (new_out) |b| a.gpa.free(b);
                a.updates.publishGraff(.updated, current, bare_tag, new_out);
                nanoui.App.after(0, a, notifyUi);
                std.log.info("harness-nano: graff {s} -> {s}", .{ current orelse "none", t });
                return;
            }
        }
    }

    // If the managed copy on disk is already newer than the last version the
    // user dismissed in Nano (for example after a background swap), surface
    // its "What's new" highlights until dismissed.
    if (current) |cur| {
        const should_show = if (dismissed) |d| newer(cur, d) else true;
        if (should_show) {
            a.updates.publishGraff(.updated, dismissed, cur, out_bytes);
            nanoui.App.after(0, a, notifyUi);
        }
    }
}

fn downloadAndSwap(a: *App, home: []const u8, managed: []const u8, tag: []const u8) bool {
    const url = std.fmt.allocPrint(a.gpa, "https://github.com/justrach/codegraff/releases/download/{s}/graff-aarch64-macos.tar.gz", .{tag}) catch return false;
    defer a.gpa.free(url);
    const tar = std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff-update.tar.gz", .{home}) catch return false;
    defer a.gpa.free(tar);
    if (!download(a, url, tar)) return false;
    defer std.Io.Dir.cwd().deleteFile(a.io, tar) catch {};
    const stage = std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff-update-stage", .{home}) catch return false;
    defer a.gpa.free(stage);
    std.Io.Dir.cwd().deleteTree(a.io, stage) catch {};
    std.Io.Dir.cwd().createDirPath(a.io, stage) catch return false;
    defer std.Io.Dir.cwd().deleteTree(a.io, stage) catch {};
    var child = std.process.spawn(a.io, .{
        .argv = &.{ "tar", "-xzf", tar, "-C", stage },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(a.io) catch return false;
    if (term != .exited or term.exited != 0) return false;
    const extracted = findGraff(a, stage) orelse return false;
    defer a.gpa.free(extracted);
    // Rename over the live path. A running graff keeps its old inode.
    std.Io.Dir.cwd().deleteFile(a.io, managed) catch {};
    std.Io.Dir.cwd().rename(extracted, std.Io.Dir.cwd(), managed, a.io) catch return false;
    return true;
}

fn findGraff(a: *App, dir: []const u8) ?[]u8 {
    const list = std.fmt.allocPrint(a.gpa, "{s}/.list", .{dir}) catch return null;
    defer a.gpa.free(list);
    const file = std.Io.Dir.cwd().createFile(a.io, list, .{}) catch return null;
    var child = std.process.spawn(a.io, .{
        .argv = &.{ "find", dir, "-type", "f", "-name", "graff" },
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .ignore,
    }) catch return null;
    _ = child.wait(a.io) catch return null;
    const out_bytes = std.Io.Dir.cwd().readFileAlloc(a.io, list, a.gpa, .limited(4096)) catch return null;
    defer a.gpa.free(out_bytes);
    const line_end = std.mem.indexOfScalar(u8, out_bytes, '\n') orelse out_bytes.len;
    const path = std.mem.trim(u8, out_bytes[0..line_end], " \t\r");
    if (path.len == 0) return null;
    return a.gpa.dupe(u8, path) catch null;
}

fn download(a: *App, url: []const u8, path: []const u8) bool {
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return false;
    var err: ?objc.Object = null;
    if (err != null) return false;
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithContentsOfURL:options:error:", .{ nsurl, @as(u64, 0), &err });
    if (err != null) return false;
    const ptr = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return false;
    const len = objc.msg(usize, data, "length", .{});
    if (len == 0 or len > 64 * 1024 * 1024) return false;
    var file = std.Io.Dir.cwd().createFile(a.io, path, .{}) catch return false;
    defer file.close(a.io);
    file.writeStreamingAll(a.io, ptr[0..len]) catch return false;
    return true;
}

fn latestTag(a: *App) ?[]u8 {
    if (builtin.os.tag != .macos) return null;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(latest_url)}) orelse return null;
    var err: ?objc.Object = null;
    if (err != null) return null;
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithContentsOfURL:options:error:", .{ url, @as(u64, 0), &err });
    if (err != null) return null;
    const ptr = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return null;
    const len = objc.msg(usize, data, "length", .{});
    const body = ptr[0..len];
    const key = "\"tag_name\":\"";
    const at = std.mem.indexOf(u8, body, key) orelse return null;
    const rest = body[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return a.gpa.dupe(u8, rest[0..end]) catch null;
}

fn versionOutput(a: *App, path: []const u8) ?[]u8 {
    const out_path = std.fmt.allocPrint(a.gpa, "{s}.version", .{path}) catch return null;
    defer a.gpa.free(out_path);
    const file = std.Io.Dir.cwd().createFile(a.io, out_path, .{}) catch return null;
    var child = std.process.spawn(a.io, .{
        .argv = &.{ path, "--version" },
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .ignore,
    }) catch return null;
    _ = child.wait(a.io) catch return null;
    const out_bytes = std.Io.Dir.cwd().readFileAlloc(a.io, out_path, a.gpa, .limited(64 * 1024)) catch return null;
    std.Io.Dir.cwd().deleteFile(a.io, out_path) catch {};
    return out_bytes;
}

pub fn dotted(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |word| {
        const bare = std.mem.trimStart(u8, word, "v");
        const cut = std.mem.indexOfScalar(u8, bare, '-') orelse bare.len;
        const ver = bare[0..cut];
        var parts: u8 = 0;
        var ok = ver.len > 0;
        for (ver) |ch| {
            if (ch == '.') parts += 1 else if (ch < '0' or ch > '9') ok = false;
        }
        if (ok and parts >= 2) return gpa.dupe(u8, ver) catch null;
    }
    return null;
}

pub fn newer(tag: []const u8, current: []const u8) bool {
    const left = std.mem.trimStart(u8, tag, "v");
    var a = std.mem.splitScalar(u8, left, '.');
    var b = std.mem.splitScalar(u8, std.mem.trimStart(u8, current, "v"), '.');
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return false;
        const xn = if (x) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        const yn = if (y) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        if (xn != yn) return xn > yn;
    }
}

test "a release is newer only past the installed dotted version" {
    try std.testing.expect(newer("v0.0.302.25", "0.0.302.24"));
    try std.testing.expect(!newer("0.0.302.24", "0.0.302.24"));
    try std.testing.expect(!newer("0.0.302.4", "0.0.302.24"));
    const got = dotted(std.testing.allocator, "graff 0.0.302.24\n") orelse return error.NoVersion;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("0.0.302.24", got);
}
