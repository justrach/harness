//! Watching file descriptors and processes on the main thread, with
//! GLib's sources: a handler runs when a pipe or pseudo-terminal has bytes
//! to read, or when a child process exits. Nothing polls.
const std = @import("std");
const gtk = @import("gtk.zig");

pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

const Source = struct {
    ctx: ?*anyopaque,
    handler: Handler,
    id: c_uint = 0,
    canceled: bool = false,
};

/// A source that calls its handler on the main thread until canceled.
pub const Watch = struct {
    source: *Source,

    pub fn cancel(w: Watch) void {
        if (w.source.id != 0) _ = gtk.api.g_source_remove(w.source.id);
        std.heap.c_allocator.destroy(w.source);
    }
};

fn onFd(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const s: *Source = @ptrCast(@alignCast(data));
    s.handler(s.ctx);
    return 1;
}

fn onChild(_: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const s: *Source = @ptrCast(@alignCast(data));
    // GLib removes a child watch once it fired.
    s.id = 0;
    s.handler(s.ctx);
}

/// Calls `handler(ctx)` on the main thread whenever `fd` can be read
/// (and at end of file). The handler reads what is there.
pub fn readable(fd: std.posix.fd_t, ctx: ?*anyopaque, handler: Handler) !Watch {
    if (!gtk.load()) return error.GtkMissing;
    const s = try std.heap.c_allocator.create(Source);
    s.* = .{ .ctx = ctx, .handler = handler };
    // G_IO_IN | G_IO_HUP | G_IO_ERR
    s.id = gtk.api.g_unix_fd_add(fd, 1 | 16 | 8, onFd, s);
    return .{ .source = s };
}

/// Calls `handler(ctx)` on the main thread when process `pid` exits.
pub fn exited(pid: std.posix.pid_t, ctx: ?*anyopaque, handler: Handler) !Watch {
    if (!gtk.load()) return error.GtkMissing;
    const s = try std.heap.c_allocator.create(Source);
    s.* = .{ .ctx = ctx, .handler = handler };
    s.id = gtk.api.g_child_watch_add(pid, onChild, s);
    return .{ .source = s };
}
