//! The composer's dictation, as the GPUI app's (`toggle_dictation`,
//! `on_dictation_event`, composer.rs): the mic shows where the device's
//! Codex voice was found at launch; clicked it starts, clicked while
//! listening it finishes (keeping the last words), clicked while starting
//! or finishing it cancels. Words go in at the caret as they're finished.
const std = @import("std");
const nanoui = @import("nanoui");
const dictation = @import("dictation.zig");
const App = @import("app.zig").App;

pub const State = struct {
    running: ?*dictation.Running = null,
    listening: bool = false,
    finishing: bool = false,
    level: f32 = 0,
    /// The utterance being heard, before it's final.
    partial: std.ArrayList(u8) = .empty,
    /// Where it runs, once the launch's look found it (`probed` then 1).
    runtime: dictation.Runtime = .{ .codex = "", .helper = "" },
    probed: std.atomic.Value(u8) = .init(0),

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.running) |r| {
            r.cancel();
            r.destroy();
        }
        s.partial.deinit(gpa);
        if (s.probed.load(.acquire) == 1) {
            gpa.free(s.runtime.codex);
            gpa.free(s.runtime.helper);
        }
    }
};

/// At launch, off the main thread: whether this device can dictate
/// (`probe_dictation`).
pub fn probe(a: *App) void {
    const env = a.env orelse return;
    const t = std.Thread.spawn(.{}, look, .{ a, env }) catch return;
    t.detach();
}

/// The same look, now: for scenes drawn offscreen, as the GPUI renderer's
/// composer probes before it draws.
pub fn probeNow(a: *App) void {
    const env = a.env orelse return;
    a.offscreen = true;
    look(a, env);
}

fn look(a: *App, env: *const std.process.Environ.Map) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const s = &a.dictation;
    const found = dictation.detect(arena.allocator(), a.io, env) catch {
        s.probed.store(2, .release);
        return;
    };
    s.runtime = .{
        .codex = a.gpa.dupe(u8, found.codex) catch return s.probed.store(2, .release),
        .helper = a.gpa.dupe(u8, found.helper) catch return s.probed.store(2, .release),
    };
    s.probed.store(1, .release);
    if (!a.offscreen) nanoui.App.after(0, a, redraw);
}

fn redraw(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    a.redraw();
}

/// The mic shows where dictation can run, and while a session is live.
pub fn shown(a: *const App) bool {
    return a.dictation.running != null or a.dictation.probed.load(.acquire) == 1;
}

/// The mic clicked.
pub fn toggle(a: *App) void {
    const s = &a.dictation;
    if (s.running) |r| {
        if (s.listening and !s.finishing) {
            r.finish();
            s.finishing = true;
        } else r.cancel();
        return a.redraw();
    }
    if (s.probed.load(.acquire) != 1) return a.setNotice(dictation.unavailableMessage(error.Unavailable));
    const env = a.env orelse return;
    s.listening = false;
    s.finishing = false;
    s.level = 0;
    s.partial.clearRetainingCapacity();
    s.running = dictation.Running.start(a.gpa, a.io, env, s.runtime, .{ .ctx = a, .func = sink }) catch
        return a.setNotice("Codex could not start.");
    a.redraw();
}

/// From the session's thread: a copy of the event, to the main thread.
const Delivery = struct {
    a: *App,
    event: std.meta.Tag(dictation.Event),
    level: f32 = 0,
    text: []u8 = &.{},
};

fn sink(ctx: *anyopaque, e: dictation.Event) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    const d = std.heap.page_allocator.create(Delivery) catch return;
    d.* = .{ .a = a, .event = e };
    switch (e) {
        .level => |l| d.level = l,
        .partial, .segment, .failed => |t| d.text = std.heap.page_allocator.dupe(u8, t) catch &.{},
        else => {},
    }
    nanoui.App.after(0, d, deliver);
}

fn deliver(ctx: ?*anyopaque) callconv(.c) void {
    const d: *Delivery = @ptrCast(@alignCast(ctx.?));
    defer {
        std.heap.page_allocator.free(d.text);
        std.heap.page_allocator.destroy(d);
    }
    apply(d.a, d.event, d.level, d.text);
}

/// An event on the main thread (`on_dictation_event`).
pub fn apply(a: *App, event: std.meta.Tag(dictation.Event), level: f32, text: []const u8) void {
    const s = &a.dictation;
    switch (event) {
        .listening => s.listening = true,
        .level => s.level = level,
        .partial => {
            s.partial.clearRetainingCapacity();
            s.partial.appendSlice(a.gpa, text) catch {};
        },
        .segment => {
            s.partial.clearRetainingCapacity();
            insert(a, text);
        },
        // The device's voice failed, not a send.
        .failed => a.setNotice(text),
        .ended => {
            if (s.running) |r| r.destroy();
            s.running = null;
            s.listening = false;
            s.finishing = false;
            s.level = 0;
            s.partial.clearRetainingCapacity();
        },
    }
    a.redraw();
}

/// Dictated words at the composer's caret, spaced from the text around
/// them (`insert_dictation`).
pub fn insert(a: *App, words: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const text = a.composer.text();
    const at = @min(a.view.composer_caret, text.len);
    const add = dictation.spaced(fba.allocator(), text, at, words) catch return;
    if (add.len == 0) return;
    const n = a.composer.replace(at, at, add);
    a.composer.want_caret = at + n;
    a.view.composer_caret = at + n;
}

const testing = std.testing;

test "dictated words go in at the caret, spaced; the session's events set the mic's state" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.composer.set("Write  please");
    a.view.composer_caret = 6;
    apply(&a, .listening, 0, "");
    try testing.expect(a.dictation.listening);
    apply(&a, .partial, 0, "the notes");
    try testing.expectEqualStrings("the notes", a.dictation.partial.items);
    apply(&a, .segment, 0, "the notes");
    try testing.expectEqualStrings("Write the notes please", a.composer.text());
    try testing.expectEqual(@as(usize, 0), a.dictation.partial.items.len);
    // Next words follow the last.
    apply(&a, .segment, 0, "now");
    try testing.expectEqualStrings("Write the notes now please", a.composer.text());
    apply(&a, .failed, 0, "Codex: quota");
    try testing.expectEqualStrings("Codex: quota", a.noticeText().?);
    apply(&a, .ended, 0, "");
    try testing.expect(!a.dictation.listening);
}
