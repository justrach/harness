//! Tool Access Map, reduced from the same transcript that drives the tree.
//! The five desktop families are capabilities, not claims about external
//! account bindings. Unknown calls belong to MCP; spawns are agent tabs.
const std = @import("std");
const tr = @import("transcript.zig");
const Allocator = std.mem.Allocator;

pub fn panOffset(current: f32, delta: f32, content: f32, viewport: f32) f32 {
    return std.math.clamp(current - delta, 0, @max(content - viewport, 0));
}

test "narrow access graphs pan sideways and clamp when resized" {
    try std.testing.expectEqual(@as(f32, 172), panOffset(0, -200, 692, 520));
    try std.testing.expectEqual(@as(f32, 92), panOffset(172, 80, 692, 520));
    try std.testing.expectEqual(@as(f32, 0), panOffset(172, 0, 692, 800));
}

pub const Family = enum {
    files,
    mcp,
    search,
    terminal,
    web,

    pub fn name(f: Family) []const u8 {
        return switch (f) {
            .files => "Files",
            .mcp => "MCP",
            .search => "Search",
            .terminal => "Terminal",
            .web => "Web search",
        };
    }

    pub fn icon(f: Family) @import("icons.zig").Name {
        return switch (f) {
            .files => .document,
            .mcp => .widget,
            .search => .magnifer,
            .terminal => .terminal,
            .web => .global,
        };
    }

    pub fn of(kind: tr.ToolKind) Family {
        return switch (kind) {
            .readFile, .writeFile, .editFile, .applyPatch, .todo => .files,
            .mcp, .unknown => .mcp,
            .search, .glob => .search,
            .exec => .terminal,
            .webFetch, .webSearch => .web,
        };
    }
};

pub const Agent = struct { id: []const u8, name: []const u8, model: []const u8, task: []const u8, running: bool };
pub const history_limit = 100;
pub const Record = struct { id: u64, family: Family, part: *const tr.Part, input: []const u8, output: []const u8 };
pub const Node = struct {
    family: Family,
    calls: usize = 0,
    failed: bool = false,
    failures: usize = 0,

    pub fn subtitle(n: Node, a: Allocator) []const u8 {
        if (n.calls == 0) return "Not used yet";
        return if (n.failures > 0) std.fmt.allocPrint(a, "{d}× · {d} failed", .{ n.calls, n.failures }) catch "" else std.fmt.allocPrint(a, "{d}×", .{n.calls}) catch "";
    }
};

pub const Snapshot = struct {
    agents: []const Agent,
    nodes: [5]Node,
    records: []const Record,

    pub fn stats(s: Snapshot, a: Allocator) []const u8 {
        var used: usize = 0;
        var calls: usize = 0;
        var running: usize = 0;
        for (s.nodes) |n| {
            if (n.calls > 0) used += 1;
            calls += n.calls;
        }
        for (s.agents) |agent| if (agent.running) {
            running += 1;
        };
        return if (running > 0)
            std.fmt.allocPrint(a, "{d}/5 tools · {d} calls · {d} running", .{ used, calls, running }) catch ""
        else
            std.fmt.allocPrint(a, "{d}/5 tools · {d} calls", .{ used, calls }) catch "";
    }

    pub fn record(s: Snapshot, family: Family, selected: ?u64) ?Record {
        var first: ?Record = null;
        for (s.records) |r| {
            if (r.family != family) continue;
            if (first == null) first = r;
            if (selected == r.id) return r;
        }
        return first;
    }
};

pub fn snapshot(a: Allocator, chat: []const u8, main: Agent, entries: []const tr.Entry) Snapshot {
    var agents: std.ArrayList(Agent) = .empty;
    agents.append(a, main) catch {};
    var records: std.ArrayList(Record) = .empty;
    var nodes = [_]Node{ .{ .family = .files }, .{ .family = .mcp }, .{ .family = .search }, .{ .family = .terminal }, .{ .family = .web } };
    for (entries) |e| {
        if (e.role != .assistant) continue;
        for (e.parts.items) |*p| {
            if (p.kind != .tool) continue;
            if (p.agent) {
                agents.append(a, .{ .id = p.id, .name = if (p.subagent_title.len > 0) p.subagent_title else p.text.items, .model = agentModel(a, p), .task = p.chip, .running = p.subagent_status == .running }) catch {};
                continue;
            }
            const n = &nodes[@backingInt(Family.of(p.tool))];
            n.calls += 1;
            n.failed = p.is_error; // Only the latest call earns a red badge.
            n.failures += @intFromBool(p.is_error);
        }
    }
    // Every turn contributes to counts; only the latest 100 calls per
    // family need their input/output materialized, newest first.
    var kept: [5]usize = @splat(0);
    var ei = entries.len;
    while (ei > 0) {
        ei -= 1;
        const e = &entries[ei];
        if (e.role != .assistant) continue;
        var pi = e.parts.items.len;
        while (pi > 0) {
            pi -= 1;
            const p = &e.parts.items[pi];
            if (p.kind != .tool or p.agent) continue;
            const family = Family.of(p.tool);
            const ix = @backingInt(family);
            if (kept[ix] == history_limit) continue;
            kept[ix] += 1;
            const id = @import("tool_ui_state.zig").key(chat, e.id, p.id);
            records.append(a, .{ .id = id, .family = family, .part = p, .input = input(a, p), .output = output(a, p) }) catch {};
        }
    }
    return .{ .agents = agents.items, .nodes = nodes, .records = records.items };
}

fn agentModel(a: Allocator, p: *const tr.Part) []const u8 {
    if (!p.agent or p.invocation.len == 0) return "";
    const call = std.json.parseFromSliceLeaky(std.json.Value, a, p.invocation, .{}) catch return "";
    if (call != .object) return "";
    const arguments = call.object.get("input") orelse return "";
    if (arguments != .object) return "";
    for ([_][]const u8{ "model", "modelId", "model_id", "subagent_model" }) |key| if (arguments.object.get(key)) |value| {
        if (value == .string) {
            const model = std.mem.trim(u8, value.string, " \t\r\n");
            if (model.len > 0) return model;
        }
    };
    return "";
}

/// The map's JSON-shaped INPUT, matching the release desktop's compact
/// invocation projection. The full real ToolCall stays in the tree detail.
pub fn input(a: Allocator, p: *const tr.Part) []const u8 {
    const parsed: ?std.json.Value = if (p.invocation.len > 0) std.json.parseFromSliceLeaky(std.json.Value, a, p.invocation, .{}) catch null else null;
    const call = if (parsed != null and parsed.? == .object) parsed.?.object else std.json.ObjectMap.empty;
    var object: std.json.ObjectMap = .empty;
    switch (p.tool) {
        .exec => object.put(a, "cmd", call.get("command") orelse .{ .string = p.text.items }) catch {},
        .readFile, .writeFile, .editFile => object.put(a, "path", call.get("path") orelse .{ .string = p.path }) catch {},
        .applyPatch => object.put(a, "path", call.get("path") orelse .{ .string = if (p.path.len > 0) p.path else "workspace" }) catch {},
        .search => {
            object.put(a, "pattern", call.get("pattern") orelse .{ .string = p.text.items }) catch {};
            if (call.get("path")) |path| if (path == .string) {
                object.put(a, "path", path) catch {};
            };
        },
        .glob => object.put(a, "pattern", call.get("pattern") orelse .{ .string = p.text.items }) catch {},
        .webSearch => object.put(a, "query", call.get("query") orelse .{ .string = p.text.items }) catch {},
        .webFetch => object.put(a, "url", call.get("url") orelse .{ .string = p.text.items }) catch {},
        .todo => {
            if (call.get("items")) |items| object.put(a, "items", items) catch {};
        },
        .mcp => {
            object.put(a, "server", call.get("server") orelse .{ .string = "" }) catch {};
            object.put(a, "tool", call.get("tool") orelse .{ .string = p.text.items }) catch {};
            if (call.get("input")) |value| object.put(a, "input", value) catch {};
        },
        .unknown => {
            object.put(a, "name", call.get("name") orelse .{ .string = p.text.items }) catch {};
            if (call.get("input")) |value| object.put(a, "input", value) catch {};
        },
    }
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = object }, .{ .whitespace = .indent_2 }) catch "";
}

fn quoted(a: Allocator, text: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(a, text, .{}) catch "\"\"";
}

/// Same structured output projection as release desktop. Parsing is bounded
/// to the detail preview, and performed only for retained history records.
pub fn output(a: Allocator, p: *const tr.Part) []const u8 {
    if (p.stats.len > 0) {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, "{\n  \"stats\": [\n") catch {};
        for (p.stats, 0..) |s, i| out.print(a, "    {{\"path\": {s}, \"+\": {d}, \"-\": {d}}}{s}\n", .{ quoted(a, s.path), s.additions, s.deletions, if (i + 1 < p.stats.len) "," else "" }) catch {};
        out.appendSlice(a, "  ]\n}") catch {};
        return out.items;
    }
    if (p.diff_new != null) return std.fmt.allocPrint(a, "{{\n  \"path\": {s},\n  \"+\": {d},\n  \"-\": {d}\n}}", .{ quoted(a, p.path), p.additions, p.deletions }) catch "";
    if (p.output.len > 0) {
        var preview: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, p.output, "\n"), '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            if (n == 24) break;
            if (n > 0) preview.appendSlice(a, "\\n") catch {};
            preview.appendSlice(a, line) catch {};
            n += 1;
        }
        return std.fmt.allocPrint(a, "{{\n  \"text\": {s}\n}}", .{quoted(a, preview.items)}) catch "";
    }
    return if (!p.resolved) "" else if (p.is_error) "{\n  \"ok\": false\n}" else "{\n  \"ok\": true\n}";
}

test "access history is newest first, bounded per family, and counts all turns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e: tr.Entry = .{ .id = @constCast("synthetic-history"), .role = .assistant, .status = .complete };
    for (0..125) |i| try e.parts.append(a, .{ .id = try std.fmt.allocPrint(a, "call-{d}", .{i}), .kind = .tool, .tool = .exec, .resolved = true, .is_error = i == 0 });
    const s = snapshot(a, "synthetic", .{ .id = "main", .name = "graff", .model = "synthetic", .task = "This chat", .running = false }, &.{e});
    try std.testing.expectEqual(@as(usize, 100), s.records.len);
    try std.testing.expectEqualStrings("call-124", s.records[0].part.id);
    try std.testing.expectEqualStrings("call-25", s.records[99].part.id);
    const terminal = s.nodes[@backingInt(Family.terminal)];
    try std.testing.expectEqual(@as(usize, 125), terminal.calls);
    try std.testing.expect(!terminal.failed);
    try std.testing.expectEqualStrings("125× · 1 failed", terminal.subtitle(a));
    try std.testing.expectEqualStrings("1/5 tools · 125 calls", s.stats(a));
}

test "access map derives real families and history without treating spawns as tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e: tr.Entry = .{ .id = @constCast("entry"), .role = .assistant, .status = .complete };
    try e.parts.appendSlice(a, &.{
        .{ .id = @constCast("read"), .kind = .tool, .tool = .readFile, .resolved = true },
        .{ .id = @constCast("run"), .kind = .tool, .tool = .exec, .resolved = true, .is_error = true },
        .{ .id = @constCast("spawn"), .kind = .tool, .agent = true, .subagent_title = @constCast("Synthetic worker"), .subagent_status = .running },
    });
    const s = snapshot(a, "synthetic", .{ .id = "main", .name = "graff", .model = "synthetic", .task = "Current turn", .running = false }, &.{e});
    try std.testing.expectEqual(@as(usize, 2), s.agents.len);
    try std.testing.expectEqual(@as(usize, 2), s.records.len);
    try std.testing.expectEqual(@as(usize, 1), s.nodes[@backingInt(Family.files)].calls);
    try std.testing.expect(s.nodes[@backingInt(Family.terminal)].failed);
    try std.testing.expectEqualStrings("Not used yet", s.nodes[@backingInt(Family.web)].subtitle(a));
    try std.testing.expectEqualStrings("2/5 tools · 2 calls · 1 running", s.stats(a));
    try std.testing.expect(s.record(.files, null) != null);
    try std.testing.expect(s.record(.web, null) == null);
}
