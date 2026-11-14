//! ImageIO turns EXIF-oriented PNGs upright; layout must use that same orientation.
//! Made-up four-color fixtures cover both the small-image shortcut and thumbnail path.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;

const State = struct {
    bytes: []const u8,
    fn view(s: *State, c: *ui.Context) void {
        const root = ui.div(c).column().wFull().hFull();
        defer root.end();
        _ = ui.image(c, .{ .key = "oriented-picture", .source = .{ .encoded = s.bytes }, .max_width = 480, .max_height = 360, .scale = 1, .radius = 0 });
    }
};

test "image orientation PNG layout matches upright pixels without stretching" {
    if (ui.portable or @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const cases = [_]struct { bytes: []const u8, width: f32, height: f32, name: []const u8 }{
        .{ .bytes = @embedFile("fixtures/image-orientation/small-rotate-270.png"), .width = 240, .height = 120, .name = "small" },
        .{ .bytes = @embedFile("fixtures/image-orientation/large-rotate-270.png"), .width = 600, .height = 300, .name = "large" },
    };
    for (cases) |case| {
        var state: State = .{ .bytes = case.bytes };
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&state, State.view), .{ .width = 520, .height = 400, .scale = 1 });
        defer tester.deinit();
        tester.settle(1);
        if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
            var path: [1024]u8 = undefined;
            try tester.screenshot(try std.fmt.bufPrint(&path, "{s}/image-orientation-{s}.png", .{ std.mem.span(dir), case.name }));
        }
        const size = ui.imageSize(&tester.ctx, "oriented-picture", case.bytes).?;
        try t.expectEqual(case.width, size.w);
        try t.expectEqual(case.height, size.h);
        var rect: ?ui.Rect = null;
        for (tester.ctx.nodes.items) |node| switch (node.content) {
            .image => rect = node.rect,
            else => {},
        };
        const fitted = rect.?;
        try t.expectApproxEqAbs(@as(f32, 2), fitted.w / fitted.h, 0.01);
        for (tester.text.images.decoded.values()) |entry| {
            const decoded = entry.?;
            try t.expectEqual(@as(u32, @intFromFloat(case.width)), decoded.width);
            try t.expectEqual(@as(u32, @intFromFloat(case.height)), decoded.height);
            try t.expectApproxEqAbs(@as(f32, 2), @as(f32, @floatFromInt(decoded.w)) / @as(f32, @floatFromInt(decoded.h)), 0.01);
        }
        const pixels = try tester.render(t.allocator);
        defer pixels.deinit(t.allocator);
        // The upright image is green/yellow above red/blue after the 270° EXIF turn.
        const colors = [_][3]u8{ .{ 20, 180, 65 }, .{ 250, 205, 20 }, .{ 240, 40, 30 }, .{ 30, 80, 240 } };
        for (colors, 0..) |rgb, i| {
            const x: usize = @intFromFloat(fitted.x + fitted.w * (if (i % 2 == 0) @as(f32, 0.25) else 0.75));
            const y: usize = @intFromFloat(fitted.y + fitted.h * (if (i < 2) @as(f32, 0.25) else 0.75));
            const at = (y * pixels.width + x) * 4;
            for (0..3) |channel| try t.expect(@abs(@as(i16, pixels.bytes[at + 2 - channel]) - @as(i16, rgb[channel])) < 8);
        }
    }
}
