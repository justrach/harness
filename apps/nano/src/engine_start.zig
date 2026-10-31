//! An engine when none answers: `harness headless`, started as a person
//! would start it from a terminal, with this app's environment (so its
//! `HARNESS_IPC_PORT` and `HARNESS_DATA_DIR`), its output in Harness's logs
//! folder (`harness-nano-engine.log`).
//!
//! Only that engine is ever stopped from here, when the app quits: SIGTERM,
//! which drains it as launchd's stop does. An engine something else started
//! (Harness.app's, a daemon, a terminal's) is never touched. Harness.app
//! attaches to a running engine and never stops it, so if it attached to
//! this one meanwhile it loses it at quit.
//!
//! `HARNESS_NANO_NO_ENGINE_START` keeps the old behaviour: wait for one.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;

pub const Status = enum {
    /// Nothing started from here: connected, or not yet needed.
    idle,
    /// `harness headless` is running and hasn't answered yet.
    starting,
    /// No `harness` to start.
    missing,
    /// It stopped before answering, `max_failed` times in a row.
    failed,
};

pub const State = struct {
    status: Status = .idle,
    /// The engine started from here, while it runs.
    pid: ?std.c.pid_t = null,
    /// When it was last started (ms, the real clock), and whether an engine
    /// has answered since.
    last_start: i64 = std.math.minInt(i64) / 2,
    answered: bool = false,
    /// Starts in a row that ended before an engine answered.
    failed: u8 = 0,
    ticking: bool = false,
    /// What the composer says while it waits.
    message: [256]u8 = undefined,
    message_len: usize = 0,
};

/// Starts that end before an engine answers before it stops trying.
pub const max_failed = 3;
/// A start, then this long before the next.
pub const retry_ms = 10_000;
/// How often it looks while there's no engine.
const tick_ms = 2_000;

/// The engine started from here, for the exit hook.
var started: std.atomic.Value(std.c.pid_t) = .init(0);
var hooked = false;

/// What to do on a tick, from what's known (a pure rule, so a test can
/// drive it).
pub const Facts = struct {
    connected: bool,
    child_running: bool,
    found: bool,
    failed: u8,
    since_last_start_ms: i64,
};

pub const Step = enum { nothing, start, missing, give_up };

pub fn next(f: Facts) Step {
    if (f.connected or f.child_running) return .nothing;
    if (f.failed >= max_failed) return .give_up;
    if (f.since_last_start_ms < retry_ms) return .nothing;
    if (!f.found) return .missing;
    return .start;
}

/// Where `harness` may be, in order: `HARNESS_NANO_ENGINE_BIN`, the app in
/// /Applications and ~/Applications, then each directory on `PATH`.
pub fn candidates(gpa: Allocator, env: *const Map) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    if (env.get("HARNESS_NANO_ENGINE_BIN")) |p| if (p.len > 0) try out.append(gpa, try gpa.dupe(u8, p));
    const in_app = "Applications/Harness.app/Contents/MacOS/harness";
    try out.append(gpa, try gpa.dupe(u8, "/" ++ in_app));
    if (env.get("HOME")) |home| if (home.len > 0) try out.append(gpa, try std.fs.path.join(gpa, &.{ home, in_app }));
    if (env.get("PATH")) |path| {
        var dirs = std.mem.tokenizeScalar(u8, path, ':');
        while (dirs.next()) |dir| try out.append(gpa, try std.fs.path.join(gpa, &.{ dir, "harness" }));
    }
    return out.toOwnedSlice(gpa);
}

/// The first candidate this user can run (owned), or null.
pub fn find(gpa: Allocator, env: *const Map) ?[]u8 {
    const list = candidates(gpa, env) catch return null;
    defer gpa.free(list);
    var found: ?[]u8 = null;
    for (list) |p| {
        if (found == null and executable(gpa, p)) found = p else gpa.free(p);
    }
    return found;
}

fn executable(gpa: Allocator, path: []const u8) bool {
    const z = gpa.dupeSentinel(u8, path, 0) catch return false;
    defer gpa.free(z);
    return std.c.access(z, std.c.X_OK) == 0;
}

/// After the connection drops (or never came up): look now, then every
/// couple of seconds until an engine answers.
pub fn disconnected(a: *App) void {
    if (!enabled(a)) return;
    tick(a);
    if (a.engine_start.ticking) return;
    a.engine_start.ticking = true;
    nanoui.App.after(tick_ms, a, onTick);
}

/// An engine answered: whichever one it is, nothing more to start.
pub fn connected(a: *App) void {
    const s = &a.engine_start;
    if (s.pid != null) s.answered = true;
    s.failed = 0;
    setStatus(a, .idle);
}

fn enabled(a: *const App) bool {
    if (a.offscreen or a.engine.scene != null) return false;
    const env = a.env orelse return false;
    return env.get("HARNESS_NANO_NO_ENGINE_START") == null;
}

fn onTick(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    if (a.engine.state == .connected) {
        a.engine_start.ticking = false;
        return;
    }
    tick(a);
    nanoui.App.after(tick_ms, a, onTick);
}

fn tick(a: *App) void {
    const s = &a.engine_start;
    reap(s);
    const now = nowMs(a.io);
    const env = a.env orelse return;
    const path = find(a.gpa, env);
    defer if (path) |p| a.gpa.free(p);
    switch (next(.{
        .connected = a.engine.state == .connected,
        .child_running = s.pid != null,
        .found = path != null,
        .failed = s.failed,
        .since_last_start_ms = now - s.last_start,
    })) {
        .nothing => {},
        .missing => setStatus(a, .missing),
        .give_up => setStatus(a, .failed),
        .start => {
            s.last_start = now;
            s.answered = false;
            s.pid = spawn(a, path.?) catch |e| {
                std.log.warn("harness-nano: couldn't start the engine: {t}", .{e});
                s.failed += 1;
                return;
            };
            started.store(s.pid.?, .release);
            if (!hooked) hooked = atexit(onExit) == 0;
            setStatus(a, .starting);
        },
    }
}

/// The engine started from here, if it has stopped: let it go, and count
/// it when it stopped before answering.
fn reap(s: *State) void {
    const pid = s.pid orelse return;
    if (std.c.waitpid(pid, null, std.c.W.NOHANG) == 0) return;
    s.pid = null;
    _ = started.cmpxchgStrong(pid, 0, .acq_rel, .acquire);
    if (!s.answered) s.failed += 1;
}

fn spawn(a: *App, path: []const u8) !std.c.pid_t {
    var log: ?std.Io.File = null;
    if (a.settings.dataDir()) |dir| {
        const logs = try std.fs.path.join(a.gpa, &.{ dir, "logs" });
        defer a.gpa.free(logs);
        std.Io.Dir.cwd().createDirPath(a.io, logs) catch {};
        const name = try std.fs.path.join(a.gpa, &.{ logs, log_name });
        defer a.gpa.free(name);
        log = std.Io.Dir.cwd().createFile(a.io, name, .{ .truncate = true }) catch null;
    }
    defer if (log) |f| f.close(a.io);
    const out: std.process.SpawnOptions.StdIo = if (log) |f| .{ .file = f } else .ignore;
    const child = try std.process.spawn(a.io, .{
        .argv = &.{ path, "headless" },
        .environ_map = a.env,
        .stdin = .ignore,
        .stdout = out,
        .stderr = out,
    });
    return child.id orelse error.NoPid;
}

pub const log_name = "harness-nano-engine.log";

fn setStatus(a: *App, status: Status) void {
    const s = &a.engine_start;
    if (s.status == status and s.message_len > 0) return;
    s.status = status;
    const text = switch (status) {
        .idle => "",
        .starting => "Starting the engine…",
        .missing => "Harness isn't installed: install it, or start an engine with `harness headless`",
        .failed => std.fmt.bufPrint(&s.message, "The engine didn't start: see {s} in {s}/logs", .{ log_name, a.settings.dataDir() orelse "Harness's data folder" }) catch "The engine didn't start",
    };
    if (text.ptr != @as([*]const u8, &s.message)) @memcpy(s.message[0..text.len], text);
    s.message_len = text.len;
    a.redraw();
}

/// What the composer says while there's no engine.
pub fn waiting(a: *const App) []const u8 {
    const s = &a.engine_start;
    if (s.status == .idle or s.message_len == 0) return "Waiting for the engine…";
    return s.message[0..s.message_len];
}

/// Stops the engine started from here, if it still runs. Safe to call
/// more than once, and from the exit hook.
pub fn stop() void {
    const pid = started.swap(0, .acq_rel);
    if (pid == 0) return;
    // Still a child of ours and still running: 0 from a no-hang wait.
    if (std.c.waitpid(pid, null, std.c.W.NOHANG) != 0) return;
    _ = std.c.kill(pid, .TERM);
}

extern "c" fn atexit(f: *const fn () callconv(.c) void) c_int;

/// AppKit quits with exit(): no defer runs, its handlers do.
fn onExit() callconv(.c) void {
    stop();
}

fn nowMs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.real.now(io).toMilliseconds());
}

const testing = std.testing;

test "start when nothing answers and nothing of ours runs; never twice at once" {
    const base: Facts = .{ .connected = false, .child_running = false, .found = true, .failed = 0, .since_last_start_ms = std.math.maxInt(i32) };
    try testing.expectEqual(Step.start, next(base));
    var f = base;
    f.connected = true;
    try testing.expectEqual(Step.nothing, next(f));
    f = base;
    f.child_running = true;
    try testing.expectEqual(Step.nothing, next(f));
    f = base;
    f.since_last_start_ms = retry_ms - 1;
    try testing.expectEqual(Step.nothing, next(f));
    f = base;
    f.found = false;
    try testing.expectEqual(Step.missing, next(f));
    f = base;
    f.failed = max_failed;
    try testing.expectEqual(Step.give_up, next(f));
    f.failed = max_failed - 1;
    try testing.expectEqual(Step.start, next(f));
}

test "harness is looked for in the override, the app, ~/Applications, then PATH" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/Users/synthetic");
    try env.put("PATH", "/opt/a::/usr/local/bin");
    try env.put("HARNESS_NANO_ENGINE_BIN", "/tmp/fake-harness");
    const got = try candidates(testing.allocator, &env);
    defer {
        for (got) |p| testing.allocator.free(p);
        testing.allocator.free(got);
    }
    const want = [_][]const u8{
        "/tmp/fake-harness",
        "/Applications/Harness.app/Contents/MacOS/harness",
        "/Users/synthetic/Applications/Harness.app/Contents/MacOS/harness",
        "/opt/a/harness",
        "/usr/local/bin/harness",
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

/// Polls for `path` (up to 5 s) and returns its contents, trimmed.
fn waitForFile(path: []const u8) ![]u8 {
    var tries: usize = 0;
    while (tries < 250) : (tries += 1) {
        if (std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4096))) |bytes| {
            if (bytes.len > 0) return bytes;
            testing.allocator.free(bytes);
        } else |_| {}
        std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
    }
    return error.Timeout;
}

test "starts `harness headless` with this app's environment, then stops that one" {
    var name_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&name_buf, "/tmp/nano-engine-start-{d}.sh", .{std.c.getpid()});
    var path_buf: [160]u8 = undefined;
    const args_path = try std.fmt.bufPrint(&path_buf, "{s}.args", .{script});
    var term_buf: [160]u8 = undefined;
    const term_path = try std.fmt.bufPrint(&term_buf, "{s}.term", .{script});
    // A stand-in for `harness`: says how it was started, and that SIGTERM
    // stopped it.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = script, .data =
        \\#!/bin/sh
        \\echo "$1 $HARNESS_IPC_PORT" > "$0.args"
        \\trap 'echo stopped > "$0.term"; exit 0' TERM
        \\while :; do sleep 0.05; done
        \\
    });
    defer for ([_][]const u8{ script, args_path, term_path }) |p| std.Io.Dir.cwd().deleteFile(testing.io, p) catch {};
    const z = try testing.allocator.dupeSentinel(u8, script, 0);
    defer testing.allocator.free(z);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(z, 0o755));

    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HARNESS_NANO_ENGINE_BIN", script);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HARNESS_IPC_PORT", "27991");
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.env = &env;

    tick(&a);
    try testing.expectEqual(Status.starting, a.engine_start.status);
    try testing.expectEqualStrings("Starting the engine…", waiting(&a));
    const pid = a.engine_start.pid orelse return error.NotStarted;
    const args = try waitForFile(args_path);
    defer testing.allocator.free(args);
    try testing.expectEqualStrings("headless 27991\n", args);
    // Still running: a second tick doesn't start another.
    tick(&a);
    try testing.expectEqual(pid, a.engine_start.pid.?);

    stop();
    const term = try waitForFile(term_path);
    defer testing.allocator.free(term);
    try testing.expectEqualStrings("stopped\n", term);
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    a.engine_start.pid = null;
}

test "a start that never answers counts as failed, and three in a row give up" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    // `false` exits at once: an engine that stops before it answers.
    try env.put("HARNESS_NANO_ENGINE_BIN", "/usr/bin/false");
    try env.put("PATH", "");
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.env = &env;
    // Each tick: let the last one go (counted), then start again as if
    // `retry_ms` had passed, until it gives up.
    var ticks: usize = 0;
    while (a.engine_start.status != .failed and ticks < 500) : (ticks += 1) {
        a.engine_start.last_start = std.math.minInt(i64) / 2;
        tick(&a);
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try testing.expectEqual(@as(u8, max_failed), a.engine_start.failed);
    try testing.expect(a.engine_start.pid == null);
    try testing.expectEqual(Status.failed, a.engine_start.status);
    try testing.expect(std.mem.startsWith(u8, waiting(&a), "The engine didn't start"));
}
