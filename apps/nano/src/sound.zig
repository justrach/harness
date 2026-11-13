//! The same chimes the GPUI app plays (crates/ui/assets/sounds). A session
//! that finishes, asks for input, or fails, and a file that lands in the
//! composer. Foreground/sound-only playback is NSSound on a detached thread.
//! Background banners carry their chime through the native center so Focus
//! and per-app notification preferences can silence it.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const workspace = @import("workspace.zig");
const native = @import("native_notification.zig");

pub const Kind = enum { done, request, attention, attach };

// Synthetic tests intercept delivery before any native APIs or audio run.
var test_capture: ?*usize = null;
const Capabilities = struct { focused: bool, banner: bool, sound: bool };
var test_capabilities: ?Capabilities = null;
var test_delivery: ?*Delivery = null;
pub const Chime = enum { silent, local, notification };
pub const Delivery = struct { banner: bool, chime: Chime };
pub fn planAlert(sound: bool, banner: bool, focused: bool, native_sound: bool) Delivery {
    return .{ .banner = banner, .chime = if (!sound) .silent else if (banner and !focused and native_sound) .notification else .local };
}

const done_wav = @embedFile("sounds/done.wav");
const request_wav = @embedFile("sounds/request.wav");
const attention_wav = @embedFile("sounds/attention.wav");
const attach_wav = @embedFile("sounds/attach.wav");

fn bytes(kind: Kind) []const u8 {
    return switch (kind) {
        .done => done_wav,
        .request => request_wav,
        .attention => attention_wav,
        .attach => attach_wav,
    };
}

/// Whether Settings allows this chime. Attach has its own switch.
pub fn allowed(a: *const App, kind: Kind) bool {
    if (a.offscreen) return false;
    if (kind == .attach) return a.settings.get(.attach_sound_enabled);
    if (!a.settings.get(.sound_enabled)) return false;
    return switch (kind) {
        .done => a.settings.get(.sound_completion_enabled),
        .request => a.settings.get(.sound_input_enabled),
        .attention => a.settings.get(.sound_attention_enabled),
        else => false,
    };
}

pub fn play(a: *const App, kind: Kind) void {
    if (!allowed(a, kind)) return;
    if (builtin.is_test) if (test_capture) |count| {
        count.* += 1;
        return;
    };
    if (builtin.os.tag != .macos) return;
    const t = std.Thread.spawn(.{}, playMac, .{bytes(kind)}) catch return;
    t.detach();
}

fn playMac(wav: []const u8) void {
    const objc = @import("nanoui").objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ wav.ptr, wav.len });
    const sound = objc.msg(objc.Object, objc.class("NSSound"), "alloc", .{});
    const made = objc.msg(objc.Object, sound, "initWithData:", .{data});
    _ = objc.msg(objc.BOOL, made, "play", .{});
}

fn bundleName(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .done => "harness-done.wav",
        .request => "harness-request.wav",
        .attention => "harness-attention.wav",
        .attach => unreachable, // Attachment feedback never uses session banners.
    };
}

pub fn bannerAllowed(enabled: bool, background_only: bool, focused: bool) bool {
    return enabled and (!background_only or !focused);
}

/// One session alert, one owner of its chime. Native suppression is final:
/// falling back after Focus swallowed a delivered banner would bypass Focus.
fn deliverAlert(a: *const App, kind: Kind, chat_id: []const u8) void {
    if (a.offscreen) return;
    if (builtin.is_test) if (test_capture) |count| {
        if (allowed(a, kind)) count.* += 1;
        return;
    };
    const capabilities: Capabilities = if (builtin.is_test and test_capabilities != null) test_capabilities.? else .{
        .focused = native.focused(),
        .banner = native.available(),
        .sound = native.soundAvailable(bundleName(kind)),
    };
    const banner = bannerAllowed(a.settings.get(.notifications_enabled), a.settings.get(.notifications_background_only), capabilities.focused) and capabilities.banner;
    const delivery = planAlert(allowed(a, kind), banner, capabilities.focused, capabilities.sound);
    if (builtin.is_test) if (test_delivery) |record| {
        record.* = delivery;
        return;
    };
    const title: [:0]const u8 = switch (kind) {
        .done => "Run finished",
        .request => "Input needed",
        .attention => "Run failed",
        .attach => unreachable,
    };
    const body: [:0]const u8 = switch (kind) {
        .done => "An agent turn completed.",
        .request => "An agent is waiting for your input.",
        .attention => "An agent run needs attention.",
        .attach => unreachable,
    };
    var workspace_id: [16]u8 = undefined;
    const locator: ?[]const u8 = if (a.external_navigation.locator(a)) |value| blk: {
        workspace_id = value;
        break :blk workspace_id[0..];
    } else null;
    const delivered = if (delivery.banner) native.postForChat(title, body, if (delivery.chime == .notification) bundleName(kind) else null, chat_id, locator) else false;
    if (delivery.chime == .local or (delivery.chime == .notification and !delivered)) play(a, kind);
}

/// A first row seeds silently; suppressed completions still advance the
/// durable baseline. Never infer success from idle (cancel/expiry/handoff).
pub fn observe(a: *App) void {
    for (a.sessions.items) |s| {
        const chat: workspace.Chat = for (a.chats.items) |ch| {
            if (std.mem.eql(u8, ch.id, s.chat_id)) break ch;
        } else continue; // Archive/ownership metadata has not arrived yet.
        const fresh = a.nowMs() - s.updated_ms <= 45_000;
        var pending = false;
        for (a.pending_sends.items) |p| {
            if (!p.rejected and std.mem.eql(u8, p.chat, s.chat_id)) {
                pending = true;
                break;
            }
        }
        const kind = a.sessions.notification_baselines.observe(a.gpa, s.chat_id, .{
            .status = if (fresh) s.status else .idle,
            .completed = s.last_completed_turn,
            .peer_only = s.last_completed_peer_only,
        }, chat.archived, fresh, pending) catch continue;
        if (kind) |k| deliverAlert(a, switch (k) {
            .done => .done,
            .request => .request,
            .attention => .attention,
        }, s.chat_id);
    }
}

test "a first known session seeds its notification baseline silently" {
    const testing = std.testing;
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    const idle = workspace.Session{ .chat_id = "synthetic", .status = .idle };
    a.sessions.items = @constCast(&[_]workspace.Session{idle});
    var chat = fixture_chat;
    a.chats.items = @as(*[1]workspace.Chat, &chat)[0..];
    observe(&a);
    try testing.expect(a.sessions.notification_baselines.states.get("synthetic") != null);
}

const fixture_chat: workspace.Chat = .{ .id = "synthetic", .title = null, .space_id = null, .archived = false, .preview = null, .harness = null, .model = null, .cwd = null };
fn fixtureSessions(a: *App, text: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    try a.sessions.replace(v);
    for (a.sessions.items) |*s| s.updated_ms = a.nowMs();
    observe(a);
}

test "retention499 peer-only completion consumes durable marker silently" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    var chat = fixture_chat;
    a.chats.items = @as(*[1]workspace.Chat, &chat)[0..];
    var count: usize = 0;
    test_capture = &count;
    defer test_capture = null;
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\"}]");
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"idle\",\"lastCompletedTurn\":\"peer-result\",\"lastCompletedPeerOnly\":true}]");
    try std.testing.expectEqual(@as(usize, 0), count);
    // A later heartbeat or restore may not replay the withheld completion.
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"idle\",\"lastCompletedTurn\":\"peer-result\",\"lastCompletedPeerOnly\":false}]");
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "retention499 archived completion is silent after restore" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    var chat = fixture_chat;
    chat.archived = true;
    a.chats.items = @as(*[1]workspace.Chat, &chat)[0..];
    var count: usize = 0;
    test_capture = &count;
    defer test_capture = null;
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\"}]");
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"idle\",\"lastCompletedTurn\":\"archived-result\"}]");
    try std.testing.expectEqual(@as(usize, 0), count);
    chat.archived = false;
    observe(&a);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "retention499 unknown chat and cancelled working turn stay silent" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    var count: usize = 0;
    test_capture = &count;
    defer test_capture = null;
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\"}]");
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"idle\"}]");
    try std.testing.expectEqual(@as(usize, 0), count);
    var chat = fixture_chat;
    a.chats.items = @as(*[1]workspace.Chat, &chat)[0..];
    observe(&a);
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\"}]");
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"idle\"}]");
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "retention499 human completion survives coalesced working snapshots" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    var chat = fixture_chat;
    a.chats.items = @as(*[1]workspace.Chat, &chat)[0..];
    var count: usize = 0;
    test_capture = &count;
    defer test_capture = null;
    // First sight is silent, even with a durable completion already present.
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\",\"lastCompletedTurn\":\"old\"}]");
    try std.testing.expectEqual(@as(usize, 0), count);
    // The next queued run can already be working when the watch catches up.
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\",\"lastCompletedTurn\":\"human-result\"}]");
    try std.testing.expectEqual(@as(usize, 1), count);
    observe(&a);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "retention518 background banner owns chime foreground stays local" {
    try std.testing.expectEqual(Delivery{ .banner = true, .chime = .notification }, planAlert(true, true, false, true));
    try std.testing.expectEqual(Delivery{ .banner = true, .chime = .local }, planAlert(true, true, true, true));
    try std.testing.expectEqual(Delivery{ .banner = false, .chime = .local }, planAlert(true, false, false, true));
    try std.testing.expectEqual(Delivery{ .banner = true, .chime = .silent }, planAlert(false, true, false, true));
}

test "retention499 sound toggles and attachment stay independent" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    try std.testing.expect(allowed(&a, .done));
    a.settings.set(.sound_enabled, false);
    try std.testing.expect(!allowed(&a, .done));
    try std.testing.expect(!allowed(&a, .request));
    try std.testing.expect(!allowed(&a, .attention));
    try std.testing.expect(allowed(&a, .attach));
    a.settings.set(.attach_sound_enabled, false);
    a.settings.set(.sound_enabled, true);
    a.settings.set(.sound_completion_enabled, false);
    try std.testing.expect(!allowed(&a, .done));
    try std.testing.expect(allowed(&a, .request));
    try std.testing.expect(allowed(&a, .attention));
    try std.testing.expect(!allowed(&a, .attach));
}

test "retention518 production session delivery respects settings and Focus ownership" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    var delivery: Delivery = undefined;
    test_delivery = &delivery;
    test_capabilities = .{ .focused = false, .banner = true, .sound = true };
    defer {
        test_delivery = null;
        test_capabilities = null;
    }
    deliverAlert(&a, .done, "synthetic");
    try std.testing.expectEqual(Delivery{ .banner = true, .chime = .notification }, delivery);
    test_capabilities.?.focused = true;
    deliverAlert(&a, .done, "synthetic");
    try std.testing.expectEqual(Delivery{ .banner = false, .chime = .local }, delivery);
    a.settings.set(.notifications_background_only, false);
    deliverAlert(&a, .request, "synthetic");
    try std.testing.expectEqual(Delivery{ .banner = true, .chime = .local }, delivery);
    a.settings.set(.sound_input_enabled, false);
    deliverAlert(&a, .request, "synthetic");
    try std.testing.expectEqual(Delivery{ .banner = true, .chime = .silent }, delivery);
    test_capabilities.?.focused = false;
    a.settings.set(.notifications_enabled, false);
    deliverAlert(&a, .attention, "synthetic");
    try std.testing.expectEqual(Delivery{ .banner = false, .chime = .local }, delivery);
    a.settings.set(.notifications_enabled, true);
    test_capabilities.?.sound = false; // Unbundled runs retain sound-only feedback.
    deliverAlert(&a, .done, "synthetic");
    try std.testing.expectEqual(Delivery{ .banner = true, .chime = .local }, delivery);
}

test "retention499 archived peer input and failure transitions still notify once" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    var chat = fixture_chat;
    chat.archived = true;
    a.chats.items = @as(*[1]workspace.Chat, &chat)[0..];
    var count: usize = 0;
    test_capture = &count;
    defer test_capture = null;
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\"}]");
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"awaitingInput\",\"lastCompletedPeerOnly\":true}]");
    try std.testing.expectEqual(@as(usize, 1), count);
    observe(&a);
    try std.testing.expectEqual(@as(usize, 1), count);
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"errored\",\"lastCompletedPeerOnly\":true}]");
    try std.testing.expectEqual(@as(usize, 2), count);
    observe(&a);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "retention499 disabled completion is consumed not replayed and attachment stays local" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    var chat = fixture_chat;
    a.chats.items = @as(*[1]workspace.Chat, &chat)[0..];
    var count: usize = 0;
    test_capture = &count;
    defer test_capture = null;
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"working\"}]");
    a.settings.set(.sound_completion_enabled, false);
    try fixtureSessions(&a, "[{\"chatId\":\"synthetic\",\"status\":\"idle\",\"lastCompletedTurn\":\"muted\"}]");
    try std.testing.expectEqual(@as(usize, 0), count);
    a.settings.set(.sound_completion_enabled, true);
    observe(&a);
    try std.testing.expectEqual(@as(usize, 0), count);
    a.settings.set(.sound_enabled, false);
    play(&a, .attach);
    try std.testing.expectEqual(@as(usize, 1), count);
    a.settings.set(.attach_sound_enabled, false);
    play(&a, .attach);
    try std.testing.expectEqual(@as(usize, 1), count);
}
