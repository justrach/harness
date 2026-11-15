//! Native Extensions ABI v1 JSON serializer and value formatters for
//! the GitHub Actions runners status panel.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const plugin = @import("github_runners_plugin.zig");
const Snapshot = plugin.Snapshot;
const WorkerStatus = plugin.WorkerStatus;
const CompletedJob = plugin.CompletedJob;

pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const gib: f64 = 1024.0 * 1024.0 * 1024.0;
    const mib: f64 = 1024.0 * 1024.0;
    const f: f64 = @floatFromInt(bytes);
    if (f >= gib) return std.fmt.bufPrint(buf, "{d:.1} GiB", .{f / gib}) catch "-";
    if (f >= mib) return std.fmt.bufPrint(buf, "{d:.0} MiB", .{f / mib}) catch "-";
    return std.fmt.bufPrint(buf, "{d} KiB", .{bytes / 1024}) catch "-";
}

pub fn formatDuration(buf: []u8, secs_in: i64) []const u8 {
    const s: u64 = if (secs_in <= 0) 0 else @intCast(secs_in);
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ s / 3600, (s % 3600) / 60 }) catch "-";
    if (s >= 60) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ s / 60, s % 60 }) catch "-";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "-";
}

pub fn formatAgo(buf: []u8, now_epoch: i64, then_epoch: i64) []const u8 {
    const delta = now_epoch - then_epoch;
    if (delta < 45) return "just now";
    if (delta < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divFloor(delta, 60)}) catch "recent";
    if (delta < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divFloor(delta, 3600)}) catch "recent";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divFloor(delta, 86400)}) catch "recent";
}

pub fn buildPanelJson(a: Allocator, s: Snapshot) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: json.Stringify = .{ .writer = &aw.writer };

    const online_cnt: usize = @as(usize, @intFromBool(s.workers[0].proc.listener_alive)) +
        @intFromBool(s.workers[1].proc.listener_alive);
    const busy_cnt: usize = @as(usize, @intFromBool(s.workers[0].proc.worker_alive or s.workers[0].active_job != null)) +
        @intFromBool(s.workers[1].proc.worker_alive or s.workers[1].active_job != null);
    const routing = if (online_cnt > 0 and !s.paused) "Local active" else "Cloud fallback";
    const hb_label = if (s.paused or !s.heartbeat_online) "Offline" else "Online";

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    var b4: [32]u8 = undefined;

    const online_str = std.fmt.bufPrint(&b1, "{d} / 2", .{online_cnt}) catch "0 / 2";
    const busy_str = std.fmt.bufPrint(&b2, "{d}", .{busy_cnt}) catch "0";
    const disk_str = if (s.disk_free_bytes) |bytes| formatBytes(&b3, bytes) else "—";
    const lock_str = if (s.lock_pid) |pid| (std.fmt.bufPrint(&b4, "Held · PID {d}", .{pid}) catch "Held") else "Free";

    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(1);
    try jw.objectField("panel");
    try jw.beginObject();
    try jw.objectField("title");
    try jw.write("GitHub Actions Runners");
    try jw.objectField("root");
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("column");
    try jw.objectField("children");
    try jw.beginArray();

    try writeRow(&jw, &.{
        .{ .stat = .{ .label = "Online", .value = online_str } },
        .{ .stat = .{ .label = "Busy", .value = busy_str } },
        .{ .stat = .{ .label = "Routing", .value = routing } },
        .{ .stat = .{ .label = "Disk free", .value = disk_str } },
    });
    try writeRow(&jw, &.{
        .{ .stat = .{ .label = "Heartbeat", .value = hb_label } },
        .{ .stat = .{ .label = "Build lock", .value = lock_str } },
        .{ .stat = .{ .label = "Repository", .value = if (s.repo.len > 0) s.repo else "—" } },
    });

    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("row");
    try jw.objectField("children");
    try jw.beginArray();
    for (s.workers) |w| try writeWorkerColumn(&jw, s, w);
    try jw.endArray();
    try jw.endObject();

    try writeText(&jw, "Recent completed jobs");
    if (s.recent_jobs.len == 0) {
        try writeText(&jw, "No completed jobs recorded in runner logs yet.");
    } else {
        for (s.recent_jobs) |job| {
            var lbl_buf: [128]u8 = undefined;
            var val_buf: [64]u8 = undefined;
            var ago_buf: [24]u8 = undefined;
            const lbl = std.fmt.bufPrint(&lbl_buf, "{s} · {s}", .{ job.worker, job.job }) catch job.job;
            const ago = formatAgo(&ago_buf, s.now_epoch, job.epoch);
            const val = std.fmt.bufPrint(&val_buf, "{s} · {s}", .{ titleResult(job.result), ago }) catch job.result;
            try writeStat(&jw, lbl, val);
        }
    }

    const can_pause = !s.paused and online_cnt > 0;
    try writeRow(&jw, &.{
        .{ .button = .{ .label = "Refresh", .action = "refresh" } },
        .{ .button = .{
            .label = if (can_pause) "Pause Local (Cloud Fallback)" else "Resume Local Runners",
            .action = if (can_pause) "pause" else "resume",
        } },
    });

    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
    return aw.toOwnedSlice();
}

const RowItem = union(enum) {
    stat: struct { label: []const u8, value: []const u8 },
    button: struct { label: []const u8, action: []const u8 },
};

fn writeRow(jw: *json.Stringify, items: []const RowItem) !void {
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("row");
    try jw.objectField("children");
    try jw.beginArray();
    for (items) |it| switch (it) {
        .stat => |st| try writeStat(jw, st.label, st.value),
        .button => |btn| try writeButton(jw, btn.label, btn.action),
    };
    try jw.endArray();
    try jw.endObject();
}

fn writeWorkerColumn(jw: *json.Stringify, s: Snapshot, w: WorkerStatus) !void {
    var st_buf: [48]u8 = undefined;
    var dur_buf: [24]u8 = undefined;
    var pr_buf: [64]u8 = undefined;
    var mem_buf: [24]u8 = undefined;
    var ver_buf: [48]u8 = undefined;

    const status_str = if (!w.configured)
        "Unconfigured"
    else if (w.proc.worker_alive or w.active_job != null) blk: {
        if (w.active_started_epoch) |started| {
            const dur = formatDuration(&dur_buf, s.now_epoch - started);
            break :blk std.fmt.bufPrint(&st_buf, "Busy · {s}", .{dur}) catch "Busy";
        }
        break :blk "Busy";
    } else if (w.proc.listener_alive)
        "Online · Idle"
    else if (s.paused)
        "Paused"
    else
        "Offline";

    const proc_str = if (w.proc.pid) |pid| blk: {
        const mem = formatBytes(&mem_buf, w.proc.rss_bytes);
        if (w.proc.cpu_pct > 0) {
            break :blk std.fmt.bufPrint(&pr_buf, "PID {d} · {d}% CPU · {s}", .{ pid, w.proc.cpu_pct, mem }) catch "Running";
        }
        break :blk std.fmt.bufPrint(&pr_buf, "PID {d} · Idle · {s}", .{ pid, mem }) catch "Idle";
    } else if (w.proc.listener_alive) "Running" else "Stopped";

    const runner_str = if (w.version) |v| (if (w.agent_id) |id|
        std.fmt.bufPrint(&ver_buf, "v{s} · #{d}", .{ v, id }) catch v
    else
        std.fmt.bufPrint(&ver_buf, "v{s}", .{v}) catch v) else if (w.agent_id) |id|
        std.fmt.bufPrint(&ver_buf, "#{d}", .{id}) catch "—"
    else
        "—";

    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("column");
    try jw.objectField("children");
    try jw.beginArray();
    try writeStat(jw, w.name, status_str);
    try writeStat(jw, "Active job", w.active_job orelse "—");
    try writeStat(jw, "Process", proc_str);
    try writeStat(jw, "Runner", runner_str);
    try jw.endArray();
    try jw.endObject();
}

fn writeStat(jw: *json.Stringify, label: []const u8, value: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("stat");
    try jw.objectField("label");
    try jw.write(label);
    try jw.objectField("value");
    try jw.write(value);
    try jw.endObject();
}

fn writeText(jw: *json.Stringify, text: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("text");
    try jw.objectField("text");
    try jw.write(text);
    try jw.endObject();
}

fn writeButton(jw: *json.Stringify, label: []const u8, action: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("button");
    try jw.objectField("label");
    try jw.write(label);
    try jw.objectField("action");
    try jw.write(action);
    try jw.endObject();
}

fn titleResult(raw: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "succeeded")) return "Succeeded";
    if (std.ascii.eqlIgnoreCase(raw, "failed")) return "Failed";
    if (std.ascii.eqlIgnoreCase(raw, "canceled") or std.ascii.eqlIgnoreCase(raw, "cancelled")) return "Canceled";
    return raw;
}

const testing = std.testing;

test "generated panel JSON validates against extension schema across states" {
    const schema = @import("extension_panel.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = plugin.parseUtcTimestamp("2026-11-15 10:05:00Z").?;
    const done = [_]CompletedJob{.{ .worker = "worker-m3-1", .job = "clippy", .result = "Succeeded", .epoch = now - 240 }};

    const states = [_]Snapshot{
        .{
            .now_epoch = now,
            .repo = "acme/app",
            .heartbeat_known = true,
            .heartbeat_online = true,
            .disk_free_bytes = 32 * 1024 * 1024 * 1024,
            .workers = .{
                .{ .name = "worker-m3-1", .configured = true, .agent_id = 21, .version = "2.338.2", .proc = .{ .pid = 101, .listener_alive = true, .rss_bytes = 64 * 1024 * 1024 } },
                .{ .name = "worker-m3-2", .configured = true, .agent_id = 22, .version = "2.338.2", .proc = .{ .pid = 102, .listener_alive = true, .rss_bytes = 64 * 1024 * 1024 } },
            },
            .recent_jobs = &done,
        },
        .{
            .now_epoch = now,
            .repo = "acme/app",
            .heartbeat_known = true,
            .heartbeat_online = true,
            .lock_pid = 41208,
            .disk_free_bytes = 50 * 1024 * 1024 * 1024,
            .workers = .{
                .{ .name = "worker-m3-1", .configured = true, .agent_id = 21, .version = "2.338.2", .active_job = "verify", .active_started_epoch = now - 134, .proc = .{ .pid = 201, .listener_alive = true, .worker_alive = true, .cpu_pct = 184, .rss_bytes = 1500 * 1024 * 1024 } },
                .{ .name = "worker-m3-2", .configured = true, .agent_id = 22, .version = "2.338.2", .proc = .{ .pid = 202, .listener_alive = true, .rss_bytes = 68 * 1024 * 1024 } },
            },
            .recent_jobs = &done,
        },
        .{
            .now_epoch = now,
            .repo = "acme/app",
            .paused = true,
            .workers = .{
                .{ .name = "worker-m3-1", .configured = true },
                .{ .name = "worker-m3-2", .configured = true },
            },
        },
        .{
            .now_epoch = now,
            .workers = .{
                .{ .name = "worker-m3-1" },
                .{ .name = "worker-m3-2" },
            },
        },
    };
    for (states) |st| {
        const out = try buildPanelJson(a, st);
        const parsed = try json.parseFromSliceLeaky(json.Value, a, out, .{});
        try testing.expectEqual(@as(i64, 1), parsed.object.get("version").?.integer);
        try schema.validatePanel(parsed.object.get("panel").?);
    }
}
