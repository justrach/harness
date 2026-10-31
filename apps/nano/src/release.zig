//! The newest Harness release, from the manifest its release job attaches
//! to every GitHub release (crates/update/src/lib.rs: `{base}/manifest.json`).
//! On macOS through the system's own client (nanoui.http: NSURLSession, its
//! TLS, proxies and certificates, following the download URL's redirect to
//! GitHub's object store), so the app links no TLS of its own; elsewhere
//! over HTTPS with ALPN h2 by http-zig on a thread of its own, following up
//! to three hops.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const http_zig = @import("http_zig");
const Allocator = std.mem.Allocator;

pub const manifest_url = "https://github.com/justrach/harness/releases/latest/download/manifest.json";

pub const Check = struct {
    gpa: Allocator,
    io: std.Io,
    /// `version` from the manifest, once it came.
    latest: [32]u8 = undefined,
    latest_len: usize = 0,
    /// Called on the UI thread when it came.
    done: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    pub fn version(c: *const Check) ?[]const u8 {
        return if (c.latest_len == 0) null else c.latest[0..c.latest_len];
    }

    /// Checks once, in the background; `c` must stay where it is.
    pub fn start(c: *Check) void {
        // Decided at compile time: on macOS http-zig isn't analysed or linked.
        if (builtin.os.tag == .macos) {
            nanoui.http.fetch(c.gpa, .{
                .url = manifest_url,
                .headers = &.{.{ .name = "User-Agent", .value = "harness-nano" }},
            }, c, loaded);
        } else {
            const t = std.Thread.spawn(.{}, work, .{c}) catch return;
            t.detach();
        }
    }

    /// On the UI thread: the manifest, or why there was none.
    fn loaded(c: *Check, r: nanoui.http.Response) void {
        if (r.status != 200) {
            std.log.info("harness-nano: no release manifest: {s} ({d})", .{ r.err, r.status });
            return;
        }
        if (!c.take(r.body)) return;
        if (c.done) |d| d.func(d.ctx);
    }

    /// Keeps the manifest's version; false without one.
    fn take(c: *Check, body: []const u8) bool {
        const v = parseVersion(c.gpa, body) orelse return false;
        defer c.gpa.free(v);
        const n = @min(v.len, c.latest.len);
        @memcpy(c.latest[0..n], v[0..n]);
        c.latest_len = n;
        return true;
    }

    fn work(c: *Check) void {
        const body = fetch(c.gpa, c.io, manifest_url) catch |e| {
            std.log.info("harness-nano: no release manifest: {t}", .{e});
            return;
        };
        defer c.gpa.free(body);
        // Written before the UI thread is told; read only after.
        if (!c.take(body)) return;
        nanoui.App.after(0, c, delivered);
    }

    fn delivered(ctx: ?*anyopaque) callconv(.c) void {
        const c: *Check = @ptrCast(@alignCast(ctx.?));
        if (c.done) |d| d.func(d.ctx);
    }
};

/// GETs `url`'s body, following redirects.
fn fetch(gpa: Allocator, io: std.Io, url: []const u8) ![]u8 {
    var next: []u8 = try gpa.dupe(u8, url);
    defer gpa.free(next);
    for (0..4) |_| {
        const u = try http_zig.https.parseHttpsUrl(next);
        const s = try http_zig.Session.open(gpa, io, u.host, u.port);
        defer s.close();
        var res = try s.request(.{
            .method = "GET",
            .scheme = "https",
            .authority = u.host,
            .path = u.path,
            .extra = &.{.{ .name = "user-agent", .value = "harness-nano" }},
        });
        defer res.deinit();
        if (res.status >= 300 and res.status < 400) {
            const loc = header(res.headers, "location") orelse return error.BadRedirect;
            const to = try gpa.dupe(u8, loc);
            gpa.free(next);
            next = to;
            continue;
        }
        if (res.status != 200) return error.BadStatus;
        return gpa.dupe(u8, res.body);
    }
    return error.TooManyRedirects;
}

fn header(headers: []const http_zig.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// The manifest's `version`, trimmed, or null.
pub fn parseVersion(gpa: Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(struct { version: []const u8 = "" }, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const v = std.mem.trim(u8, parsed.value.version, " \n\tv");
    if (v.len == 0) return null;
    return gpa.dupe(u8, v) catch null;
}

test "the manifest's version, and none from a manifest without one" {
    const gpa = std.testing.allocator;
    const v = parseVersion(gpa, "{\"version\":\"0.2.136\",\"artifacts\":{}}").?;
    defer gpa.free(v);
    try std.testing.expectEqualStrings("0.2.136", v);
    try std.testing.expect(parseVersion(gpa, "{\"version\":\" \"}") == null);
    try std.testing.expect(parseVersion(gpa, "not json") == null);
}
