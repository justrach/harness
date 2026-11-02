//! Catching ChatGPT's loopback redirect on this computer, for a graff
//! sign-in that finishes on another one (a relayed sign-in), as the GPUI app
//! does (crates/ui/src/settings/accounts/relay_callback.rs).
//!
//! OpenAI's authorize page sends the browser to `http://127.0.0.1:<port>/…`,
//! which only the computer running graff listens on. When Settings signs in
//! a different computer, the browser here lands on that address instead, so
//! Harness listens on it briefly, hands the full address to the execution
//! device (`CompleteAgentLogin`), and graff there exchanges the code with
//! its own PKCE verifier. Tokens never pass through this computer. A busy
//! port (a local sign-in already waiting) leaves the paste field as the way
//! back.
const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const Allocator = std.mem.Allocator;

/// `WAIT`: how long the listener waits for the browser before giving the
/// port back.
pub const wait_s: i64 = 10 * 60;
/// How often the listener looks up from its port to see if it was let go.
const poll_ms: i32 = 100;
/// How long one request has to send its first line (`set_read_timeout`).
const read_ms: i64 = 5000;

const done_page = "<!doctype html><meta charset=utf-8><title>Harness</title>" ++
    "<body style=\"font-family:-apple-system,system-ui,sans-serif;margin:4rem auto;max-width:28rem\">" ++
    "<h2>Sign-in sent to Harness</h2><p>You can close this tab and go back to Harness.</p></body>";

pub const Target = struct { port: u16, path: []const u8 };

/// `callback_target`: the loopback address the authorize page redirects to,
/// its port and path (in `buf`). Null for anything but an
/// `http://127.0.0.1:<port>` redirect.
pub fn callbackTarget(buf: []u8, authorize_url: []const u8) ?Target {
    const q = std.mem.indexOfScalar(u8, authorize_url, '?') orelse return null;
    var query = authorize_url[q + 1 ..];
    if (std.mem.indexOfScalar(u8, query, '#')) |h| query = query[0..h];
    var it = std.mem.splitScalar(u8, query, '&');
    const raw = while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        var kb: [32]u8 = undefined;
        const k = decode(&kb, pair[0..eq]) orelse continue;
        if (std.mem.eql(u8, k, "redirect_uri")) break if (eq < pair.len) pair[eq + 1 ..] else "";
    } else return null;
    const redirect = decode(buf, raw) orelse return null;
    const prefix = "http://127.0.0.1:";
    if (redirect.len < prefix.len or !std.ascii.eqlIgnoreCase(redirect[0..prefix.len], prefix)) return null;
    const rest = redirect[prefix.len..];
    const digits = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    const port = std.fmt.parseInt(u16, rest[0..digits], 10) catch return null;
    // A URL's own port for http (80) reads as none, as `Url::port` has it.
    if (port == 80) return null;
    var path = rest[digits..];
    if (std.mem.indexOfAny(u8, path, "?#")) |end| path = path[0..end];
    if (path.len > 0 and path[0] != '/') return null;
    return .{ .port = port, .path = if (path.len == 0) "/" else path };
}

/// A query component decoded (`%XX`, `+` as a space) into `buf`.
fn decode(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n >= buf.len) return null;
        switch (s[i]) {
            '%' => {
                if (i + 3 > s.len) return null;
                buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
                i += 3;
            },
            '+' => {
                buf[n] = ' ';
                i += 1;
            },
            else => |ch| {
                buf[n] = ch;
                i += 1;
            },
        }
    }
    return buf[0..n];
}

/// `request_target`: `GET <path>?<query> HTTP/1.1` gives `<path>?<query>`,
/// only for the callback path with a query.
pub fn requestTarget(request_line: []const u8, path: []const u8) ?[]const u8 {
    var parts = std.mem.tokenizeAny(u8, request_line, " \t\r\n");
    if (!std.mem.eql(u8, parts.next() orelse return null, "GET")) return null;
    const target = parts.next() orelse return null;
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    if (!std.mem.eql(u8, target[0..q], path) or q + 1 == target.len) return null;
    return target;
}

/// Told on the listener's thread when the browser lands; the capture is
/// the callee's to `release` from then on.
pub const Landed = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, cap: *Capture) void,
};

/// A listener on the callback port until the browser arrives, the deadline
/// passes, or its owner lets it go (`cancel`, as dropping the GPUI app's
/// guard). The thread then frees the port within a poll interval.
pub const Capture = struct {
    gpa: Allocator,
    io: std.Io,
    server: net.Server,
    port: u16,
    path: []u8,
    landed: Landed,
    cancelled: std.atomic.Value(bool) = .init(false),
    /// The owner's and the thread's (or, once landed, the callee's).
    refs: std.atomic.Value(u32) = .init(2),
    /// The address the browser landed on, set before `landed` is told.
    address: []u8 = &.{},

    /// Let it go: the listener stops and the port is freed.
    pub fn cancel(c: *Capture) void {
        c.cancelled.store(true, .release);
        c.release();
    }

    pub fn isCancelled(c: *const Capture) bool {
        return c.cancelled.load(.acquire);
    }

    pub fn release(c: *Capture) void {
        if (c.refs.fetchSub(1, .acq_rel) != 1) return;
        c.gpa.free(c.path);
        c.gpa.free(c.address);
        c.gpa.destroy(c);
    }

    fn run(c: *Capture) void {
        const got = c.accept(nowMs(c.io) + wait_s * std.time.ms_per_s);
        c.server.deinit(c.io);
        if (got) |address| {
            c.address = address;
            if (!c.isCancelled()) return c.landed.func(c.landed.ctx, c);
        }
        c.release();
    }

    fn accept(c: *Capture, deadline_ms: i64) ?[]u8 {
        while (!c.isCancelled() and nowMs(c.io) < deadline_ms) {
            if (!ready(c.server.socket.handle, poll_ms)) continue;
            const stream = c.server.accept(c.io) catch |e| switch (e) {
                error.WouldBlock, error.ConnectionAborted => continue,
                else => return null,
            };
            defer stream.close(c.io);
            if (answer(c.gpa, c.io, stream, c.path)) |target| {
                defer c.gpa.free(target);
                return std.fmt.allocPrint(c.gpa, "http://127.0.0.1:{d}{s}", .{ c.port, target }) catch null;
            }
        }
        return null;
    }

    /// Reply to one request; its target (owned) when it's the callback.
    /// Anything else (a favicon request) gets a 404 and the wait goes on.
    fn answer(gpa: Allocator, io: std.Io, stream: net.Stream, path: []const u8) ?[]u8 {
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        const until = nowMs(io) + read_ms;
        const line = while (n < buf.len) {
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |end| break buf[0..end];
            const left = until - nowMs(io);
            if (left <= 0 or !ready(stream.socket.handle, @intCast(left))) return null;
            var bufs = [_][]u8{buf[n..]};
            const got = (stream.readWithControl(io, &bufs, &.{}) catch return null).data_len;
            if (got == 0) break buf[0..n];
            n += got;
        } else buf[0..n];
        const target = requestTarget(line, path);
        var wb: [512]u8 = undefined;
        var w = stream.writer(io, &wb);
        if (target != null) {
            w.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ done_page.len, done_page }) catch {};
        } else {
            w.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
        }
        w.interface.flush() catch {};
        return if (target) |t| gpa.dupe(u8, t) catch null else null;
    }
};

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

/// Whether `fd` has something to read within `ms`.
fn ready(fd: std.posix.fd_t, ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, ms) catch return false;
    return n > 0;
}

/// `start`: bind the callback port and wait on a thread of its own. Null
/// when the port is taken, so the caller relies on pasting the address.
pub fn start(gpa: Allocator, io: std.Io, port: u16, path: []const u8, landed: Landed) ?*Capture {
    if (builtin.os.tag == .windows) return null;
    const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return null;
    var server = addr.listen(io, .{}) catch return null;
    const c = gpa.create(Capture) catch {
        server.deinit(io);
        return null;
    };
    c.* = .{ .gpa = gpa, .io = io, .server = server, .port = port, .path = gpa.dupe(u8, path) catch {
        server.deinit(io);
        gpa.destroy(c);
        return null;
    }, .landed = landed };
    const t = std.Thread.spawn(.{}, Capture.run, .{c}) catch {
        server.deinit(io);
        gpa.free(c.path);
        gpa.destroy(c);
        return null;
    };
    t.detach();
    return c;
}

const testing = std.testing;

const authorize = "https://auth.openai.com/api/accounts/authorize?client_id=c&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&state=s";

test "the callback target comes only from a loopback redirect" {
    var buf: [512]u8 = undefined;
    const t = callbackTarget(&buf, authorize).?;
    try testing.expectEqual(@as(u16, 1455), t.port);
    try testing.expectEqualStrings("/auth/callback", t.path);
    var tmp: [512]u8 = undefined;
    for ([_][]const u8{
        try std.mem.replaceOwned(u8, testing.allocator, authorize, "127.0.0.1", "localhost"),
        try std.mem.replaceOwned(u8, testing.allocator, authorize, "http%3A%2F%2F", "https%3A%2F%2F"),
        try std.mem.replaceOwned(u8, testing.allocator, authorize, "%3A1455", ""),
        try testing.allocator.dupe(u8, "https://auth.openai.com/authorize?state=s"),
    }) |other| {
        defer testing.allocator.free(other);
        try testing.expect(callbackTarget(&tmp, other) == null);
    }
}

test "only the callback request counts" {
    const path = "/auth/callback";
    try testing.expectEqualStrings("/auth/callback?code=a&state=s", requestTarget("GET /auth/callback?code=a&state=s HTTP/1.1\r\n", path).?);
    try testing.expect(requestTarget("GET /favicon.ico HTTP/1.1\r\n", path) == null);
    try testing.expect(requestTarget("GET /auth/callback HTTP/1.1\r\n", path) == null);
    try testing.expect(requestTarget("POST /auth/callback?code=a HTTP/1.1\r\n", path) == null);
}

const Probe = struct {
    got: std.atomic.Value(?*Capture) = .init(null),

    fn landed(ctx: ?*anyopaque, cap: *Capture) void {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        p.got.store(cap, .release);
    }
};

/// A free loopback port, as the OS hands one out.
fn freePort() !u16 {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var probe = try addr.listen(testing.io, .{});
    defer probe.deinit(testing.io);
    return probe.socket.address.getPort();
}

fn get(port: u16, request: []const u8, reply: []u8) ![]const u8 {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    const s = try addr.connect(testing.io, .{ .mode = .stream });
    defer s.close(testing.io);
    var wb: [256]u8 = undefined;
    var w = s.writer(testing.io, &wb);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var n: usize = 0;
    while (n < reply.len) {
        var bufs = [_][]u8{reply[n..]};
        const got = (s.readWithControl(testing.io, &bufs, &.{}) catch break).data_len;
        if (got == 0) break;
        n += got;
    }
    return reply[0..n];
}

test "a browser redirect is caught and answered" {
    const port = try freePort();
    var probe: Probe = .{};
    const cap = start(testing.allocator, testing.io, port, "/auth/callback", .{ .ctx = &probe, .func = Probe.landed }) orelse return error.PortBusy;
    var reply: [1024]u8 = undefined;
    // A favicon first: a 404, and the wait goes on.
    try testing.expect(std.mem.startsWith(u8, try get(port, "GET /favicon.ico HTTP/1.1\r\n\r\n", &reply), "HTTP/1.1 404"));
    try testing.expect(probe.got.load(.acquire) == null);
    const r = try get(port, "GET /auth/callback?code=abc&state=st HTTP/1.1\r\nHost: x\r\n\r\n", &reply);
    try testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, r, "Sign-in sent to Harness") != null);
    var waited: usize = 0;
    while (probe.got.load(.acquire) == null and waited < 500) : (waited += 1) try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    const landed = probe.got.load(.acquire) orelse return error.NotLanded;
    try testing.expectEqual(cap, landed);
    var want: [96]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "http://127.0.0.1:{d}/auth/callback?code=abc&state=st", .{port}), landed.address);
    // The callee's ref, then the owner's.
    landed.release();
    cap.cancel();
}

test "a busy port falls back to pasting" {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var taken = try addr.listen(testing.io, .{});
    defer taken.deinit(testing.io);
    var probe: Probe = .{};
    try testing.expect(start(testing.allocator, testing.io, taken.socket.address.getPort(), "/auth/callback", .{ .ctx = &probe, .func = Probe.landed }) == null);
}

test "let go before the browser comes, the port is freed" {
    const port = try freePort();
    var probe: Probe = .{};
    // The listener's thread frees the capture after it frees the port,
    // which can be after this test returns: an allocator that outlives it.
    const cap = start(std.heap.smp_allocator, testing.io, port, "/auth/callback", .{ .ctx = &probe, .func = Probe.landed }) orelse return error.PortBusy;
    cap.cancel();
    // Within a poll interval or so, the port binds again.
    const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        var again = addr.listen(testing.io, .{}) catch {
            try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
            continue;
        };
        again.deinit(testing.io);
        break;
    } else return error.PortHeld;
    try testing.expect(probe.got.load(.acquire) == null);
}
