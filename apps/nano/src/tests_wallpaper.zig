//! Synthetic, offscreen acceptance tests for native wallpapers.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const wall = @import("wallpaper.zig");
const testing = std.testing;

fn hasScene(t: *ui.Tester, which: wall.Scene, dark: bool) bool {
    const sky = ui.Color.hex(wall.layers(which, 1, 1, dark)[0].color);
    for (t.ctx.nodes.items) |n| if (std.meta.eql(n.style.background, sky)) return true;
    return false;
}

const Harness = struct {
    a: App,
    t: ui.Tester,
    fn init(h: *Harness, dark: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = dark;
        h.a.offscreen = true;
        h.a.view.setup_checked = true;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 820, .dark = dark });
        h.t.settle(1);
    }
    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
    fn snap(h: *Harness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_WALLPAPER_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try h.t.screenshot(path);
    }
};

test "wallpaper is opt-in, new-chat-only, preserves composer input and becomes quiescent" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try testing.expectEqual(wall.Scene.none, wall.scene(&h.a.settings));
    try testing.expect(!hasScene(&h.t, .dusk, true));
    try h.snap("before");
    h.a.settings.setText("newChatWallpaper", "dusk");
    h.t.settle(1);
    try testing.expect(hasScene(&h.t, .dusk, true));
    try testing.expect(h.t.hasText("What should Graff do?"));
    try h.snap("after");
    h.t.settle(1);
    try testing.expect(!h.t.ctx.animating);
    _ = h.t.shortcut(.{ .key = 'l', .cmd = true });
    h.t.typeText("Synthetic wallpaper draft");
    try testing.expectEqualStrings("Synthetic wallpaper draft", h.a.composer.text());
    h.a.openChat("synthetic-conversation", null);
    h.t.settle(1);
    h.t.moveTo(900, 200);
    h.t.settle(1);
    try testing.expect(!hasScene(&h.t, .dusk, true));
}

test "wallpaper scenes render in both schemes and parallax stops with reduced motion" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        for ([_]wall.Scene{ .dusk, .dunes }) |scene| {
            h.a.settings.setText("newChatWallpaper", @tagName(scene));
            h.a.settings.setText("wallpaperParallax", "normal");
            h.t.settle(1);
            h.t.moveTo(1050, 200);
            h.t.settle(0.03);
            try testing.expect(h.t.ctx.animating);
            h.t.moveTo(500, 650);
            h.t.settle(2);
            try testing.expect(!h.t.ctx.animating);
            var buf: [64]u8 = undefined;
            try h.snap(try std.fmt.bufPrint(&buf, "{s}-{s}", .{ @tagName(scene), if (dark) "dark" else "light" }));
            h.a.settings.setText("reduceMotion", "on");
            h.t.settle(1);
            h.t.moveTo(1000, 210);
            h.t.settle(0.03);
            try testing.expect(!h.t.ctx.animating);
            h.a.settings.setText("reduceMotion", "off");
        }
    }
}

test "wallpaper pointer leaves to center and parallax off always holds still" {
    const r: ui.Rect = .{ .x = 100, .y = 40, .w = 400, .h = 200 };
    const center: ui.Point = .{ .x = 0.5, .y = 0.5 };
    try testing.expectEqual(center, wall.pointer(r, .{ .x = 99, .y = 50 }, .normal, false));
    try testing.expectEqual(center, wall.pointer(r, .{ .x = 450, .y = 200 }, .off, false));
    try testing.expectEqual(center, wall.pointer(r, .{ .x = 450, .y = 200 }, .normal, true));
    const p = wall.pointer(r, .{ .x = 400, .y = 190 }, .subtle, false);
    try testing.expectApproxEqAbs(@as(f32, 0.6125), p.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.6125), p.y, 0.0001);
}

test "wallpaper unknown preferences stay plain and valid scene changes apply" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.setText("newChatWallpaper", "unknown-scene");
    h.a.settings.setText("wallpaperParallax", "unknown-reach");
    h.t.settle(1);
    try testing.expectEqual(wall.Scene.none, wall.scene(&h.a.settings));
    try testing.expectEqual(wall.Reach.subtle, wall.reach(&h.a.settings));
    try testing.expect(!hasScene(&h.t, .dusk, true));
    try testing.expect(!hasScene(&h.t, .dunes, true));
    h.a.settings.setText("newChatWallpaper", "dunes");
    h.t.settle(1);
    try testing.expect(hasScene(&h.t, .dunes, true));
    h.a.settings.setText("newChatWallpaper", "none");
    h.t.settle(1);
    try testing.expect(!hasScene(&h.t, .dunes, true));
}

test "wallpaper settings use the actual choice controls and leave unrelated preferences alone" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.view.settings_open = true;
    h.a.settings.section = .appearance;
    h.t.settle(1);
    // The settings page scrolls; use the shared view directly to exercise its
    // exact controls without depending on the settings page's initial viewport.
    const Fixture = struct {
        fn view(a: *App, c: *ui.Context) void {
            const box = ui.div(c).column().w(900);
            defer box.end();
            @import("view_wallpaper_settings.zig").card(c, a, @import("theme.zig").colors(true));
        }
    };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&h.a, Fixture.view), .{ .width = 1000, .height = 300 });
    defer t.deinit();
    t.settle(1);
    try t.clickText("Dunes");
    try testing.expectEqual(wall.Scene.dunes, wall.scene(&h.a.settings));
    try t.clickText("Off");
    try testing.expectEqual(wall.Reach.off, wall.reach(&h.a.settings));
    try testing.expect(h.a.settings.get(.sound_enabled));
}
