//! Synthetic regressions for the current desktop workspace lane. No engine,
//! account data, builds, private journals or live sessions are involved.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const strip = @import("view_tab_strip.zig");
const chrome = @import("panel_chrome.zig");
const testing = std.testing;

pub const Harness = struct {
    a: App,
    t: ui.Tester,

    pub fn init(h: *Harness, dark: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.device_id = try testing.allocator.dupe(u8, "local");
        try replace(&h.a.devices,
            \\[{"id":"local","name":"Studio"},{"id":"remote","name":"Build box"}]
        );
        try replace(&h.a.spaces,
            \\[{"id":"local-project","deviceId":"local","path":"/synthetic/fieldnotes"},
            \\ {"id":"remote-project","deviceId":"remote","path":"/synthetic/remote-project"}]
        );
        try replace(&h.a.chats,
            \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
            \\ {"id":"b","deviceId":"remote","title":"Beta","spaceId":"remote-project","archived":false}]
        );
        h.a.openChat("a", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = dark });
        h.t.settle(1);
    }
    pub fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
    pub fn press(h: *Harness, key: ui.Shortcut) void {
        _ = h.t.shortcut(key);
        h.t.settle(1);
    }
    fn topText(h: *Harness, text: []const u8) ?ui.Rect {
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, text) and node.rect.y < chrome.header_height and node.rect.x >= h.a.view.sidebar_width) return node.rect,
            else => {},
        };
        return null;
    }
};
fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}

test "saved GPUI tabs reopen in order with their active chat" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.apply(
        \\{"openTabs":["b","missing","a"],"lastChatId":"a","syntheticKeep":17}
    );
    h.a.tabs.setCurrent(null);
    h.a.select(null, null);
    h.a.tabs_ready = false;
    h.a.restoreTabs();
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("b", h.a.tabs.items.items[0].?);
    try testing.expectEqualStrings("a", h.a.tabs.items.items[1].?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.active);
    try testing.expectEqualStrings("a", h.a.selected.?);
    // Publishing mirrors GPUI's keys without replacing unrelated settings.
    h.a.rememberTabs();
    try testing.expectEqual(@as(usize, 2), h.a.settings.open_tabs.items.len);
    try testing.expectEqualStrings("b", h.a.settings.open_tabs.items[0]);
    try testing.expectEqualStrings("a", h.a.settings.open_tabs.items[1]);
    try testing.expectEqualStrings("a", h.a.settings.text("lastChatId").?);
}

test "a legacy saved active chat reopens when openTabs has no rows" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.apply(
        \\{"lastChatId":"b"}
    );
    h.a.tabs.setCurrent(null);
    h.a.select(null, null);
    h.a.tabs_ready = false;
    h.a.restoreTabs();
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("b", h.a.tabs.current().?);
    try testing.expectEqualStrings("b", h.a.selected.?);
}

test "unified strip: one panel has top folder tabs and a 42px content boundary" {
    for ([_]bool{ true, false }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        const title = h.topText("Alpha") orelse return error.MissingTopTab;
        try testing.expect(title.y >= 5 and title.y + title.h <= 37);
        try testing.expectEqual(@as(f32, 42), h.a.view.chrome.y);
        try testing.expectEqual(@as(f32, 730), h.a.view.chrome.height);
        try testing.expect(!h.a.view.chrome.strip);
        const computer = h.topText(@import("strip_device.zig").localLabel()) orelse return error.MissingDeviceLabel;
        try testing.expect(computer.x > 1000);
        var surface = false;
        for (h.t.ctx.nodes.items) |node| {
            if (node.style.radius == 10 and @abs(node.rect.y - 42) < 0.1 and node.rect.x >= h.a.view.sidebar_width) surface = true;
        }
        try testing.expect(surface);
    }
}

test "unified strip: split slots own both titles without a second peer header" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    const alpha = h.topText("Alpha") orelse return error.MissingFirstSlot;
    const draft = h.topText("New tab") orelse return error.MissingSecondSlot;
    try testing.expect(draft.x > alpha.x);
    try testing.expect(h.a.view.chrome.strip);
    const expected = chrome.paneSpan(h.a.view.chrome.chat_width, 0.5, 2, true);
    try testing.expect(expected > 220);
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "Alpha") and node.rect.x >= h.a.view.sidebar_width and node.rect.y >= 42) return error.DuplicatePeerHeader,
        else => {},
    };
}

test "unified strip: Cmd T opens a new top-level tab and restores the split draft on close" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.composer.set("A parked synthetic prompt");
    h.press(.{ .key = 't', .cmd = true });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.showTab(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqualStrings("A parked synthetic prompt", h.a.composer.text());
    h.a.showTab(1);
    h.a.closeFocused();
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqualStrings("a", h.a.tabs.layout().?.panes.items[0].?);
    try testing.expectEqualStrings("A parked synthetic prompt", h.a.composer.text());
}

test "unified strip: a first split preserves other top-level tabs independently" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.openChat("b", null);
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.groups[0].count());
    h.a.openChat("a", null);
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
}

test "unified strip: sidebar new session parks an independent workspace without changing panel tabs" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.composer.set("Left panel draft");
    h.a.splitPane(.horizontal);
    h.a.pickDraftDevice("remote");
    h.a.composer.set("Right panel draft");
    const original = h.a.tabs.active;
    h.a.newWorkspaceSession();
    try testing.expectEqual(@as(usize, 3), h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    h.a.composer.set("Independent workspace draft");
    const independent = h.a.tabs.active;
    h.a.showTab(original);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.groups[0].count());
    try testing.expectEqualStrings("Right panel draft", h.a.composer.text());
    h.a.focusPane(0);
    try testing.expectEqualStrings("Left panel draft", h.a.composer.text());
    h.a.showTab(independent);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("Independent workspace draft", h.a.composer.text());
}

test "unified strip: expansion keeps all slots and slot shortcuts change the expanded panel" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expectEqual(@as(usize, 1), h.a.view.strip.expanded.?.chat);
    try testing.expect(h.topText("Alpha") != null and h.topText("New tab") != null);
    h.press(.{ .key = '1', .cmd = true, .alt = true });
    try testing.expectEqual(@as(usize, 0), h.a.view.strip.expanded.?.chat);
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expect(h.a.view.strip.expanded == null);
}

test "unified strip: parked draft metadata names its own folder and computer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.select(null, "remote-project");
    h.a.splitPane(.horizontal);
    h.a.select(null, "local-project");
    h.t.settle(1);
    try testing.expectEqualStrings("Build box", strip.deviceLabel(&h.a, strip.device(&h.a, .{ .chat = 0 })));
    try testing.expectEqualStrings("remote-project", strip.folder(&h.a, .{ .chat = 0 }).?.name);
    try testing.expectEqualStrings("fieldnotes", strip.folder(&h.a, .{ .chat = 1 }).?.name);
    strip.queue(&h.a, .{ .folder = .{ .panel = .{ .chat = 1 }, .index = null } });
    h.t.settle(1);
    try testing.expect(h.a.new_no_project);
    try testing.expectEqualStrings("No project", strip.folder(&h.a, .{ .chat = 1 }).?.name);
}

test "unified strip: hidden errors take precedence over streaming without stealing focus" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    h.a.addChatTab(false);
    h.a.openChat("b", null);
    try replace(&h.a.sessions,
        \\[{"chatId":"a","status":"errored"},{"chatId":"b","status":"working"}]
    );
    const k = @import("theme.zig").colors(true);
    try testing.expectEqualDeep(k.danger, strip.attention(&h.a, .{ .chat = 0 }, k).?);
    try testing.expectEqualStrings("b", h.a.selected.?);
    strip.nextAttention(&h.a);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "unified strip: panel menus work with keyboard and close without losing the split" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    strip.open(&h.a, .panel, .{ .chat = 1 }, .{ .x = 760, .y = 5, .w = 100, .h = 32 });
    h.t.settle(1);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(h.a.view.strip.menu == null);
    // New tab from the menu starts in the shared computer/folder sheet.
    try testing.expect(h.a.view.open_chooser.open);
    h.press(.{ .key = ui.Shortcut.enter });
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.groups[1].count());
}

test "closing the only tab moves on to a new chat" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.set(.archive_on_close_chosen, true);
    h.a.closeTabArchiving(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.tabs.current() == null);
    h.a.composer.set("Keep this draft on repeated close");
    h.a.closeByShortcut();
    h.t.settle(1);
    try testing.expectEqualStrings("Keep this draft on repeated close", h.a.composer.text());
    h.a.closeFocused();
    h.t.settle(1);
    try testing.expectEqualStrings("Keep this draft on repeated close", h.a.composer.text());
}

test "closing the tab you are on goes back to the one before it" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try replace(&h.a.chats,
        \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
        \\ {"id":"b","deviceId":"remote","title":"Beta","spaceId":"remote-project","archived":false},
        \\ {"id":"c","deviceId":"local","title":"Gamma","spaceId":"local-project","archived":false}]
    );
    h.a.newTab();
    h.a.openChat("b", null);
    h.a.newTab();
    h.a.openChat("c", null);
    // Visit c -> a -> b, then close b: should return to a, not neighbour c.
    h.a.showTab(2);
    h.a.showTab(0);
    h.a.showTab(1);
    h.a.closeTab(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
    // After a restart (clearShown), closing the active tab falls back to its neighbour.
    h.a.showTab(1);
    h.a.newTab();
    h.a.openChat("b", null);
    // Tabs are now [a, c, b] with b (index 2) active; switch to c (index 1) and clearShown.
    h.a.showTab(1);
    h.a.tabs.clearShown();
    h.a.closeTab(1);
    try testing.expectEqualStrings("b", h.a.selected.?);
}

test "strip slot close button closes a tab and then its panel" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    // Add a second tab in the right pane (pane 1).
    h.a.addChatTab(false);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.groups[1].count());
    const slot_title = h.topText("New tab") orelse return error.MissingRightSlot;
    h.t.moveTo(slot_title.x + 8, slot_title.y + 4);
    h.t.settle(1);
    // Click the slot's ✕ button on the right edge of the second slot.
    var close_rect: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.y < chrome.header_height and node.rect.x > slot_title.x and @abs(node.rect.w - 18) < 0.5 and @abs(node.rect.h - 18) < 0.5) {
            if (close_rect == null or node.rect.x > close_rect.?.x) close_rect = node.rect;
        }
    }
    const r = close_rect orelse return error.MissingSlotCloseButton;
    h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(1);
    // First click closes the active tab in pane 1, leaving 1 tab in pane 1.
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.groups[1].count());
    // Second click on the same slot's ✕ closes the last tab and removes pane 1.
    h.t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(1);
    h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "Cmd+[ and Cmd+] step single-pane panel tabs and retain loaded transcripts in one pass" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try replace(&h.a.chats,
        \\[{"id":"a","deviceId":"local","title":"Alpha","spaceId":"local-project","archived":false},
        \\ {"id":"c","deviceId":"local","title":"Gamma","spaceId":"local-project","archived":false}]
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic prompt"}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    const entries_ptr = h.a.transcript.entries.items.ptr;
    h.a.openChatInTab("c");
    h.t.settle(1);
    try testing.expectEqualStrings("c", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.groups[0].count());
    _ = h.t.shortcut(.{ .key = '[', .cmd = true });
    try testing.expectEqual(@as(u8, 1), h.t.ctx.stats.passes);
    try testing.expectEqual(@as(usize, 0), h.t.ctx.scroll_moved.count());
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(entries_ptr, h.a.transcript.entries.items.ptr);
    _ = h.t.shortcut(.{ .key = ']', .cmd = true });
    try testing.expectEqual(@as(u8, 1), h.t.ctx.stats.passes);
    try testing.expectEqual(@as(usize, 0), h.t.ctx.scroll_moved.count());
    try testing.expectEqualStrings("c", h.a.selected.?);
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    try testing.expectEqual(@as(u8, 1), h.t.ctx.stats.passes);
}

test "streaming turn with detail lines and mermaid diagram stays visible and updates prompt cache percent" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("b", "local-project");
    try replace(&h.a.sessions,
        \\[{"chatId":"b","status":"working","startedAt":1700000000000}]
    );
    const apply = struct {
        fn run(t: *@import("transcript.zig").Transcript, s: []const u8) !void {
            var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
            defer p.deinit();
            try t.apply(p.value);
        }
    }.run;
    try apply(&h.a.transcript,
        \\{"reset":[
        \\  {"id":"u1","role":"user","parts":[{"id":"p1","kind":"text","text":"hey there"}]},
        \\  {"id":"a1","role":"assistant","status":"completed","parts":[{"id":"p2","kind":"text","text":"Hey! What can I help you with today?"}]},
        \\  {"id":"u2","role":"user","parts":[{"id":"p3","kind":"text","text":"can you show it as a mermaid diagram"}]},
        \\  {"id":"a2","role":"assistant","status":"streaming","parts":[
        \\    {"id":"r1","kind":"reasoning","text":"Exploring the repository layout and runtime flow before drawing the diagram for the user."},
        \\    {"id":"tc1","kind":"tool_call","tool":"Bash","status":"running","input":"{\"description\":\"Inspect workspace crates and directories across the repository\"}"}
        \\  ]}
        \\],"contextUsage":{"tokens":10000,"window":1000000,"savings":{"handleBytes":0,"compactedTokens":0,"cacheReadTokens":6000}}}
    );
    h.t.settle(2);
    // Detail lines in working-trailer must wrap at pane width, keeping messages visible in the viewport.
    try testing.expect(h.t.hasText("can you show it as a mermaid diagram"));
    const prompt_rect = h.t.findText("can you show it as a mermaid diagram") orelse return error.MissingPrompt;
    try testing.expect(prompt_rect.y >= 0 and prompt_rect.y < 760);
    const cw = @import("context_window.zig");
    try testing.expectEqual(@as(?u64, 60), cw.promptCachePercent(
        h.a.transcript.tokens,
        h.a.transcript.savings,
        h.a.transcript.turn_cache_read_tokens,
        h.a.transcript.turn_input_tokens,
    ));

    // Stream a Mermaid diagram reply and an updated cacheReadTokens delta (14,400 new cached out of 16,000 input = 90%).
    try apply(&h.a.transcript,
        \\{"upsert":[
        \\  {"entry":{"id":"a2","role":"assistant","status":"completed","parts":[
        \\    {"id":"m1","kind":"text","text":"Here is the diagram:\n\n```mermaid\ngraph TD\n  ROOT[\"harness/ (repo root)\"] --> APPS[\"apps/\"]\n  APPS --> NANO[\"nano/ — nanoui desktop\"]\n```"}
        \\  ]}}
        \\],"contextUsage":{"tokens":16000,"window":1000000,"savings":{"handleBytes":0,"compactedTokens":0,"cacheReadTokens":20400}}}
    );
    h.t.settle(2);
    try testing.expect(h.t.hasText("apps/"));
    try testing.expectEqual(@as(?u64, 90), cw.promptCachePercent(
        h.a.transcript.tokens,
        h.a.transcript.savings,
        h.a.transcript.turn_cache_read_tokens,
        h.a.transcript.turn_input_tokens,
    ));
}
