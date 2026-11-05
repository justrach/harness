//! ⌘K's command palette and the sidebar's session search, driven
//! headlessly on made-up chats as a person would (nanoui's Tester): the
//! GPUI app's command_palette.rs and sidebar_search.rs tests, as far as
//! nano has their pieces.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const palette = @import("view_palette.zig");
const search = @import("view_sidebar_search.zig");
const S = ui.Shortcut;

const testing = std.testing;

const two =
    \\[{"id":"a","deviceId":"d","title":"Alpha","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z","createdAt":"2026-10-01T00:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Beta","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z","createdAt":"2026-10-01T00:00:00Z"}]
;

/// The GPUI tests' fixture: the current session, a match, an archived match.
const sidebar_chats =
    \\[{"id":"current","deviceId":"d","title":"Current session","archived":false,"spaceId":"project","createdAt":"2026-10-03T00:00:00Z"},
    \\ {"id":"active","deviceId":"d","title":"Sidebar polish","archived":false,"spaceId":"project","createdAt":"2026-10-02T00:00:00Z"},
    \\ {"id":"archived","deviceId":"d","title":"Sidebar experiments","archived":true,"spaceId":"project","createdAt":"2026-10-01T00:00:00Z"}]
;

const spaces =
    \\[{"id":"project","deviceId":"d","path":"/work/project","gitDetected":true,"createdAt":"2026-09-01T00:00:00Z"}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, chats: []const u8, open: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        var sp = try std.json.parseFromSlice(std.json.Value, testing.allocator, spaces, .{});
        defer sp.deinit();
        try h.a.spaces.replace(sp.value);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        @import("workspace.zig").sortChats(h.a.chats.items);
        h.a.openChat(open, null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn press(h: *Harness, s: S) void {
        _ = h.t.shortcut(s);
        h.t.settle(1);
    }

    fn typed(h: *Harness, s: []const u8) void {
        h.t.typeText(s);
        h.t.settle(1);
    }

    fn selected(h: *Harness) []const u8 {
        return h.a.selected orelse "";
    }

    /// The tabs' chats, in order ("" for a new chat).
    fn tabIs(h: *Harness, i: usize, want: []const u8) !void {
        try testing.expectEqualStrings(want, h.a.tabs.items.items[i] orelse "");
    }

    fn expectSearch(h: *Harness, want: []const []const u8) !void {
        const got = try search.ids(&h.a, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try testing.expectEqualStrings(w, g);
    }
};

const cmd_k: S = .{ .key = 'k', .cmd = true };

test "⌘K opens the palette with its actions and chats; typing narrows it; ↓ Return opens the chat in a new tab, the old one kept" {
    var h: Harness = undefined;
    try h.init(two, "a");
    defer h.deinit();
    h.press(cmd_k);
    try testing.expect(h.a.view.palette.open);
    for ([_][]const u8{ "Search commands and chats…", "New chat", "New project", "Open settings", "Switch to light theme", "Navigate", "Select", "Close" }) |s|
        try testing.expect(h.t.hasText(s));
    h.typed("a");
    // "a": New chat, New project ("Open settings" hasn't one), the theme, both chats.
    try testing.expect(!h.t.hasText("Open settings"));
    h.typed("lpha");
    try testing.expect(!h.t.hasText("New chat"));
    try testing.expect(!h.t.hasText("Switch to light theme"));
    // Return answers the query as typed: Alpha is the only result.
    h.press(.{ .key = S.enter });
    try testing.expect(!h.a.view.palette.open);
    try testing.expectEqualStrings("a", h.selected());
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    // Beta: a tab of its own after Alpha's.
    h.press(cmd_k);
    h.typed("beta");
    h.press(.{ .key = S.enter });
    try testing.expectEqualStrings("b", h.selected());
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try h.tabIs(0, "a");
    try h.tabIs(1, "b");
    // Alpha again: its tab is shown, no third one.
    h.press(cmd_k);
    h.typed("alpha");
    h.press(.{ .key = S.enter });
    try testing.expectEqualStrings("a", h.selected());
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
}

test "the palette's arrows go round; Escape, ⌘K and a press outside close it; no results says so" {
    var h: Harness = undefined;
    try h.init(two, "a");
    defer h.deinit();
    h.press(cmd_k);
    // Four actions, then the two chats.
    h.press(.{ .key = S.up });
    try testing.expectEqual(@as(usize, 5), h.a.view.palette.active);
    h.press(.{ .key = S.down });
    try testing.expectEqual(@as(usize, 0), h.a.view.palette.active);
    h.press(.{ .key = S.down });
    h.press(.{ .key = S.down });
    try testing.expectEqual(@as(usize, 2), h.a.view.palette.active);
    // Typing starts the highlight over.
    h.typed("e");
    try testing.expectEqual(@as(usize, 0), h.a.view.palette.active);
    h.press(.{ .key = S.escape });
    try testing.expect(!h.a.view.palette.open);
    h.press(cmd_k);
    // Opened again, empty.
    try testing.expectEqualStrings("", h.a.view.palette.query.text());
    h.press(cmd_k);
    try testing.expect(!h.a.view.palette.open);
    h.press(cmd_k);
    h.typed("deployment zebra");
    try testing.expect(h.t.hasText("No results"));
    try testing.expect(h.t.hasText("Try a pane, command, chat title, project, or device."));
    // Return with nothing to pick does nothing.
    h.press(.{ .key = S.enter });
    try testing.expect(h.a.view.palette.open);
    h.t.click(40, 700);
    h.t.settle(1);
    try testing.expect(!h.a.view.palette.open);
    try testing.expectEqualStrings("a", h.selected());
}

test "the theme action switches the appearance and stays open, naming the other one" {
    var h: Harness = undefined;
    try h.init(two, "a");
    defer h.deinit();
    h.press(cmd_k);
    h.typed("theme");
    h.press(.{ .key = S.enter });
    try testing.expect(h.a.view.palette.open);
    try testing.expectEqual(false, h.a.dark.?);
    try testing.expect(h.t.hasText("Switch to dark theme"));
    h.press(.{ .key = S.enter });
    try testing.expectEqual(true, h.a.dark.?);
}

test "the split's other panes lead the results; picking one moves focus there" {
    var h: Harness = undefined;
    try h.init(two, "a");
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    h.a.openChatInTab("b");
    h.t.settle(1);
    // b went to a tab of its own; back to a's split.
    h.a.showTab(0);
    h.t.settle(1);
    const s = h.a.tabs.layout().?;
    try testing.expectEqual(@as(usize, 1), s.focus);
    h.press(cmd_k);
    try testing.expect(h.t.hasText("Search open panes, commands and chats…"));
    try testing.expect(h.t.hasText("Go to pane"));
    const list = try palette.entries(&h.a, testing.allocator, "");
    defer testing.allocator.free(list);
    try testing.expect(list[0] == .pane);
    // Alpha is in the pane: it leaves the history.
    for (list) |e| if (e == .chat) try testing.expect(!std.mem.eql(u8, e.chat, "a"));
    h.press(.{ .key = S.enter });
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
    try testing.expectEqualStrings("a", h.selected());
}

test "/resume's palette replaces the current tab without switching or adding; ⌘K after it keeps the tabs" {
    var h: Harness = undefined;
    try h.init(two, "a");
    defer h.deinit();
    h.a.openChatInTab("b");
    h.a.showTab(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    for (0..2) |_| {
        palette.toggle(&h.a, .replace_current);
        h.t.settle(1);
        palette.activate(&h.a, .{ .chat = "b" });
        h.t.settle(1);
        try testing.expect(!h.a.view.palette.open);
        try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
        try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
        try testing.expectEqualStrings("b", h.selected());
    }
    // Closing a resume palette doesn't leak replacement into the next ⌘K.
    palette.toggle(&h.a, .replace_current);
    palette.close(&h.a);
    palette.toggle(&h.a, .preserve_tabs);
    palette.activate(&h.a, .{ .chat = "a" });
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.active);
    try h.tabIs(0, "b");
    try testing.expectEqualStrings("a", h.selected());
}

test "other tools' conversations come after the chats, five until something's typed, with Import first among the actions" {
    var h: Harness = undefined;
    try h.init(two, "a");
    defer h.deinit();
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(testing.allocator);
    try rows.appendSlice(testing.allocator, "[");
    for (0..7) |i| {
        if (i > 0) try rows.appendSlice(testing.allocator, ",");
        try rows.print(testing.allocator, "{{\"source\":\"codex\",\"id\":\"c{d}\",\"cwd\":\"/work/app/\",\"title\":\"add a retry {d}\",\"updatedAt\":1}}", .{ i, i });
    }
    try rows.appendSlice(testing.allocator, "]");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, rows.items, .{});
    defer parsed.deinit();
    try palette.setExternal(&h.a, parsed.value);
    const idle = try palette.entries(&h.a, testing.allocator, "");
    defer testing.allocator.free(idle);
    var external: usize = 0;
    for (idle) |e| if (e == .external) {
        external += 1;
    };
    try testing.expectEqual(@as(usize, 5), external);
    try testing.expect(idle[4] == .import_all);
    try testing.expect(idle[idle.len - 1] == .external);
    const typed = try palette.entries(&h.a, testing.allocator, "codex app");
    defer testing.allocator.free(typed);
    try testing.expectEqual(@as(usize, 7), typed.len);
    h.press(cmd_k);
    try testing.expect(h.t.hasText("Import 7 conversations from other tools"));
    try testing.expect(h.t.containsText("Codex · app ·"));
}

test "the sidebar search: the magnifier opens it focused; it finds names, the archived when asked; ↓ Return opens one in a tab of its own" {
    var h: Harness = undefined;
    try h.init(sidebar_chats, "current");
    defer h.deinit();
    try testing.expect(!h.t.hasText("Include archived sessions"));
    h.t.click(200, 96);
    h.t.settle(1);
    try testing.expect(h.a.view.search.open);
    try testing.expect(h.t.hasText("Search session names…"));
    try testing.expect(h.t.hasText("Include archived sessions"));
    // Not filtering yet: the lists stay.
    try testing.expect(h.t.hasText("Sessions"));
    h.typed("SIDEBAR");
    try h.expectSearch(&.{"active"});
    try testing.expect(h.t.hasText("1 result"));
    try testing.expect(!h.t.hasText("Sessions"));
    try h.t.clickText("Include archived sessions");
    h.t.settle(1);
    try testing.expect(h.a.view.search.include_archived);
    try h.expectSearch(&.{ "active", "archived" });
    try testing.expect(h.t.hasText("2 results"));
    try testing.expect(h.t.containsText("Archived · project"));
    h.press(.{ .key = S.down });
    try testing.expectEqual(@as(usize, 1), h.a.view.search.cursor.active);
    h.press(.{ .key = S.enter });
    try testing.expectEqualStrings("archived", h.selected());
    try testing.expect(h.a.findChat("archived").?.archived);
    // The session it was on keeps its tab.
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try h.tabIs(0, "current");
    // Nothing found says so; Escape clears, then closes.
    h.a.view.search.focus = true;
    h.a.view.search.query.set("no matches");
    h.t.settle(1);
    try testing.expect(h.t.hasText("No matching sessions"));
    try testing.expect(h.t.hasText("Try another name or project."));
    h.press(.{ .key = S.escape });
    try testing.expect(h.a.view.search.open);
    try testing.expect(!search.filtering(&h.a));
    try testing.expect(!h.a.view.search.include_archived);
    try testing.expect(!h.t.hasText("No matching sessions"));
    h.press(.{ .key = S.escape });
    try testing.expect(!h.a.view.search.open);
    try testing.expect(!h.t.hasText("Include archived sessions"));
}

test "the sidebar search: whitespace is cleared before closing; the arrows go round; nothing found tolerates them" {
    var h: Harness = undefined;
    try h.init(sidebar_chats, "current");
    defer h.deinit();
    h.t.click(200, 96);
    h.t.settle(1);
    h.typed("   ");
    h.press(.{ .key = S.escape });
    try testing.expect(h.a.view.search.open);
    try testing.expectEqualStrings("", h.a.view.search.query.text());
    h.typed("sidebar");
    search.toggleArchived(null, &h.a);
    h.t.settle(1);
    h.press(.{ .key = S.up });
    try testing.expectEqual(@as(usize, 1), h.a.view.search.cursor.active);
    h.press(.{ .key = S.down });
    try testing.expectEqual(@as(usize, 0), h.a.view.search.cursor.active);
    h.press(.{ .key = S.down });
    // Typing starts a fresh choice.
    h.a.view.search.query.set("polish");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.view.search.cursor.active);
    h.a.view.search.query.set("not present");
    h.t.settle(1);
    h.press(.{ .key = S.up });
    h.press(.{ .key = S.down });
    h.press(.{ .key = S.enter });
    try testing.expectEqual(@as(usize, 0), h.a.view.search.cursor.active);
    try testing.expectEqualStrings("current", h.selected());
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
}

test "the sidebar search: a click picks the result under the keys too; another project starts over; ⌘B closes it" {
    var h: Harness = undefined;
    try h.init(sidebar_chats, "current");
    defer h.deinit();
    h.t.click(200, 96);
    h.t.settle(1);
    h.typed("sidebar");
    search.toggleArchived(null, &h.a);
    h.t.settle(1);
    try h.t.clickText("Sidebar experiments");
    h.t.settle(1);
    try testing.expectEqualStrings("archived", h.selected());
    try testing.expectEqual(@as(usize, 1), h.a.view.search.cursor.active);
    try testing.expect(h.a.findChat("archived").?.archived);
    // The project filter changed: a fresh result scope.
    h.a.setSpaceFilter("project");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.view.search.cursor.active);
    h.a.setSpaceFilter("elsewhere");
    h.t.settle(1);
    try h.expectSearch(&.{});
    h.press(.{ .key = 'b', .cmd = true });
    try testing.expect(!h.a.view.sidebar_open);
    try testing.expect(!h.a.view.search.open);
}

test "the sidebar search and the palette take each other's place" {
    var h: Harness = undefined;
    try h.init(sidebar_chats, "current");
    defer h.deinit();
    h.t.click(200, 96);
    h.t.settle(1);
    h.press(cmd_k);
    try testing.expect(h.a.view.palette.open);
    try testing.expect(!h.a.view.search.open);
    search.toggle(&h.a);
    h.t.settle(1);
    try testing.expect(h.a.view.search.open);
    try testing.expect(!h.a.view.palette.open);
}

test "/resume sent from the composer opens the palette that replaces the current tab" {
    var h: Harness = undefined;
    try h.init(two, "a");
    defer h.deinit();
    h.a.view.focus_composer = true;
    h.t.settle(1);
    h.typed("/resume");
    h.t.key(.enter);
    h.t.settle(1);
    try testing.expect(h.a.view.palette.open);
    try testing.expectEqual(palette.Navigation.replace_current, h.a.view.palette.navigation);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.typed("beta");
    h.press(.{ .key = S.enter });
    try testing.expectEqualStrings("b", h.selected());
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
}
