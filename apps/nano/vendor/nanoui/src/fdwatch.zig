//! Watching file descriptors and processes from the main thread, with
//! libdispatch sources: a handler runs when a pipe or pseudo-terminal has
//! bytes to read, or when a child process exits. Nothing polls.
const std = @import("std");
const objc = @import("objc.zig");

const dispatch_source_t = *opaque {};
extern "c" var _dispatch_source_type_read: opaque {};
extern "c" var _dispatch_source_type_proc: opaque {};
extern "c" fn dispatch_source_create(kind: *anyopaque, handle: usize, mask: usize, queue: objc.dispatch_queue_t) ?dispatch_source_t;
extern "c" fn dispatch_set_context(obj: *anyopaque, ctx: ?*anyopaque) void;
extern "c" fn dispatch_source_set_event_handler_f(src: dispatch_source_t, handler: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_resume(obj: *anyopaque) void;
extern "c" fn dispatch_source_cancel(src: dispatch_source_t) void;
extern "c" fn dispatch_release(obj: *anyopaque) void;

const proc_exit: usize = 0x80000000;

pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

/// A source that calls its handler on the main thread until canceled.
pub const Watch = struct {
    source: dispatch_source_t,

    pub fn cancel(w: Watch) void {
        dispatch_source_cancel(w.source);
        dispatch_release(w.source);
    }
};

fn make(kind: *anyopaque, handle: usize, mask: usize, ctx: ?*anyopaque, handler: Handler) !Watch {
    const src = dispatch_source_create(kind, handle, mask, objc.mainQueue()) orelse return error.DispatchSource;
    dispatch_set_context(src, ctx);
    dispatch_source_set_event_handler_f(src, handler);
    dispatch_resume(src);
    return .{ .source = src };
}

/// Calls `handler(ctx)` on the main thread whenever `fd` can be read
/// (and once at end of file). The handler reads what is there.
pub fn readable(fd: std.posix.fd_t, ctx: ?*anyopaque, handler: Handler) !Watch {
    return make(@ptrCast(&_dispatch_source_type_read), @intCast(fd), 0, ctx, handler);
}

/// Calls `handler(ctx)` on the main thread when process `pid` exits.
pub fn exited(pid: std.posix.pid_t, ctx: ?*anyopaque, handler: Handler) !Watch {
    return make(@ptrCast(&_dispatch_source_type_proc), @intCast(pid), proc_exit, ctx, handler);
}
