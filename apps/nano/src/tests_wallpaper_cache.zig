const std = @import("std");
const ui = @import("nanoui").ui;
const wall = @import("wallpaper.zig");
const testing = std.testing;

test "wallpaper caches retain separate split-pane leases and never evict current-frame trees" {
    const Empty = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const box = ui.div(c).sizeFull();
            box.end();
        }
    };
    var empty: Empty = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&empty, Empty.view), .{ .width = 640, .height = 480 });
    defer t.deinit();
    t.settle(0.1);
    var state: wall.State = .{};
    defer state.deinit();
    state.prepare(testing.allocator, .dusk);
    const first = state.render(&t.ctx, testing.allocator, 1, .{ .width = 300, .height = 400 }) orelse return error.MissingFirst;
    const second = state.render(&t.ctx, testing.allocator, 2, .{ .width = 500, .height = 400 }) orelse return error.MissingSecond;
    try testing.expect(first.id.ptr != second.id.ptr);
    try testing.expectEqualStrings("dusk", first.id);
    try testing.expectEqualStrings("dusk", second.id);
    try testing.expectEqual(@as(f32, 300), first.width);
    for (3..9) |id| try testing.expect(state.render(&t.ctx, testing.allocator, id, .{ .width = 200, .height = 300 }) != null);
    // At capacity, a ninth pane falls back instead of freeing a live tree.
    try testing.expect(state.render(&t.ctx, testing.allocator, 9, .{ .width = 200, .height = 300 }) == null);
    try testing.expectEqualStrings("dusk", first.id);
    // An unusual second draw of the same key uses the frame allocator.
    try testing.expect(state.render(&t.ctx, testing.allocator, 1, .{ .width = 320, .height = 400 }) != null);
    try testing.expectEqual(@as(f32, 300), first.width);
    t.ctx.frame += 3;
    try testing.expect(state.render(&t.ctx, testing.allocator, 9, .{ .width = 200, .height = 300 }) != null);
}
