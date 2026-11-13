//! Browser navigation authority follows the visible source, not the last focus.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const browser = @import("app_browser.zig");

fn chats(h: *Harness, source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, source, .{});
    defer parsed.deinit();
    try h.a.chats.replace(parsed.value);
}

test "deep browser first peer link promotes its owner and parks the focused canvas" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.composer.set("Synthetic canvas must survive browser promotion");
    browser.openLink(&h.a, "a", "https://example.invalid/peer");
    browser.settleFrame(&h.a);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expectEqualStrings("a", h.a.panels.tabs.items[0].browser.?.parent);
    h.a.focusPane(1);
    try testing.expectEqualStrings("Synthetic canvas must survive browser promotion", h.a.composer.text());
}

test "deep browser known archived and authoritative missing owners cannot navigate" {
    for ([_]bool{ false, true }) |missing| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        if (missing) {
            try chats(&h, "[]");
            h.a.chats_synced = true;
        } else try chats(&h, "[{\"id\":\"a\",\"archived\":true}]");
        browser.openLink(&h.a, "a", "https://example.invalid/revoked");
        try testing.expect(h.a.panels.pending_browser == null);
    }
}

test "deep browser missing startup rows do not revoke a cached visible source" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try chats(&h, "[]");
    browser.openLink(&h.a, "a", "https://example.invalid/startup");
    try testing.expect(h.a.panels.pending_browser != null);
    browser.settleFrame(&h.a);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
}

test "deep browser hidden routes and zoom-hidden peers reject old callbacks" {
    for ([_]bool{ false, true }) |zoomed| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        if (zoomed) {
            h.a.splitPane(.horizontal);
            h.a.tabs.layout().?.zoomed = true;
        } else h.a.view.settings_open = true;
        browser.openLink(&h.a, "a", "https://example.invalid/hidden");
        try testing.expect(h.a.panels.pending_browser == null);
    }
}

test "deep browser deletion retires only its owner without stealing the surviving focus" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    browser.openLink(&h.a, "a", "https://example.invalid/a");
    browser.settleFrame(&h.a);
    h.a.openChat("b", null);
    browser.openLink(&h.a, "b", "https://example.invalid/b");
    browser.settleFrame(&h.a);
    const surviving = h.a.panels.tabs.items[1].browser.?;
    const focus = h.t.ctx.focus;
    try chats(&h, "[{\"id\":\"b\",\"deviceId\":\"remote\",\"spaceId\":\"remote-project\"}]");
    h.a.chats_synced = true;
    browser.settleFrame(&h.a);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expect(h.a.panels.tabs.items[0].browser.? == surviving);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqual(focus, h.t.ctx.focus);
}

test "deep browser archival keeps the reference but revokes navigation" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    browser.openLink(&h.a, "a", "https://example.invalid/before");
    browser.settleFrame(&h.a);
    const kept = h.a.panels.tabs.items[0].browser.?;
    try chats(&h, "[{\"id\":\"a\",\"archived\":true}]");
    h.a.chats_synced = true;
    browser.settleFrame(&h.a);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expect(h.a.panels.tabs.items[0].browser.? == kept);
    kept.navigate("https://example.invalid/after");
    try testing.expectEqualStrings("https://example.invalid/before", kept.url);
}

test "deep browser queued navigation rechecks source liveness and project ownership" {
    for (0..3) |change| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        browser.openLink(&h.a, "a", "https://example.invalid/queued");
        try testing.expect(h.a.panels.pending_browser != null);
        switch (change) {
            0 => try chats(&h, "[{\"id\":\"a\",\"archived\":true}]"),
            1 => {
                try chats(&h, "[]");
                h.a.chats_synced = true;
            },
            else => try chats(&h, "[{\"id\":\"a\",\"spaceId\":\"replacement-project\",\"deviceId\":\"local\"}]"),
        }
        browser.settleFrame(&h.a);
        try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    }
}
