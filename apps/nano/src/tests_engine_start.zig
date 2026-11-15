//! POSIX process-spawn tests for `engine_start.zig`, isolated inside
//! `std.testing.tmpDir` so sandboxed runners never touch `/tmp`.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const engine_start = @import("engine_start.zig");
const Map = std.process.Environ.Map;
const testing = std.testing;

extern "c" fn getpgid(pid: std.c.pid_t) std.c.pid_t;

fn tmpBasePath(tmp: *std.testing.TmpDir) ![:0]u8 {
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    return std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
}

fn writeExecutableScript(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
    const z = try testing.allocator.dupeSentinel(u8, path, 0);
    defer testing.allocator.free(z);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(z, 0o755));
}

/// Polls for `path` (up to 5 s) and returns its contents.
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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpBasePath(&tmp);
    defer testing.allocator.free(base);

    const script = try std.fs.path.join(testing.allocator, &.{ base, "nano-engine-start.sh" });
    defer testing.allocator.free(script);
    const args_path = try std.fmt.allocPrint(testing.allocator, "{s}.args", .{script});
    defer testing.allocator.free(args_path);
    const term_path = try std.fmt.allocPrint(testing.allocator, "{s}.term", .{script});
    defer testing.allocator.free(term_path);

    // A stand-in for `harness`: says how it was started, and whether SIGTERM
    // stopped it.
    try writeExecutableScript(script,
        \\#!/bin/sh
        \\echo "$1 $HARNESS_IPC_PORT" > "$0.args"
        \\trap 'echo stopped > "$0.term"; exit 0' TERM
        \\while :; do sleep 0.05; done
        \\
    );

    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HARNESS_NANO_ENGINE_BIN", script);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HARNESS_IPC_PORT", "27991");
    var a: App = .init(testing.allocator, testing.io, 1);
    var app_alive = true;
    defer if (app_alive) a.deinit();
    a.env = &env;

    engine_start.tick(&a);
    try testing.expectEqual(engine_start.Status.starting, a.engine_start.status);
    try testing.expectEqualStrings("Starting the engine…", engine_start.waiting(&a));
    const pid = a.engine_start.pid orelse return error.NotStarted;
    var pid_reaped = false;
    defer if (!pid_reaped) {
        _ = std.c.kill(pid, .KILL);
        _ = std.c.waitpid(pid, null, 0);
    };
    const args = try waitForFile(args_path);
    defer testing.allocator.free(args);
    try testing.expectEqualStrings("headless 27991\n", args);
    // Still running: a second tick doesn't start another.
    engine_start.tick(&a);
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
    pid_reaped = true;
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
        engine_start.tick(&a);
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try testing.expectEqual(@as(u8, engine_start.max_failed), a.engine_start.failed);
    try testing.expect(a.engine_start.pid == null);
    try testing.expectEqual(engine_start.Status.failed, a.engine_start.status);
    try testing.expect(std.mem.startsWith(u8, engine_start.waiting(&a), "The engine didn't start"));
}

test "replaces an older background engine session with the updated engine instead of showing a warning banner" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpBasePath(&tmp);
    defer testing.allocator.free(data_dir);

    const lock_path = try std.fs.path.join(testing.allocator, &.{ data_dir, "engine.lock" });
    defer testing.allocator.free(lock_path);
    const old_script = try std.fs.path.join(testing.allocator, &.{ data_dir, "old-engine.sh" });
    defer testing.allocator.free(old_script);
    const old_term = try std.fmt.allocPrint(testing.allocator, "{s}.term", .{old_script});
    defer testing.allocator.free(old_term);
    const new_script = try std.fs.path.join(testing.allocator, &.{ data_dir, "new-engine.sh" });
    defer testing.allocator.free(new_script);
    const new_args = try std.fmt.allocPrint(testing.allocator, "{s}.args", .{new_script});
    defer testing.allocator.free(new_args);

    try writeExecutableScript(old_script,
        \\#!/bin/sh
        \\printf "%s\n" "$$" > "$HARNESS_DATA_DIR/engine.lock"
        \\trap 'echo old-stopped > "$0.term"; exit 0' TERM
        \\while :; do sleep 0.05; done
        \\
    );
    try writeExecutableScript(new_script,
        \\#!/bin/sh
        \\echo "new-started $1 $HARNESS_IPC_PORT" > "$0.args"
        \\trap 'exit 0' TERM
        \\while :; do sleep 0.05; done
        \\
    );

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
    var old_reaped = false;
    defer if (!old_reaped) {
        _ = std.c.kill(old_pid, .KILL);
        _ = std.c.waitpid(old_pid, null, 0);
    };

    const locked_pid_str = try waitForFile(lock_path);
    defer testing.allocator.free(locked_pid_str);
    try testing.expectEqual(@as(?i64, old_pid), engine_start.parseLockPid(locked_pid_str, std.c.getpid()));

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
    old_reaped = true;

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
