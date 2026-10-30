//! How a reply's tool calls fold, as the GPUI transcript folds them
//! (crates/ui/src/transcript.rs, crates/proto/src/view.rs): consecutive
//! tool and reasoning parts make one group, any text ends it, and the group
//! reads like "Ran 2 commands · read 1 file · 1 failed".
const std = @import("std");
const tr = @import("transcript.zig");

/// A reply split into runs: one part alone, or a group of tool and
/// reasoning parts (`start..end` into the entry's parts).
pub const Run = struct { start: usize, end: usize, group: bool };

pub fn runs(buf: []Run, parts: []const tr.Part) []Run {
    var n: usize = 0;
    var i: usize = 0;
    while (i < parts.len and n < buf.len) {
        if (foldable(parts[i])) {
            var j = i;
            while (j < parts.len and foldable(parts[j])) j += 1;
            buf[n] = .{ .start = i, .end = j, .group = true };
            i = j;
        } else {
            buf[n] = .{ .start = i, .end = i + 1, .group = false };
            i += 1;
        }
        n += 1;
    }
    return buf[0..n];
}

fn foldable(p: tr.Part) bool {
    return p.kind == .reasoning or (p.kind == .tool and !p.agent and p.saved_view == null);
}

/// The group's header (`tool_group_label`): its segments joined with " · ",
/// only the first letter capitalized.
pub fn label(buf: []u8, parts: []const tr.Part) []const u8 {
    var thoughts: usize = 0;
    var commands: usize = 0;
    var reads: usize = 0;
    var searches: usize = 0;
    var fetches: usize = 0;
    var todos = false;
    var calls: usize = 0;
    var failed: usize = 0;
    var tools: usize = 0;
    var edited: [32][]const u8 = undefined;
    var edits: usize = 0;
    for (parts) |*p| {
        if (p.kind == .reasoning) {
            thoughts += 1;
            continue;
        }
        if (p.kind != .tool) continue;
        tools += 1;
        if (p.is_error) failed += 1;
        switch (p.tool) {
            .exec => commands += 1,
            .readFile => reads += 1,
            .writeFile, .editFile, .applyPatch => {
                const seen = for (edited[0..edits]) |e| {
                    if (std.mem.eql(u8, e, p.path)) break true;
                } else false;
                if (!seen and edits < edited.len) {
                    edited[edits] = p.path;
                    edits += 1;
                }
            },
            .search, .glob, .webSearch => searches += 1,
            .webFetch => fetches += 1,
            .todo => todos = true,
            .mcp, .unknown => calls += 1,
        }
    }
    var w: std.Io.Writer = .fixed(buf);
    var first = true;
    const S = struct {
        fn seg(wr: *std.Io.Writer, f: *bool, comptime fmt: []const u8, args: anytype) void {
            if (!f.*) wr.writeAll(" · ") catch {};
            f.* = false;
            wr.print(fmt, args) catch {};
        }
        fn s(n: usize) []const u8 {
            return if (n == 1) "" else "s";
        }
    };
    if (thoughts == 1) S.seg(&w, &first, "thought process", .{});
    if (thoughts > 1) S.seg(&w, &first, "thought {d} times", .{thoughts});
    if (commands > 0) S.seg(&w, &first, "ran {d} command{s}", .{ commands, S.s(commands) });
    if (edits > 0) S.seg(&w, &first, "edited {d} file{s}", .{ edits, S.s(edits) });
    if (reads > 0) S.seg(&w, &first, "read {d} file{s}", .{ reads, S.s(reads) });
    if (searches > 0) S.seg(&w, &first, "searched {d} time{s}", .{ searches, S.s(searches) });
    if (fetches > 0) S.seg(&w, &first, "fetched {d} page{s}", .{ fetches, S.s(fetches) });
    if (todos) S.seg(&w, &first, "updated todos", .{});
    if (calls > 0) S.seg(&w, &first, "called {d} tool{s}", .{ calls, S.s(calls) });
    if (first and tools > 0) S.seg(&w, &first, "{d} tool{s}", .{ tools, S.s(tools) });
    if (failed > 0) S.seg(&w, &first, "{d} failed", .{failed});
    const out = w.buffered();
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub const Chip = struct { label: []const u8, detail: []const u8 };

/// A tool call's chip, its label and what it ran on one line
/// (`tool_chip_content`, crates/proto/src/view.rs). `call` is the
/// `ToolCall` object, tagged by `kind`; strings go in `arena`.
pub fn chipContent(arena: std.mem.Allocator, call: std.json.ObjectMap) Chip {
    const S = struct {
        fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
            const v = o.get(k) orelse return null;
            return if (v == .string) v.string else null;
        }
    };
    const kind = S.str(call, "kind") orelse "";
    const eq = std.mem.eql;
    const raw: struct { []const u8, []const u8 } = if (eq(u8, kind, "exec"))
        .{ "Run", S.str(call, "command") orelse "" }
    else if (eq(u8, kind, "readFile"))
        .{ "Read", S.str(call, "path") orelse "" }
    else if (eq(u8, kind, "writeFile"))
        .{ "Write", S.str(call, "path") orelse "" }
    else if (eq(u8, kind, "editFile"))
        .{ "Edit", S.str(call, "path") orelse "" }
    else if (eq(u8, kind, "applyPatch"))
        .{ "Patch", S.str(call, "path") orelse "workspace" }
    else if (eq(u8, kind, "search"))
        .{ "Search", if (S.str(call, "path")) |path| std.fmt.allocPrint(arena, "{s} in {s}", .{ S.str(call, "pattern") orelse "", path }) catch "" else S.str(call, "pattern") orelse "" }
    else if (eq(u8, kind, "glob"))
        .{ "Glob", S.str(call, "pattern") orelse "" }
    else if (eq(u8, kind, "webFetch"))
        .{ "Fetch", S.str(call, "url") orelse "" }
    else if (eq(u8, kind, "webSearch"))
        .{ "Web", S.str(call, "query") orelse "" }
    else if (eq(u8, kind, "todo")) blk: {
        var done: usize = 0;
        var all: usize = 0;
        if (call.get("items")) |items| if (items == .array) for (items.array.items) |it| {
            all += 1;
            if (it == .object) if (it.object.get("done")) |d| {
                if (d == .bool and d.bool) done += 1;
            };
        };
        break :blk .{ "Todo", std.fmt.allocPrint(arena, "{d}/{d} done", .{ done, all }) catch "" };
    } else if (eq(u8, kind, "mcp"))
        (if (@import("agent_link.zig").isAgent(call)) unknownChip(S.str(call, "tool") orelse "") else .{ "MCP", std.fmt.allocPrint(arena, "{s} · {s}", .{ S.str(call, "server") orelse "", S.str(call, "tool") orelse "" }) catch "" })
    else
        unknownChip(S.str(call, "name") orelse "");
    return .{ .label = raw[0], .detail = singleLine(arena, raw[1]) };
}

/// An `unknown` call: subagents and the agent's own controls read as what
/// they are; anything else is a tool by its name.
fn unknownChip(name: []const u8) struct { []const u8, []const u8 } {
    const starts = std.mem.startsWith;
    const eq = std.mem.eql;
    if (starts(u8, name, "Agent: ")) return .{ "Agent", name["Agent: ".len..] };
    if (starts(u8, name, "Jev: ")) return .{ "Jev", name["Jev: ".len..] };
    if (eq(u8, name, "Agent")) return .{ "Agent", "" };
    if (eq(u8, name, "Compact context")) return .{ "Compact", "context" };
    if (starts(u8, name, "Wait for ")) return .{ "Waiting on", "subagent" };
    for ([_][2][]const u8{ .{ "Message agent", "Message" }, .{ "Resume agent", "Resume" }, .{ "Close agent", "Close" } }) |p| {
        if (eq(u8, name, p[0]) or (starts(u8, name, p[0]) and name.len > p[0].len and name[p[0].len] == ' ')) return .{ p[1], "subagent" };
    }
    if (eq(u8, name, "agent_output")) return .{ "Waiting on", "subagent" };
    if (eq(u8, name, "Send agent message") or eq(u8, name, "agent_message")) return .{ "Message", "subagent" };
    if (eq(u8, name, "subagent_resume")) return .{ "Resume", "subagent" };
    if (eq(u8, name, "Load tools")) return .{ "Load", "tools" };
    return .{ "Tool", name };
}

/// Runs of whitespace become one space, none at the ends (`single_line`).
pub fn singleLine(arena: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r\x0b\x0c");
    while (it.next()) |word| {
        if (out.items.len > 0) out.append(arena, ' ') catch break;
        out.appendSlice(arena, word) catch break;
    }
    return out.items;
}


const testing = std.testing;

fn part(kind: tr.PartKind, tool: tr.ToolKind, path: []const u8, failed: bool) tr.Part {
    return .{ .id = @constCast(""), .kind = kind, .tool = tool, .path = @constCast(path), .is_error = failed };
}

test "labels read as the desktop's" {
    var b: [128]u8 = undefined;
    const two = [_]tr.Part{ part(.tool, .exec, "", false), part(.tool, .exec, "", false) };
    try testing.expectEqualStrings("Ran 2 commands", label(&b, &two));
    const mixed = [_]tr.Part{ part(.tool, .exec, "", true), part(.tool, .readFile, "a", false), part(.tool, .search, "", false), part(.tool, .glob, "", false) };
    try testing.expectEqualStrings("Ran 1 command · read 1 file · searched 2 times · 1 failed", label(&b, &mixed));
    const edits = [_]tr.Part{ part(.tool, .editFile, "a", false), part(.tool, .writeFile, "a", false), part(.tool, .applyPatch, "b", false) };
    try testing.expectEqualStrings("Edited 2 files", label(&b, &edits));
    const thought = [_]tr.Part{part(.reasoning, .unknown, "", false)};
    try testing.expectEqualStrings("Thought process", label(&b, &thought));
}

test "text ends a group" {
    var buf: [8]Run = undefined;
    const ps = [_]tr.Part{ part(.text, .unknown, "", false), part(.tool, .exec, "", false), part(.reasoning, .unknown, "", false), part(.text, .unknown, "", false) };
    const r = runs(&buf, &ps);
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expect(r[1].group and r[1].start == 1 and r[1].end == 3);
}
