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

test "Settings › Devices: only a remote computer has Updates, and only the open one is watched" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = true;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, devices, .{});
    defer parsed.deinit();
    try a.devices.replace(parsed.value);
    a.device_id = try testing.allocator.dupe(u8, "studio-device-0001");
    a.engine.state = .connected;
    // A stream that has started and hasn't said anything yet.
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"UpdateStatus\": {\"ok\": true}}", .{});
    a.view.settings_open = true;
    a.settings.section = .devices;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(1);

    // This device has none; the laptop does. It's offline: nothing to watch,
    // and it says so.
    try testing.expectEqual(@as(usize, 1), countText(&t, "Updates"));
    try t.clickText("Updates");
    t.settle(1);
    try testing.expect(t.hasText("Hide updates"));
    try testing.expect(t.containsText("Offline. Open Harness"));
    try testing.expect(a.view.devices.updates.watch == null);
    try testing.expect(!sentMethod(&a, "UpdateStatus"));
    try t.clickText("Hide updates");
    t.settle(1);
    try testing.expect(t.hasText("Updates"));
    try testing.expect(!t.containsText("Offline. Open Harness"));

    // Online, it's watched while open, and no longer once the page is left.
    a.devices.items[1].last_seen_ms = a.nowMs();
    t.settle(0.1);
    try t.clickText("Updates");
    t.settle(0.1);
    try testing.expect(sentMethod(&a, "UpdateStatus"));
    try testing.expect(t.containsText("Reading this host's update status"));
    try testing.expect(a.view.devices.updates.watch != null);
    a.settings.section = .appearance;
    t.settle(0.1);
    try testing.expect(a.view.devices.updates.watch == null);
    try testing.expectEqual(@as(usize, 0), a.view.devices.updates.device.items.len);
}

test "a press on nothing focusable hands the keys back to the composer; Escape's blur stays" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = true;
    a.engine.state = .connected;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(1);
    try testing.expectEqual(a.view.composer_id, t.ctx.focus);

    // Empty canvas, well above the composer.
    t.click(800, 60);
    t.settle(0.1);
    try testing.expectEqual(a.view.composer_id, t.ctx.focus);

    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.key(.escape);
    t.settle(0.1);
    try testing.expectEqual(@as(u64, 0), t.ctx.focus);
}

fn countText(t: *ui.Tester, s: []const u8) usize {
    var n: usize = 0;
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| {
            if (std.mem.eql(u8, tx.str, s)) n += 1;
        },
        else => {},
    };
    return n;
}

fn sentMethod(a: *App, method: []const u8) bool {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"method\":\"{s}\"", .{method}) catch return false;
    for (a.engine.sent.items) |frame| {
        if (std.mem.indexOf(u8, frame, needle) != null) return true;
    }
    return false;
}
