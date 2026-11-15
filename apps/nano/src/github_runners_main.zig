//! Standalone Native Extensions ABI v1 binary for bound macOS GitHub Actions
//! runners (`harness-m3-1`, `harness-m3-2`) and cloud fallback controls.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const plugin = @import("github_runners_plugin.zig");

const default_path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return error.MissingExtensionEnvelope;

    const raw_req = args[args.len - 1];
    const req = json.parseFromSliceLeaky(json.Value, a, raw_req, .{}) catch return error.InvalidExtensionRequest;
    if (req != .object) return error.InvalidExtensionRequest;
    const version = req.object.get("version") orelse return error.InvalidExtensionRequest;
    if (version != .integer or version.integer != 1) return error.UnsupportedExtensionVersion;

    const event_val = req.object.get("event") orelse return error.InvalidExtensionRequest;
    if (event_val != .string) return error.InvalidExtensionRequest;
    const event = event_val.string;

    if (std.mem.eql(u8, event, "action")) {
        const action = extractAction(req.object.get("data")) orelse return error.MissingAction;
        try handleAction(a, init.io, init.environ_map, action);
    } else if (!std.mem.eql(u8, event, "ui")) {
        return error.UnsupportedExtensionEvent;
    }

    const snap = plugin.collect(a, init.io, init.environ_map);
    const out = try plugin.buildPanelJson(a, snap);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, out);
    try stdout.writeStreamingAll(init.io, "\n");
}

fn extractAction(data_opt: ?json.Value) ?[]const u8 {
    const data = data_opt orelse return null;
    if (data != .object) return null;
    const act = data.object.get("action") orelse return null;
    return if (act == .string and act.string.len > 0) act.string else null;
}

fn handleAction(a: Allocator, io: std.Io, env: *const std.process.Environ.Map, action: []const u8) !void {
    if (std.mem.eql(u8, action, "refresh")) return;
    const pause = std.mem.eql(u8, action, "pause");
    const unpause = std.mem.eql(u8, action, "resume");
    if (!pause and !unpause) return error.UnsupportedAction;

    if (env.get("HARNESS_GH_RUNNERS_ROOT")) |root| if (root.len > 0) {
        const state_path = try std.fmt.allocPrint(a, "{s}/heartbeat.state", .{std.mem.trimEnd(u8, root, "/")});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = if (pause) "offline\n" else "online\n" });
        return;
    };

    if (comptime builtin.os.tag != .macos) return;
    const home = env.get("HOME") orelse return error.MissingHomeDirectory;
    const repo = detectRepo(a, io, home) orelse plugin.default_repo;
    var child_env = try buildChildEnv(a, env);
    defer child_env.deinit();

    const uid = plugin.mac.getuid();
    if (pause) {
        for ([_][]const u8{ plugin.heartbeat_service, plugin.workers[0].service, plugin.workers[1].service }) |svc| {
            const target = try std.fmt.allocPrint(a, "gui/{d}/{s}", .{ uid, svc });
            _ = runCmd(a, io, &child_env, &.{ "/bin/launchctl", "bootout", target });
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plugin.heartbeat_state_path, .data = "offline\n" }) catch {};
        setHeartbeatVar(a, io, &child_env, repo, "0");
    } else {
        const domain = try std.fmt.allocPrint(a, "gui/{d}", .{uid});
        for ([_][]const u8{ plugin.workers[0].service, plugin.workers[1].service, plugin.heartbeat_service }) |svc| {
            const plist = try std.fmt.allocPrint(a, "{s}/Library/LaunchAgents/{s}.plist", .{ home, svc });
            if (!runCmd(a, io, &child_env, &.{ "/bin/launchctl", "bootstrap", domain, plist })) {
                const target = try std.fmt.allocPrint(a, "gui/{d}/{s}", .{ uid, svc });
                _ = runCmd(a, io, &child_env, &.{ "/bin/launchctl", "kickstart", "-k", target });
            }
        }
        var attempt: usize = 0;
        while (attempt < 6) : (attempt += 1) {
            if (anyListenerAlive(a, home)) break;
            std.Io.sleep(io, .fromMilliseconds(250), .awake) catch break;
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plugin.heartbeat_state_path, .data = "online\n" }) catch {};
        const now_epoch: i64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
        const epoch_str = try std.fmt.allocPrint(a, "{d}", .{now_epoch});
        setHeartbeatVar(a, io, &child_env, repo, epoch_str);
    }
}

fn buildChildEnv(a: Allocator, src: *const std.process.Environ.Map) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(a);
    errdefer out.deinit();
    var it = src.iterator();
    while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);
    if (src.get("PATH")) |existing| {
        if (existing.len > 0) {
            const merged = try std.fmt.allocPrint(a, "{s}:{s}", .{ default_path, existing });
            try out.put("PATH", merged);
            return out;
        }
    }
    try out.put("PATH", default_path);
    return out;
}

fn resolveGh(io: std.Io, a: Allocator) []const u8 {
    for ([_][]const u8{ "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh" }) |cand| {
        std.Io.Dir.cwd().access(io, cand, .{}) catch continue;
        return a.dupe(u8, cand) catch cand;
    }
    return "gh";
}

fn setHeartbeatVar(a: Allocator, io: std.Io, env: *const std.process.Environ.Map, repo: []const u8, body: []const u8) void {
    const gh = resolveGh(io, a);
    _ = runCmd(a, io, env, &.{ gh, "variable", "set", "HARNESS_MAC_HEARTBEAT", "-R", repo, "--body", body });
}

fn runCmd(a: Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) bool {
    const r = std.process.run(a, io, .{
        .argv = argv,
        .environ_map = env,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    return switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn detectRepo(a: Allocator, io: std.Io, home: []const u8) ?[]const u8 {
    for (plugin.workers) |spec| {
        const path = std.fmt.allocPrint(a, "{s}/.github-runners/{s}/.runner", .{ home, spec.dir_name }) catch continue;
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024)) catch continue;
        if (plugin.parseRunnerConfig(a, raw).repo) |repo| return repo;
    }
    return null;
}

fn anyListenerAlive(a: Allocator, home: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const bytes_need = plugin.mac.proc_listpids(plugin.mac.PROC_ALL_PIDS, 0, null, 0);
    if (bytes_need <= 0) return false;
    const cap = @as(usize, @intCast(bytes_need)) / @sizeOf(c_int) + 32;
    const pids = a.alloc(c_int, cap) catch return false;
    const got = plugin.mac.proc_listpids(plugin.mac.PROC_ALL_PIDS, 0, pids.ptr, @intCast(cap * @sizeOf(c_int)));
    if (got <= 0) return false;
    const n = @as(usize, @intCast(got)) / @sizeOf(c_int);
    const p0 = std.fmt.allocPrint(a, "{s}/.github-runners/{s}/", .{ home, plugin.workers[0].dir_name }) catch return false;
    const p1 = std.fmt.allocPrint(a, "{s}/.github-runners/{s}/", .{ home, plugin.workers[1].dir_name }) catch return false;
    var path_buf: [plugin.mac.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    for (pids[0..n]) |pid| {
        if (pid <= 0) continue;
        const plen = plugin.mac.proc_pidpath(pid, &path_buf, path_buf.len);
        if (plen <= 0) continue;
        const path = path_buf[0..@intCast(plen)];
        if (std.mem.startsWith(u8, path, p0) or std.mem.startsWith(u8, path, p1)) return true;
    }
    return false;
}
