//! Graff's generated pages, with the same fixed-ID boundary and CSP as
//! crates/ui/src/browser/saved_view.rs. No agent-provided filesystem paths.
const std = @import("std");

pub const Kind = enum { html, mcpApp };
pub const max_bytes = 16 * 1024 * 1024;
pub const html_csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'; sandbox allow-scripts";
pub const mcp_csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; frame-src data:; child-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'; sandbox allow-scripts";

pub const View = struct {
    kind: Kind,
    id: [32]u8,

    pub fn init(kind: Kind, id: []const u8) ?View {
        if (id.len != 32) return null;
        for (id) |ch| if (!(ch >= '0' and ch <= '9') and !(ch >= 'a' and ch <= 'f')) return null;
        return .{ .kind = kind, .id = id[0..32].* };
    }

    pub fn parse(value: std.json.Value) ?View {
        if (value != .object) return null;
        const kind = value.object.get("kind") orelse return null;
        const id = value.object.get("id") orelse return null;
        if (kind != .string or id != .string) return null;
        return init(std.meta.stringToEnum(Kind, kind.string) orelse return null, id.string);
    }

    pub fn url(v: View, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "graff-view://{s}/{s}", .{ if (v.kind == .html) "html" else "mcp-app", v.id });
    }

    pub fn path(v: View, gpa: std.mem.Allocator, home: []const u8) ![]u8 {
        _ = init(v.kind, &v.id) orelse return error.InvalidView;
        return std.fmt.allocPrint(gpa, "{s}/.graff/{s}/{s}.html", .{ std.mem.trimEnd(u8, home, "/"), if (v.kind == .html) "views" else "mcp-apps", v.id });
    }

    pub fn csp(v: View) []const u8 {
        return if (v.kind == .html) html_csp else mcp_csp;
    }
};

pub fn fromUrl(address: []const u8) ?View {
    const kinds = [_]struct { prefix: []const u8, kind: Kind }{
        .{ .prefix = "graff-view://html/", .kind = .html },
        .{ .prefix = "graff-view://mcp-app/", .kind = .mcpApp },
    };
    for (kinds) |k| if (std.mem.startsWith(u8, address, k.prefix)) return View.init(k.kind, address[k.prefix.len..]);
    return null;
}

pub fn allowedNavigation(view: View, address: []const u8, main_frame: bool) bool {
    if (main_frame) {
        const target = fromUrl(address) orelse return false;
        return std.meta.eql(view, target);
    }
    return std.mem.eql(u8, address, "about:srcdoc") or std.mem.eql(u8, address, "about:blank") or
        (view.kind == .mcpApp and std.mem.startsWith(u8, address, "data:text/html"));
}

/// O_NOFOLLOW refuses a symlink; O_NONBLOCK prevents a planted FIFO from
/// hanging the main thread before the regular-file check can run.
pub fn read(gpa: std.mem.Allocator, io: std.Io, home: []const u8, view: View) ![]u8 {
    const p = try view.path(gpa, home);
    defer gpa.free(p);
    const z = try gpa.allocSentinel(u8, p.len, 0);
    @memcpy(z, p);
    defer gpa.free(z);
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return error.ViewUnavailable;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > max_bytes) return error.InvalidView;
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(max_bytes));
}

test "saved views accept only fixed generated-page IDs and keep network blocked" {
    const gpa = std.testing.allocator;
    const id = "0123456789abcdef0123456789abcdef";
    for ([_]Kind{ .html, .mcpApp }) |kind| {
        const view = View.init(kind, id).?;
        const address = try view.url(gpa);
        defer gpa.free(address);
        try std.testing.expectEqualDeep(view, fromUrl(address).?);
        try std.testing.expect(allowedNavigation(view, address, true));
        try std.testing.expect(!allowedNavigation(view, "https://example.com/", true));
        try std.testing.expect(!allowedNavigation(view, "file:///synthetic", false));
        try std.testing.expect(allowedNavigation(view, "about:srcdoc", false));
        try std.testing.expectEqual(kind == .mcpApp, allowedNavigation(view, "data:text/html,synthetic", false));
        try std.testing.expect(std.mem.indexOf(u8, view.csp(), "connect-src 'none'") != null);
        const path = try view.path(gpa, "/synthetic");
        defer gpa.free(path);
        try std.testing.expect(std.mem.startsWith(u8, path, if (kind == .html) "/synthetic/.graff/views/" else "/synthetic/.graff/mcp-apps/"));
    }
    for ([_][]const u8{ "", "../synthetic", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcdef/extra" }) |bad| try std.testing.expect(View.init(.html, bad) == null);
    for ([_][]const u8{ "https://html/0123456789abcdef0123456789abcdef", "graff-view://html/0123456789abcdef0123456789abcdef?x=1", "graff-view://html/0123456789abcdef0123456789abcdef#top", "graff-view://html/..%2fsecret", "graff-view://user@html/0123456789abcdef0123456789abcdef" }) |bad| try std.testing.expect(fromUrl(bad) == null);
}

test "saved-page reads reject symlinks and directories while accepting synthetic regular files" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".graff/views");
    const id = "0123456789abcdef0123456789abcdef";
    const linked = "fedcba9876543210fedcba9876543210";
    const directory = "00000000000000000000000000000000";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".graff/views/" ++ id ++ ".html", .data = "<p>Synthetic saved page</p>" });
    try tmp.dir.symLink(testing.io, id ++ ".html", ".graff/views/" ++ linked ++ ".html", .{});
    try tmp.dir.createDirPath(testing.io, ".graff/views/" ++ directory ++ ".html");
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    const body = try read(testing.allocator, testing.io, home, View.init(.html, id).?);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("<p>Synthetic saved page</p>", body);
    try testing.expectError(error.ViewUnavailable, read(testing.allocator, testing.io, home, View.init(.html, linked).?));
    try testing.expectError(error.InvalidView, read(testing.allocator, testing.io, home, View.init(.html, directory).?));
}
