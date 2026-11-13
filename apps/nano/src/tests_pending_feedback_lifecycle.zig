//! Pending presentation is not an acknowledgement or a source of local drafts.
const std = @import("std");
const testing = std.testing;
const feedback = @import("app_send_feedback.zig");
const Harness = @import("tests_ui_tab_strip.zig").Harness;

fn snapshot(h: *Harness, chat: []const u8, source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, source, .{});
    defer parsed.deinit();
    feedback.syncRemote(&h.a, chat, parsed.value);
}

test "restore pending remote snapshots deduplicate local sends and render every prompt (#415)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const local = try feedback.begin(&h.a, "a", "local-message", "LOCAL_SYNTHETIC");
    try snapshot(&h, "a",
        \\{"pendingPrompts":[{"messageId":"local-message","text":"LOCAL_SYNTHETIC","issuedAt":123},{"messageId":"remote-message","text":"SECOND_SYNTHETIC","issuedAt":124}]}
    );
    try testing.expectEqual(@as(usize, 2), h.a.pending_sends.items.len);
    try testing.expect(!local.remote);
    try testing.expect(local.delivery_pending);
    h.t.settle(1);
    try testing.expect(h.t.hasText("LOCAL_SYNTHETIC"));
    try testing.expect(h.t.hasText("SECOND_SYNTHETIC"));
    try testing.expect(h.t.hasText("Waiting for host"));
    h.a.composer.set("UNSENT_SYNTHETIC_DRAFT");
    try snapshot(&h, "a", "{\"pendingPrompts\":[]}");
    feedback.reap(&h.a);
    // The real local RPC can still be in flight after the command snapshot
    // withdraws a remote delivery indicator. Only its own callback owns it.
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    try testing.expect(!local.delivery_pending);
    try testing.expectEqualStrings("UNSENT_SYNTHETIC_DRAFT", h.a.composer.text());
}

test "restore pending transcript echo suppresses remote placeholder without speculative doc rows (#415)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try snapshot(&h, "a",
        \\{"pendingPrompts":[{"messageId":"echo-message","text":"REMOTE_ECHO_SYNTHETIC","issuedAt":123}]}
    );
    try testing.expectEqual(@as(usize, 0), h.a.transcript.entries.items.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"echo-message","role":"user","parts":[{"kind":"text","text":"REMOTE_ECHO_SYNTHETIC"}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    try testing.expect(feedback.active(&h.a, "a", &h.a.transcript) == null);
    feedback.reap(&h.a);
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.transcript.entries.items.len);
    try testing.expectEqualStrings("", h.a.composer.text());
}

test "restore pending remote snapshot ownership is chat local and frame safe (#415)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try snapshot(&h, "a", "{\"pendingPrompts\":[{\"messageId\":\"same-id\",\"text\":\"A_OLD_SYNTHETIC\",\"issuedAt\":123}]}");
    const old = h.a.pending_sends.items[0];
    try snapshot(&h, "b", "{\"pendingPrompts\":[{\"messageId\":\"same-id\",\"text\":\"B_SYNTHETIC\",\"issuedAt\":123}]}");
    try snapshot(&h, "a", "{\"pendingPrompts\":[{\"messageId\":\"same-id\",\"text\":\"A_NEW_SYNTHETIC\",\"issuedAt\":123}]}");
    try testing.expectEqualStrings("A_OLD_SYNTHETIC", old.part.text.items);
    try testing.expect(old.withdrawn);
    try testing.expectEqualStrings("A_NEW_SYNTHETIC", feedback.active(&h.a, "a", &h.a.transcript).?.part.text.items);
    try testing.expectEqualStrings("B_SYNTHETIC", feedback.active(&h.a, "b", &h.a.transcript).?.part.text.items);
    feedback.clearRemote(&h.a, "a");
    feedback.reap(&h.a);
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    try testing.expectEqualStrings("b", h.a.pending_sends.items[0].chat);
}
