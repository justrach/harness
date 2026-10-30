//! Menus and hover as GPUI's: a press outside a menu closes it and goes on
//! to what's under it (`on_mouse_down_out`); after the keyboard nothing is
//! hovered until the pointer moves (`Hitbox::is_hovered`); a row's hover
//! changes with the pointer, not with a menu opening over it
//! (`hover_listener`). Made-up chats.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;

const testing = std.testing;

const chats =
    \\[{"id":"a","deviceId":"d","title":"Alpha","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z","createdAt":"2026-10-01T00:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Beta","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z","createdAt":"2026-10-01T00:00:00Z"}]
;

fn centre(r: ui.Rect) ui.Point {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

/// The sidebar's row for `title` (its rect in the last frame).
fn rowOf(t: *ui.Tester, title: []const u8) !ui.Point {
    const r = t.findText(title) orelse return error.TextNotFound;
    return centre(r);
}

test "a press outside the chat menu closes it and opens the session pressed" {
    if (!@hasField(@FieldType(ui.Context, "input"), "secondary")) return error.SkipZigTest;
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = true;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
    defer parsed.deinit();
    try a.chats.replace(parsed.value);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(1);

    const alpha = try rowOf(&t, "Alpha");
    t.secondaryClick(alpha.x, alpha.y);
    t.settle(1);
    try testing.expect(a.view.chat_menu.open);
    try testing.expect(t.hasText("Rename…"));
    // Opened under a still pointer, the row stays hovered (its actions
    // shown), as GPUI's does.
    var it = a.view.hovers.valueIterator();
    var any = false;
    while (it.next()) |v| any = any or v.*;
    try testing.expect(any);

    const beta = try rowOf(&t, "Beta");
    t.click(beta.x, beta.y);
    t.settle(1);
    try testing.expect(!a.view.chat_menu.open);
    try testing.expectEqualStrings("b", a.selected.?);
}

test "after the keyboard nothing is hovered until the pointer moves" {
    if (!@hasField(ui.Context, "keyboard_hides_hover")) return error.SkipZigTest;
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = true;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
    defer parsed.deinit();
    try a.chats.replace(parsed.value);
    a.openChat("a", null);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(1);

    const beta = try rowOf(&t, "Beta");
    t.moveTo(beta.x, beta.y);
    t.settle(1);
    try testing.expect(t.ctx.hot != 0);
    t.key(.escape);
    t.settle(1);
    try testing.expectEqual(@as(u64, 0), t.ctx.hot);
    t.moveTo(beta.x + 1, beta.y);
    t.settle(1);
    try testing.expect(t.ctx.hot != 0);
}
