//! The same chimes the GPUI app plays (crates/ui/assets/sounds). A session
//! that finishes, asks for input, or fails, and a file that lands in the
//! composer. Playback is NSSound on a detached thread so a frame never
//! waits on it.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const workspace = @import("workspace.zig");

pub const Kind = enum { done, request, attention, attach };

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

/// A session that just finished, asked a question, or failed. The first
/// sight of a row is silent, so opening the app does not replay old turns.
pub fn observe(a: *App) void {
    for (a.sessions.items) |s| {
        const gop = a.sound_seen.getOrPut(a.gpa, s.chat_id) catch continue;
        if (!gop.found_existing) {
            const owned = a.gpa.dupe(u8, s.chat_id) catch {
                _ = a.sound_seen.remove(s.chat_id);
                continue;
            };
            // The session list's arena dies on the next replace.
            _ = a.sound_seen.remove(s.chat_id);
            a.sound_seen.put(a.gpa, owned, .{ .status = s.status, .seen = true }) catch {
                a.gpa.free(owned);
            };
            continue;
        }
        const prev = gop.value_ptr.status;
        gop.value_ptr.status = s.status;
        if (!gop.value_ptr.seen) {
            gop.value_ptr.seen = true;
            continue;
        }
        const kind: ?Kind = if (s.status == .errored and prev != .errored)
            .attention
        else if (s.status == .awaiting_input and prev != .awaiting_input)
            .request
        else if (s.status == .idle and prev == .working)
            .done
        else
            null;
        if (kind) |k| play(a, k);
    }
}

test "a first session row is silent and a finish after working chimes" {
    const testing = std.testing;
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    const idle = workspace.Session{ .chat_id = "c", .status = .idle };
    a.sessions.items = @constCast(&[_]workspace.Session{idle});
    observe(&a);
    try testing.expect(a.sound_seen.get("c") != null);
}
