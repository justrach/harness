//! Shortcut edge cases use synthetic workspaces and the real UI dispatcher.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const strip = @import("view_tab_strip.zig");
const chooser = @import("app_open_chooser.zig");
const project_setup = @import("app_project_setup.zig");
const tabs = @import("tabs.zig");

fn draft(h: *Harness, space: []const u8) void {
    h.a.newTab();
    h.a.select(null, space);
    h.a.composer.set("Original synthetic prompt");
    h.t.settle(1);
}

fn fillPanes(h: *Harness) void {
    while (strip.chatCount(&h.a) < tabs.max_panes) h.a.splitPane(.horizontal);
    h.t.settle(1);
}

test "shortcut edge: remote and projectless canvases split without copying or losing their prompt" {
    for ([_]bool{ false, true }) |projectless| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        draft(&h, "remote-project");
        if (projectless) {
            h.a.pickDraftDevice("local");
            h.a.pickDraftDevice("remote");
        }
        h.press(.{ .key = 'd', .cmd = true });
        try testing.expectEqualStrings("remote", h.a.draftDevice().?);
        try testing.expectEqual(projectless, h.a.new_no_project);
        if (projectless) try testing.expect(h.a.newChatSpace() == null) else try testing.expectEqualStrings("remote-project", h.a.newChatSpace().?.id);
        try testing.expect(h.a.view.strip.menu == null);
        try testing.expectEqualStrings("", h.a.composer.text());
        h.t.typeText("New pane prompt");
        h.press(.{ .key = '[', .cmd = true });
        try testing.expectEqualStrings("Original synthetic prompt", h.a.composer.text());
        h.press(.{ .key = ']', .cmd = true });
        try testing.expectEqualStrings("New pane prompt", h.a.composer.text());
    }
}

test "shortcut edge: a remote chat overrides an unrelated local draft and sidebar filter" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    draft(&h, "local-project");
    h.a.openChat("b", null);
    h.a.setSpaceFilter("local-project");
    h.t.settle(1);
    try testing.expectEqualStrings("local-project", h.a.space.?);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqualStrings("remote-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    try testing.expect(h.a.view.strip.menu == null);
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqualStrings("remote-project", h.a.findChat("b").?.space_id.?);
}

test "shortcut edge: Cmd D from folder search inherits the current project not the search result" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try @import("tests_ui_strip_folder_search.zig").openFolderMenu(&h);
    h.t.typeText("no matching folder");
    h.t.settle(1);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqual(@as(usize, 3), strip.chatCount(&h.a));
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    h.t.typeText("Ready immediately");
    try testing.expectEqualStrings("Ready immediately", h.a.composer.text());
}

test "shortcut edge: refused Cmd D preserves the source prompt destination and folder search" {
    for ([_]bool{ false, true }) |at_cap| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        if (at_cap) fillPanes(&h) else h.a.splitPane(.vertical);
        h.a.composer.set("Keep this draft");
        h.t.settle(1);
        const pane = h.a.tabs.layout().?.focus;
        strip.open(&h.a, .folder, .{ .chat = pane }, .{ .x = 750, .y = 24, .w = 80, .h = 14 });
        h.t.settle(1);
        h.t.typeText("field");
        h.t.settle(1);
        const count = strip.chatCount(&h.a);
        const focus = h.t.ctx.focus;
        h.press(.{ .key = 'd', .cmd = true });
        try testing.expectEqual(count, strip.chatCount(&h.a));
        try testing.expectEqual(pane, h.a.tabs.layout().?.focus);
        try testing.expect(h.a.view.strip.menu == .folder);
        try testing.expectEqual(focus, h.t.ctx.focus);
        try testing.expectEqualStrings("field", h.a.view.strip.query.text());
        try testing.expectEqualStrings("Keep this draft", h.a.composer.text());
        try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    }
}

test "shortcut edge: Cmd T cancellation never changes the source draft or creates a tab" {
    for ([_]bool{ false, true }) |button| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        draft(&h, "local-project");
        const source = h.a.tabs.active;
        const count = h.a.tabs.items.items.len;
        h.press(.{ .key = 't', .cmd = true });
        try h.t.clickText("Build box");
        h.t.settle(1);
        h.t.typeText("no such project");
        h.t.settle(1);
        if (button) {
            try h.t.clickText("Cancel");
            h.t.settle(1);
        } else h.press(.{ .key = ui.Shortcut.escape });
        try testing.expect(!h.a.view.open_chooser.open);
        try testing.expectEqual(count, h.a.tabs.items.items.len);
        try testing.expectEqual(source, h.a.tabs.active);
        try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
        try testing.expectEqualStrings("local", h.a.draftDevice().?);
        try testing.expectEqualStrings("Original synthetic prompt", h.a.composer.text());
        h.t.typeText("!");
        try testing.expectEqualStrings("Original synthetic prompt!", h.a.composer.text());
    }
}

test "shortcut edge: repeated Cmd T creates exactly one tab and supports an explicit projectless remote" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    draft(&h, "local-project");
    const source = h.a.tabs.active;
    const count = h.a.tabs.items.items.len;
    for (0..3) |_| h.press(.{ .key = 't', .cmd = true });
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expectEqual(count, h.a.tabs.items.items.len);
    try h.t.clickText("Build box");
    h.t.settle(1);
    try h.t.clickText("Don't work in a project");
    h.t.settle(1);
    try testing.expectEqual(count + 1, h.a.tabs.items.items.len);
    try testing.expect(h.a.new_no_project);
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.closeTab(h.a.tabs.active);
    h.t.settle(1);
    try testing.expectEqual(source, h.a.tabs.active);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("Original synthetic prompt", h.a.composer.text());
}

test "shortcut edge: Cmd T from folder search dismisses only that menu and cancellation restores typing" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    h.a.composer.set("Keep the split prompt");
    try @import("tests_ui_strip_folder_search.zig").openFolderMenu(&h);
    const count = h.a.tabs.items.items.len;
    h.press(.{ .key = 't', .cmd = true });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expect(h.a.view.open_chooser.open);
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expectEqual(count, h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 2), strip.chatCount(&h.a));
    h.t.typeText("!");
    try testing.expectEqualStrings("Keep the split prompt!", h.a.composer.text());
}

test "shortcut edge: Cmd Shift D is inert in empty drafts chooser device menus and auxiliary panels" {
    const Surface = enum { canvas, projectless, chooser, device, host, files };
    for (std.enums.values(Surface)) |surface| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        draft(&h, "local-project");
        switch (surface) {
            .canvas => {},
            .projectless => h.a.pickDraftDevice("remote"),
            .chooser => h.press(.{ .key = 't', .cmd = true }),
            .device => strip.open(&h.a, .device, .{ .chat = 0 }, .{ .x = 750, .y = 24, .w = 80, .h = 14 }),
            .host => {
                h.a.panels.host_open = true;
                h.a.view.strip.focused = .host;
            },
            .files => {
                h.a.panels.files_open = true;
                h.a.view.strip.focused = .files;
            },
        }
        h.t.settle(1);
        const count = h.a.tabs.items.items.len;
        const focus = h.t.ctx.focus;
        const menu = h.a.view.strip.menu;
        const panel = strip.active(&h.a);
        for (0..3) |_| h.press(.{ .key = 'd', .cmd = true, .shift = true });
        try testing.expectEqual(count, h.a.tabs.items.items.len);
        try testing.expectEqual(@as(usize, 1), strip.chatCount(&h.a));
        try testing.expectEqual(menu, h.a.view.strip.menu);
        try testing.expectEqual(focus, h.t.ctx.focus);
        try testing.expect(strip.same(panel, strip.active(&h.a)));
        try testing.expectEqual(surface == .chooser, h.a.view.open_chooser.open);
        try testing.expectEqualStrings("Original synthetic prompt", h.a.composer.text());
    }
}

test "shortcut edge: opening and cancelling folder setup preserves the source draft destination" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    draft(&h, "local-project");
    const count = h.a.tabs.items.items.len;
    h.press(.{ .key = 't', .cmd = true });
    chooser.pickDevice(&h.a, "remote");
    chooser.newProject(&h.a);
    h.t.settle(1);
    project_setup.dismiss(&h.a);
    h.t.settle(1);
    try testing.expectEqual(count, h.a.tabs.items.items.len);
    try testing.expect(h.a.newChatSpace() != null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("local", h.a.draftDevice().?);
    try testing.expectEqualStrings("Original synthetic prompt", h.a.composer.text());
}

test "shortcut edge: folder setup honors a remote choice from an established local chat" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 't', .cmd = true });
    chooser.pickDevice(&h.a, "remote");
    chooser.newProject(&h.a);
    h.t.settle(1);
    try testing.expect(h.a.view.project_setup.open);
    try testing.expectEqualStrings("remote", h.a.view.project_setup.device.?);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "shortcut edge: finishing folder setup parks the unchanged source and opens the chosen project" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    draft(&h, "local-project");
    const source = h.a.tabs.active;
    const count = h.a.tabs.items.items.len;
    h.press(.{ .key = 't', .cmd = true });
    chooser.pickDevice(&h.a, "remote");
    chooser.newProject(&h.a);
    h.a.view.project_setup.folder = .{ .device = "remote", .device_name = "Build box", .path = "/synthetic/remote-project", .git = false };
    project_setup.submit(&h.a);
    h.t.settle(1);
    try testing.expectEqual(count + 1, h.a.tabs.items.items.len);
    try testing.expectEqualStrings("remote-project", h.a.newChatSpace().?.id);
    h.a.showTab(source);
    h.t.settle(1);
    try testing.expect(h.a.newChatSpace() != null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("local", h.a.draftDevice().?);
    try testing.expectEqualStrings("Original synthetic prompt", h.a.composer.text());
}

test "shortcut edge: impossible explicit splits never replace the source chat or its draft" {
    for ([_]bool{ false, true }) |at_cap| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        if (at_cap) fillPanes(&h) else h.a.splitPane(.vertical);
        h.a.openChat("b", null);
        h.a.composer.set("Keep this source chat prompt");
        h.t.settle(1);
        const count = strip.chatCount(&h.a);
        strip.splitChoosingDestination(&h.a, .horizontal);
        chooser.choose(&h.a, "local-project");
        h.t.settle(1);
        try testing.expectEqual(count, strip.chatCount(&h.a));
        try testing.expect(h.a.selected != null);
        try testing.expectEqualStrings("b", h.a.selected.?);
        try testing.expectEqualStrings("Keep this source chat prompt", h.a.composer.text());
    }
}

test "shortcut edge: a missing source project never falls back to another remote folder" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChat("b", null);
    var spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"other-remote-project","deviceId":"remote","path":"/synthetic/unrelated"} ]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    h.t.settle(1);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqualStrings("remote-project", h.a.space.?);
    try testing.expect(!h.a.new_no_project);
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    h.a.engine.state = .connected;
    h.a.composer.set("Wait for the intended project");
    const sent = h.a.engine.sent.items.len;
    h.a.send();
    try testing.expectEqual(sent, h.a.engine.sent.items.len);
    try testing.expect(h.a.selected == null);
    try testing.expectEqualStrings("Wait for the intended project", h.a.composer.text());
    try testing.expect(h.a.noticeText() != null);

    // Once metadata catches up, the same draft sends to its original project.
    var restored = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"remote-project","deviceId":"remote","path":"/synthetic/remote-project"} ]
    , .{});
    defer restored.deinit();
    try h.a.spaces.replace(restored.value);
    h.a.send();
    try testing.expect(h.a.selected != null);
    try testing.expectEqualStrings("", h.a.composer.text());
    var correct_project = false;
    for (h.a.engine.sent.items[sent..]) |frame| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse continue;
        if (params != .object) continue;
        const op = params.object.get("op") orelse continue;
        if (op != .string or !std.mem.eql(u8, op.string, "createChat")) continue;
        try testing.expectEqualStrings("remote-project", params.object.get("spaceId").?.string);
        correct_project = true;
    }
    try testing.expect(correct_project);
}
