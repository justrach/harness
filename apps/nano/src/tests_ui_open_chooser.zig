//! Synthetic coverage for the shared start sheet and its split motion.
const std = @import("std");
const testing = std.testing;
const App = @import("app.zig").App;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const strip = @import("view_tab_strip.zig");
const tabs = @import("tabs.zig");
const chrome = @import("panel_chrome.zig");
const view = @import("view.zig");

test "new tab chooses its computer and folder in the shared sheet" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.settle(1);
    strip.newTab(&h.a, .{ .chat = 0 });
    h.t.settle(1);
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expect(h.t.hasText("New session"));
    try testing.expect(h.t.hasText("Computer"));
    try testing.expect(h.t.hasText("Folder"));
    try testing.expect(h.t.hasText("fieldnotes"));
    try h.t.clickText("Build box");
    h.t.settle(1);
    try testing.expectEqualStrings("remote", h.a.view.open_chooser.device.?);
    try testing.expect(h.t.hasText("remote-project"));
    try h.t.clickText("remote-project");
    h.t.settle(1);
    try testing.expect(!h.a.view.open_chooser.open);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expect(h.a.selected == null);
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expectEqualStrings("remote-project", h.a.newChatSpace().?.id);
}

test "project shortcut: Cmd D inherits the source project without opening a picker" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    // The global draft destination can differ from the source chat.
    h.a.select("a", "remote-project");
    h.a.setSpaceFilter("remote-project");
    try testing.expectEqualStrings("remote-project", h.a.space.?);
    h.a.composer.set("Original synthetic prompt");
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqual(@as(usize, 2), strip.chatCount(&h.a));
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expect(h.a.view.strip.pending_folder == null);
    try testing.expect(!h.a.view.open_chooser.open);
    try testing.expect(h.a.selected == null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("local", h.a.draftDevice().?);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.typeText("New split prompt");
    try testing.expectEqualStrings("New split prompt", h.a.composer.text());
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqualStrings("Original synthetic prompt", h.a.composer.text());
}

test "project shortcut: Cmd Shift D does nothing, including with a folder menu open" {
    for ([_]bool{ false, true }) |menu_open| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.composer.set("Keep this prompt");
        if (menu_open) {
            h.a.splitPane(.horizontal);
            h.t.settle(1);
            try @import("tests_ui_strip_folder_search.zig").openFolderMenu(&h);
            h.t.typeText("field");
            h.t.settle(1);
        }
        const panes = strip.chatCount(&h.a);
        const focus = h.t.ctx.focus;
        h.press(.{ .key = 'd', .cmd = true, .shift = true });
        try testing.expectEqual(panes, strip.chatCount(&h.a));
        try testing.expectEqual(focus, h.t.ctx.focus);
        try testing.expect(!h.a.view.open_chooser.open);
        if (menu_open) {
            try testing.expect(h.a.view.strip.menu == .folder);
            try testing.expectEqualStrings("field", h.a.view.strip.query.text());
        } else {
            try testing.expectEqualStrings("a", h.a.selected.?);
            try testing.expectEqualStrings("Keep this prompt", h.a.composer.text());
        }
    }
}

test "project shortcut: Cmd T asks for a project before creating a top-level tab" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.composer.set("Parked split prompt");
    h.t.settle(1);
    h.press(.{ .key = 't', .cmd = true });
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 2), strip.chatCount(&h.a));
    try testing.expectEqualStrings("Parked split prompt", h.a.composer.text());
    try h.t.clickText("Build box");
    h.t.settle(1);
    h.press(.{ .key = @import("nanoui").ui.Shortcut.enter });
    try testing.expect(!h.a.view.open_chooser.open);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expect(h.a.selected == null);
    try testing.expectEqualStrings("remote-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.showTab(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), strip.chatCount(&h.a));
    try testing.expectEqualStrings("Parked split prompt", h.a.composer.text());
}

test "shared sheet fades and lifts into place on open" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.settle(1);
    strip.newTab(&h.a, .{ .chat = 0 });
    h.t.frame();
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expect(h.t.ctx.animating);
    var translucent = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.style.radius == 16 and node.style.opacity < 0.99) translucent = true;
    }
    try testing.expect(translucent);
    h.t.settle(1);
    try testing.expect(!h.t.ctx.animating);
}

test "shared sheet split only changes the layout after its folder is chosen" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.settle(1);
    strip.splitChoosingDestination(&h.a, .horizontal);
    h.t.settle(1);
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expect(h.t.hasText("Split to the right"));
    try testing.expect(h.a.tabs.layout() == null);
    try h.t.clickText("fieldnotes");
    h.t.frame();
    try testing.expect(!h.a.view.open_chooser.open);
    const split = h.a.tabs.layout() orelse return error.NoSplit;
    try testing.expectEqual(@as(usize, 2), split.panes.items.len);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    // The pane grows on the clock; it is not an immediate layout swap.
    try testing.expect(h.a.view.split_reveal != null);
    h.t.advance(0.08);
    try testing.expect(h.a.view.split_reveal != null);
    h.t.advance(0.3);
    try testing.expect(h.a.view.split_reveal == null);
}

test "shared sheet split reveal starts at the old spans and ends at the even split" {
    var r: @import("app.zig").SplitReveal = .{ .tab = 0, .new_index = 1, .old_count = 1 };
    r.from_shares[0] = 1;
    const total: f32 = 1000;
    const target = chrome.paneSpan(total, 0.5, 2, true);
    try testing.expectApproxEqAbs(chrome.paneSpan(total, 1, 1, true), view.revealSpan(total, true, r, 0, target, 0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), view.revealSpan(total, true, r, 1, target, 0), 0.01);
    try testing.expectApproxEqAbs(target, view.revealSpan(total, true, r, 0, target, 1), 0.01);
    try testing.expectApproxEqAbs(target, view.revealSpan(total, true, r, 1, target, 1), 0.01);
}

test "shared sheet opens from the rebindable New project shortcut" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.press(.{ .key = 'n', .cmd = true, .shift = true });
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expectEqual(@import("app_open_chooser.zig").Intent.new_project, h.a.view.open_chooser.intent);
}

test "shared sheet new project begins in the same sheet and opens the name form" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.device_id = try testing.allocator.dupe(u8, "local");
    @import("app_open_chooser.zig").open(&a, .new_project);
    try testing.expect(a.view.open_chooser.open);
    try testing.expect(a.view.project_setup.open == false);
    @import("app_open_chooser.zig").newProject(&a);
    try testing.expect(!a.view.open_chooser.open);
    try testing.expect(a.view.project_setup.open);
    try testing.expect(a.view.project_setup.step == .details);
}
