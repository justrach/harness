//! Queue edit controls at split-pane widths, using only synthetic rows.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, width: f32, dark: bool) !void {
        theme.registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = dark;
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"queued","text":"Synthetic queued message"}]
        , .{});
        defer parsed.deinit();
        try h.a.queue.replace(parsed.value);
        h.a.queue_edit = .{
            .row = try testing.allocator.dupe(u8, "queued"),
            .lease = try testing.allocator.dupe(u8, "synthetic-lease"),
            .base_hash = try testing.allocator.dupe(u8, "synthetic-hash"),
            .renew_at = 100,
        };
        try h.t.init(testing.allocator, .init(&h.a, draw), .{ .width = width, .height = 130, .dark = dark });
        h.t.settle(2);
    }

    fn draw(a: *App, c: *ui.Context) void {
        const k = theme.colors(a.dark orelse false);
        const root = ui.div(c).column().wFull().hFull().bg(k.background).pt(20).itemsCenter();
        defer root.end();
        _ = @import("view_queue.zig").tray(c, a, k, c.size.w);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, width: u32) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/queue-edit-{d}-{s}.png", .{ std.mem.span(dir), width, if (h.a.dark orelse false) "dark" else "light" }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "queue edit keeps both action hitboxes inside the tray at split-pane widths" {
    for ([_]bool{ false, true }) |dark| {
        for ([_]u32{ 220, 320, 520, 900, 160 }) |width| {
            var h: Harness = undefined;
            try h.init(@floatFromInt(width), dark);
            defer h.deinit();
            h.snap(width);
            // Check the whole button, not just its visible text or a clip.
            var actions: usize = 0;
            for (h.t.ctx.nodes.items) |node| {
                if (@abs(node.rect.h - 28) > 0.01 or node.style.radius != 5) continue;
                actions += 1;
                try testing.expect(node.rect.x >= 21);
                try testing.expect(node.rect.x + node.rect.w <= @as(f32, @floatFromInt(width)) - 21);
            }
            try testing.expectEqual(@as(usize, 2), actions);
            if (width >= 220) try testing.expect(h.t.hasText("Cancel"));
        }
    }
}

test "queue edit actions stay visually centered at every pane width" {
    for ([_]bool{ false, true }) |dark| {
        for ([_]u32{ 160, 220, 320, 520, 900 }) |width| {
            var h: Harness = undefined;
            try h.init(@floatFromInt(width), dark);
            defer h.deinit();
            h.snap(width);
            var left: f32 = std.math.inf(f32);
            var right: f32 = 0;
            for (h.t.ctx.nodes.items) |node| {
                if (@abs(node.rect.h - 28) > 0.01 or node.style.radius != 5) continue;
                left = @min(left, node.rect.x);
                right = @max(right, node.rect.x + node.rect.w);
            }
            try testing.expectApproxEqAbs(@as(f32, @floatFromInt(width)) / 2, (left + right) / 2, 0.5);
        }
    }
}

test "queue edit tray does not scroll a single row or its decorative tuck" {
    var h: Harness = undefined;
    try h.init(320, false);
    defer h.deinit();
    for (h.t.ctx.nodes.items) |node| {
        if (!node.style.scroll) continue;
        try testing.expectEqual(@as(f32, 0), h.t.ctx.scroll_max.get(node.id) orelse 0);
        try testing.expect(node.rect.h >= 36);
    }
}

test "queue edit tray still scrolls genuinely overflowing rows" {
    var h: Harness = undefined;
    try h.init(320, false);
    defer h.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"queued","text":"Synthetic first message"},{"id":"second","text":"Synthetic second message"},{"id":"third","text":"Synthetic third message"}]
    , .{});
    defer parsed.deinit();
    try h.a.queue.replace(parsed.value);
    h.t.settle(2);
    var scroller: ?ui.Rect = null;
    var id: @TypeOf(h.t.ctx.nodes.items[0].id) = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (!node.style.scroll) continue;
        scroller = node.rect;
        id = node.id;
        try testing.expect((h.t.ctx.scroll_max.get(id) orelse 0) > 0);
    }
    const box = scroller orelse return error.NoQueueScroller;
    h.t.scroll(box.x + box.w / 2, box.y + box.h / 2, -100);
    h.t.settle(2);
    try testing.expect((h.t.ctx.scroll.get(id) orelse 0) > 0);
}

test "queue edit icon actions retain meaningful hints" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(160, dark);
        defer h.deinit();
        var cancel: ?ui.Rect = null;
        for (h.t.ctx.nodes.items) |node| {
            if (@abs(node.rect.h - 28) < 0.01 and node.style.radius == 5) cancel = node.rect;
        }
        const button = cancel orelse return error.NoCancel;
        h.t.moveTo(button.x + button.w / 2, button.y + button.h / 2);
        h.t.advance(0.5);
        h.snap(160);
        try testing.expectEqualStrings("Cancel", h.t.tooltipText() orelse return error.NoHint);
    }
}

test "queue edit labeled actions do not spawn redundant hover bubbles" {
    var h: Harness = undefined;
    try h.init(320, false);
    defer h.deinit();
    const cancel = h.t.findText("Cancel") orelse return error.NoCancel;
    h.t.moveTo(cancel.x + cancel.w / 2, cancel.y + cancel.h / 2);
    h.t.advance(0.5);
    h.snap(320);
    try testing.expect(h.t.tooltipText() == null);
}
