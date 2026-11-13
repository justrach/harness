//! Synthetic regression for a mode control clipped by the selected tab cap.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const strip = @import("view_tab_strip.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,
    fn init(h: *Harness, dark: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.view.setup_checked = true;
        h.a.view.sidebar_open = false;
        h.a.settings.setText("surface", "opaque");
        h.a.settings.applyUiMode(.zen);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1000, .height = 700, .dark = dark });
        h.t.settle(1);
    }
    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
    fn button(h: *Harness, comptime name: []const u8) !u32 {
        for (h.t.ctx.nodes.items, 0..) |n, i| switch (n.content) {
            .image => |im| if (n.rect.y < 38 and im.source == .encoded and std.mem.eql(u8, im.source.encoded, @import("icons_svg").get(name))) {
                var at: u32 = @intCast(i);
                while (at != std.math.maxInt(u32)) : (at = h.t.ctx.nodes.items[at].parent) {
                    const parent = h.t.ctx.nodes.items[at];
                    if (parent.style.control and parent.rect.w == 24 and parent.rect.h == 24) return at;
                }
            },
            else => {},
        };
        return error.MissingTitlebarButton;
    }
    fn snap(h: *Harness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_TITLEBAR_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }));
    }
};

test "titlebar clearance keeps collapsed history and mode controls beside the selected tab" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        try h.snap(if (dark) "dark" else "light");
        const history = try h.button("clock-circle");
        const mode = try h.button("magic-stick-3");
        const hn = h.t.ctx.nodes.items[history];
        const mn = h.t.ctx.nodes.items[mode];
        // Both are siblings in the toolbar, not a button inside another button.
        try testing.expectEqual(hn.parent, mn.parent);
        try testing.expect(mn.rect.x >= hn.rect.x + hn.rect.w + 4);
        const tab_left = h.a.view.sidebar_width + strip.leftInset(&h.a);
        try testing.expect(tab_left >= mn.rect.x + mn.rect.w + 14);
        h.t.click(mn.rect.x + mn.rect.w / 2, mn.rect.y + mn.rect.h / 2);
        try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
        h.t.settle(0.2);
        const dev = try h.button("terminal");
        const d = h.t.ctx.nodes.items[dev].rect;
        h.t.click(d.x + d.w / 2, d.y + d.h / 2);
        try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
        h.t.settle(0.2);
        const hr = h.t.ctx.nodes.items[try h.button("clock-circle")].rect;
        h.t.click(hr.x + hr.w / 2, hr.y + hr.h / 2);
        try testing.expect(h.a.view.strip.menu == .history);
    }
}
