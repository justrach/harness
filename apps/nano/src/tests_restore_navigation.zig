//! Regression tests for the original tab-preserving navigation contract.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const sidebar = @import("view_sidebar.zig");

fn visibleTarget(h: *Harness, wanted: []const u8) !usize {
    h.a.settings.setText("sidebarLastActivity", "all");
    h.t.settle(1);
    for (sidebar.visibleSessionIds(&h.t.ctx, &h.a), 0..) |id, ix| {
        if (std.mem.eql(u8, id, wanted)) return ix;
    }
    return error.MissingSyntheticSession;
}

test "restore navigation numbered jump preserves the current conversation (#349)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const slot = try visibleTarget(&h, "b");
    try testing.expect(slot < 9);
    h.press((ui.Shortcut{ .key = @as(u21, '1') + @as(u21, @intCast(slot)), .cmd = true }).native());
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.tabs.find("a") != null);
    try testing.expect(h.a.tabs.find("b") != null);
}

test "restore navigation single-tab cycle opens rather than replaces (#349)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    _ = try visibleTarget(&h, "b");
    h.press(.{ .key = ui.Shortcut.tab, .ctrl = true });
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.tabs.find("a") != null);
}

test "restore navigation cycles the focused panel tabs before sidebar sessions (#349)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.a.tabs.isolateWorkspace();
    h.a.addChatTab(true);
    h.a.tabs.setCurrent("b");
    h.a.select("b", null);
    h.t.settle(1);
    h.press(.{ .key = ui.Shortcut.tab, .ctrl = true, .shift = true });
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.groups[0].count());
}

test "restore navigation reopen inserts a closed tab at its original position (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.openChat("b", null);
    h.a.closeTab(0);
    h.a.reopenClosedTab();
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("a", h.a.tabs.items.items[0].?);
    try testing.expectEqualStrings("b", h.a.tabs.items.items[1].?);
}

test "restore navigation reopen restores a split pane instead of another workspace (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("b", null);
    h.a.closeFocused();
    try testing.expect(h.a.tabs.layout() == null);
    h.a.reopenClosedTab();
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    const split = h.a.tabs.layout() orelse return error.MissingRestoredSplit;
    try testing.expectEqual(@as(usize, 2), split.panes.items.len);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqualStrings("a", split.panes.items[0].?);
}
