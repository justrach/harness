//! Tooltips where the GPUI app has them, driven headlessly on made-up data:
//! each shows its text once the pointer has been over its control for the
//! control's delay (350 ms, or GPUI's default 500 ms), not before, by the
//! pointer; leaving or a press hides it. They need a nanoui with tooltips
//! (view_tooltip.zig); with one without, these skip.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const tip = @import("view_tooltip.zig");
const sandboxes = @import("sandboxes.zig");

const testing = std.testing;

const chats =
    \\[{"id":"a","deviceId":"d","title":"Alpha","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Beta","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z"}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.view.sidebar_open = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        h.a.openChat("a", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn sandboxes(h: *Harness, reply: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
        defer parsed.deinit();
        @import("app_sandboxes.zig").apply(&h.a, parsed.value);
        h.t.settle(1);
    }

    /// The tooltip's text in the last frame, if one showed.
    fn shown(h: *Harness) ?[]const u8 {
        return h.t.tooltipText();
    }

    fn count(h: *Harness, s: []const u8) usize {
        var n: usize = 0;
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |t| n += @intFromBool(std.mem.eql(u8, t.str, s)),
            else => {},
        };
        return n;
    }

    /// `NANO_SNAP_DIR=dir`, running the test binary: saves what it saw.
    fn snap(h: *Harness, name: []const u8) void {
        const d = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(d), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

const running =
    \\{"enabled": true, "sandboxes": [{"id": "cnd_1", "provider": "fleet", "state": "running", "harness": true, "keepRunning": true},
    \\ {"id": "tmp-7", "provider": "daytona", "state": "paused", "tier": "ephemeral"}]}
;

fn sidebarViewOptions() !void {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const r = h.a.view.more_anchor orelse return error.NoButton;
    const x = r.x + r.w / 2;
    const y = r.y + r.h / 2;
    h.t.moveTo(x, y);
    h.t.advance(0.3);
    try testing.expect(h.shown() == null and !h.t.hasText("Sidebar view options"));
    h.t.advance(0.1);
    try testing.expectEqualStrings("Sidebar view options", h.shown().?);
    try testing.expect(h.t.hasText("Sidebar view options"));
    // By the pointer, 1 right of it and 1 below, as GPUI places it.
    const box = h.t.tooltipRect().?;
    try testing.expectEqual(x + 1, box.x);
    try testing.expectEqual(y + 1, box.y);
    // text_tooltip: 11-point text on an 18-point line, py 6 inside a 1-point border.
    try testing.expectApproxEqAbs(@as(f32, 32), box.h, 0.01);
    h.snap("tooltip-view-options");
    // Leaving hides it at once.
    h.t.moveTo(600, 400);
    try testing.expect(h.shown() == null);
    // A press on the button hides it, and opens the menu.
    h.t.moveTo(x, y);
    h.t.advance(0.4);
    try testing.expect(h.shown() != null);
    h.t.click(x, y);
    h.t.advance(0.5);
    try testing.expect(h.shown() == null);
    try testing.expect(h.a.view.more_menu);
}

test "the sidebar's ⋯ says Sidebar view options after 350 ms, not before; leaving or a press hides it" {
    if (comptime tip.has) try sidebarViewOptions() else return error.SkipZigTest;
}

fn projectIcon() !void {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // The row's monogram tile: "Home" has no project, so "H".
    var tile: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| if (std.mem.eql(u8, t.str, "H") and t.style.mono and tile == null) {
            tile = n.rect;
        },
        else => {},
    };
    const r = tile orelse return error.NoTile;
    try testing.expectEqual(@as(usize, 0), h.count("Unknown device"));
    h.t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
    h.t.advance(0.3);
    try testing.expect(h.shown() == null);
    h.t.advance(0.1);
    // The app's own card: the project over its device.
    try testing.expectEqualStrings("", h.shown().?);
    try testing.expectEqual(@as(usize, 1), h.count("Unknown device"));
    const name = h.t.findText("Home").?;
    const device = h.t.findText("Unknown device").?;
    try testing.expect(device.y > name.y);
    h.snap("tooltip-project-icon");
    h.t.moveTo(600, 400);
    try testing.expect(h.shown() == null);
}

test "a project icon names its project and device after 350 ms" {
    if (comptime tip.has) try projectIcon() else return error.SkipZigTest;
}

fn turnOff() !void {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.sandboxes(running);
    const off = h.t.findText("Turn off") orelse return error.NoButton;
    h.t.moveTo(off.x + 2, off.y + 2);
    h.t.advance(0.3);
    try testing.expect(h.shown() == null);
    h.t.advance(0.1);
    try testing.expectEqualStrings(sandboxes.turn_off_hint, h.shown().?);
    h.snap("tooltip-turn-off");
}

test "the sandbox strip's Turn off explains itself after 350 ms" {
    if (comptime tip.has) try turnOff() else return error.SkipZigTest;
}

fn copyId() !void {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1200, 2400);
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .agents;
    h.t.settle(1);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, running, .{});
    defer parsed.deinit();
    @import("view_settings_accounts.zig").feedSandboxes(&h.a, parsed.value);
    h.t.settle(1);
    const copy = h.t.findText("Copy ID") orelse return error.NoButton;
    h.t.moveTo(copy.x + 2, copy.y + 2);
    // GPUI's default: not at 450 ms, at 500.
    h.t.advance(0.45);
    try testing.expect(h.shown() == null);
    h.t.advance(0.06);
    try testing.expectEqualStrings("Use this ID with sandbox API/tools.", h.shown().?);
    h.t.moveTo(5, 5);
    try testing.expect(h.shown() == null);
}

test "Settings' Copy ID waits GPUI's default 500 ms" {
    if (comptime tip.has) try copyId() else return error.SkipZigTest;
}
