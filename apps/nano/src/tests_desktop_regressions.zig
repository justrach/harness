//! Synthetic regressions for desktop issues #788–790; no live data or clipboard.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");
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
        h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-local");
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"chat-a","deviceId":"synthetic-local","title":"Synthetic first conversation","archived":false},
            \\  {"id":"chat-b","deviceId":"synthetic-remote","title":"Synthetic second conversation","archived":false} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("chat-a", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(0.3);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
};

fn fileUrl(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "synthetic image.png", .data = @embedFile("icons/close.png") });
    const relative = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, gpa);
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "file://{s}/synthetic%20image.png", .{base});
}

test "desktop issues file drop attaches an encoded image once without sending" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp, testing.allocator);
    defer testing.allocator.free(url);
    h.a.composer.set("Keep the synthetic prompt");
    try testing.expect(h.t.ctx.acceptsDropAt(.{ .x = 800, .y = 600 }));
    h.t.drop(800, 600, &.{url}, "");
    h.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("synthetic image.png", item.name);
    try testing.expectEqualStrings("chat-a", item.owner);
    try testing.expectEqualStrings("Keep the synthetic prompt", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    h.t.frame();
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
}

test "desktop issues file drop focuses the inactive pane and keeps its remote owner" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp, testing.allocator);
    defer testing.allocator.free(url);
    h.a.splitPane(.horizontal);
    h.a.openChatInTab("chat-b");
    h.a.focusPane(0);
    h.t.settle(1);
    h.t.drop(1000, 600, &.{url}, "");
    h.t.settle(0.3);
    try testing.expectEqualStrings("chat-b", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("chat-b", item.owner);
    try testing.expectEqualStrings("synthetic-remote", item.target.?);
    h.a.focusPane(0);
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
}

test "desktop issues file drop works on a fresh draft and reports rejected items" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp, testing.allocator);
    defer testing.allocator.free(url);
    h.a.newWorkspaceSession();
    h.t.settle(0.3);
    h.t.drop(800, 600, &.{ "https://example.invalid/not-a-file", "file:///missing-synthetic-file", url }, "");
    h.t.settle(0.3);
    try testing.expect(h.a.selected == null);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    try testing.expect(h.a.notice_len > 0);
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
}

test "desktop issues modal settings and sidebar are not attachment destinations" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expect(!h.t.ctx.acceptsDropAt(.{ .x = 50, .y = 300 }));
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .appearance;
    h.t.settle(0.3);
    try testing.expect(!h.t.ctx.acceptsDropAt(.{ .x = 800, .y = 600 }));
    h.t.drop(800, 600, &.{"file:///missing-synthetic-file"}, "");
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
}

test "desktop issues All sessions and Task view have no remaining controls" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var helps = h.t.ctx.helps.valueIterator();
    while (helps.next()) |help| try testing.expect(!std.mem.eql(u8, help.*, "All sessions"));
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .appearance;
    h.t.settle(0.3);
    try testing.expect(!h.t.hasText("Task view"));
    try testing.expect(!h.t.hasText("All sessions"));
}

test "desktop issues failed tool chrome has no pill or patterned wash" {
    const Chrome = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const row = ui.div(c).row().w(300).h(32);
            defer row.end();
            const chrome = @import("view_tool_rows.zig");
            const k = @import("theme.zig").colors(true);
            chrome.wash(c, k, .{ .failed = "failed" }, 300, 32, 1);
            chrome.trail(c, k, .{ .failed = "failed" }, 1);
        }
    };
    var chrome: Chrome = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&chrome, Chrome.view), .{});
    defer t.deinit();
    try testing.expect(!t.hasText("failed"));
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .image => return error.UnexpectedFailureDecoration,
        else => {},
    };
    try testing.expect(!(@as(@import("tool_rows.zig").Result, .{ .failed = "failed" })).washed());
}

test "desktop issues legacy Task view preferences cannot change update placement" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nano-ui-settings.json", .data = "{\"sidebarTaskView\":true}" });
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(base);
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.settings.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HARNESS_DATA_DIR", base);
    h.a.settings = @import("settings.zig").Store.open(testing.allocator, testing.io, &env);
    try testing.expect(!@hasField(@import("settings.zig").Prefs, "sidebar_task_view"));
    try testing.expect(!@hasField(@import("view_sidebar_menus.zig").State, "overview"));
    try testing.expect(@import("view_updates.zig").sidebarFits(&h.a));
    h.a.view.sidebar_open = false;
    try testing.expect(!@import("view_updates.zig").sidebarFits(&h.a));
}

test "desktop issues stale file drops cannot follow a changed chat destination" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp, testing.allocator);
    defer testing.allocator.free(url);
    const target_id = h.t.ctx.drop_targets.items[0];
    for (h.t.ctx.nodes.items, 0..) |node, index| if (node.id == target_id) {
        h.t.ctx.input.drop = .{ .point = .{ .x = 800, .y = 600 }, .urls = &.{url} };
        @import("view_attachment_drop.zig").target(&h.t.ctx, &h.a, @intCast(index), null);
        break;
    };
    try testing.expect(h.a.file_drop.pending != null);
    // Change destinations before the queued drop's pre-tree delivery.
    h.a.openChat("chat-b", null);
    @import("view_attachment_drop.zig").prepare(&h.a);
    try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
    try testing.expect(h.a.notice_len > 0);
}

test "desktop issues composer multiline text field never paints a phantom vertical scrollbar" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set("Line one\nLine two\nLine three\nLine four");
    h.a.view.focus_composer = true;
    h.t.settle(0.2);
    const comp_id = h.a.view.composer_id;
    try testing.expect(comp_id != 0);
    try testing.expect(!h.t.ctx.scrollbars.contains(comp_id));
    for (h.t.ctx.nodes.items) |n| if (n.id == comp_id) {
        try testing.expect(!n.style.scroll_bar);
    };
}

test "desktop issues rendered transcript text is selectable and Cmd+C copies it while scope change clears it (#717, #745)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var text_buf: std.ArrayList(u8) = .empty;
    try text_buf.appendSlice(h.a.gpa, "Synthetic selectable reply");
    var parts_list: std.ArrayList(@import("transcript.zig").Part) = .empty;
    try parts_list.append(h.a.gpa, .{
        .id = try h.a.gpa.dupe(u8, "p-1"),
        .kind = .text,
        .text = text_buf,
    });
    try h.a.transcript.entries.append(h.a.gpa, .{
        .id = try h.a.gpa.dupe(u8, "m-1"),
        .role = .assistant,
        .status = .complete,
        .parts = parts_list,
    });
    h.t.settle(0.3);
    var leaf_id: u64 = 0;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "Synthetic selectable reply")) {
            leaf_id = n.id;
            break;
        },
        else => {},
    };
    try testing.expect(leaf_id != 0);
    h.t.ctx.selection.anchor = .{ .id = leaf_id, .at = 0 };
    h.t.ctx.selection.focus = .{ .id = leaf_id, .at = 9 };
    h.t.ctx.selection.moved = true;
    h.t.frame();
    try testing.expectEqualStrings("Synthetic", h.t.ctx.selection.text.items);

    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings("Synthetic", h.t.clipboard.items);

    // Switching chats invalidates the selection scope (#745).
    h.a.openChat("chat-b", null);
    h.t.settle(0.2);
    try testing.expect(h.t.ctx.selection.anchor == null);
    try testing.expectEqual(@as(usize, 0), h.t.ctx.selection.text.items.len);
}

test "desktop issues inline-code URLs and balanced-paren bare URLs linkify (#348)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const md = @import("markdown.zig");
    const pal: md.Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };
    const blocks = md.parse(
        arena.allocator(),
        "Open `https://localhost:3000/app` or https://en.wikipedia.org/wiki/Rust_(programming_language).",
        pal,
    );
    try testing.expectEqual(@as(usize, 1), blocks.len);
    const links = blocks[0].paragraph.links;
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqualStrings("https://localhost:3000/app", links[0].url);
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Rust_(programming_language)", links[1].url);
}

test "desktop issues currency-safe math delimiters and native equation formatting (#795)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const md = @import("markdown.zig");
    const pal: md.Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };

    const prose = md.parse(arena.allocator(), "Plans cost $5 and $10 per seat, or `$a + b$` in code.", pal);
    try testing.expectEqualStrings("Plans cost $5 and $10 per seat, or $a + b$ in code.", prose[0].paragraph.text);

    const inline_math = md.parse(arena.allocator(), "Energy is $E = mc^2$ and $\\frac{a+b}{2} \\le \\sqrt{\\alpha}$.", pal);
    try testing.expectEqualStrings("Energy is E = mc² and (a+b)/2 ≤ √α.", inline_math[0].paragraph.text);

    const display_math = md.parse(arena.allocator(), "$$\n\\int_0^\\infty x^2 dx\n$$", pal);
    try testing.expectEqual(@as(usize, 1), display_math.len);
    try testing.expect(display_math[0] == .math);
    try testing.expectEqualStrings("∫₀^∞ x² dx", display_math[0].math.text);
}

test "desktop issues startup restoreTabs fences dirty boot draft and skips archived chats (#797)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // Reset to boot-like state with an archived chat and a live chat in open_tabs.
    h.a.tabs.close(0);
    h.a.select(null, null);
    h.a.tabs_ready = false;
    var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"chat-archived","deviceId":"synthetic-local","title":"Archived chat","archived":true},
        \\  {"id":"chat-b","deviceId":"synthetic-remote","title":"Live chat","archived":false} ]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.settings.apply("{\"openTabs\":[\"chat-archived\",\"chat-b\"]}");

    // 1. Typing on the boot canvas before restoreTabs arrives fences restoration.
    h.a.composer.set("Draft typed before WatchChats arrived");
    h.a.restoreTabs();
    try testing.expect(h.a.tabs_ready);
    try testing.expect(h.a.selected == null);
    try testing.expectEqualStrings("Draft typed before WatchChats arrived", h.a.composer.text());

    // 2. Clean boot canvas restores only non-archived chats.
    h.a.composer.clear();
    h.a.tabs_ready = false;
    h.a.restoreTabs();
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("chat-b", h.a.selected.?);
}

test "desktop issues project picker, model picker, reopenClosedTab shortcuts and sidebar tooltips (#792, #793, #794)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // #794: Top search trigger and bottom new-workspace button have distinct tooltips.
    const more = h.a.view.more_anchor orelse return error.MissingMoreButton;
    h.t.moveTo(more.x - 19, more.y + more.h / 2);
    h.t.advance(0.4);
    try testing.expectEqualStrings("Search sessions", h.t.tooltipText() orelse return error.MissingSearchTooltip);
    h.t.moveTo(600, 400);
    h.t.advance(0.1);

    const sidebar_w = @import("view_sidebar.zig").widthOf(&h.a);
    var new_ws_rect: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 26 and r.h == 26 and r.y >= 736 and r.x < sidebar_w) new_ws_rect = r;
    }
    const create_btn = new_ws_rect orelse return error.MissingCreateButton;
    h.t.moveTo(create_btn.x + 13, create_btn.y + 13);
    h.t.advance(0.4);
    try testing.expectEqualStrings("New workspace", h.t.tooltipText() orelse return error.MissingCreateTooltip);
    h.t.moveTo(600, 400);
    h.t.advance(0.1);

    // #792: Cmd+Shift+P toggles the project picker open and closed.
    _ = h.t.shortcut(.{ .key = 'p', .cmd = true, .shift = true });
    h.t.settle(0.2);
    try testing.expectEqual(@import("view_tab_strip.zig").Menu.folder, h.a.view.strip.menu.?);
    _ = h.t.shortcut(.{ .key = 'p', .cmd = true, .shift = true });
    h.t.settle(0.2);
    try testing.expect(h.a.view.strip.menu == null);

    // #793: Cmd+/ toggles the model picker open and closed; Cmd+Shift+T reopens a closed tab.
    _ = h.t.shortcut(.{ .key = '/', .cmd = true });
    h.t.settle(0.2);
    try testing.expect(h.a.picker != .none);
    _ = h.t.shortcut(.{ .key = '/', .cmd = true });
    h.t.settle(0.2);
    try testing.expect(h.a.picker == .none);

    h.a.openChatInTab("chat-b");
    h.t.settle(0.2);
    try testing.expectEqualStrings("chat-b", h.a.selected.?);
    h.a.closeArchiving(false);
    h.t.settle(0.2);
    try testing.expect(!std.mem.eql(u8, h.a.selected orelse "", "chat-b"));
    _ = h.t.shortcut(.{ .key = 't', .cmd = true, .shift = true });
    h.t.settle(0.2);
    try testing.expectEqualStrings("chat-b", h.a.selected.?);
}
