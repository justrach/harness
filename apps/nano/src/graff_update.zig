//! Keep `~/.harness/bin/graff` on Codegraff's latest stable release, the
//! check the GPUI app runs off its launch path. Nano cannot call that Rust
//! loop, so it does the same steps on a detached thread: read the latest
//! release, compare `graff --version`, and replace the binary only when the
//! release is newer. A `GRAFF_EXECUTABLE` the user set, or
//! `HARNESS_GRAFF_AUTO_UPDATE=0`, leaves the copy alone.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;

const latest_url = "https://api.github.com/repos/justrach/codegraff/releases/latest";

pub fn start(a: *App) void {
    if (a.offscreen or builtin.os.tag != .macos) return;
    if (a.env) |env| {
        if (env.get("GRAFF_EXECUTABLE")) |v| if (v.len > 0) return;
        if (off(env.get("HARNESS_GRAFF_AUTO_UPDATE"))) return;
    }
    const t = std.Thread.spawn(.{}, run, .{a}) catch return;
    t.detach();
}

fn off(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "no");
}

fn run(a: *App) void {
    // The desktop waits so launch stays quick. This thread is not the frame.
    const home = if (a.env) |env| env.get("HOME") orelse return else return;
    const managed = std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff", .{home}) catch return;
    defer a.gpa.free(managed);
    const tag = latestTag(a) orelse return;
    defer a.gpa.free(tag);
    const current = versionOf(a, managed) orelse return;
    defer a.gpa.free(current);
    if (!newer(tag, current)) return;
    const url = std.fmt.allocPrint(a.gpa, "https://github.com/justrach/codegraff/releases/download/{s}/graff-aarch64-macos.tar.gz", .{tag}) catch return;
    defer a.gpa.free(url);
    const tar = std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff-update.tar.gz", .{home}) catch return;
    defer a.gpa.free(tar);
    if (!download(a, url, tar)) return;
    defer std.Io.Dir.cwd().deleteFile(a.io, tar) catch {};
    const stage = std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff-update-stage", .{home}) catch return;
    defer a.gpa.free(stage);
    std.Io.Dir.cwd().deleteTree(a.io, stage) catch {};
    std.Io.Dir.cwd().createDirPath(a.io, stage) catch return;
    defer std.Io.Dir.cwd().deleteTree(a.io, stage) catch {};
    var child = std.process.spawn(a.io, .{
        .argv = &.{ "tar", "-xzf", tar, "-C", stage },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    const term = child.wait(a.io) catch return;
    if (term != .exited or term.exited != 0) return;
    const extracted = findGraff(a, stage) orelse return;
    defer a.gpa.free(extracted);
    // Rename over the live path. A running graff keeps its old inode.
    std.Io.Dir.cwd().deleteFile(a.io, managed) catch {};
    std.Io.Dir.cwd().rename(extracted, std.Io.Dir.cwd(), managed, a.io) catch return;
    std.log.info("harness-nano: graff {s} -> {s}", .{ current, tag });
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
    const objc = @import("nanoui").objc;
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
    const objc = @import("nanoui").objc;
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

fn versionOf(a: *App, path: []const u8) ?[]u8 {
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
    const out_bytes = std.Io.Dir.cwd().readFileAlloc(a.io, out_path, a.gpa, .limited(4096)) catch return null;
    defer a.gpa.free(out_bytes);
    std.Io.Dir.cwd().deleteFile(a.io, out_path) catch {};
    return dotted(a.gpa, out_bytes);
}

fn dotted(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
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

fn newer(tag: []const u8, current: []const u8) bool {
    const left = std.mem.trimStart(u8, tag, "v");
    var a = std.mem.splitScalar(u8, left, '.');
    var b = std.mem.splitScalar(u8, current, '.');
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
