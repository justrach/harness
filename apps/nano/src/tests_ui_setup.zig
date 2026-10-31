//! First-run setup (view_setup.zig), driven headlessly as a person would:
//! Graff first and picked, Return through the questions, and the answers
//! landing on the new chat and Settings.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const setup = @import("view_setup.zig");
const S = ui.Shortcut;

const testing = std.testing;

const harnesses =
    \\[{"id":"graff","name":"graff","installed":true,"enabled":true,"reasoningLevels":["low","medium","high"]},
    \\ {"id":"claude-code","name":"Claude Code","installed":true,"enabled":false},
    \\ {"id":"codex","name":"Codex","installed":false,"enabled":false}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.new_harness = try testing.allocator.dupe(u8, "codex");
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, harnesses, .{});
        defer parsed.deinit();
        try h.a.harnesses.replace(parsed.value);
        h.a.view.setup_checked = true;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn press(h: *Harness, s: S) void {
        _ = h.t.shortcut(s);
        h.t.settle(1);
    }
};

test "setup starts on Graff, picked and recommended, with the extras as this device has them" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    setup.open(&h.a, 0);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Start with Graff"));
    try testing.expect(h.t.hasText("Recommended"));
    try testing.expect(h.t.hasText("Optional, ready"));
    try testing.expect(h.t.hasText("Not installed. Install it from Settings > Agents"));
    try testing.expect(h.t.hasText("1 of 4"));
}

test "Return walks the questions; Escape goes back; the answers land" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    setup.open(&h.a, 0);
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("How hard should it think?"));
    h.press(.{ .key = S.escape });
    try testing.expect(h.t.hasText("Start with Graff"));
    h.press(.{ .key = S.enter });
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("How much can it do without asking?"));
    try testing.expect(h.t.hasText("Workspace"));
    h.press(.{ .key = S.left });
    try testing.expectEqual(setup.Autonomy.read_only, h.a.view.setup.?.autonomy);
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("Ping you when it needs you?"));
    try h.t.clickText("No, I'll check in");
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("Your first agent is ready"));
    try testing.expect(h.t.hasText("Read only"));
    try h.t.clickText("Tour this project");
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(h.a.view.setup == null);
    try testing.expectEqualStrings("graff", h.a.new_harness);
    try testing.expect(!h.a.settings.get(.notifications_enabled));
    try testing.expect(std.mem.startsWith(u8, h.a.composer.text(), "Tour this project"));
}

test "Skip setup leaves the defaults alone" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    setup.open(&h.a, 1);
    h.t.settle(1);
    try h.t.clickText("Skip setup");
    h.t.settle(1);
    try testing.expect(h.a.view.setup == null);
    try testing.expectEqualStrings("codex", h.a.new_harness);
    try testing.expect(h.a.settings.get(.notifications_enabled));
}
