//! #750: loading, unavailable and capture failures are not a clean diff.
//! Feed replies through the same request callback the live engine uses.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const panels = @import("app_panels.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, scene: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"plain-folder","deviceId":"fixture","cwd":"/synthetic/plain-folder","title":"Synthetic diff"}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("plain-folder", null);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
        h.a.engine.state = .connected;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(0.2);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
};

test "diff availability 750 plain-folder and transient failures stop loading without claiming clean" {
    for ([_]bool{ false, true }) |transient| {
        const message = if (transient) "Synthetic Git capture timed out" else "fatal: not a git repository (or any of the parent directories): .git";
        const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{
            .GetCheckoutDiff = .{ .@"$err" = message },
        }, .{});
        defer testing.allocator.free(scene);
        var h: Harness = undefined;
        try h.init(scene);
        defer h.deinit();
        panels.addDiffsTab(&h.a);
        try testing.expect(h.a.panels.diff_loading);
        try testing.expect(h.a.engine.pump());
        h.t.settle(0.2);
        try testing.expect(!h.a.panels.diff_loading);
        try testing.expect(h.a.panels.diff == null);
        try testing.expect(h.t.hasText(if (transient) message else panels.not_git_notice));
        try testing.expect(!h.t.hasText("Preparing diff…"));
        try testing.expect(!h.t.hasText("No uncommitted changes"));
        if (transient) try testing.expect(!h.t.hasText(panels.not_git_notice));
    }
}

test "diff availability 750 retry recovers from capture failure to clean and changed snapshots" {
    var h: Harness = undefined;
    try h.init(
        \\{"GetCheckoutDiff":{"$seq":[
        \\ {"$err":"Synthetic Git capture timed out"},
        \\ {"checkoutId":"checkout","checksum":"clean","patch":""},
        \\ {"checkoutId":"checkout","checksum":"changed","patch":"diff --git a/example.md b/example.md\n--- a/example.md\n+++ b/example.md\n@@ -1 +1 @@\n-before\n+after\n","additions":1,"deletions":1}
        \\]}}
    );
    defer h.deinit();
    panels.addDiffsTab(&h.a);
    try testing.expect(h.a.engine.pump());
    try testing.expect(h.a.panels.diff_error != null);
    panels.fetchDiff(&h.a);
    try testing.expect(h.a.panels.diff_loading);
    try testing.expect(h.a.engine.pump());
    h.t.settle(0.2);
    try testing.expect(h.a.panels.diff_error == null);
    try testing.expect(!h.a.panels.diff_loading);
    try testing.expect(h.t.hasText("No uncommitted changes"));
    panels.fetchDiff(&h.a);
    try testing.expect(h.a.engine.pump());
    h.t.settle(0.2);
    try testing.expect(h.a.panels.diff_error == null);
    try testing.expectEqual(@as(usize, 1), h.a.panels.diff.?.files.len);
    try testing.expect(h.t.hasText("example.md"));
    try testing.expect(!h.t.hasText("Preparing diff…"));
    try testing.expect(!h.t.hasText(panels.not_git_notice));
}
