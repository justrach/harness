//! release/v0.2.172's split → search folder → type flow, on made-up data.
const std = @import("std");
const ui = @import("nanoui").ui;
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const strip = @import("view_tab_strip.zig");

test "release folder menu: Cmd D opens a focused searchable folder menu under its new slot" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    try testing.expectEqual(@as(usize, 1), h.a.view.strip.target.chat);
    const anchor = h.a.view.strip.anchor orelse return error.MissingFolderAnchor;
    try testing.expect(anchor.y >= 5 and anchor.y + anchor.h <= 42);
    try testing.expect(h.t.hasText("Search folders…"));
    h.t.typeText("field notes");
    h.t.settle(1);
    try testing.expectEqualStrings("field notes", h.a.view.strip.query.text());
    try testing.expectEqual(@as(usize, 3), h.a.view.strip.rows);
    try testing.expectEqual(@as(usize, 0), h.a.view.strip.cursor);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "release folder menu: Escape accepts the inherited folder and returns typing to the composer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.press(.{ .key = ui.Shortcut.escape });
    h.t.typeText("A synthetic new-panel prompt");
    h.t.settle(1);
    try testing.expectEqualStrings("A synthetic new-panel prompt", h.a.composer.text());
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqual(@as(usize, 2), strip.chatCount(&h.a));
}

test "release folder menu: one Cmd W closes the panel Cmd D made even while search has focus" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expectEqual(@as(usize, 1), strip.chatCount(&h.a));
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expect(h.a.view.strip.pending_folder == null);
}

test "release folder menu: pane navigation dismisses search and preserves each composer's typing" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.composer.set("Original draft");
    h.t.settle(1);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.t.typeText("field");
    h.press(.{ .key = '[', .cmd = true });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.typeText("!");
    try testing.expectEqualStrings("Original draft!", h.a.composer.text());
    h.press(.{ .key = ']', .cmd = true });
    h.t.typeText("Right draft");
    try testing.expectEqualStrings("Right draft", h.a.composer.text());
    try testing.expectEqualStrings("field", h.a.view.strip.query.text());
}

test "release folder menu: Cmd L accepts the inherited folder and focuses its composer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.press(.{ .key = 'l', .cmd = true });
    h.t.typeText("Type directly");
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqualStrings("Type directly", h.a.composer.text());
}

test "release folder menu: no matches retains both actions and never selects projectless accidentally" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    h.t.typeText("no such synthetic folder");
    h.t.settle(1);
    try testing.expect(h.t.hasText("No folders match"));
    try testing.expect(h.t.hasText("Don't work in a project"));
    try testing.expect(h.t.hasText("New project…"));
    try testing.expectEqual(@as(usize, 2), h.a.view.strip.rows);
    try testing.expectEqual(@as(usize, 1), h.a.view.strip.cursor);
    try testing.expect(!h.a.new_no_project);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
}

test "release folder menu: no folders means a split goes straight to typing" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
    defer parsed.deinit();
    try h.a.spaces.replace(parsed.value);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expect(h.a.view.strip.pending_folder == null);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "release footer project menu: shared search is280px above its trigger with New project first" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.view.space_anchor = .{ .x = 350, .y = 740, .w = 100, .h = 20 };
    h.a.view.space_menu = true;
    h.t.settle(2);
    try testing.expect(!h.a.view.space_menu);
    try testing.expect(h.a.view.strip.footer_folder);
    try testing.expect(h.t.hasText("Search projects…"));
    const create = h.t.findText("New project…") orelse return error.MissingCreate;
    const none = h.t.findText("Don't work in a project") orelse return error.MissingProjectless;
    try testing.expect(create.y < none.y and none.y + none.h < 740);
    var wide_card = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.w == 280 and node.style.radius == 12 and node.rect.y + node.rect.h <= 740) wide_card = true;
    }
    try testing.expect(wide_card);
    // Other-device project headers remain visible in the sidebar; only
    // the open project menu must exclude those destinations.
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "remote-project")) {
            try testing.expect(node.rect.x < h.a.view.sidebar_width);
        },
        else => {},
    };
    h.t.typeText("no matching project");
    h.t.settle(1);
    try testing.expect(h.t.hasText("No projects match."));
    try testing.expectEqual(@as(usize, 0), h.a.view.strip.cursor);
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    try testing.expect(!h.a.new_no_project);
}

test "release folder menu: only seven folders scroll while search and actions stay visible" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var rows: std.json.Array = .init(alloc);
    for (0..20) |ix| {
        const text = try std.fmt.allocPrint(alloc,
            \\{{"id":"p{d}","deviceId":"local","path":"/synthetic/folder-{d}"}}
        , .{ ix, ix });
        try rows.append(try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}));
    }
    try h.a.spaces.replace(.{ .array = rows });
    h.press(.{ .key = 'd', .cmd = true });
    const list = h.t.ctx.rects.get(h.a.view.strip.search_scroll) orelse return error.MissingFolderScroller;
    try testing.expectApproxEqAbs(@as(f32, 224), list.h, 0.1);
    const actions = h.t.findText("Don't work in a project") orelse return error.MissingPersistentAction;
    try testing.expect(actions.y >= list.y + list.h);
    h.t.typeText("folder-17");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.view.strip.rows);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expectEqualStrings("p17", h.a.newChatSpace().?.id);
}
