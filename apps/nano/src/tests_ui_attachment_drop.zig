//! External drops through the real view, with synthetic files and no engine.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        h.a.view.setup_checked = true;
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"drop-chat","deviceId":"synthetic","title":"Synthetic drop"} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("drop-chat", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 880, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try h.t.screenshot(path);
    }
};

fn fixtureUrl() ![]u8 {
    const path = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, "src/icons/project-default.png", testing.allocator);
    defer testing.allocator.free(path);
    return std.fmt.allocPrint(testing.allocator, "{f}", .{std.Uri{ .scheme = "file", .host = .{ .raw = "" }, .path = .{ .raw = path } }});
}

test "external file drop focuses only the receiving split pane and preserves other drafts" {
    for ([_]@import("tabs.zig").Axis{ .horizontal, .vertical }) |axis| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.a.composer.set("Keep the chat draft");
        h.a.splitPane(axis);
        h.t.settle(1);
        h.a.composer.set("Keep the canvas draft");
        const p: ui.Point = .{ .x = h.a.view.chrome.x + 30, .y = 180 };
        try testing.expect(h.t.ctx.acceptsDropAt(p));
        // Hover, including cancellation, is not focus or attachment intake.
        h.t.ctx.input.drag_over = p;
        h.t.frame();
        try testing.expect(h.t.hasText("Drop to attach"));
        try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
        h.t.ctx.input.drag_over = null;
        h.t.frame();
        try testing.expect(!h.t.hasText("Drop to attach"));
        try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
        const url = try fixtureUrl();
        defer testing.allocator.free(url);
        h.t.drop(p.x, p.y, &.{url}, "");
        h.t.settle(2);
        try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
        try testing.expectEqualStrings("drop-chat", h.a.selected.?);
        try testing.expectEqualStrings("Keep the chat draft", h.a.composer.text());
        try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
        try testing.expectEqualStrings("synthetic", h.a.attachments.items.items[0].target.?);
        h.a.focusPane(1);
        h.t.settle(1);
        try testing.expectEqualStrings("Keep the canvas draft", h.a.composer.text());
        try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
    }
}

test "external file drop ignores sidebar and settings and does not follow chat navigation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const url = try fixtureUrl();
    defer testing.allocator.free(url);
    try testing.expect(!h.t.ctx.acceptsDropAt(.{ .x = 40, .y = 200 }));
    h.t.drop(40, 200, &.{url}, "");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
    const r = h.a.view.composer_anchor.?;
    h.t.drop(r.x + 20, r.y + 20, &.{url}, "");
    h.a.select(null, null);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
    h.a.view.settings_open = true;
    h.t.settle(1);
    try testing.expect(!h.t.ctx.acceptsDropAt(.{ .x = 700, .y = 400 }));
}

fn dropVeil(t: *ui.Tester) !u32 {
    var found: ?u32 = null;
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "Drop to attach")) {
            if (found != null) return error.MoreThanOneDropVeil;
            found = node.parent;
        },
        else => {},
    };
    return found orelse error.DropVeilMissing;
}

fn pixel(pixels: anytype, scale: f32, point: ui.Point) [4]u8 {
    const x: usize = @intFromFloat(point.x * scale);
    const y: usize = @intFromFloat(point.y * scale);
    return pixels.bytes[(y * pixels.width + x) * 4 ..][0..4].*;
}

test "file drop shading matches legacy Harness and follows only the hovered split pane" {
    for ([_]bool{ true, false }) |dark| for ([_]@import("tabs.zig").Axis{ .horizontal, .vertical }) |axis| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.a.dark = dark;
        h.a.splitPane(axis);
        h.t.settle(1);
        try testing.expectEqual(@as(usize, 2), h.t.ctx.drop_targets.items.len);
        const rects = [2]ui.Rect{
            h.t.ctx.rects.get(h.t.ctx.drop_targets.items[0]).?,
            h.t.ctx.rects.get(h.t.ctx.drop_targets.items[1]).?,
        };
        const idle = try h.t.render(testing.allocator);
        defer idle.deinit(testing.allocator);
        // Cross between both panes without exiting the window: only the
        // current destination is shaded, without changing keyboard focus.
        for (rects, 0..) |r, ix| {
            const point: ui.Point = .{ .x = r.x + 30, .y = r.y + 70 };
            h.t.ctx.input.drag_over = point;
            h.t.frame();
            var name: [100]u8 = undefined;
            try h.snap(try std.fmt.bufPrint(&name, "file-drop-{s}-{s}-pane-{d}", .{ if (dark) "dark" else "light", @tagName(axis), ix }));
            const veil = h.t.ctx.nodes.items[try dropVeil(&h.t)];
            // Legacy attachment_drop_veil was a black scrim, not an
            // almost-opaque background fill or an accent-bordered card.
            const color = veil.style.background.?;
            try testing.expectEqual(@as(f32, 0), color.r);
            try testing.expectEqual(@as(f32, 0), color.g);
            try testing.expectEqual(@as(f32, 0), color.b);
            try testing.expectApproxEqAbs(if (dark) @as(f32, 0.4) else 0.32 * (0.4 / 0.6), color.a, 0.0001);
            try testing.expect(veil.rect.x >= r.x and veil.rect.y >= r.y);
            try testing.expect(veil.rect.x + veil.rect.w <= r.x + r.w + 1);
            try testing.expect(veil.rect.y + veil.rect.h <= r.y + r.h + 1);
            try testing.expect(veil.rect.w >= r.w - 2 and veil.rect.h >= r.h - 2);
            try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
            const hovered = try h.t.render(testing.allocator);
            defer hovered.deinit(testing.allocator);
            const before = pixel(idle, h.t.scale, point);
            const after = pixel(hovered, h.t.scale, point);
            for (before[0..3], after[0..3]) |b, a| try testing.expect(a < b);
            const other = rects[1 - ix];
            const untouched: ui.Point = .{ .x = other.x + 30, .y = other.y + 70 };
            try testing.expectEqual(pixel(idle, h.t.scale, untouched), pixel(hovered, h.t.scale, untouched));
        }
        h.t.ctx.input.drag_over = null;
        h.t.frame();
        try testing.expect(!h.t.hasText("Drop to attach"));
        const exited = try h.t.render(testing.allocator);
        defer exited.deinit(testing.allocator);
        for (rects) |r| {
            const point: ui.Point = .{ .x = r.x + 30, .y = r.y + 70 };
            try testing.expectEqual(pixel(idle, h.t.scale, point), pixel(exited, h.t.scale, point));
        }
    };
}
