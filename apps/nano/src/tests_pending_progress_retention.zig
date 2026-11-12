//! Synthetic engine streams must drive the actual pending/waiting presentation.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;

fn connect(h: *Harness, replies: []const u8) !void {
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, replies, .{});
    h.a.engine.state = .connected;
}

// Engine.scene's simple replies are unary. Promote these two test replies to
// live stream items, leaving their real Mux handlers registered for later frames.
fn liveItems(h: *Harness) !void {
    for (h.a.engine.queued.items) |*frame| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.*, .{});
        defer parsed.deinit();
        const id = parsed.value.object.get("id").?.integer;
        const value = parsed.value.object.get("ok") orelse continue;
        var stream = false;
        for (h.a.engine.sent.items) |sent| {
            const call = try std.json.parseFromSlice(std.json.Value, testing.allocator, sent, .{});
            defer call.deinit();
            if (call.value.object.get("id").?.integer != id) continue;
            const method = call.value.object.get("method").?.string;
            stream = std.mem.eql(u8, method, "WatchQueue") or std.mem.eql(u8, method, "WatchToolProgress");
            break;
        }
        if (!stream) continue;
        const replacement = try std.json.Stringify.valueAlloc(testing.allocator, .{ .id = id, .item = value }, .{});
        testing.allocator.free(frame.*);
        frame.* = replacement;
    }
}

test "restore pending remote prompt is visible before its transcript echo (#415)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h,
        \\{"WatchQueue":{"items":[],"pendingPrompts":[{"messageId":"remote-message","text":"REMOTE_PENDING_SYNTHETIC","issuedAt":123,"issuedBy":"synthetic-device","waitingForAttachments":true}]}}
    );
    @import("app_queue.zig").watch(&h.a);
    try liveItems(&h);
    _ = h.a.engine.pump();
    h.t.settle(1);
    try testing.expect(h.t.hasText("REMOTE_PENDING_SYNTHETIC"));
    try testing.expect(h.t.hasText("Waiting for attachments"));
    if (std.c.getenv("NANO_PENDING_SCREENSHOT")) |path| try h.t.screenshot(std.mem.span(path));
}

test "restore waiting progress subscribes to the real engine stream (#606)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h,
        \\{"WatchToolProgress":{"items":[{"toolId":"harness:build-wait","output":"123","state":"waiting"}]},"WatchQueue":{"items":[],"pendingPrompts":[]}}
    );
    const now = h.a.nowMs();
    var sessions = [_]@import("workspace.zig").Session{.{ .chat_id = "a", .status = .working, .started_ms = now - 10_000, .updated_ms = now }};
    h.a.sessions.items = &sessions;
    _ = h.a.tick(1);
    try liveItems(&h);
    _ = h.a.tick(2);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Waiting for build slot"));
    var watched: ?i64 = null;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const method = parsed.value.object.get("method").?.string;
        if (std.mem.eql(u8, method, "WatchToolProgress")) watched = parsed.value.object.get("id").?.integer;
    }
    try testing.expect(watched != null);
    if (std.c.getenv("NANO_WAITING_SCREENSHOT")) |path| try h.t.screenshot(std.mem.span(path));
    // The live marker is authoritative even if session publication is late.
    h.a.sessions.items = &.{};
    h.t.settle(0.2);
    try testing.expect(h.t.hasText("Waiting for build slot"));
    const ended = try std.json.Stringify.valueAlloc(testing.allocator, .{ .id = watched.?, .done = true }, .{});
    defer testing.allocator.free(ended);
    try h.a.engine.mux.dispatch(ended);
    h.t.settle(0.2);
    try testing.expect(!h.t.hasText("Waiting for build slot"));
}
