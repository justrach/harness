//! Settings › Archived sessions' Delete all, driven headlessly on made-up
//! chats against a scene engine: the GPUI app's
//! `delete_all_deletes_the_confirmed_archived_chats_and_reports_failures`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;

const testing = std.testing;

const chats =
    \\[{"id":"live","deviceId":"d","title":"Live one","archived":false,"cwd":"/work/app","createdAt":"2026-10-05T00:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Bee","archived":true,"cwd":"/work/app","branch":"main","createdAt":"2026-10-04T00:00:00Z"},
    \\ {"id":"c","deviceId":"d","title":"Sea","archived":true,"createdAt":"2026-10-03T00:00:00Z"},
    \\ {"id":"restored","deviceId":"d","title":"Restored","archived":true,"createdAt":"2026-10-02T00:00:00Z"},
    \\ {"id":"late","deviceId":"d","title":"Late","archived":false,"createdAt":"2026-10-01T00:00:00Z"}]
;

/// The first delete is refused, the rest go through.
const replies =
    \\{"Mutate": {"$seq": [{"$err": "rejected"}, {"ok": true}]}}
;

fn chat(a: *App, id: []const u8) *@import("workspace.zig").Chat {
    for (a.chats.items) |*ch| if (std.mem.eql(u8, ch.id, id)) return ch;
    unreachable;
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

/// The chats each `deleteChat` sent was for, in order.
fn deleted(a: *App, out: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    for (a.engine.sent.items) |frame| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{});
        const params = v.object.get("params") orelse continue;
        if (params != .object) continue;
        const op = params.object.get("op") orelse continue;
        if (op != .string or !std.mem.eql(u8, op.string, "deleteChat")) continue;
        try out.append(arena, params.object.get("chatId").?.string);
    }
}

test "Settings › Archived: Delete all deletes the chats confirmed and still archived, and says what failed" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = true;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
    defer parsed.deinit();
    try a.chats.replace(parsed.value);
    a.engine.state = .connected;
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, replies, .{});
    a.view.settings_open = true;
    a.settings.section = .archived;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(1);

    // Each row: device unknown, so just "project · branch".
    try testing.expect(t.hasText("app · main"));
    // Escape closes the dialog, deleting nothing.
    try t.clickText("Delete all");
    t.settle(1);
    try testing.expect(t.hasText("Delete all archived sessions?"));
    try testing.expect(t.hasText("3 archived sessions will be permanently deleted. This can\u{2019}t be undone."));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try testing.expect(!t.hasText("Delete all archived sessions?"));
    try testing.expect(a.view.archived.confirm == null);

    try t.clickText("Delete all");
    t.settle(1);
    // Archived while the dialog is open: not what was confirmed.
    chat(&a, "late").archived = true;
    try clickLast(&t, "Delete all");
    // Unarchived mid-run (on another device, say): spared.
    chat(&a, "restored").archived = false;
    for (0..6) |_| t.frame();
    t.settle(1);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ids: std.ArrayList([]const u8) = .empty;
    try deleted(&a, &ids, arena.allocator());
    try testing.expectEqual(@as(usize, 2), ids.items.len);
    try testing.expectEqualStrings("b", ids.items[0]);
    try testing.expectEqualStrings("c", ids.items[1]);
    try testing.expect(!a.view.archived.deleting);
    try testing.expect(t.hasText("Couldn\u{2019}t delete 1 archived session. Try again."));
    // A click on the strip clears it.
    try t.clickText("Couldn\u{2019}t delete 1 archived session. Try again.");
    t.settle(1);
    try testing.expect(!t.hasText("Couldn\u{2019}t delete 1 archived session. Try again."));
}

fn replaceFixture(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}

fn screenshot(t: *ui.Tester, name: []const u8) !void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
    try t.screenshot(path);
}

test "archived sidebar navigation preserves the current workspace on open and close" {
    for ([_]bool{ false, true }) |split| {
        var h: @import("tests_ui_tab_strip.zig").Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try replaceFixture(&h.a.chats,
            \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
            \\ {"id":"c","deviceId":"local","title":"Archived example","spaceId":"local-project","archived":true}]
        );
        if (split) {
            h.a.splitPane(.horizontal);
            h.a.composer.set("Keep this synthetic draft");
        }
        h.a.settings.set(.sidebar_show_archived, true);
        h.a.settings.set(.archive_on_close_chosen, true);
        h.a.view.archived_open = true;
        h.t.settle(1);
        try h.t.clickText("Archived example");
        h.t.settle(1);
        if (!split) try screenshot(&h.t, "archived-open");
        try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
        try testing.expectEqualStrings("c", h.a.selected.?);
        try testing.expect(h.a.tabs.layout() == null);
        try testing.expectEqual(@as(usize, 0), h.a.tabs.find("a").?.tab);
        h.a.closeByShortcut();
        h.t.settle(1);
        try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
        try testing.expect(h.a.findChat("c").?.archived);
        if (split) {
            try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
            try testing.expectEqualStrings("Keep this synthetic draft", h.a.composer.text());
        } else try testing.expectEqualStrings("a", h.a.selected.?);
    }
}

test "archived sidebar close never warns that an already archived chat was not archived" {
    var h: @import("tests_ui_tab_strip.zig").Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try replaceFixture(&h.a.chats,
        \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":true}]
    );
    try replaceFixture(&h.a.sessions,
        \\[{"chatId":"a","status":"working"}]
    );
    h.a.settings.set(.archive_on_close_chosen, true);
    h.a.settings.set(.archive_sessions_on_close, true);
    h.a.closeByShortcut();
    h.t.settle(1);
    try screenshot(&h.t, "archived-close");
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.findChat("a").?.archived);
    try testing.expectEqual(@as(usize, 0), h.a.view.sidebar_notice_len);
}
