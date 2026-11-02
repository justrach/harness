//! Settings › Devices' Rename, Remove and id chip, driven headlessly on
//! made-up devices against a scene engine (settings/devices.rs).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;

const testing = std.testing;

const devices =
    \\[{"id":"studio-device-0001","name":"Studio","platform":"macos","lastSeenAt":null},
    \\ {"id":"laptop-device-0002","name":"Laptop","platform":"macos","lastSeenAt":"2026-01-01T00:00:00Z"}]
;

/// Each Mutate sent, as `op deviceId name`.
fn mutations(a: *App, out: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    for (a.engine.sent.items) |frame| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{});
        if (!std.mem.eql(u8, v.object.get("method").?.string, "Mutate")) continue;
        const p = v.object.get("params").?.object;
        const name = if (p.get("name")) |n| n.string else "";
        try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ p.get("op").?.string, p.get("deviceId").?.string, name }));
    }
}

/// The last place `s` is drawn: over the page, a dialog's.
fn clickLast(t: *ui.Tester, s: []const u8) !void {
    var at: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s)) {
            at = n.rect;
        },
        else => {},
    };
    const r = at orelse return error.TextNotFound;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
}

test "Settings › Devices: Rename sends the new name, Remove asks once more, the id chip copies" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = true;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, devices, .{});
    defer parsed.deinit();
    try a.devices.replace(parsed.value);
    a.device_id = try testing.allocator.dupe(u8, "studio-device-0001");
    a.engine.state = .connected;
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"Mutate\": {\"ok\": true}}", .{});
    a.view.settings_open = true;
    a.settings.section = .devices;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(1);

    // Rename: the dialog has the name, focused; Escape closes it, sending nothing.
    try clickLast(&t, "Rename");
    t.settle(1);
    try testing.expect(t.hasText("Rename device"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try testing.expect(!t.hasText("Rename device"));
    try clickLast(&t, "Rename");
    t.settle(1);
    try testing.expectEqualStrings("Laptop", a.view.devices.name.text());
    t.typeText(" Pro");
    t.settle(1);
    try clickLast(&t, "Rename");
    t.settle(1);
    try testing.expect(!t.hasText("Rename device"));

    // Remove: the first click asks, the second sends.
    try t.clickText("Remove");
    t.settle(1);
    try testing.expect(t.hasText("Remove?"));
    try t.clickText("Remove?");
    t.settle(1);
    try testing.expect(t.hasText("Remove"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var sent: std.ArrayList([]const u8) = .empty;
    try mutations(&a, &sent, arena.allocator());
    try testing.expectEqual(@as(usize, 2), sent.items.len);
    try testing.expectEqualStrings("renameDevice laptop-device-0002 Laptop Pro", sent.items[0]);
    try testing.expectEqualStrings("forgetDevice laptop-device-0002 ", sent.items[1]);

    // The id chip copies the whole id and says so.
    try t.clickText("laptop-d…0002");
    t.settle(0.1);
    try testing.expectEqualStrings("laptop-device-0002", t.clipboard.items);
    try testing.expect(t.hasText("Copied"));
    t.advance(1.6);
    try testing.expect(!t.hasText("Copied"));
}
