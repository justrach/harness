//! What's left behind when harness-nano dies or hangs, in Harness's logs
//! folder (`~/.harness/logs`), as the GPUI app leaves its own
//! (crates/ui/src/stall_watch.rs):
//!
//! - `harness-nano.log`: a line at launch and one at a clean exit (a launch
//!   with no exit after it was killed), and everything written to stderr
//!   when nothing reads it: a panic's message and stack trace, and a fatal
//!   signal's (the segfault handler is on in every build), and the
//!   watchdog's lines. The last launch's is kept as `harness-nano.log.old`.
//! - `harness-nano-stall-<time>.txt`: every thread's stack, sampled when the
//!   main thread stops answering (macOS's `sample`), so a hang that ends in
//!   Force Quit still says where it was. The newest three are kept.
//!
//! Content-free: no titles, prompts or paths from the workspace.
const std = @import("std");
const builtin = @import("builtin");

const log_name = "harness-nano.log";
const stall_prefix = "harness-nano-stall-";
/// A log past this is set aside at the next launch.
const rotate_bytes = 2 << 20;
const stalls_kept = 3;

/// What the watchdog does after a one-second tick (a pure rule, so a test
/// can drive it). Ticks are the watch thread's own naps: while the computer
/// sleeps, neither thread runs and no time is counted.
pub const Watch = struct {
    /// Ticks the outstanding ping has gone unanswered.
    waited: u32 = 0,
    /// Reported as stalled; the answer, when it comes, is logged.
    reported: bool = false,
    /// Ticks since the last stack sample (one at most every `sample_every`).
    since_sample: u32 = std.math.maxInt(u32) / 2,

    pub const stall_after = 3;
    pub const sample_every = 10 * 60;

    pub const Event = union(enum) {
        /// Answered: send the next ping.
        ping,
        /// Answered after a stall this many seconds long.
        resumed: u32,
        /// Unanswered this long, for the first time: log it, and sample the
        /// stacks when `sample` says so.
        stalled: struct { seconds: u32, sample: bool },
        /// Still waiting.
        wait,
    };

    pub fn tick(w: *Watch, got: bool) Event {
        w.since_sample +|= 1;
        if (got) {
            defer w.* = .{ .since_sample = w.since_sample };
            return if (w.reported) .{ .resumed = w.waited } else .ping;
        }
        w.waited += 1;
        if (w.waited < stall_after or w.reported) return .wait;
        w.reported = true;
        const sample = w.since_sample >= sample_every;
        if (sample) w.since_sample = 0;
        return .{ .stalled = .{ .seconds = w.waited, .sample = sample } };
    }
};

var logs_buf: [std.fs.max_path_bytes]u8 = undefined;
var logs: []const u8 = "";
var log_file: ?std.Io.File = null;
var global_io: std.Io = undefined;

/// Opens the log, takes stderr into it when nothing reads stderr, and
/// starts the watchdog. `data_dir` is Harness's (`~/.harness`).
pub fn start(io: std.Io, data_dir: []const u8) void {
    global_io = io;
    logs = std.fmt.bufPrint(&logs_buf, "{s}/logs", .{data_dir}) catch return;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, logs) catch return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ logs, log_name }) catch return;
    const old = std.fmt.bufPrint(&old_buf, "{s}.old", .{path}) catch return;
    // The last launch's log is kept beside this one's.
    if (cwd.statFile(io, path, .{})) |_| cwd.rename(path, cwd, old, io) catch {} else |_| {}
    const file = cwd.createFile(io, path, .{ .truncate = true }) catch return;
    log_file = file;
    if (builtin.os.tag != .windows and std.c.isatty(2) == 0) _ = std.c.dup2(file.handle, 2);
    line("started pid={d} build={s}", .{ std.c.getpid(), @tagName(builtin.mode) });
    // AppKit quits with exit(): no defer runs, its handlers do.
    if (builtin.os.tag != .windows) _ = atexit(onExit);
    if (builtin.os.tag == .macos) {
        const t = std.Thread.spawn(.{}, watch, .{}) catch return;
        t.detach();
    }
}

extern "c" fn atexit(f: *const fn () callconv(.c) void) c_int;

/// A clean exit: its line, so a log without one was killed.
fn onExit() callconv(.c) void {
    line("exited", .{});
}

/// One timestamped line in the log.
pub fn line(comptime fmt: []const u8, args: anytype) void {
    const f = log_file orelse return;
    var buf: [512]u8 = undefined;
    var w = f.writerStreaming(global_io, &buf);
    w.interface.print("[{d}] " ++ fmt ++ "\n", .{@divTrunc(std.Io.Clock.real.now(global_io).toMilliseconds(), 1000)} ++ args) catch return;
    w.interface.flush() catch {};
}

/// `HARNESS_NANO_CRASH_TEST`: "hang" holds the main thread 5 seconds,
/// "panic" panics on it, "exit" quits as AppKit does, each once the run
/// loop is going.
pub fn selfTest(what: []const u8) void {
    if (builtin.os.tag != .macos) return;
    const f: *const fn (?*anyopaque) callconv(.c) void = if (std.mem.eql(u8, what, "panic")) testPanic else if (std.mem.eql(u8, what, "hang")) testHang else if (std.mem.eql(u8, what, "exit")) testExit else return;
    dispatch_async_f(@ptrCast(&_dispatch_main_q), null, f);
}

fn testHang(_: ?*anyopaque) callconv(.c) void {
    std.Io.sleep(global_io, .fromSeconds(5), .awake) catch {};
}

fn testExit(_: ?*anyopaque) callconv(.c) void {
    std.c.exit(0);
}

fn testPanic(_: ?*anyopaque) callconv(.c) void {
    @panic("HARNESS_NANO_CRASH_TEST");
}

// The watchdog (macOS): the main queue is pinged once a second.

const dispatch_queue_t = *anyopaque;
extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async_f(queue: dispatch_queue_t, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

var sent = std.atomic.Value(u64).init(0);
var answered_seq = std.atomic.Value(u64).init(0);

fn pong(ctx: ?*anyopaque) callconv(.c) void {
    answered_seq.store(@intFromPtr(ctx), .release);
}

fn ping() void {
    const seq = sent.fetchAdd(1, .acq_rel) + 1;
    dispatch_async_f(@ptrCast(&_dispatch_main_q), @ptrFromInt(seq), pong);
}

fn watch() void {
    var w: Watch = .{};
    ping();
    while (true) {
        std.Io.sleep(global_io, .fromSeconds(1), .awake) catch {};
        switch (w.tick(answered_seq.load(.acquire) == sent.load(.acquire))) {
            .ping => ping(),
            .resumed => |s| {
                line("main thread answered again after {d}s", .{s});
                ping();
            },
            .stalled => |s| {
                line("main thread hasn't answered for {d}s", .{s.seconds});
                if (s.sample) sampleStacks();
            },
            .wait => {},
        }
    }
}

/// Every thread's stack, two seconds' worth, in a file of its own.
fn sampleStacks() void {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}/{s}{d}.txt", .{ logs, stall_prefix, @divTrunc(std.Io.Clock.real.now(global_io).toMilliseconds(), 1000) }) catch return;
    var pid_buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch return;
    var child = std.process.spawn(global_io, .{
        .argv = &.{ "/usr/bin/sample", pid, "2", "-file", name },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| return line("couldn't sample the stacks: {t}", .{e});
    _ = child.wait(global_io) catch {};
    line("stacks sampled: {s}", .{std.fs.path.basename(name)});
    prune();
}

/// The newest samples kept, the rest removed.
fn prune() void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(global_io, logs, .{ .iterate = true }) catch return;
    defer dir.close(global_io);
    var names: [64][64]u8 = undefined;
    var lens: [64]usize = undefined;
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(global_io) catch null) |e| {
        if (n == names.len or !std.mem.startsWith(u8, e.name, stall_prefix) or e.name.len > 64) continue;
        @memcpy(names[n][0..e.name.len], e.name);
        lens[n] = e.name.len;
        n += 1;
    }
    if (n <= stalls_kept) return;
    // Names carry the time: the smallest are the oldest.
    for (0..n - stalls_kept) |_| {
        var oldest: usize = 0;
        for (1..n) |i| if (std.mem.order(u8, names[i][0..lens[i]], names[oldest][0..lens[oldest]]) == .lt) {
            oldest = i;
        };
        dir.deleteFile(global_io, names[oldest][0..lens[oldest]]) catch {};
        names[oldest] = names[n - 1];
        lens[oldest] = lens[n - 1];
        n -= 1;
    }
}

test "the watchdog: a ping a second, a stall at 3 unanswered, sampled at most every 10 minutes" {
    var w: Watch = .{};
    try std.testing.expectEqual(Watch.Event.ping, w.tick(true));
    try std.testing.expectEqual(Watch.Event.wait, w.tick(false));
    try std.testing.expectEqual(Watch.Event.wait, w.tick(false));
    // Three seconds unanswered: reported once, with a sample.
    try std.testing.expectEqualDeep(Watch.Event{ .stalled = .{ .seconds = 3, .sample = true } }, w.tick(false));
    try std.testing.expectEqual(Watch.Event.wait, w.tick(false));
    // Answered: how long it was.
    try std.testing.expectEqualDeep(Watch.Event{ .resumed = 4 }, w.tick(true));
    try std.testing.expectEqual(Watch.Event.ping, w.tick(true));
    // Another stall soon after: reported, but not sampled again.
    for (0..2) |_| _ = w.tick(false);
    try std.testing.expectEqualDeep(Watch.Event{ .stalled = .{ .seconds = 3, .sample = false } }, w.tick(false));
}
