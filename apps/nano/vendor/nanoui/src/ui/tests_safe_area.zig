//! The safe area: what the system draws over a window (iOS's status bar,
//! home indicator and keyboard). A box padded by it keeps its content
//! clear of those edges; on the desktop it is empty and pads nothing.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Screen = struct {
    fn view(_: *Screen, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().safeArea().bg(.white);
        defer root.end();
        const content = ui.div(c).wFull().grow().bg(.hex(0xff0000));
        defer content.end();
    }
};

fn at(px: anytype, x: usize, y: usize) [3]u8 {
    const i = (y * px.width + x) * 4;
    return .{ px.bytes[i + 2], px.bytes[i + 1], px.bytes[i] };
}

test "a box padded by the safe area keeps its content clear of the system's edges" {
    var s: Screen = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Screen.view), .{ .width = 100, .height = 200, .scale = 1 });
    defer t.deinit();
    t.ctx.safe_area = .{ .top = 40, .bottom = 30, .left = 10 };
    t.settle(0.1);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const white = [3]u8{ 255, 255, 255 };
    const red = [3]u8{ 255, 0, 0 };
    try testing.expectEqual(white, at(px, 50, 20)); // under the status bar
    try testing.expectEqual(white, at(px, 50, 185)); // over the home indicator
    try testing.expectEqual(white, at(px, 5, 100)); // the left inset
    try testing.expectEqual(red, at(px, 50, 100));
    try testing.expectEqual(red, at(px, 95, 45));
}

test "the safe area is empty unless the platform sets it" {
    var s: Screen = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Screen.view), .{ .width = 100, .height = 100, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    try testing.expectEqual([3]u8{ 255, 0, 0 }, at(px, 2, 2));
}
