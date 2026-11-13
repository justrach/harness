//! Real open-workspace rows over two different surfaces: an opaque overlay
//! cannot pass this test, nor can fading each overlapping primitive separately.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const sidebar = @import("view_sidebar.zig");
const theme = @import("theme.zig");
const testing = std.testing;

const Scene = struct {
    a: App,
    fade: bool = true,
    const left = ui.Color.hex(0x45222b);
    const right = ui.Color.hex(0x142d48);

    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).size(224, 260);
        defer root.end();
        ui.div(c).absolute().size(112, 260).bg(left).end();
        ui.div(c).absolute().offset(112, 0).size(112, 260).bg(right).end();
        sidebar.openWorkspaces(c, &s.a, theme.colors(true));
        if (!s.fade) for (c.nodes.items) |*node| {
            if (node.style.scroll and node.style.max_height == 260) node.style.scroll_edge_fade = 0;
        };
    }
};

fn snapshot(t: *ui.Tester, name: []const u8) void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
    t.screenshot(path) catch {};
}

fn pixel(bytes: []const u8, width: usize, x: usize, y: usize, channel: usize) u8 {
    return bytes[(y * width + x) * 4 + channel];
}

fn underlay(x: f32, channel: usize) f32 {
    const color = if (x < 112) Scene.left else Scene.right;
    return (switch (channel) {
        0 => color.b,
        1 => color.g,
        else => color.r,
    }) * 255;
}

test "retention 427 native workspace fade masks complete rows over a two-tone underlay only at hidden edges" {
    theme.registerFonts();
    for ([_]f32{ 2, 1 }) |scale| {
        var scene: Scene = .{ .a = .init(testing.allocator, testing.io, 1) };
        defer scene.a.deinit();
        scene.a.offscreen = true;
        for (0..12) |_| scene.a.newWorkspaceSession();
        scene.a.showTab(7);
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&scene, Scene.view), .{ .width = 224, .height = 260, .scale = scale, .dark = true, .theme = theme.ui(true) });
        defer t.deinit();
        t.settle(1);
        if (@import("builtin").os.tag == .windows) {
            // Wait for the lazy DirectWrite initialization before overriding
            // its system LCD setting; the initial zero-opacity frame has not
            // rasterized the row text yet. Compare grayscale on both sides:
            // a transparent group's glyphs cannot use opaque-only ClearType.
            try testing.expect(t.text.atlas.native.factory != null);
            t.text.atlas.native.cleartype = false;
            t.text.atlas.reset();
            t.settle(0.2);
            try testing.expect(!t.text.atlas.native.cleartype);
        }
        var scroller: ?u64 = null;
        for (t.ctx.nodes.items) |node| if (node.style.scroll and node.style.max_height == 260) {
            scroller = node.id;
        };
        const id = scroller orelse return error.NoWorkspaceScroller;
        const max = t.ctx.scroll_max.get(id) orelse 0;
        try testing.expect(max > 120);
        for ([_]f32{ 0, 120, max }, 0..) |offset, position| {
            scene.fade = true;
            t.ctx.setScroll(id, .y, offset);
            t.settle(0.1);
            try testing.expectApproxEqAbs(offset, t.ctx.scroll.get(id) orelse 0, 0.01);
            if (scale == 2) snapshot(&t, switch (position) {
                0 => "retention-427-two-tone-top",
                1 => "retention-427-two-tone-middle",
                else => "retention-427-two-tone-bottom",
            });
            const masked = try t.render(testing.allocator);
            defer masked.deinit(testing.allocator);
            scene.fade = false;
            t.settle(0.1);
            const reference = try t.render(testing.allocator);
            defer reference.deinit(testing.allocator);
            if (scale == 2 and position == 0) snapshot(&t, "retention-427-two-tone-unmasked");
            var max_error: f32 = 0;
            var max_sample: [8]f32 = @splat(0);
            var foreground_pixels: usize = 0;
            for (0..masked.height) |y| {
                const py = (@as(f32, @floatFromInt(y)) + 0.5) / scale;
                // Independent expected mask, applied to the already composited
                // reference frame. At fully visible edges it must remain 1.
                var alpha: f32 = 1;
                if (position != 0) alpha = @min(alpha, std.math.clamp(py / 12, 0, 1));
                if (position != 2) alpha = @min(alpha, std.math.clamp((260 - py) / 12, 0, 1));
                const end: usize = @intFromFloat(208 * scale); // exclude the native scrollbar
                for (0..end) |x| {
                    const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
                    for (0..3) |channel| {
                        const base = underlay(px, channel);
                        const original: f32 = @floatFromInt(pixel(reference.bytes, reference.width, x, y, channel));
                        const actual: f32 = @floatFromInt(pixel(masked.bytes, masked.width, x, y, channel));
                        const expected = original * alpha + base * (1 - alpha);
                        const pixel_error = @abs(actual - expected);
                        if (pixel_error > max_error) {
                            max_error = pixel_error;
                            max_sample = .{ px, py, @floatFromInt(channel), alpha, original, actual, expected, base };
                        }
                        if (alpha < 0.95 and original > base + 60) foreground_pixels += 1;
                    }
                }
            }
            std.debug.print("#427 scale={d} position={d} composited pixel error={d:.2}, faded foreground samples={d}\n", .{ scale, position, max_error, foreground_pixels });
            if (max_error > 4) std.debug.print("#427 worst sample x/y/channel/alpha/reference/actual/expected/base={any}\n", .{max_sample});
            try testing.expect(foreground_pixels > 0); // text/marks, not just a bare rectangle
            try testing.expect(max_error <= 4);
        }
    }
}

test "retention 427 fitting workspace rows have no fade or compositing layer" {
    theme.registerFonts();
    var scene: Scene = .{ .a = .init(testing.allocator, testing.io, 1) };
    defer scene.a.deinit();
    scene.a.offscreen = true;
    scene.a.newWorkspaceSession();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&scene, Scene.view), .{ .width = 224, .height = 260, .scale = 2, .dark = true, .theme = theme.ui(true) });
    defer t.deinit();
    t.settle(1);
    for (t.ctx.nodes.items) |node| if (node.style.scroll and node.style.max_height == 260) {
        try testing.expectEqual(@as(f32, 0), t.ctx.scroll_max.get(node.id) orelse 0);
    };
    // Group markers are part of the renderer stream (gpu.Kind 9/10).
    // Exact-fit content must not allocate an offscreen compositing layer.
    for (t.instances.items) |instance| try testing.expect(instance.kind != 9 and instance.kind != 10);
    const on = try t.render(testing.allocator);
    defer on.deinit(testing.allocator);
    scene.fade = false;
    t.settle(0.1);
    const off = try t.render(testing.allocator);
    defer off.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, on.bytes, off.bytes);
}
