//! A second turn must not blank the conversation while its timer advances.
//! Synthetic data only: no engine, account or saved chats.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const history =
    \\{"reset":[
    \\ {"id":"user-one","role":"user","parts":[{"id":"p","kind":"text","text":"First synthetic question"}]},
    \\ {"id":"assistant-one","role":"assistant","status":"complete","parts":[
    \\   {"id":"thought","kind":"reasoning","text":"A completed synthetic thought"},
    \\   {"id":"answer","kind":"text","text":"The previous synthetic answer"}]},
    \\ {"id":"user-two","role":"user","parts":[{"id":"p","kind":"text","text":"Second synthetic question"}]}
    \\]}
;

fn apply(t: *@import("transcript.zig").Transcript, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
}

fn visible(t: *ui.Tester, text: []const u8) !void {
    const rect = t.findText(text) orelse return error.HistoryMissing;
    try testing.expect(rect.y >= 40 and rect.y + rect.h <= t.ctx.size.h - 100);
}

test "a rejected document frame keeps the last good history while resubscribing" {
    for ([_]bool{ false, true }) |peer| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
        a.engine.state = .connected;
        a.openChat("synthetic-history", null);
        try apply(&a.transcript, history);
        if (peer) {
            a.splitPane(.horizontal);
            a.syncPeers();
        }
        const old = if (peer) a.peer("synthetic-history").?.watch.? else a.w_doc.id.?;
        // A missed/out-of-order frame trips the count check AFTER removes.
        // It must trigger a fresh watch, not erase the last verified view.
        const bad = try std.json.Stringify.valueAlloc(testing.allocator, .{
            .id = old,
            .item = .{ .remove = &.{ "user-one", "assistant-one", "user-two" }, .count = 3 },
        }, .{});
        defer testing.allocator.free(bad);
        try a.engine.mux.dispatch(bad);
        try testing.expect(a.engine.mux.pending.get(old) == null);
        const t = if (peer) &a.peer("synthetic-history").?.transcript else &a.transcript;
        try testing.expectEqual(@as(usize, 3), t.entries.items.len);
        try testing.expectEqualStrings("The previous synthetic answer", t.entries.items[1].parts.items[1].text.items);
        try testing.expect(t.complete);
        if (peer) a.syncPeers();
        const fresh = if (peer) a.peer("synthetic-history").?.watch.? else a.w_doc.id.?;
        try testing.expect(fresh != old);
        var reset = try std.json.parseFromSlice(std.json.Value, testing.allocator, history, .{});
        defer reset.deinit();
        const reply = try std.json.Stringify.valueAlloc(testing.allocator, .{ .id = fresh, .item = reset.value }, .{});
        defer testing.allocator.free(reply);
        try a.engine.mux.dispatch(reply);
        try testing.expectEqual(@as(usize, 3), t.entries.items.len);
    }
}

test "rejected resets and compound deltas roll back entries, appends and context" {
    const bad_frames = [_][]const u8{
        \\{"remove":["user-one"],"upsert":[{"after":null,"entry":{"id":"assistant-one","role":"assistant","parts":[]}}],"append":[{"entry":"user-two","part":"p","text":" lost","len":999}],"count":2,"contextUsage":{"tokens":999}}
        ,
        \\{"remove":["user-one"],"upsert":[{"after":"user-two","entry":{"id":"temporary","role":"user","parts":[]}},{"after":"missing","entry":{"id":"user-two","role":"user","parts":[]}}],"count":3}
        ,
        \\{"reset":[{"id":"replacement","role":"user","parts":[]},42]}
        ,
        \\{"reset":null}
        ,
        \\{"append":[{"entry":"user-two","part":"p","text":"!","len":26},{"entry":"user-two","part":"p","text":"?","len":999}],"count":3}
        ,
    };
    for (bad_frames) |bad| {
        var t: @import("transcript.zig").Transcript = .{ .gpa = testing.allocator };
        defer t.deinit();
        try apply(&t, history);
        t.tokens = 123;
        t.window = 456;
        try testing.expectError(error.Desync, apply(&t, bad));
        try testing.expectEqual(@as(usize, 3), t.entries.items.len);
        for (t.entries.items, [_][]const u8{ "user-one", "assistant-one", "user-two" }) |entry, id| try testing.expectEqualStrings(id, entry.id);
        try testing.expectEqualStrings("The previous synthetic answer", t.entries.items[1].parts.items[1].text.items);
        try testing.expectEqualStrings("Second synthetic question", t.entries.items[2].parts.items[0].text.items);
        try testing.expectEqual(@as(?u64, 123), t.tokens);
        try testing.expectEqual(@as(?u64, 456), t.window);
        try testing.expect(t.complete);
        // A valid deletion is still authoritative, not silently ignored.
        try apply(&t, "{\"remove\":[\"user-one\",\"assistant-one\",\"user-two\"],\"count\":0}");
        try testing.expectEqual(@as(usize, 0), t.entries.items.len);
    }
}

test "transactional streaming does not copy history or allocate an undo log for an append" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var t: @import("transcript.zig").Transcript = .{ .gpa = failing.allocator() };
    defer t.deinit();
    try apply(&t, history);
    try t.entries.items[2].parts.items[0].text.ensureUnusedCapacity(t.gpa, 64);
    var frame = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"append":[{"entry":"user-two","part":"p","text":"!","len":26}],"count":3}
    , .{});
    defer frame.deinit();
    failing.fail_index = failing.alloc_index;
    try t.apply(frame.value);
    try testing.expectEqualStrings("Second synthetic question!", t.entries.items[2].parts.items[0].text.items);
}

test "a waiting second turn retains visible history through timer frames and resizes" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = false;
    a.openChat("synthetic-history", null);
    try apply(&a.transcript, history);
    var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"synthetic-history","status":"working","startedAt":"2026-10-26T00:00:00Z","updatedAt":"2026-10-26T00:00:00Z"}]
    , .{});
    defer sessions.deinit();
    try a.sessions.replace(sessions.value);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = false });
    defer t.deinit();
    t.settle(1);
    a.sessions.items[0].started_ms = a.nowMs();
    a.sessions.items[0].updated_ms = a.nowMs() + 30_000;
    t.settle(1);
    for (0..300) |frame| {
        // The trailer uses the real clock, not Tester's animation clock.
        // Move the synthetic start time so elapsed text and word rotation
        // really advance without sleeping or changing the production clock.
        const seconds: i64 = @intCast(frame / 15);
        a.sessions.items[0].started_ms = a.nowMs() - seconds * 1000 - 250;
        a.sessions.items[0].updated_ms = a.nowMs();
        if (frame == 75) try testing.expectError(error.Desync, apply(&a.transcript,
            \\{"remove":["user-one","assistant-one","user-two"],"count":3}
        ));
        if (frame == 90) t.scroll(900, 300, -10_000);
        if (frame == 95) t.scroll(900, 300, 10_000);
        if (frame == 100) t.resize(1100, 700);
        if (frame == 150) a.splitPane(.horizontal);
        if (frame == 175) a.focusPane(0);
        if (frame == 200) t.resize(1200, 780);
        if (frame == 225) a.focusPane(1);
        if (frame == 250) a.closeFocused();
        t.advance(1.0 / 15.0);
        const shown = if (a.selected != null) &a.transcript else &a.peer("synthetic-history").?.transcript;
        try testing.expectEqual(@as(usize, 3), shown.entries.items.len);
        try visible(&t, "First synthetic question");
        try visible(&t, "The previous synthetic answer");
        try visible(&t, "Second synthetic question");
        var elapsed_buf: [32]u8 = undefined;
        try testing.expect(t.hasText(try std.fmt.bufPrint(&elapsed_buf, "{d}s", .{seconds})));
        var word_buf: [64]u8 = undefined;
        try testing.expect(t.hasText(try std.fmt.bufPrint(&word_buf, "{s}…", .{@import("view_working.zig").word("synthetic-history", seconds)})));
        if (frame == 0 or frame == 75 or frame == 299) if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
            var buf: [2048]u8 = undefined;
            try t.screenshot(try std.fmt.bufPrint(&buf, "{s}/history-{d}.png", .{ std.mem.span(dir), frame }));
        };
    }
}
