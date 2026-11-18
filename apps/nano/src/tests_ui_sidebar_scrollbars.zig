//! Cmd+B sidebar rails use synthetic rows and the renderer's simulated clock.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const testing = std.testing;

const Scene = struct {
    a: App,

    fn view(s: *Scene, c: *ui.Context) void {
        @import("view_sidebar.zig").sidebar(c, &s.a, theme.colors(false));
    }
};

fn snapshot(t: *ui.Tester, name: []const u8) !void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
    try t.screenshot(path);
}

fn checkScrollRails(t: *ui.Tester, expected_rails: usize) !void {
    t.advance(1);
    var rails: std.ArrayList(struct { id: u64, rect: ui.Rect }) = .empty;
    defer rails.deinit(testing.allocator);
    for (t.ctx.nodes.items) |n| if (n.style.scroll and (t.ctx.scroll_max.get(n.id) orelse 0) > 40) {
        try rails.append(testing.allocator, .{ .id = n.id, .rect = n.rect });
    };
    try testing.expectEqual(expected_rails, rails.items.len);
    try snapshot(t, "sidebar-idle");
    // Neither list should paint a permanent rail just because it overflows.
    try testing.expectEqual(@as(usize, 0), t.ctx.scrollbars.count());
    for (rails.items) |rail| {
        const x = rail.rect.x + rail.rect.w - 5;
        const y = rail.rect.y + rail.rect.h / 2;
        // Hover alone must not reveal the rail; wheel motion must.
        t.move(x, y);
        t.advance(0.1);
        try testing.expect(!t.ctx.scrollbars.contains(rail.id));
        t.scroll(x, y, -40);
        t.frame();
        try testing.expect(t.ctx.scrollbars.contains(rail.id));
        try testing.expect(t.ctx.frame_in != null or t.ctx.animating);
        t.advance(2.5);
        try testing.expect(t.ctx.scrollbars.contains(rail.id));
        // More scrolling resets the full three-second countdown.
        t.scroll(x, y, -40);
        t.advance(2.5);
        try testing.expect(t.ctx.scrollbars.contains(rail.id));
        try snapshot(t, "sidebar-scrolling");
        t.advance(0.6);
        try testing.expect(!t.ctx.scrollbars.contains(rail.id));
        try snapshot(t, "sidebar-after-three-seconds");
        // Hidden rails cannot intercept clicks through stale hit geometry.
        t.scroll(x, y, -20);
        t.frame();
        try testing.expect(t.ctx.scrollbars.contains(rail.id));
        const g = t.ctx.scrollbars.get(rail.id).?;
        t.down(x, g.thumb_y + g.thumb_h / 2);
        t.advance(3.2);
        try testing.expect(t.ctx.scrollbars.contains(rail.id));
        // A stationary held pointer may produce no frames before release.
        t.time += 2;
        t.up();
        t.advance(2.5);
        try testing.expect(t.ctx.scrollbars.contains(rail.id));
        t.advance(0.6);
        try testing.expect(!t.ctx.scrollbars.contains(rail.id));
    }
}

test "Cmd+B sidebar scrollbars hide after three idle seconds independently of hover" {
    theme.registerFonts();
    var scene: Scene = .{ .a = .init(testing.allocator, testing.io, 1) };
    defer scene.a.deinit();
    scene.a.offscreen = true;
    scene.a.dark = false;
    for (0..18) |_| scene.a.newWorkspaceSession();
    var json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try json.writer.writeByte('[');
    for (0..40) |i| {
        if (i > 0) try json.writer.writeByte(',');
        try json.writer.print("{{\"id\":\"sample-{d}\",\"deviceId\":\"sample\",\"title\":\"Example conversation {d}\",\"archived\":false}}", .{ i, i });
    }
    try json.writer.writeByte(']');
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json.written(), .{});
    defer parsed.deinit();
    try scene.a.chats.replace(parsed.value);

    // Developer mode renders both openWorkspaces and lists rails.
    scene.a.settings.applyUiMode(.developer);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&scene, Scene.view), .{ .width = 310, .height = 720, .theme = theme.ui(false) });
    defer t.deinit();
    try checkScrollRails(&t, 2);

    // Zen mode also hides its sidebar rail after three idle seconds.
    scene.a.settings.applyUiMode(.zen);
    var zen: ui.Tester = undefined;
    try zen.init(testing.allocator, .init(&scene, Scene.view), .{ .width = 310, .height = 720, .theme = theme.ui(false) });
    defer zen.deinit();
    try checkScrollRails(&zen, 1);
}
