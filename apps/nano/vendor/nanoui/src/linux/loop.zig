//! Running GLib's main loop for a while, between headless frames: process
//! output, timers and replies get handled. Without GTK, it sleeps.
const std = @import("std");
const gtk = @import("gtk.zig");
const clock = @import("../ui/clock.zig");

pub fn runFor(seconds: f64) void {
    if (gtk.load()) {
        const end = clock.now() + seconds;
        while (clock.now() < end) {
            if (gtk.api.g_main_context_iteration(null, 0) == 0) sleep(0.002);
        }
        return;
    }
    sleep(seconds);
}

fn sleep(seconds: f64) void {
    const ns: u64 = @intFromFloat(seconds * 1e9);
    var ts: std.c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = std.c.nanosleep(&ts, &ts);
}
