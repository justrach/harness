//! The real composer's caret, driven with synthetic state and a test clock.
//! A blink needs two frames a second, not a continuously redrawn window.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const composer = @import("view_composer.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,
    shape: composer.Shape,

    fn init(h: *Harness, shape: composer.Shape) !void {
        theme.registerFonts();
        h.shape = shape;
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"caret","deviceId":"synthetic","title":"Synthetic caret","archived":false,
            \\  "config":{"harness":"graff","model":"synthetic-model"}}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        const models = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-model","label":"Synthetic model"}]
        , .{});
        defer models.deinit();
        // No loading skeleton: the caret alone must schedule the next frame.
        try h.a.models.replace(models.value);
        h.a.openChat("caret", null);
        try h.t.init(testing.allocator, .init(h, view), .{
            .width = 800,
            .height = 240,
            .dark = true,
            .theme = theme.ui(true),
        });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn view(h: *Harness, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        composer.pill(c, &h.a, theme.colors(true), 736, h.shape, 22);
    }

    fn carets(h: *const Harness) usize {
        var count: usize = 0;
        for (h.t.ctx.nodes.items) |n| {
            if (n.content == .none and n.style.absolute and
                n.style.width == .px and n.style.width.px == 1.5 and
                n.style.height == .px and n.style.height.px == 22.75) count += 1;
        }
        return count;
    }

    fn at(h: *Harness, time: f64) void {
        h.t.time = time;
        h.t.frame();
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}-{s}.png", .{ std.mem.span(dir), @tagName(h.shape), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "compact and expanded composer carets blink at 500 ms and restart on typing" {
    for ([_]composer.Shape{ .compact, .expanded }) |shape| {
        var h: Harness = undefined;
        try h.init(shape);
        defer h.deinit();
        try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
        const typed_at = h.t.time;
        h.t.typeText("Synthetic draft");
        try testing.expectEqual(@as(usize, 1), h.carets());
        try testing.expect(!h.t.ctx.animating);
        try testing.expectApproxEqAbs(@as(f32, 0.5), h.t.ctx.frame_in orelse return error.NoCaretWakeup, 0.001);
        h.snap("caret-on");
        h.at(typed_at + 0.49);
        try testing.expectEqual(@as(usize, 1), h.carets());
        h.at(typed_at + 0.5);
        try testing.expectEqual(@as(usize, 0), h.carets());
        h.snap("caret-off");
        h.at(typed_at + 1.0);
        try testing.expectEqual(@as(usize, 1), h.carets());
        h.at(typed_at + 1.5);
        try testing.expectEqual(@as(usize, 0), h.carets());
        h.t.typeText("!");
        try testing.expectEqualStrings("Synthetic draft!", h.a.composer.text());
        try testing.expectEqual(@as(usize, 1), h.carets());
        try testing.expectApproxEqAbs(@as(f32, 0.5), h.t.ctx.frame_in orelse return error.NoCaretWakeup, 0.001);
    }
}

test "inactive composer carets schedule no frames and restart on window activation" {
    for ([_]composer.Shape{ .compact, .expanded }) |shape| {
        var h: Harness = undefined;
        try h.init(shape);
        defer h.deinit();
        h.t.typeText("Synthetic draft");
        if (comptime @hasField(@TypeOf(h.t.ctx.input), "window_active")) {
            h.t.ctx.input.window_active = false;
            h.t.frame();
            try testing.expectEqual(@as(usize, 0), h.carets());
            try testing.expect(h.t.ctx.frame_in == null);
            try testing.expect(!h.t.ctx.animating);
            h.at(30);
            try testing.expect(h.t.ctx.frame_in == null);
            h.t.ctx.input.window_active = true;
            h.t.frame();
            try testing.expectEqual(@as(usize, 1), h.carets());
            try testing.expectApproxEqAbs(@as(f32, 0.5), h.t.ctx.frame_in orelse return error.NoCaretWakeup, 0.001);
            h.t.textOps(&.{.{ .command = .select_all }});
            try testing.expectEqual(@as(usize, 0), h.carets());
            try testing.expect(h.t.ctx.frame_in == null);
        } else return error.WindowActivityMissing;
    }
}
