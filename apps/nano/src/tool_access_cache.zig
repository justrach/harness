//! Release Tool Access snapshots change when tools/identity change, not
//! for every streamed reply word. Cached records own their small metadata
//! and projected I/O so a transcript reset/upsert cannot leave pointers stale.
const std = @import("std");
const access = @import("tool_access.zig");
const tr = @import("transcript.zig");
const Allocator = std.mem.Allocator;

pub const Activity = struct {
    calls: usize = 0,
    resolved: usize = 0,
    failed: usize = 0,
    running_agents: usize = 0,
};

pub fn activity(entries: []const tr.Entry) Activity {
    var result: Activity = .{};
    for (entries) |e| {
        if (e.role != .assistant) continue;
        for (e.parts.items) |p| {
            if (p.kind != .tool) continue;
            result.calls += 1;
            result.resolved += @intFromBool(p.resolved);
            result.failed += @intFromBool(p.is_error);
            result.running_agents += @intFromBool(p.subagent_status == .running);
        }
    }
    return result;
}

pub const Cache = struct {
    arena: ?std.heap.ArenaAllocator = null,
    value: ?access.Snapshot = null,
    seen: Activity = .{},
    identity: u64 = 0,
    touched: f64 = 0,
    /// Structural regression hook: narration alone must not rebuild I/O.
    rebuilds: usize = 0,

    pub fn deinit(cache: *Cache) void {
        if (cache.arena) |*arena| arena.deinit();
        cache.* = .{};
    }

    pub fn refresh(cache: *Cache, gpa: Allocator, chat: []const u8, main: access.Agent, entries: []const tr.Entry) access.Snapshot {
        const current = activity(entries);
        const identity = identityHash(main);
        const unloaded = current.calls == 0 and cache.seen.calls > 0;
        const changed = !unloaded and !std.meta.eql(current, cache.seen);
        if (!changed and cache.identity == identity) if (cache.value) |value| return value;
        var next = std.heap.ArenaAllocator.init(gpa);
        const a = next.allocator();
        const source = if (!changed and cache.value != null) cache.value.? else access.snapshot(a, chat, main, entries);
        const value = own(a, source, main) catch {
            next.deinit();
            if (cache.value) |old| return old;
            // Allocation failure: a stack-only empty snapshot, no borrowed
            // data from the temporary arena and no fabricated tool calls.
            return .{ .agents = &.{}, .nodes = .{ .{ .family = .files }, .{ .family = .mcp }, .{ .family = .search }, .{ .family = .terminal }, .{ .family = .web } }, .records = &.{} };
        };
        if (cache.arena) |*old| old.deinit();
        cache.arena = next;
        cache.value = value;
        cache.identity = identity;
        if (!unloaded) cache.seen = current;
        cache.rebuilds += 1;
        return value;
    }
};

fn identityHash(main: access.Agent) u64 {
    var hash = std.hash.Wyhash.init(@intFromBool(main.running));
    for ([_][]const u8{ main.name, main.model, main.task }) |text| {
        const n: u64 = @intCast(text.len);
        hash.update(std.mem.asBytes(&n));
        hash.update(text);
    }
    return hash.final();
}

fn own(a: Allocator, source: access.Snapshot, main: access.Agent) !access.Snapshot {
    const agents = try a.alloc(access.Agent, source.agents.len);
    for (source.agents, agents, 0..) |old, *agent, i| {
        const from = if (i == 0) main else old;
        agent.* = .{ .id = try a.dupe(u8, from.id), .name = try a.dupe(u8, from.name), .model = try a.dupe(u8, from.model), .task = try a.dupe(u8, from.task), .running = from.running };
    }
    const records = try a.alloc(access.Record, source.records.len);
    for (source.records, records) |old, *record| {
        const p = old.part;
        const part = try a.create(tr.Part);
        part.* = .{ .id = try a.dupe(u8, p.id), .kind = .tool, .tool = p.tool, .chip = try a.dupe(u8, p.chip), .resolved = p.resolved, .is_error = p.is_error };
        try part.text.appendSlice(a, p.text.items);
        record.* = .{ .id = old.id, .family = old.family, .part = part, .input = try a.dupe(u8, old.input), .output = try a.dupe(u8, old.output) };
    }
    return .{ .agents = agents, .nodes = source.nodes, .records = records };
}

test "access cache ignores narration and retains calls when the transcript unloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry: tr.Entry = .{ .id = @constCast("synthetic"), .role = .assistant, .status = .streaming };
    try entry.parts.append(a, .{ .id = @constCast("run"), .kind = .tool, .tool = .exec, .resolved = true, .output = @constCast("48 passed") });
    var cache: Cache = .{};
    defer cache.deinit();
    const main: access.Agent = .{ .id = "main", .name = "graff", .model = "synthetic", .task = "Synthetic parser", .running = true };
    const first = cache.refresh(std.testing.allocator, "synthetic", main, &.{entry});
    try std.testing.expectEqual(@as(usize, 1), first.records.len);
    try entry.parts.append(a, .{ .id = @constCast("narration"), .kind = .text });
    _ = cache.refresh(std.testing.allocator, "synthetic", main, &.{entry});
    try std.testing.expectEqual(@as(usize, 1), cache.rebuilds);
    const unloaded = cache.refresh(std.testing.allocator, "synthetic", main, &.{});
    try std.testing.expectEqual(@as(usize, 1), unloaded.records.len);
    // The cache never points at the source Part, even before an unload.
    try std.testing.expect(unloaded.records[0].part != &entry.parts.items[0]);
}
