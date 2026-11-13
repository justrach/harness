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
