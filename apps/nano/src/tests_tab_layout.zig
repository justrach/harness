//! Reload coverage for Nano's tab/split record. Synthetic chats only.
const std = @import("std");
const testing = std.testing;
const App = @import("app.zig").App;
const tabs = @import("tabs.zig");
const persistence = @import("app_tab_layout.zig");

fn chats(a: *App) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"a","deviceId":"d","title":"A","archived":false},
        \\ {"id":"b","deviceId":"d","title":"B","archived":false},
        \\ {"id":"c","deviceId":"d","title":"C","archived":false},
        \\ {"id":"d","deviceId":"d","title":"D","archived":false},
        \\ {"id":"e","deviceId":"d","title":"E","archived":false}]
    , .{});
    defer parsed.deinit();
    try a.chats.replace(parsed.value);
}

fn own(a: *App, text: []const u8) ![]u8 {
    return a.gpa.dupe(u8, text);
}

test "split layout survives a reload with axis shares focus zoom and panel tabs" {
    var first: App = .init(testing.allocator, testing.io, 1);
    defer first.deinit();
    try chats(&first);
    first.tabs_ready = true;

    first.tabs.items.items[0] = try own(&first, "a");
    first.tabs.appendTab();
    first.tabs.items.items[1] = try own(&first, "e");
    first.tabs.active = 0;

    var split: tabs.Split = .{ .axis = .horizontal, .focus = 1, .zoomed = true };
    try split.panes.append(first.gpa, try own(&first, "b"));
    try split.panes.append(first.gpa, null);
    try split.panes.append(first.gpa, try own(&first, "c"));
    try split.shares.append(first.gpa, 0.4);
    try split.shares.append(first.gpa, 0.3);
    try split.shares.append(first.gpa, 0.3);
    for (0..3) |_| try split.drafts.append(first.gpa, null);
    try split.groups[0].items.append(first.gpa, .{});
    try split.groups[0].items.append(first.gpa, .{ .chat = try own(&first, "d") });
    first.tabs.splits.items[0] = split;

    first.rememberTabs();
    const body = first.settings.tabLayout() orelse return error.MissingLayout;

    var second: App = .init(testing.allocator, testing.io, 1);
    defer second.deinit();
    try chats(&second);
    second.settings.setTabLayout(body);
    second.restoreTabs();

    try testing.expectEqual(@as(usize, 2), second.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 0), second.tabs.active);
    try testing.expectEqualStrings("a", second.tabs.current().?);
    try testing.expectEqualStrings("e", second.tabs.items.items[1].?);
    const restored = second.tabs.layout() orelse return error.MissingSplit;
    try testing.expect(restored.axis == .horizontal);
    try testing.expectEqual(@as(usize, 1), restored.focus);
    try testing.expect(restored.zoomed);
    try testing.expectEqual(@as(usize, 3), restored.panes.items.len);
    try testing.expectEqualStrings("b", restored.panes.items[0].?);
    try testing.expect(restored.panes.items[1] == null);
    try testing.expectEqualStrings("c", restored.panes.items[2].?);
    try testing.expectApproxEqAbs(@as(f32, 0.4), restored.shares.items[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), restored.shares.items[2], 1e-6);
    try testing.expectEqual(@as(usize, 2), restored.groups[0].items.items.len);
    try testing.expect(restored.groups[0].items.items[0].chat == null);
    try testing.expectEqualStrings("d", restored.groups[0].items.items[1].chat.?);
    try testing.expectEqualStrings("a", second.selected.?);
}

test "a malformed or absent Nano layout falls back without replacing tabs" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try chats(&a);
    try testing.expect(!persistence.restore(&a));
    try testing.expectEqual(@as(usize, 1), a.tabs.items.items.len);
    a.settings.setTabLayout("{\"version\":1,\"tabs\":[]}");
    try testing.expect(!persistence.restore(&a));
    try testing.expectEqual(@as(usize, 1), a.tabs.items.items.len);
}
