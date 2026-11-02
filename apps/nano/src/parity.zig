//! harness-nano's runner for `protocol/desktop`: the rules, transcript
//! frames, theme roles and requests the Rust desktop runs the same files
//! for (crates/proto/tests/desktop_vectors.rs, crates/doc/tests/
//! desktop_transcript_vectors.rs, crates/theme/tests/desktop_theme_vectors.rs,
//! crates/engine/tests/desktop_requests.rs). The files are read from the
//! repository at test time, never copied.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const nanoui = @import("nanoui");
const rules = @import("rules.zig");
const tools = @import("tools.zig");
const workspace = @import("workspace.zig");
const tr = @import("transcript.zig");
const theme = @import("theme.zig");
const parity_requests = @import("parity_requests.zig");
const dir = @import("parity_options").protocol_dir;

fn load(arena: std.mem.Allocator, name: []const u8) !json.Value {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(4 << 20));
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

fn items(v: json.Value, key: []const u8) []const json.Value {
    return v.object.get(key).?.array.items;
}

fn str(v: json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

fn int(v: json.Value, key: []const u8) i64 {
    return v.object.get(key).?.integer;
}

fn caseName(v: json.Value) []const u8 {
    const n = v.object.get("name") orelse return "";
    return if (n == .string) n.string else "";
}

/// Builds a JSON array value of one item, for a list that is replaced whole.
fn one(arena: std.mem.Allocator, v: json.Value) !json.Value {
    var a: json.Array = .init(arena);
    try a.append(v);
    return .{ .array = a };
}

test "rules: how long ago" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try load(ar.allocator(), "rules.json");
    const now = int(v, "nowMs");
    var buf: [16]u8 = undefined;
    for (items(v, "timeAgo")) |c| {
        const got = rules.relativeTime(&buf, now, now - int(c, "agoMs"));
        testing.expectEqualStrings(str(c, "expect"), got) catch |e| {
            std.debug.print("{d} ms ago\n", .{int(c, "agoMs")});
            return e;
        };
    }
}

test "rules: tool chips" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try load(ar.allocator(), "rules.json");
    for (items(v, "toolChip")) |c| {
        const got = tools.chipContent(ar.allocator(), c.object.get("call").?.object);
        const want = c.object.get("expect").?;
        try testing.expectEqualStrings(str(want, "label"), got.label);
        try testing.expectEqualStrings(str(want, "detail"), got.detail);
    }
}

test "rules: tool group summaries, through the transcript's own parsing" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try load(a, "rules.json");
    for (items(v, "toolGroupSummary")) |c| {
        // The calls as tool parts of one entry, as WatchDocMessages sends them.
        var parts: json.Array = .init(a);
        for (items(c, "tools"), 0..) |t, i| {
            var p: json.ObjectMap = .empty;
            try p.put(a, "kind", .{ .string = "tool" });
            try p.put(a, "id", .{ .string = try std.fmt.allocPrint(a, "t{d}", .{i}) });
            try p.put(a, "call", t.object.get("call").?);
            try p.put(a, "isError", t.object.get("isError") orelse .{ .bool = false });
            try p.put(a, "resolved", .{ .bool = true });
            try parts.append(.{ .object = p });
        }
        var entry: json.ObjectMap = .empty;
        try entry.put(a, "id", .{ .string = "e" });
        try entry.put(a, "role", .{ .string = "assistant" });
        try entry.put(a, "parts", .{ .array = parts });
        var frame: json.ObjectMap = .empty;
        try frame.put(a, "reset", try one(a, .{ .object = entry }));
        var t: tr.Transcript = .{ .gpa = testing.allocator };
        defer t.deinit();
        try t.apply(.{ .object = frame });
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(str(c, "expect"), tools.label(&buf, t.entries.items[0].parts.items));
    }
}

fn markName(m: workspace.Mark) []const u8 {
    return switch (m) {
        .working => "working",
        .awaiting_input => "awaitingInput",
        .errored => "errored",
        .completed => "completed",
        .idle => "idle",
    };
}

test "rules: a session row's status" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try load(a, "rules.json");
    const now = int(v, "nowMs");
    for (items(v, "displayStatus")) |c| {
        var chats: workspace.Chats = .init(testing.allocator);
        defer chats.deinit();
        try chats.replace(try one(a, c.object.get("chat").?));
        var sessions: workspace.Sessions = .init(testing.allocator);
        defer sessions.deinit();
        const s = c.object.get("session").?;
        if (s != .null) try sessions.replace(try one(a, s));
        const session: ?workspace.Session = if (sessions.items.len > 0) sessions.items[0] else null;
        testing.expectEqualStrings(str(c, "expect"), markName(workspace.markOf(chats.items[0], session, now))) catch |e| {
            std.debug.print("case: {s}\n", .{caseName(c)});
            return e;
        };
    }
}

test "rules: the sidebar's order" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try load(ar.allocator(), "rules.json");
    for (items(v, "sortActive")) |c| {
        var chats: workspace.Chats = .init(testing.allocator);
        defer chats.deinit();
        try chats.replace(c.object.get("chats").?);
        workspace.sortChats(chats.items);
        const want = items(c, "expect");
        try testing.expectEqual(want.len, chats.items.len);
        for (want, chats.items) |w, got| try testing.expectEqualStrings(w.string, got.id);
    }
}

test "transcript: frames apply as the desktop applies them" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try load(ar.allocator(), "transcript.json");
    for (items(v, "cases")) |c| {
        var t: tr.Transcript = .{ .gpa = testing.allocator };
        defer t.deinit();
        var desync: ?i64 = null;
        for (items(c, "frames"), 0..) |f, i| {
            t.apply(f) catch {
                desync = @intCast(i);
                break;
            };
        }
        if (c.object.get("desyncAt")) |at| {
            testing.expectEqual(@as(?i64, at.integer), desync) catch |e| {
                std.debug.print("case: {s}\n", .{caseName(c)});
                return e;
            };
            continue;
        }
        try testing.expectEqual(@as(?i64, null), desync);
        const want = items(c, "expect");
        try testing.expectEqual(want.len, t.entries.items.len);
        for (want, t.entries.items) |w, e| {
            try testing.expectEqualStrings(str(w, "id"), e.id);
            try testing.expectEqualStrings(str(w, "role"), @tagName(e.role));
            var texts: std.ArrayList([]const u8) = .empty;
            for (e.parts.items) |*p| if (p.kind == .text or p.kind == .reasoning) try texts.append(ar.allocator(), p.text.items);
            const wt = items(w, "texts");
            try testing.expectEqual(wt.len, texts.items.len);
            for (wt, texts.items) |x, y| try testing.expectEqualStrings(x.string, y);
        }
    }
}

/// A colour as harness_theme::Color prints it: #rrggbb, or #rrggbbaa when
/// it isn't opaque.
fn hex(buf: []u8, c: nanoui.ui.Color) []const u8 {
    const b = struct {
        fn b(x: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
        }
    }.b;
    if (b(c.a) == 255) return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ b(c.r), b(c.g), b(c.b) }) catch "";
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ b(c.r), b(c.g), b(c.b), b(c.a) }) catch "";
}

test "theme: the Codegraff roles" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try load(ar.allocator(), "theme.json");
    for (items(v, "variants")) |variant| {
        const k = theme.colors(variant.object.get("dark").?.bool);
        const cs = variant.object.get("colors").?;
        const roles = .{
            .{ "background", k.background }, .{ "shell", k.shell },              .{ "raised", k.raised },
            .{ "text", k.text },             .{ "textMuted", k.muted },          .{ "textFaint", k.faint },
            .{ "hover", k.hover },           .{ "border", k.border },            .{ "borderStrong", k.border_strong },
            .{ "danger", k.danger },         .{ "dangerMuted", k.danger_muted }, .{ "warning", k.warning },
            .{ "success", k.success },       .{ "solid", k.solid },              .{ "onSolid", k.on_solid },
            .{ "diffAdd", k.diff_add },      .{ "diffDelete", k.diff_del },
        };
        var buf: [16]u8 = undefined;
        inline for (roles) |r| {
            testing.expectEqualStrings(str(cs, r[0]), hex(&buf, r[1])) catch |e| {
                std.debug.print("{s} {s}\n", .{ str(variant, "id"), r[0] });
                return e;
            };
        }
        const acc = variant.object.get("accent").?;
        try testing.expectEqualStrings(str(acc, "primary"), hex(&buf, k.accent));
        try testing.expectEqualStrings(str(acc, "wash"), hex(&buf, k.accent_wash));
        for (items(acc, "glyph"), k.glyph, 0..) |g, c, i| {
            testing.expectEqualStrings(g.string, hex(&buf, c)) catch |e| {
                std.debug.print("{s} glyph {d}\n", .{ str(variant, "id"), i });
                return e;
            };
        }
        for (items(variant, "ansi"), k.ansi) |want, c| try testing.expectEqualStrings(want.string, hex(&buf, c));
    }
}

fn jsonEqual(a: json.Value, b: json.Value) bool {
    switch (a) {
        .object => |o| {
            if (b != .object or b.object.count() != o.count()) return false;
            var it = o.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse return false;
                if (!jsonEqual(e.value_ptr.*, other)) return false;
            }
            return true;
        },
        .array => |x| {
            if (b != .array or b.array.items.len != x.items.len) return false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q)) return false;
            return true;
        },
        .string => |s| return b == .string and std.mem.eql(u8, s, b.string),
        .integer => |n| return b == .integer and b.integer == n,
        .bool => |x| return b == .bool and b.bool == x,
        .null => return b == .null,
        else => return false,
    }
}

test "requests: every request is still the JSON the engine was shown" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try load(a, "requests.json");
    const want = items(v, "requests");
    const got = try parity_requests.cases(a);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(str(w, "name"), g.name);
        try testing.expectEqualStrings(str(w, "method"), g.method);
        try testing.expectEqual(w.object.get("stream").?.bool, g.stream);
        const params = try json.parseFromSliceLeaky(json.Value, a, g.params, .{});
        if (!jsonEqual(w.object.get("params").?, params)) {
            std.debug.print("{s}: the builder sends {s}\n(run `zig build vectors` if the change is meant, then the Rust runner)\n", .{ g.name, g.params });
            return error.RequestChanged;
        }
    }
}
