//! Live `WatchToolProgress` stream for the focused chat (`crates/ui/src/state.rs`):
//! rolling tool output tails, live subagent states (`running` / `completed` /
//! `failed` / `cancelled`), `harness:build-wait`, and cross-turn `graff/waiting`
//! background subagents and jobs while a session is parked.
const std = @import("std");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const Allocator = std.mem.Allocator;

pub const build_wait_tool_id = "harness:build-wait";
pub const graff_waiting_tool_id = "harness:graff-waiting";

pub const Item = struct {
    tool_id: []const u8,
    output: []const u8,
    state: ?[]const u8 = null,
};

pub const WaitingAgent = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    model: []const u8 = "",
    task: []const u8 = "",
};

pub const WaitingJob = struct {
    id: []const u8 = "",
    command: []const u8 = "",
};

pub const Waiting = struct {
    text: []const u8 = "",
    state: []const u8 = "parked",
    wakes: bool = true,
    agents: []WaitingAgent = &.{},
    jobs: []WaitingJob = &.{},
};

pub const State = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    waiting: ?Waiting = null,
    build_wait_since_ms: ?i64 = null,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(s: *State) void {
        s.arena.deinit();
    }

    pub fn clear(s: *State, a: ?*App) void {
        const old = s.arena;
        s.arena = .init(s.gpa);
        s.items = &.{};
        s.waiting = null;
        s.build_wait_since_ms = null;
        if (a) |app| app.retireArena(old) else {
            var ar = old;
            ar.deinit();
        }
    }

    pub fn find(s: *const State, tool_id: []const u8) ?Item {
        if (tool_id.len == 0) return null;
        for (s.items) |item| {
            if (std.mem.eql(u8, item.tool_id, tool_id)) return item;
        }
        return null;
    }

    pub fn replace(s: *State, a: ?*App, v: std.json.Value) !void {
        if (v != .array) return;
        var next_arena: std.heap.ArenaAllocator = .init(s.gpa);
        errdefer next_arena.deinit();
        const ar = next_arena.allocator();

        var list: std.ArrayList(Item) = .empty;
        var next_waiting: ?Waiting = null;
        var next_build_wait: ?i64 = null;

        for (v.array.items) |raw| {
            if (raw != .object) continue;
            const o = raw.object;
            const id_val = o.get("toolId") orelse continue;
            if (id_val != .string or id_val.string.len == 0) continue;
            const out_str = if (o.get("output")) |ov| (if (ov == .string) ov.string else "") else "";
            const state_str: ?[]const u8 = if (o.get("state")) |sv| (if (sv == .string and sv.string.len > 0) sv.string else null) else null;

            const dup_id = try ar.dupe(u8, id_val.string);
            const dup_out = try ar.dupe(u8, out_str);
            const dup_state = if (state_str) |st| try ar.dupe(u8, st) else null;
            try list.append(ar, .{ .tool_id = dup_id, .output = dup_out, .state = dup_state });

            if (std.mem.eql(u8, dup_id, build_wait_tool_id)) {
                next_build_wait = parseBuildWaitSince(dup_out);
            } else if (std.mem.eql(u8, dup_id, graff_waiting_tool_id)) {
                next_waiting = parseWaiting(ar, dup_out, dup_state) catch null;
            }
        }

        const old = s.arena;
        s.arena = next_arena;
        s.items = list.items;
        s.waiting = next_waiting;
        s.build_wait_since_ms = next_build_wait;
        if (a) |app| app.retireArena(old) else {
            var old_ar = old;
            old_ar.deinit();
        }
    }
};

fn parseBuildWaitSince(output: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(i64, trimmed, 10)) |ms| return ms else |_| {}
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("sinceMs")) |v| if (v == .integer) return v.integer;
    }
    return null;
}

fn parseWaiting(ar: Allocator, output: []const u8, state: ?[]const u8) !?Waiting {
    if (state) |st| {
        if (std.mem.eql(u8, st, "completed") or std.mem.eql(u8, st, "cancelled") or std.mem.eql(u8, st, "failed")) return null;
    }
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ar, trimmed, .{});
    if (parsed != .object) return null;
    const o = parsed.object;
    const text = if (o.get("text")) |tv| (if (tv == .string) try ar.dupe(u8, tv.string) else "") else "";
    const wakes = if (o.get("wakes")) |wv| (if (wv == .bool) wv.bool else true) else true;

    var agents: std.ArrayList(WaitingAgent) = .empty;
    if (o.get("agents")) |av| if (av == .array) {
        for (av.array.items) |item| {
            if (item != .object) continue;
            const ao = item.object;
            const id = strField(ao, "id") orelse strField(ao, "agentId") orelse "";
            const name = strField(ao, "name") orelse strField(ao, "label") orelse "";
            const model = strField(ao, "model") orelse "";
            const task = strField(ao, "task") orelse strField(ao, "description") orelse "";
            if (id.len == 0 and name.len == 0 and task.len == 0) continue;
            try agents.append(ar, .{
                .id = try ar.dupe(u8, id),
                .name = try ar.dupe(u8, name),
                .model = try ar.dupe(u8, model),
                .task = try ar.dupe(u8, task),
            });
        }
    };

    var jobs: std.ArrayList(WaitingJob) = .empty;
    if (o.get("jobs")) |jv| if (jv == .array) {
        for (jv.array.items) |item| {
            if (item != .object) continue;
            const jo = item.object;
            const id = strField(jo, "id") orelse strField(jo, "jobId") orelse "";
            const cmd = strField(jo, "command") orelse strField(jo, "label") orelse strField(jo, "title") orelse "";
            if (id.len == 0 and cmd.len == 0) continue;
            try jobs.append(ar, .{
                .id = try ar.dupe(u8, id),
                .command = try ar.dupe(u8, cmd),
            });
        }
    };

    if (text.len == 0 and agents.items.len == 0 and jobs.items.len == 0) return null;
    return .{
        .text = text,
        .state = state orelse "parked",
        .wakes = wakes,
        .agents = agents.items,
        .jobs = jobs.items,
    };
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

pub fn watch(a: *App) void {
    const chat = a.selected orelse return;
    if (a.engine.state != .connected or a.w_progress.id != null) return;
    a.w_progress = .{ .id = a.send_(requests.watchToolProgress(chat), .of(App, a, onProgress)) };
}

pub fn stop(a: *App) void {
    if (a.w_progress.id) |id| a.engine.cancel(id);
    a.w_progress = .{};
    a.tool_progress.clear(a);
}

pub fn tick(a: *App, now: f64) ?f64 {
    if (a.w_progress.retry_at) |t| {
        if (now >= t) {
            a.w_progress = .{};
            watch(a);
        } else return t;
    }
    return null;
}

fn onProgress(a: *App, id: u64, r: rpc.Reply) void {
    if (a.w_progress.id != id) return;
    switch (r) {
        .item => |v| a.tool_progress.replace(a, v) catch {},
        .done, .err => {
            a.w_progress.id = null;
            if (a.engine.state == .connected) a.w_progress.retry_at = a.now + 2.0;
        },
        .ok => {},
    }
    a.redraw();
}
