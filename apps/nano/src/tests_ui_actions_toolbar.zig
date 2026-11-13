//! Project actions stay reachable after the unified strip replaced titlebar controls.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, unavailable: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"p","deviceId":"synthetic","path":"/synthetic/project"}]
        , .{});
        defer spaces.deinit();
        try h.a.spaces.replace(spaces.value);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"c","spaceId":"p","deviceId":"synthetic","title":"Synthetic actions"}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("c", null);
        h.a.actions.status = if (unavailable) .unavailable else .ready;
        h.a.actions.error_text = "Synthetic action failure";
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(0.3);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
};

test "project actions unavailable control stays reachable below the unified strip" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const anchor = h.a.actions.anchor orelse return error.MissingActionsToolbar;
    try testing.expect(anchor.y >= 42 and anchor.y + anchor.h <= 79);
    h.t.click(anchor.x + anchor.w / 2, anchor.y + anchor.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Synthetic action failure"));
    try testing.expect(h.t.hasText("Retry"));
}

test "project actions toolbar opens the real action editor" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const add = h.t.findText("Add action") orelse return error.MissingActionsToolbar;
    try testing.expect(add.y >= 42 and add.y < 79);
    try h.t.clickText("Add action");
    h.t.settle(0.3);
    try testing.expect(h.a.actions.editor != null);
}
