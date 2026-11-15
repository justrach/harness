//! Native choice groups and real checkout-menu rows, using synthetic input.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const behavior = @import("control_behavior.zig");
const groups = @import("control_group.zig");

fn named(c: *ui.Context, label: []const u8) !u64 {
    for (c.a11y_items.items) |item| if (std.mem.eql(u8, item.label, label)) return item.id;
    return error.MissingControl;
}

const Choices = struct {
    selected: usize = 0,
    enabled: bool = true,
    commits: usize = 0,

    fn view(s: *Choices, c: *ui.Context) void {
        const root = ui.div(c).column().p(10).gap(8);
        defer root.end();
        const k = theme.colors(false);
        const before = ui.div(c).size(80, 25).control();
        _ = behavior.activate(c, before, k, "Before", true, false);
        before.end();
        if (groups.choices(c, k, "Test choices", &.{ "Open", "Closed", "All" }, s.selected, s.enabled, .radio_button)) |selected| {
            s.selected = selected;
            s.commits += 1;
        }
        const after = ui.div(c).size(80, 25).control();
        _ = behavior.activate(c, after, k, "After", true, false);
        after.end();
    }
};

test "native choices have one Tab stop and separate arrow focus from selection" {
    var s: Choices = .{};
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, Choices.view), .{ .width = 500, .height = 220 });
    defer tester.deinit();
    tester.settle(0.1);
    try t.expectEqual(@as(usize, 3), tester.ctx.last_focusable_ids.items.len);
    tester.key(.tab);
    try t.expectEqual(try named(&tester.ctx, "Before"), tester.ctx.focus);
    tester.key(.tab);
    try t.expectEqual(try named(&tester.ctx, "Open"), tester.ctx.focus);
    tester.key(.right);
    try t.expectEqual(try named(&tester.ctx, "Closed"), tester.ctx.focus);
    try t.expectEqual(@as(usize, 0), s.selected);
    try t.expectEqual(@as(usize, 0), s.commits);
    tester.key(.end);
    try t.expectEqual(try named(&tester.ctx, "All"), tester.ctx.focus);
    tester.key(.right);
    try t.expectEqual(try named(&tester.ctx, "Open"), tester.ctx.focus);
    tester.key(.left);
    try t.expectEqual(try named(&tester.ctx, "All"), tester.ctx.focus);
    tester.key(.enter);
    try t.expectEqual(@as(usize, 2), s.selected);
    try t.expectEqual(@as(usize, 1), s.commits);
    tester.key(.home);
    _ = tester.shortcut(.{ .key = ' ' });
    try t.expectEqual(@as(usize, 0), s.selected);
    try t.expectEqual(@as(usize, 2), s.commits);
    tester.key(.tab);
    try t.expectEqual(try named(&tester.ctx, "After"), tester.ctx.focus);
    tester.setMods(.{ .shift = true });
    tester.key(.tab);
    try t.expectEqual(try named(&tester.ctx, "Open"), tester.ctx.focus);
    tester.setMods(.{});
    const closed = try named(&tester.ctx, "Closed");
    const rect = tester.ctx.rects.get(closed).?;
    tester.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try t.expectEqual(@as(usize, 1), s.selected);
    try t.expectEqual(@as(usize, 3), s.commits);
    try t.expectEqual(closed, tester.ctx.focus);
    tester.key(.tab);
    try t.expectEqual(try named(&tester.ctx, "After"), tester.ctx.focus);
}

test "native choices skip disabled rows and recover focus without stealing it" {
    var s: Choices = .{};
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, Choices.view), .{ .width = 500, .height = 220 });
    defer tester.deinit();
    tester.settle(0.1);
    tester.ctx.focus = try named(&tester.ctx, "Open");
    s.enabled = false;
    tester.settle(0.1);
    try t.expectEqual(@as(u64, 0), tester.ctx.focus);
    try t.expectEqual(@as(usize, 2), tester.ctx.last_focusable_ids.items.len);
    s.enabled = true;
    tester.settle(0.1);
    try t.expectEqual(try named(&tester.ctx, "Open"), tester.ctx.focus);
    s.enabled = false;
    tester.settle(0.1);
    tester.ctx.focus = try named(&tester.ctx, "After");
    s.enabled = true;
    tester.settle(0.1);
    try t.expectEqual(try named(&tester.ctx, "After"), tester.ctx.focus);
    try t.expectEqual(@as(usize, 0), s.commits);
}

fn menuView(a: *@import("app.zig").App, c: *ui.Context) void {
    @import("view_menus.zig").menus(c, a, theme.colors(false));
}

test "native checkout menu rows activate from keyboard and expose selection" {
    const App = @import("app.zig").App;
    var a: App = .init(t.allocator, t.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.new_checkout_local = true;
    a.view.checkout_menu = true;
    a.view.checkout_anchor = .{ .x = 30, .y = 40, .w = 28, .h = 24 };
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&a, menuView), .{ .width = 500, .height = 300 });
    defer tester.deinit();
    tester.settle(0.1);
    const label = @import("view_newchat.zig").checkoutLabel(false);
    tester.ctx.focus = try named(&tester.ctx, label);
    tester.key(.enter);
    tester.settle(0.1);
    try t.expect(!a.new_checkout_local);
    try t.expect(!a.view.checkout_menu);
}
