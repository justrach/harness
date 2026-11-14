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
    // Generous CPU bound: large history must not rebuild every group subtree.
    try testing.expect(large.ms < small.ms * 5);
}
