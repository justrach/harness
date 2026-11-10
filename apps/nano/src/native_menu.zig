//! AppKit handles menu accelerators before the view's shortcuts. The
//! window menu must route ⌘W to the same pane/tab action as the view.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const StoredItem = @typeInfo(@FieldType(@FieldType(nanoui.Menu, "items"), "items")).pointer.child;
const ItemArg = if (@typeInfo(StoredItem) == .pointer) StoredItem else *StoredItem;

pub fn install(app: *nanoui.App, a: *App) !void {
    const view_items = viewItems(a);
    const items = windowItems(a);
    try app.setMenu(&.{
        .{ .role = .app_menu },
        .{ .role = .edit_menu },
        .{ .role = .view_menu, .submenu = &view_items },
        .{ .role = .window_menu, .submenu = &items },
    });
}

fn viewItems(a: *App) [7]nanoui.MenuItem {
    return .{
        .{ .label = "Bigger Text", .accelerator = "Cmd+=", .click = .of(a, zoomIn) },
        .{ .label = "Smaller Text", .accelerator = "Cmd+-", .click = .of(a, zoomOut) },
        .{ .label = "Actual Size", .accelerator = "Cmd+0", .click = .of(a, resetZoom) },
        .separator,
        .{ .label = "Toggle Zen / Developer Mode", .accelerator = "Cmd+Shift+M", .click = .of(a, toggleUiMode) },
        .separator,
        .{ .role = .toggle_full_screen },
    };
}

fn windowItems(a: *App) [7]nanoui.MenuItem {
    return .{
        .{ .role = .minimize },
        .{ .role = .zoom },
        .separator,
        .{ .role = .front },
        .separator,
        .{ .label = "Close Tab", .accelerator = "Cmd+W", .click = .of(a, closeTab) },
        .{ .role = .close, .accelerator = "Cmd+Shift+W" },
    };
}

fn zoomIn(a: *App, _: ItemArg) void {
    const was = a.view.in_pre_tree;
    a.view.in_pre_tree = true;
    a.stepZoom(1);
    a.view.in_pre_tree = was;
    a.redraw();
}

fn zoomOut(a: *App, _: ItemArg) void {
    const was = a.view.in_pre_tree;
    a.view.in_pre_tree = true;
    a.stepZoom(-1);
    a.view.in_pre_tree = was;
    a.redraw();
}

fn resetZoom(a: *App, _: ItemArg) void {
    const was = a.view.in_pre_tree;
    a.view.in_pre_tree = true;
    a.resetZoom();
    a.view.in_pre_tree = was;
    a.redraw();
}

fn toggleUiMode(a: *App, _: ItemArg) void {
    const was = a.view.in_pre_tree;
    a.view.in_pre_tree = true;
    a.settings.toggleUiMode();
    a.view.in_pre_tree = was;
    a.redraw();
}

fn closeTab(a: *App, _: ItemArg) void {
    const was = a.view.in_pre_tree;
    a.view.in_pre_tree = true;
    a.closeByShortcut();
    a.view.in_pre_tree = was;
    a.redraw();
}

/// Dispatches through NSMenu, not ui.Tester: AppKit consumes these keys
/// before the view sees them. No event is posted and no window is shown.
fn pressClose(menu: *nanoui.Menu) bool {
    const objc = nanoui.objc;
    const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, @as(objc.NSUInteger, 1 << 20), @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), objc.nsString("w"), objc.nsString("w"), objc.NO, @as(u16, 13),
    });
    return objc.msg(objc.BOOL, menu.ns, "performKeyEquivalent:", .{event});
}

test "native Cmd+W closes a split pane, then a tab, without closing the app window" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    a.newTab();
    a.newTab();
    a.splitPane(.horizontal);
    try std.testing.expect(a.tabs.layout() != null);
    const tabs = a.tabs.items.items.len;
    const items = windowItems(&a);
    const menu = try nanoui.Menu.create(std.testing.allocator, "Harness", &.{.{ .role = .window_menu, .submenu = &items }});
    defer menu.destroy();
    try std.testing.expect(pressClose(menu));
    // First Cmd+W closes the split pane, leaving the current tab unsplit and
    // preserving the other top-level tabs.
    try std.testing.expect(a.tabs.layout() == null);
    try std.testing.expectEqual(tabs, a.tabs.items.items.len);
    try std.testing.expect(pressClose(menu));
    try std.testing.expectEqual(tabs - 1, a.tabs.items.items.len);
    while (a.tabs.items.items.len > 1) try std.testing.expect(pressClose(menu));
    // Closing the final tab leaves the new-session canvas, not no window.
    try std.testing.expect(pressClose(menu));
    try std.testing.expectEqual(@as(usize, 1), a.tabs.items.items.len);
    try std.testing.expect(a.selected == null);
    // Native accelerators also respect the focused non-chat panel.
    a.panels.host_open = true;
    a.panels.active = a.panels.tabs.items.len;
    a.view.strip.focused = .host;
    try std.testing.expect(pressClose(menu));
    try std.testing.expect(!a.panels.host_open);
    a.panels.files_open = true;
    a.view.strip.focused = .files;
    try std.testing.expect(pressClose(menu));
    try std.testing.expect(!a.panels.files_open);
    try std.testing.expectEqual(@as(usize, 1), a.tabs.items.items.len);
}
