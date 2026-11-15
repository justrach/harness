//! Production Cmd+B frames with synthetic grouped session histories.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Sample = struct { nodes: usize, ms: f64 };
fn sample(groups: usize) !Sample {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = true;
    a.settings.setText("surface", "opaque");
    a.settings.setText("sidebarOrganization", "byProject");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var spaces: std.ArrayList(u8) = .empty;
    var chats: std.ArrayList(u8) = .empty;
    try spaces.appendSlice(alloc, "[");
    try chats.appendSlice(alloc, "[");
    for (0..groups) |i| {
        if (i > 0) {
            try spaces.appendSlice(alloc, ",");
            try chats.appendSlice(alloc, ",");
        }
        try spaces.print(alloc, "{{\"id\":\"project-{d}\",\"deviceId\":\"d\",\"path\":\"/synthetic/project-{d}\"}}", .{ i, i });
        try chats.print(alloc, "{{\"id\":\"chat-{d}\",\"deviceId\":\"d\",\"spaceId\":\"project-{d}\",\"title\":\"Synthetic session {d}\",\"archived\":false}}", .{ i, i, i });
    }
    try spaces.appendSlice(alloc, "]");
    try chats.appendSlice(alloc, "]");
    try a.spaces.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, spaces.items, .{}));
    try a.chats.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, chats.items, .{}));
    a.openChat("chat-0", null);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(0.4);
    var peak: usize = 0;
    var elapsed: i96 = 0;
    // Real shortcut dispatch, both opening and closing, not a fake width loop.
    for (0..2) |_| {
        _ = t.shortcut(.{ .key = 'b', .cmd = true });
        for (0..16) |_| {
            const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
            t.advance(1.0 / 120.0);
            elapsed += std.Io.Clock.awake.now(testing.io).toNanoseconds() - start;
            peak = @max(peak, t.ctx.nodes.items.len);
        }
        t.advance(0.3);
    }
    try testing.expect(a.view.sidebar_open);
    try testing.expect(t.hasText("Synthetic session 0"));
    return .{ .nodes = peak, .ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / 32 };
}

test "Cmd+B grouped sidebar frame work stays near the viewport" {
    @import("theme.zig").registerFonts();
    const small = try sample(8);
    const large = try sample(1024);
    std.debug.print("\nSynthetic Cmd+B: 8 projects={d:.2}ms/{d} nodes, 1024 projects={d:.2}ms/{d} nodes\n", .{ small.ms, small.nodes, large.ms, large.nodes });
    try testing.expect(large.nodes < small.nodes * 2);
    // Node growth is the viewport contract. Raw timing for 8 versus 1024
    // groups also includes legitimate O(N) indexing, so it is diagnostic,
    // not a constant-factor guarantee. Compare equal workloads below.
}

test "Cmd+B group indexing avoids the former repeated full-list scans" {
    const workspace = @import("workspace.zig");
    const Index = @import("sidebar_groups.zig").Index;
    const Item = struct { listed: bool = true, pinned: bool = false, row_h: f32 = 38, group_key: []const u8 };
    const n = 4096;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const chats = try alloc.alloc(workspace.Chat, n);
    const items = try alloc.alloc(Item, n);
    for (chats, items, 0..) |*chat, *item, i| {
        const key = try std.fmt.allocPrint(alloc, "project-{d}", .{i});
        chat.* = .{ .id = key, .title = null, .space_id = key, .archived = false, .preview = null, .harness = null, .model = null, .cwd = null };
        item.* = .{ .group_key = key };
    }
    var legacy_ns: i96 = std.math.maxInt(i96);
    var indexed_ns: i96 = std.math.maxInt(i96);
    // Best of three removes scheduler pauses, not actual algorithmic work.
    // Each trial checks the same 4096 memberships on both implementations.
    for (0..3) |_| {
        var matches: usize = 0;
        const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        for (items) |group| for (chats) |chat| {
            if (std.mem.eql(u8, group.group_key, chat.space_id.?)) matches += 1;
        };
        legacy_ns = @min(legacy_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - start);
        try testing.expectEqual(@as(usize, n), matches);
        var frame: std.heap.ArenaAllocator = .init(testing.allocator);
        defer frame.deinit();
        const indexed_start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        const index = try Index.build(frame.allocator(), chats, items);
        indexed_ns = @min(indexed_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - indexed_start);
        try testing.expectEqual(@as(usize, n), index.groups.items.len);
        for (index.groups.items) |group| try testing.expectEqual(@as(usize, 1), group.count);
    }
    std.debug.print("\nSynthetic equal-work Cmd+B grouping: repeated scans={d}us, indexed={d}us\n", .{ @divTrunc(legacy_ns, 1000), @divTrunc(indexed_ns, 1000) });
    try testing.expect(indexed_ns * 2 < legacy_ns);
}

fn sampleZen(groups: usize) !Sample {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = false;
    a.settings.setText("surface", "opaque");
    a.settings.applyUiMode(.zen);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var spaces: std.ArrayList(u8) = .empty;
    var chats: std.ArrayList(u8) = .empty;
    try spaces.appendSlice(alloc, "[");
    try chats.appendSlice(alloc, "[");
    for (0..groups) |i| {
        if (i > 0) {
            try spaces.appendSlice(alloc, ",");
            try chats.appendSlice(alloc, ",");
        }
        const archived = i % 5 == 0 and i > 0;
        try spaces.print(alloc, "{{\"id\":\"project-{d}\",\"deviceId\":\"d\",\"name\":\"Proj {d}\",\"path\":\"/synthetic/project-{d}\"}}", .{ i, i, i });
        try chats.print(alloc, "{{\"id\":\"chat-{d}\",\"deviceId\":\"d\",\"spaceId\":\"project-{d}\",\"title\":\"Synthetic Zen Session {d} with a reasonably long title for ellipsis truncation\",\"archived\":{s}}}", .{ i, i, i, if (archived) "true" else "false" });
    }
    try spaces.appendSlice(alloc, "]");
    try chats.appendSlice(alloc, "]");
    try a.spaces.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, spaces.items, .{}));
    try a.chats.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, chats.items, .{}));
    a.openChat("chat-0", null);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = false });
    defer t.deinit();
    t.settle(0.4);
    var peak: usize = 0;
    var elapsed: i96 = 0;
    for (0..2) |_| {
        _ = t.shortcut(.{ .key = 'b', .cmd = true });
        for (0..16) |_| {
            const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
            t.advance(1.0 / 120.0);
            elapsed += std.Io.Clock.awake.now(testing.io).toNanoseconds() - start;
            peak = @max(peak, t.ctx.nodes.items.len);
        }
        t.advance(0.3);
    }
    try testing.expect(a.view.sidebar_open);
    try testing.expect(t.hasText("Archived"));
    return .{ .nodes = peak, .ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / 32 };
}

test "Cmd+B Zen sidebar frame work stays near the viewport" {
    @import("theme.zig").registerFonts();
    const small = try sampleZen(32);
    const large = try sampleZen(1024);
    std.debug.print("\nSynthetic Zen Cmd+B: 32 sessions={d:.2}ms/{d} nodes, 1024 sessions={d:.2}ms/{d} nodes\n", .{ small.ms, small.nodes, large.ms, large.nodes });
    try testing.expect(large.nodes < small.nodes * 2);
}

test "Cmd+B Zen row and footer indexing is at least 5x faster than repeated scans" {
    const sidebar = @import("view_sidebar.zig");
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.settings.applyUiMode(.zen);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var spaces: std.ArrayList(u8) = .empty;
    var chats: std.ArrayList(u8) = .empty;
    var sessions: std.ArrayList(u8) = .empty;
    try spaces.appendSlice(alloc, "[");
    try chats.appendSlice(alloc, "[");
    try sessions.appendSlice(alloc, "[");
    const n_spaces = 256;
    const n_chats = 1024;
    for (0..n_spaces) |i| {
        if (i > 0) try spaces.appendSlice(alloc, ",");
        try spaces.print(alloc, "{{\"id\":\"sp-{d}\",\"deviceId\":\"d\",\"name\":\"Space {d}\",\"path\":\"/synthetic/sp-{d}\"}}", .{ i, i, i });
    }
    var first_sess = true;
    for (0..n_chats) |i| {
        if (i > 0) try chats.appendSlice(alloc, ",");
        const sid = i % n_spaces;
        const archived = i % 5 == 0;
        try chats.print(alloc, "{{\"id\":\"ch-{d}\",\"deviceId\":\"d\",\"spaceId\":\"sp-{d}\",\"title\":\"Chat {d}\",\"archived\":{s}}}", .{ i, sid, i, if (archived) "true" else "false" });
        if (i % 4 == 0) {
            if (!first_sess) try sessions.appendSlice(alloc, ",");
            first_sess = false;
            try sessions.print(alloc, "{{\"chatId\":\"ch-{d}\",\"status\":\"running\",\"updatedAt\":\"2026-11-15T10:00:00Z\"}}", .{i});
        }
    }
    try spaces.appendSlice(alloc, "]");
    try chats.appendSlice(alloc, "]");
    try sessions.appendSlice(alloc, "]");
    try a.spaces.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, spaces.items, .{}));
    try a.chats.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, chats.items, .{}));
    try a.sessions.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, sessions.items, .{}));

    var legacy_ns: i96 = std.math.maxInt(i96);
    var indexed_ns: i96 = std.math.maxInt(i96);
    var want_archived: usize = 0;
    for (0..3) |_| {
        // Legacy path: full `listed` scan for `zenFooter` archived badge + repeated `listed` + 2x `rowMark` on visible rows.
        const legacy_start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        var arch_n: usize = 0;
        var vis_marks: usize = 0;
        for (a.chats.items, 0..) |ch, idx| {
            if (!sidebar.listed(&a, ch)) continue;
            if (ch.archived) arch_n += 1;
            if (idx < 32 and !ch.archived) {
                if (sidebar.rowMark(&a, ch) == .awaiting_input) vis_marks += 1;
                if (sidebar.rowMark(&a, ch) != .idle) vis_marks += 1;
            }
        }
        for (a.chats.items) |ch| if (ch.archived and sidebar.listed(&a, ch)) {
            arch_n +%= 1;
        };
        std.mem.doNotOptimizeAway(vis_marks);
        legacy_ns = @min(legacy_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - legacy_start);
        want_archived = arch_n / 2;

        var frame: std.heap.ArenaAllocator = .init(testing.allocator);
        defer frame.deinit();
        const idx_start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        const res = sidebar.zenIndexPass(&a, frame.allocator());
        indexed_ns = @min(indexed_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - idx_start);
        try testing.expectEqual(want_archived, res.archived);
    }
    std.debug.print("\nSynthetic equal-work Zen Cmd+B indexing: legacy={d}us, indexed={d}us\n", .{ @divTrunc(legacy_ns, 1000), @divTrunc(indexed_ns, 1000) });
    try testing.expect(indexed_ns * 5 < legacy_ns);
}
