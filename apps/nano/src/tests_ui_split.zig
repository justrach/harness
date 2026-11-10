//! Split panes with real transcript rows, not just clickable blank space.
//! All data is synthetic; no engine or account is opened.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const testing = std.testing;

const frame =
    \\{"reset":[
    \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic question"}]},
    \\ {"id":"a","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic reply in the other pane."}]}
    \\]}
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"a","deviceId":"d","title":"Synthetic chat","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("a", null);
        try load(&h.a.transcript);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }

    fn load(t: *@import("transcript.zig").Transcript) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try t.apply(parsed.value);
    }
};

test "splitting and focusing keep the loaded transcript without another engine replay" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const entries = h.a.transcript.entries.items.ptr;
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    const p = h.a.peer("a").?;
    try testing.expectEqual(@as(usize, 2), p.transcript.entries.items.len);
    try testing.expectEqual(entries, p.transcript.entries.items.ptr);
    try testing.expect(p.transcript.complete);
    const reply = h.t.findText("Synthetic reply in the other pane.") orelse return error.ReplyMissing;
    try testing.expect(reply.y > 40 and reply.y + reply.h < 780);
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expectEqual(entries, h.a.transcript.entries.items.ptr);
    try testing.expectEqual(@as(usize, 2), h.a.transcript.entries.items.len);
    try testing.expect(h.a.transcript.complete);
    const composer = h.a.view.composer_anchor orelse return error.ComposerMissing;
    const chrome = @import("panel_chrome.zig");
    const first = chrome.paneSpan(h.a.view.chrome.chat_width, 0.5, 2, true);
    try testing.expect(composer.x >= h.a.view.chrome.x + 1 and composer.x + composer.w < h.a.view.chrome.x + first);
    try testing.expect(composer.y > 40 and composer.y + composer.h < 780);
    _ = h.t.shortcut(.{ .key = ']', .cmd = true });
    h.t.settle(1);
    try testing.expectEqual(entries, h.a.peer("a").?.transcript.entries.items.ptr);
}

test "clicking a peer message focuses its pane and accepts typing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    // Supply the peer's asynchronous reply explicitly: this test isolates
    // hit routing even on a build that still discards the outgoing rows.
    if (h.a.peer("a").?.transcript.entries.items.len == 0) try Harness.load(&h.a.peer("a").?.transcript);
    h.t.settle(1);
    try h.t.clickText("Synthetic reply in the other pane.");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.t.typeText("Synthetic draft");
    h.t.settle(1);
    try testing.expectEqualStrings("Synthetic draft", h.a.composer.text());
}

test "a live transcript subscription keeps delivering through promotion and demotion" {
    // A subscription can have started in either outlet. Focus must move
    // its data and route subsequent deltas without cancel/re-subscribe.
    for ([_]bool{ false, true }) |started_as_peer| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        if (!started_as_peer) a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
        a.engine.state = .connected;
        a.openChat("a", null);
        try Harness.load(&a.transcript);
        a.splitPane(.horizontal);
        if (started_as_peer) a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
        a.syncPeers();
        const id = a.peer("a").?.watch orelse return error.SubscriptionMissing;
        var len = "Synthetic reply in the other pane.".len;
        for ([_][]const u8{ " More.", " Again.", " Last." }, 0..) |text, phase| {
            if (phase == 1) a.focusPane(0);
            if (phase == 2) a.focusPane(1);
            len += text.len;
            const update = try std.json.Stringify.valueAlloc(testing.allocator, .{
                .id = id,
                .item = .{ .append = &.{.{ .entry = "a", .part = "p", .text = text, .len = len }}, .count = 2 },
            }, .{});
            defer testing.allocator.free(update);
            try a.engine.mux.dispatch(update);
            const t = if (phase == 1) &a.transcript else &a.peer("a").?.transcript;
            try testing.expectEqual(len, t.entries.items[1].parts.items[0].text.items.len);
            try testing.expect(t.complete);
        }
        var subscriptions: usize = 0;
        for (a.engine.sent.items) |request| {
            if (std.mem.indexOf(u8, request, "WatchDocMessages") != null) subscriptions += 1;
        }
        try testing.expectEqual(@as(usize, 1), subscriptions);
    }
}

test "a link in a split is not squeezed to an equal share" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1500, 780);
    h.a.splitPane(.horizontal);
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.tabs.layout().?.panes.items.len);
    @import("app_browser.zig").openLink(&h.a, "a", "http://localhost:31997/split");
    h.t.settle(1);
    const chrome = @import("panel_chrome.zig");
    const each_chat = chrome.paneSpan(h.a.view.chrome.chat_width, 1.0 / 3.0, 3, true);
    try testing.expect(h.a.view.chrome.host_width > each_chat);
    try testing.expectApproxEqAbs(@as(f32, 520), h.a.view.chrome.host_width, 0.5);
}

test "closing a split page leaves no empty panel to close again" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    h.t.settle(1);
    const before_chat_width = h.a.view.chrome.chat_width;
    @import("app_browser.zig").openLink(&h.a, "a", "http://localhost:31997/split");
    h.t.settle(1);
    try testing.expect(h.a.panels.host_open);
    @import("app_panels.zig").closeTab(&h.a, 0);
    h.t.settle(1);
    try testing.expect(!h.a.panels.host_open);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expectEqual(before_chat_width, h.a.view.chrome.chat_width);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
}

fn applyFrame(t: *@import("transcript.zig").Transcript, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
}

fn textTop(h: *Harness, text: []const u8) !f32 {
    return (h.t.findText(text) orelse {
        std.debug.print("missing text: {s}\n", .{text});
        return error.TextMissing;
    }).y;
}

test "a message sent while the turn works sits where it arrived, with later work under it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try applyFrame(&h.a.transcript,
        \\{"reset":[
        \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic question"}]},
        \\ {"id":"a","role":"assistant","status":"streaming","parts":[{"id":"p0","kind":"text","text":"Synthetic work before the message."}]}
        \\]}
    );
    h.t.settle(1);
    // The engine writes the message at the document's end at once...
    try applyFrame(&h.a.transcript,
        \\{"upsert":[{"after":"a","entry":{"id":"s","role":"user","status":"complete","parts":[{"id":"t0","kind":"text","text":"Synthetic steer"}]}}],"count":3}
    );
    h.t.settle(1);
    // ...and keeps streaming the running reply into the entry before it.
    try applyFrame(&h.a.transcript,
        \\{"upsert":[{"after":"u","entry":{"id":"a","role":"assistant","status":"streaming","parts":[
        \\ {"id":"p0","kind":"text","text":"Synthetic work before the message."},
        \\ {"id":"p1","kind":"text","text":"Synthetic work after the message."}]}}],"count":3}
    );
    h.t.settle(1);
    {
        const before = try textTop(&h, "Synthetic work before the message.");
        const message = try textTop(&h, "Synthetic steer");
        const after = try textTop(&h, "Synthetic work after the message.");
        try testing.expect(before < message);
        try testing.expect(message < after);
        h.snap("steer-mid-turn");
    }
    // The agent takes the message: the reply ends and the next one starts
    // after it. Each piece keeps its place; a split pane draws the same.
    try applyFrame(&h.a.transcript,
        \\{"upsert":[
        \\ {"after":"u","entry":{"id":"a","role":"assistant","status":"complete","durationMs":4000,"parts":[
        \\  {"id":"p0","kind":"text","text":"Synthetic work before the message."},
        \\  {"id":"p1","kind":"text","text":"Synthetic work after the message."}]}},
        \\ {"after":"s","entry":{"id":"b","role":"assistant","status":"streaming","parts":[{"id":"p0","kind":"text","text":"Synthetic reply to the steer."}]}}
        \\],"count":4}
    );
    for ([_]bool{ false, true }) |split| {
        if (split) h.a.splitPane(.horizontal);
        h.t.settle(1);
        const before = try textTop(&h, "Synthetic work before the message.");
        const message = try textTop(&h, "Synthetic steer");
        const after = try textTop(&h, "Synthetic work after the message.");
        const reply = try textTop(&h, "Synthetic reply to the steer.");
        try testing.expect(before < message);
        try testing.expect(message < after);
        try testing.expect(after < reply);
        if (!split) h.snap("steer-taken");
    }
}
