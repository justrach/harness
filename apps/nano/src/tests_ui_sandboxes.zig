//! The running cloud sandbox's strip and chip, driven headlessly on
//! made-up data and no engine, as the GPUI app's tests drive them
//! (shell/cloud_sandbox_strip.rs: the_strip_shows_while_a_sandbox_runs_and_
//! opens_its_settings, a_collapsed_sidebar_keeps_a_chip_with_turn_off_in_view).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const strip = @import("view_sandbox_strip.zig");
const sidebar = @import("view_sidebar.zig");

const testing = std.testing;

const chats =
    \\[{"id":"a","deviceId":"d","title":"Alpha","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Beta","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z"}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, sidebar_open: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.view.sidebar_open = sidebar_open;
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

    /// The engine's answer to `CodegraffSandboxes`, as the app keeps it.
    fn answer(h: *Harness, reply: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
        defer parsed.deinit();
        @import("app_sandboxes.zig").apply(&h.a, parsed.value);
        h.t.settle(1);
    }

    /// How many texts read `s`.
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

/// One fleet sandbox in `state`, Harness on it and kept running.
fn one(comptime state: []const u8) []const u8 {
    return "{\"enabled\": true, \"sandboxes\": [{\"id\": \"cnd_1\", \"provider\": \"fleet\", \"state\": \"" ++ state ++
        "\", \"harness\": true, \"keepRunning\": true}]}";
}

const two_running =
    \\{"enabled": true, "sandboxes": [
    \\ {"id": "cnd_1", "provider": "fleet", "state": "running", "harness": true, "keepRunning": true},
    \\ {"id": "cnd_2", "provider": "fleet", "state": "running", "harness": true, "keepRunning": true}]}
;

const label = "Cloud sandbox running";

test "the strip shows while a sandbox runs, above the account badge, and opens its settings" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try testing.expect(!h.t.containsText("Cloud sandbox"));
    try h.answer(one("paused"));
    try testing.expect(!h.t.containsText("Cloud sandbox"));
    try testing.expect(!h.t.hasText("Turn off"));

    try h.answer(one("running"));
    try testing.expect(h.t.hasText(label));
    // "Billed per second until you turn it off", cut to the strip's width.
    try testing.expect(h.t.containsText("Billed per"));
    // In the sidebar's foot, above the badge; the open sidebar has no chip.
    const at = h.t.findText(label).?;
    try testing.expect(at.x < sidebar.width and at.y > 780 - 100);
    try testing.expectEqual(@as(usize, 1), h.count("Turn off"));
    h.snap("sandbox-strip-sidebar");

    // Without an engine Turn off sends nothing.
    try h.t.clickText("Turn off");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.cloud_sandboxes.turning_off);
    try testing.expect(h.a.noticeText() == null);
    // While it works the button reads so, in place, as Accounts' Turn off does.
    h.a.cloud_sandboxes.turning_off = 1;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Turning off…"));
    try testing.expect(!h.t.hasText("Turn off"));
    h.a.cloud_sandboxes.turning_off = 0;
    h.t.settle(1);

    // Two running: Turn off all.
    try h.answer(two_running);
    try testing.expect(h.t.containsText("2 cloud sandboxes"));
    try testing.expect(h.t.hasText("Turn off all"));
    try h.answer(one("running"));

    // The label opens Settings › Accounts, whose sidebar keeps it in view.
    try h.t.clickText(label);
    h.t.settle(1);
    try testing.expect(h.a.view.settings_open);
    try testing.expectEqual(.agents, h.a.settings.section);
    try testing.expect(h.t.hasText(label));
    try testing.expect(h.t.findText(label).?.x < sidebar.width);

    // Hidden where the feature is off.
    try h.answer("{\"enabled\": false, \"sandboxes\": [{\"id\": \"cnd_1\", \"provider\": \"fleet\", \"state\": \"running\"}]}");
    try testing.expect(!h.t.containsText("Cloud sandbox running"));
}

test "a closed sidebar keeps a chip with Turn off in view under the sidebar toggle" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try h.answer(one("paused"));
    try testing.expect(!h.t.hasText("Turn off"));

    try h.answer(one("running"));
    // The chip: Turn off under the toggle, and no strip.
    const off = h.t.findText("Turn off") orelse return error.NoChip;
    try testing.expect(off.x > strip.chip_at.x and off.x < sidebar.width);
    try testing.expect(off.y > strip.chip_at.y and off.y < strip.chip_at.y + 30);
    try testing.expect(!h.t.containsText("Cloud sandbox running"));
    try testing.expectEqual(@as(usize, 1), h.count("Turn off"));
    h.snap("sandbox-strip-chip");
    // Without an engine its Turn off sends nothing either; busy, it says so.
    try h.t.clickText("Turn off");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.cloud_sandboxes.turning_off);
    h.a.cloud_sandboxes.turning_off = 1;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Turning off…"));
    h.a.cloud_sandboxes.turning_off = 0;
    h.t.settle(1);

    // The dot and cloud open Settings › Accounts.
    h.t.click(strip.chip_at.x + 4 + 12, strip.chip_at.y + 4 + 10);
    h.t.settle(1);
    try testing.expect(h.a.view.settings_open);
    try testing.expectEqual(.agents, h.a.settings.section);
    // Settings keeps its sidebar here, and the strip in it.
    try testing.expect(h.t.hasText(label));

    // An open sidebar shows the strip instead.
    @import("view_settings.zig").close(&h.a);
    h.a.view.sidebar_open = true;
    h.t.settle(1);
    try testing.expect(h.t.hasText(label));
    try testing.expectEqual(@as(usize, 1), h.count("Turn off"));
    try testing.expect(h.t.findText("Turn off").?.y > 780 - 100);
}
