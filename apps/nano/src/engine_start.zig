//! An engine when none answers: `harness headless`, started as a person
//! would start it from a terminal, with this app's environment (so its
//! `HARNESS_IPC_PORT` and `HARNESS_DATA_DIR`), its output in Harness's logs
//! folder (`harness-nano-engine.log`).
//!
//! No engine is ever stopped from here, the one started here included: it
//! is the machine's engine from then on. Harness.app and every other chat
//! attach to whatever engine answers on the port, so stopping this one at
//! quit stopped all of their runs too, and Harness.app restarted. It runs
//! in its own process group, so a signal meant for this app's group
//! doesn't reach it either.
//!
//! `HARNESS_NANO_NO_ENGINE_START` keeps the old behaviour: wait for one.
const std = @import("std");
const builtin = @import("builtin");
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
    /// Single-shot guard (`decideEngineVersionAction` in `view_updates.zig`):
    /// true once this app session has killed an older background engine so it
    /// never loops if the fallback binary on disk is also older.
    replaced_once: bool = false,
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
    if (comptime builtin.os.tag == .windows) {
        const w = struct {
            extern "c" fn _access(p: [*:0]const u8, mode: c_int) c_int;
        };
        return w._access(z, 0) == 0;
    }
    return std.c.access(z, std.c.X_OK) == 0;
}

/// After the connection drops (or never came up): look now, then every
/// couple of seconds until an engine answers.
pub fn disconnected(a: *App) void {
    if (!enabled(a)) return;
    tick(a);
    if (builtin.is_test or a.engine_start.ticking) return;
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

fn resolveDataDir(a: *const App) ?[]const u8 {
    if (a.settings.dataDir()) |dir| return dir;
    if (a.env) |env| if (env.get("HARNESS_DATA_DIR")) |dir| if (dir.len > 0) return dir;
    return null;
}

/// Pure parser for `{data_dir}/engine.lock` (`crates/engine/src/instance_lock.rs`),
/// rejecting non-numeric contents, init/system PIDs (`<= 1`), and `self_pid`.
pub fn parseLockPid(raw: []const u8, self_pid: i64) ?i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const pid = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    if (pid <= 1 or pid == self_pid) return null;
    return pid;
}

/// Kills the background `harness headless` process recorded in
/// `{data_dir}/engine.lock` (or `engine.lock.pid` on Windows) so a newly
/// updated app can immediately start its bundled engine in place.
pub fn killLockedEngine(a: *App) bool {
    if (comptime builtin.os.tag == .ios) return false;
    if (a.offscreen or a.engine.scene != null) return false;
    const dir = resolveDataDir(a) orelse return false;
    const lock_file = if (comptime builtin.os.tag == .windows) "engine.lock.pid" else "engine.lock";
    const lock_path = std.fs.path.join(a.gpa, &.{ dir, lock_file }) catch return false;
    defer a.gpa.free(lock_path);
    const raw = std.Io.Dir.cwd().readFileAlloc(a.io, lock_path, a.gpa, .limited(64)) catch return false;
    defer a.gpa.free(raw);

    if (comptime builtin.os.tag == .windows) {
        const w = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
            extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) ?*anyopaque;
            extern "kernel32" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) callconv(.winapi) i32;
            extern "kernel32" fn WaitForSingleObject(hHandle: *anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
            extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;
        };
        const self_pid: i64 = @intCast(w.GetCurrentProcessId());
        const pid_i64 = parseLockPid(raw, self_pid) orelse return false;
        const pid: u32 = @intCast(pid_i64);
        // PROCESS_TERMINATE (0x0001) | SYNCHRONIZE (0x00100000)
        const handle = w.OpenProcess(0x00100001, 0, pid) orelse return false;
        defer _ = w.CloseHandle(handle);
        _ = w.TerminateProcess(handle, 0);
        _ = w.WaitForSingleObject(handle, 400);
        return true;
    } else {
        const self_pid: i64 = @intCast(std.c.getpid());
        const pid_i64 = parseLockPid(raw, self_pid) orelse return false;
        const pid: std.c.pid_t = @intCast(pid_i64);
        if (std.c.kill(pid, std.c.SIG.TERM) != 0) return false;
        var step: usize = 0;
        while (step < 15) : (step += 1) {
            if (std.c.kill(pid, @enumFromInt(0)) != 0) return true;
            std.Io.sleep(a.io, .fromMilliseconds(20), .awake) catch break;
        }
        _ = std.c.kill(pid, std.c.SIG.KILL);
        std.Io.sleep(a.io, .fromMilliseconds(60), .awake) catch {};
        return true;
    }
}

/// Stops the running background engine before restarting into an app update.
pub fn stopForUpdate(a: *App) void {
    if (builtin.is_test or a.offscreen or a.engine.scene != null) return;
    _ = a.engine.call("StopEngine", .{}, .of(App, a, App.onNotice));
    _ = killLockedEngine(a);
}

/// Kills an older background `harness headless` process discovered on
/// `EngineInfo` and immediately boots the current app's engine in its place.
pub fn replaceOlderEngine(a: *App) void {
    const s = &a.engine_start;
    s.replaced_once = true;
    a.view.sidebar_notice_len = 0;
    _ = a.engine.call("StopEngine", .{}, .of(App, a, App.onNotice));
    const killed = killLockedEngine(a);
    s.pid = null;
    s.answered = false;
    s.failed = 0;
    s.last_start = std.math.minInt(i64) / 2;
    if (killed) {
        a.engine.disconnectForRestart();
        a.engine.state = .disconnected;
        if (a.engine.events.state) |f| {
            f(a.engine.events.ctx, .disconnected);
        } else {
            disconnected(a);
        }
    } else {
        a.engine.reconnect_fast.store(true, .release);
    }
}

fn enabled(a: *const App) bool {
    if (comptime builtin.os.tag == .ios) return false;
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
            setStatus(a, .starting);
        },
    }
}

/// The engine started from here, if it has stopped: let it go, and count
/// it when it stopped before answering.
fn reap(s: *State) void {
    if (comptime builtin.os.tag == .ios) return;
    const pid = s.pid orelse return;
    if (comptime builtin.os.tag == .windows) {
        const w = struct {
            extern "kernel32" fn WaitForSingleObject(hHandle: *anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
            extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;
        };
        if (w.WaitForSingleObject(pid, 0) == 0x00000102) return;
        _ = w.CloseHandle(pid);
    } else {
        if (std.c.waitpid(pid, null, std.c.W.NOHANG) == 0) return;
    }
    s.pid = null;
    if (!s.answered) s.failed += 1;
}

fn spawn(a: *App, path: []const u8) !std.c.pid_t {
    if (comptime !std.process.can_spawn) return error.UnsupportedPlatform;
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
        // A group of its own: it outlives this app and its signals.
        .pgid = if (builtin.os.tag == .windows) null else 0,
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
        "/Users/synthetic" ++ std.fs.path.sep_str ++ "Applications/Harness.app/Contents/MacOS/harness",
        "/opt/a" ++ std.fs.path.sep_str ++ "harness",
        "/usr/local/bin" ++ std.fs.path.sep_str ++ "harness",
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "parseLockPid extracts valid engine lock pid and rejects invalid or self pids" {
    try testing.expectEqual(@as(?i64, 68856), parseLockPid("68856\n", 71378));
    try testing.expectEqual(@as(?i64, 4242), parseLockPid("  4242 ", 71378));
    try testing.expectEqual(@as(?i64, null), parseLockPid("71378\n", 71378));
    try testing.expectEqual(@as(?i64, null), parseLockPid("1\n", 71378));
    try testing.expectEqual(@as(?i64, null), parseLockPid("0\n", 71378));
    try testing.expectEqual(@as(?i64, null), parseLockPid("-5\n", 71378));
    try testing.expectEqual(@as(?i64, null), parseLockPid("", 71378));
    try testing.expectEqual(@as(?i64, null), parseLockPid("unknown", 71378));
}

extern "c" fn getpgid(pid: std.c.pid_t) std.c.pid_t;

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

test "starts `harness headless` with this app's environment, and quitting leaves it running for everyone else" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var name_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&name_buf, "/tmp/nano-engine-start-{d}.sh", .{std.c.getpid()});
    var path_buf: [160]u8 = undefined;
    const args_path = try std.fmt.bufPrint(&path_buf, "{s}.args", .{script});
    var term_buf: [160]u8 = undefined;
    const term_path = try std.fmt.bufPrint(&term_buf, "{s}.term", .{script});
    // A stand-in for `harness`: says how it was started, and whether SIGTERM
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
    var app_alive = true;
    defer if (app_alive) a.deinit();
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

    // Out of this app's process group.
    try testing.expectEqual(pid, getpgid(pid));
    // The app quits: Harness.app and other chats may be on this engine now.
    a.deinit();
    app_alive = false;
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, term_path, .{}));
    try testing.expectEqual(@as(c_int, 0), std.c.waitpid(pid, null, std.c.W.NOHANG));
    // The test's own cleanup.
    _ = std.c.kill(pid, .KILL);
    _ = std.c.waitpid(pid, null, 0);
}

test "a start that never answers counts as failed, and three in a row give up" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
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

test "replaces an older background engine session with the updated engine instead of showing a warning banner" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var dir_buf: [128]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/nano-engine-replace-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().createDirPath(testing.io, data_dir) catch {};

    var lock_buf: [160]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/engine.lock", .{data_dir});
    var old_script_buf: [160]u8 = undefined;
    const old_script = try std.fmt.bufPrint(&old_script_buf, "{s}/old-engine.sh", .{data_dir});
    var old_term_buf: [160]u8 = undefined;
    const old_term = try std.fmt.bufPrint(&old_term_buf, "{s}/old-engine.sh.term", .{data_dir});
    var new_script_buf: [160]u8 = undefined;
    const new_script = try std.fmt.bufPrint(&new_script_buf, "{s}/new-engine.sh", .{data_dir});
    var new_args_buf: [160]u8 = undefined;
    const new_args = try std.fmt.bufPrint(&new_args_buf, "{s}/new-engine.sh.args", .{data_dir});

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = old_script, .data =
        \\#!/bin/sh
        \\printf "%s\n" "$$" > "$HARNESS_DATA_DIR/engine.lock"
        \\trap 'echo old-stopped > "$0.term"; exit 0' TERM
        \\while :; do sleep 0.05; done
        \\
    });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = new_script, .data =
        \\#!/bin/sh
        \\echo "new-started $1 $HARNESS_IPC_PORT" > "$0.args"
        \\trap 'exit 0' TERM
        \\while :; do sleep 0.05; done
        \\
    });
    defer {
        for ([_][]const u8{ lock_path, old_script, old_term, new_script, new_args }) |p| {
            std.Io.Dir.cwd().deleteFile(testing.io, p) catch {};
        }
        std.Io.Dir.cwd().deleteDir(testing.io, data_dir) catch {};
    }

    for ([_][]const u8{ old_script, new_script }) |p| {
        const z = try testing.allocator.dupeSentinel(u8, p, 0);
        defer testing.allocator.free(z);
        try testing.expectEqual(@as(c_int, 0), std.c.chmod(z, 0o755));
    }

    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HARNESS_DATA_DIR", data_dir);
    try env.put("HARNESS_NANO_ENGINE_BIN", new_script);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HARNESS_IPC_PORT", "27992");

    const old_child = try std.process.spawn(testing.io, .{
        .argv = &.{old_script},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const old_pid = old_child.id orelse return error.NoPid;
    defer {
        _ = std.c.kill(old_pid, .KILL);
        _ = std.c.waitpid(old_pid, null, 0);
    }

    const locked_pid_str = try waitForFile(lock_path);
    defer testing.allocator.free(locked_pid_str);
    try testing.expectEqual(@as(?i64, old_pid), parseLockPid(locked_pid_str, std.c.getpid()));

    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.env = &env;
    a.engine.state = .connected;

    var old_info = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"version\":\"0.0.1\",\"deviceId\":\"dev-old\"}",
        .{},
    );
    defer old_info.deinit();
    a.onEngineInfo(1, .{ .ok = old_info.value });

    try testing.expectEqual(@as(usize, 0), a.view.sidebar_notice_len);
    try testing.expect(a.engine_start.replaced_once);
    const term_out = try waitForFile(old_term);
    defer testing.allocator.free(term_out);
    try testing.expectEqualStrings("old-stopped\n", term_out);
    _ = std.c.waitpid(old_pid, null, 0);

    const new_pid = a.engine_start.pid orelse return error.NewEngineNotStarted;
    defer {
        _ = std.c.kill(new_pid, .KILL);
        _ = std.c.waitpid(new_pid, null, 0);
    }
    try testing.expect(new_pid != old_pid);
    const started_args = try waitForFile(new_args);
    defer testing.allocator.free(started_args);
    try testing.expectEqualStrings("new-started headless 27992\n", started_args);

    const cur_json = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"version\":\"{s}\",\"deviceId\":\"dev-new\"}}",
        .{@import("build_info").version},
    );
    defer testing.allocator.free(cur_json);
    var new_info = try std.json.parseFromSlice(std.json.Value, testing.allocator, cur_json, .{});
    defer new_info.deinit();
    a.onEngineInfo(2, .{ .ok = new_info.value });
    try testing.expectEqual(@as(usize, 0), a.view.sidebar_notice_len);
}
