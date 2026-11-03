//! Live document streams recover like GPUI's watches, without an engine or
//! account. A scene supplies only synthetic RPC replies.
const std = @import("std");
const App = @import("app.zig").App;
const testing = std.testing;

const snapshot =
    \\{"reset":[{"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic prompt"}]},
    \\{"id":"a","role":"assistant","status":"streaming","parts":[{"id":"p","kind":"text","text":"First live chunk"}]}]}
;

fn peerApp(a: *App) !void {
    a.* = .init(testing.allocator, testing.io, 1);
    a.openChat("chat", null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, snapshot, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
    a.splitPane(.horizontal);
    a.syncPeers();
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"WatchDocMessages":{"$items":[]}}
    , .{});
    a.engine.state = .connected;
    a.syncPeers();
}

fn docCalls(a: *const App) usize {
    var count: usize = 0;
    for (a.engine.sent.items) |request| {
        if (std.mem.indexOf(u8, request, "\"method\":\"WatchDocMessages\"") != null) count += 1;
    }
    return count;
}

test "an ended peer document stream retries after GPUI's delay without dropping its rows" {
    var a: App = undefined;
    try peerApp(&a);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), docCalls(&a));
    const entries = a.peer("chat").?.transcript.entries.items.ptr;
    // The peer's stream ends while the connection and focused pane stay up.
    const wait = a.tick(10) orelse return error.PeerRetryNotScheduled;
    try testing.expectApproxEqAbs(@as(f32, 2), wait, 0.001);
    try testing.expect(a.peer("chat").?.watch == null);
    a.syncPeers();
    _ = a.tick(11.9);
    try testing.expectEqual(@as(usize, 1), docCalls(&a));
    _ = a.tick(12);
    a.syncPeers();
    try testing.expectEqual(@as(usize, 2), docCalls(&a));
    try testing.expect(a.peer("chat").?.watch != null);
    try testing.expectEqual(entries, a.peer("chat").?.transcript.entries.items.ptr);
    try testing.expectEqualStrings("First live chunk", a.peer("chat").?.transcript.entries.items[1].parts.items[0].text.items);
}

test "promoting a failed peer preserves its retry deadline instead of immediately reopening it" {
    var a: App = undefined;
    try peerApp(&a);
    defer a.deinit();
    _ = a.tick(10);
    a.focusPane(0);
    try testing.expectEqualStrings("chat", a.selected.?);
    try testing.expectEqual(@as(usize, 1), docCalls(&a));
    _ = a.tick(11.9);
    try testing.expectEqual(@as(usize, 1), docCalls(&a));
    _ = a.tick(12);
    try testing.expectEqual(@as(usize, 2), docCalls(&a));
    try testing.expectEqualStrings("First live chunk", a.transcript.entries.items[1].parts.items[0].text.items);
}
