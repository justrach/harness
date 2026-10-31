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
    try testing.expect(composer.x >= 256 and composer.x + composer.w < 729);
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
