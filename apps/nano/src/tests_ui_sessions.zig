//! Synthetic workspace/history/project-footer regression coverage.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const palette = @import("view_palette.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        h.a.account.scope = .local;
        var spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"project-a","deviceId":"synthetic-device","path":"/work/synthetic-alpha","gitDetected":false},
            \\  {"id":"project-b","deviceId":"synthetic-device","path":"/work/synthetic-beta","gitDetected":false} ]
        , .{});
        defer spaces.deinit();
        try h.a.spaces.replace(spaces.value);
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"chat-a","deviceId":"synthetic-device","title":"Synthetic first conversation","spaceId":"project-a","archived":false,"lastMessagePreview":"A real synthetic preview"},
            \\  {"id":"chat-b","deviceId":"synthetic-device","title":"Synthetic second conversation","spaceId":"project-a","archived":false},
            \\  {"id":"chat-archived","deviceId":"synthetic-device","title":"Synthetic archived conversation","spaceId":"project-b","archived":true} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(0.3);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn press(h: *Harness, shortcut: ui.Shortcut) void {
        _ = h.t.shortcut(shortcut);
        h.t.settle(0.3);
    }
};

test "independent workspaces in the same project keep their panel tabs" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.openChat("chat-a", null);
    h.a.newWorkspaceSession();
    h.a.openChat("chat-b", null);
    h.a.splitPane(.horizontal);
    h.a.addChatTab(false); // A panel tab, not another workspace.
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("chat-a", h.a.tabs.items.items[0].?);
    const layout = h.a.tabs.layout().?;
    try testing.expectEqual(@as(usize, 2), layout.panes.items.len);
    try testing.expectEqual(@as(usize, 3), layout.groups[0].count() + layout.groups[1].count());
    try testing.expectEqualStrings("chat-b", layout.panes.items[0].?);
}

test "project header creates an independent session in that project" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.openChat("chat-a", null);
    h.t.settle(0.3);
    const group = h.t.findText("synthetic-alpha") orelse return error.NoProjectGroup;
    h.t.click(@import("view_sidebar.zig").widthOf(&h.a) - 26, group.y + group.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.a.selected == null);
    try testing.expectEqualStrings("project-a", h.a.space.?);
    try testing.expect(!h.a.new_no_project);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("chat-a", h.a.tabs.items.items[0].?);
}

test "chat history contains only conversations across project filters including archived" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.openChat("chat-a", null);
    h.a.setSpaceFilter("project-a");
    palette.toggle(&h.a, .chat_history);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Search chats across projects…"));
    try testing.expect(h.t.hasText("Chat history"));
    try testing.expect(h.t.hasText("All chats"));
    try testing.expect(!h.t.hasText("Navigate"));
    const entries = try palette.entries(&h.a, testing.allocator, "");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 3), entries.len);
    var archived = false;
    for (entries) |entry| {
        try testing.expect(entry == .chat);
        if (std.mem.eql(u8, entry.chat, "chat-archived")) archived = true;
    }
    try testing.expect(archived);
    palette.toggle(&h.a, .preserve_tabs);
    try testing.expect(h.a.view.palette.open);
    try testing.expectEqual(palette.Navigation.preserve_tabs, h.a.view.palette.navigation);
}

test "chat history Escape returns to the composer without changing its draft" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set("Synthetic draft survives history");
    palette.toggle(&h.a, .chat_history);
    h.t.settle(0.3);
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.a.view.palette.open);
    try testing.expect(h.t.hasText("Build something new"));
    try testing.expectEqualStrings("Synthetic draft survives history", h.a.composer.text());
}

test "draft footer shows real project selection and hides it in plain chat" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.new_no_project = false;
    h.t.settle(0.3);
    const anchor = h.a.view.space_anchor orelse return error.NoProjectChip;
    h.t.click(anchor.x + anchor.w / 2, anchor.y + anchor.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.a.view.strip.menu == .folder);
    try testing.expect(h.a.view.strip.footer_folder);
    try testing.expect(h.t.hasText("Search projects…"));
    try testing.expect(h.t.hasText("Don't work in a project"));
    h.press(.{ .key = ui.Shortcut.escape });
    h.a.new_chat_mode = true;
    h.a.view.space_anchor = null;
    h.t.settle(0.3);
    try testing.expect(h.a.view.space_anchor == null);
}
