//! Steering a live run from the composer: ⌘↩ queues the message and promotes
//! it, as the desktop's composer does.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const enter: ui.Shortcut = .{ .key = ui.Shortcut.enter };
const cmd_enter: ui.Shortcut = .{ .key = ui.Shortcut.enter, .cmd = true };
const cmd_alt_enter: ui.Shortcut = .{ .key = ui.Shortcut.enter, .cmd = true, .alt = true };
const accepted =
    \\{"QueueMessage":{"id":"row-1"},"SteerQueuedMessageNow":{"sent":true}}
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, scene: []const u8, steering_mode: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = false;
        h.a.view.sidebar_open = false;
        h.a.device_id = try testing.allocator.dupe(u8, "d");
        h.a.caps = .{ .queue = true, .actions = true };
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
        h.a.engine.state = .connected;
        try h.load(&h.a.chats,
            \\[{"id":"a","deviceId":"d","title":"Synthetic chat","archived":false,
            \\  "config":{"harness":"graff","model":"m","reasoning":null,"modelOptions":{},"sandbox":"workspace-write"}}]
        );
        const agents = try std.fmt.allocPrint(testing.allocator,
            \\[{{"id":"graff","name":"Graff","installed":true,"enabled":true,"supportsSteering":true,"steeringMode":"{s}"}}]
        , .{steering_mode});
        defer testing.allocator.free(agents);
        try h.load(&h.a.harnesses, agents);
        h.a.openChat("a", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 800, .dark = false });
        h.t.settle(1);
        try h.load(&h.a.sessions,
            \\[{"chatId":"a","status":"working","startedAt":"2026-10-26T00:00:00Z","updatedAt":"2026-10-26T00:00:00Z"}]
        );
        h.a.sessions.items[0].updated_ms = h.a.nowMs();
        h.a.sessions.items[0].started_ms = h.a.nowMs();
        h.a.view.focus_composer = true;
        h.t.settle(1);
    }

    fn load(_: *Harness, list: anytype, text: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
        defer parsed.deinit();
        try list.replace(parsed.value);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn press(h: *Harness, s: ui.Shortcut) void {
        _ = h.t.shortcut(s);
        h.t.settle(1);
    }

    /// The calls of `method` so far.
    fn calls(h: *Harness, method: []const u8) usize {
        var n: usize = 0;
        for (h.a.engine.sent.items) |f| {
            if (std.mem.indexOf(u8, f, method) != null) n += 1;
        }
        return n;
    }

    fn sentHas(h: *Harness, text: []const u8) bool {
        for (h.a.engine.sent.items) |f| if (std.mem.indexOf(u8, f, text) != null) return true;
        return false;
    }
};

test "⌘↩ on a draft while the agent works steers: queued for its id, then promoted" {
    var h: Harness = undefined;
    try h.init(accepted, "step-boundary");
    defer h.deinit();
    h.t.typeText("Synthetic steer");
    h.press(cmd_enter);
    try testing.expectEqual(@as(usize, 1), h.calls("\"QueueMessage\""));
    try testing.expectEqual(@as(usize, 1), h.calls("\"SteerQueuedMessageNow\""));
    try testing.expect(h.sentHas("Synthetic steer"));
    try testing.expect(h.sentHas("\"id\":\"row-1\""));
    try testing.expectEqualStrings("", h.a.composer.text());
    // The scene answers only the queue; the other calls' misses aside, no failure.
    if (h.a.noticeText()) |n| try testing.expectEqualStrings("isn't in this scene", n);
    try testing.expectEqual(@as(usize, 0), h.a.steers.items.len);
}

test "Enter on a draft while the agent works queues it, and doesn't steer" {
    var h: Harness = undefined;
    try h.init(accepted, "step-boundary");
    defer h.deinit();
    h.t.typeText("Synthetic follow-up");
    h.t.key(.enter);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.calls("\"QueueMessage\""));
    try testing.expectEqual(@as(usize, 0), h.calls("\"SteerQueuedMessageNow\""));
    try testing.expectEqualStrings("", h.a.composer.text());
}

test "an agent that steers only between turns keeps the draft and says why" {
    var h: Harness = undefined;
    try h.init(accepted, "turn-boundary");
    defer h.deinit();
    h.t.typeText("Synthetic steer");
    h.press(cmd_enter);
    try testing.expectEqual(@as(usize, 0), h.calls("\"QueueMessage\""));
    try testing.expectEqualStrings("Synthetic steer", h.a.composer.text());
    try testing.expectEqualStrings("This agent does not support steering during a turn", h.a.noticeText().?);
}

test "with Steer as the follow-up behaviour, Enter steers and ⌘↩ queues" {
    var h: Harness = undefined;
    try h.init(accepted, "step-boundary");
    defer h.deinit();
    h.a.settings.setText("followUpBehavior", "steer");
    h.t.typeText("Synthetic first");
    h.t.key(.enter);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.calls("\"SteerQueuedMessageNow\""));
    h.t.typeText("Synthetic second");
    h.press(cmd_enter);
    try testing.expectEqual(@as(usize, 2), h.calls("\"QueueMessage\""));
    try testing.expectEqual(@as(usize, 1), h.calls("\"SteerQueuedMessageNow\""));
}

test "with ⌘ Enter sending, ⌘↩ queues and ⌘⌥↩ steers" {
    var h: Harness = undefined;
    try h.init(accepted, "step-boundary");
    defer h.deinit();
    h.a.settings.setText("composerSendBehavior", "mod-enter");
    h.t.settle(1);
    h.t.typeText("Synthetic first");
    h.press(cmd_enter);
    try testing.expectEqual(@as(usize, 1), h.calls("\"QueueMessage\""));
    try testing.expectEqual(@as(usize, 0), h.calls("\"SteerQueuedMessageNow\""));
    h.t.typeText("Synthetic second");
    h.press(cmd_alt_enter);
    try testing.expectEqual(@as(usize, 1), h.calls("\"SteerQueuedMessageNow\""));
}

test "a message the engine couldn't queue goes back to the draft" {
    var h: Harness = undefined;
    try h.init(
        \\{"QueueMessage":{"$err":"Synthetic refusal"}}
    , "step-boundary");
    defer h.deinit();
    h.t.typeText("Synthetic steer");
    h.press(cmd_enter);
    try testing.expectEqualStrings("Synthetic steer", h.a.composer.text());
    try testing.expect(h.a.noticeText() != null);
    try testing.expectEqual(@as(usize, 0), h.calls("\"SteerQueuedMessageNow\""));
    try testing.expectEqual(@as(usize, 0), h.a.steers.items.len);
}

test "a queued message the engine won't promote stays queued, and the composer says so" {
    var h: Harness = undefined;
    try h.init(
        \\{"QueueMessage":{"id":"row-1"},"SteerQueuedMessageNow":{"sent":false}}
    , "step-boundary");
    defer h.deinit();
    h.t.typeText("Synthetic steer");
    h.press(cmd_enter);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqualStrings("Message queued, but it couldn't steer the run. Check the queue.", h.a.noticeText().?);
    try testing.expectEqual(@as(usize, 0), h.calls("\"RemoveQueuedMessage\""));
}
