//! Watching pipes and processes from the main thread, the Windows way:
//! anonymous pipes and pseudo consoles can't say when they're readable, so
//! each watch has a thread of its own that blocks (in ReadFile, or waiting on
//! a process) and posts what it got to a message-only window, whose
//! procedure runs the handler on the main thread. Nothing polls.
//!
//! `reader` hands over the bytes read (POSIX's `readable` lets the handler
//! read them itself, which a Windows pipe can't do without blocking).
const std = @import("std");
const w = @import("win32.zig");

pub const HANDLE = *anyopaque;
pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;
/// Bytes read, on the main thread; valid for the call only.
pub const BytesHandler = *const fn (ctx: ?*anyopaque, bytes: []const u8) void;

extern "kernel32" fn CreateThread(attrs: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn CancelSynchronousIo(thread: HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn WaitForMultipleObjects(n: u32, hs: [*]const HANDLE, all: w.BOOL, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) w.BOOL;

const WM_BYTES = 0x8000 + 0x4e1; // WM_APP + …
const WM_DONE = WM_BYTES + 1;
const WM_CALL = WM_BYTES + 2;
const HWND_MESSAGE: isize = -3;
const timeout: u32 = 0x102;

const gpa = std.heap.smp_allocator;

/// What a watch's thread and the main thread share. Freed when both are
/// done with it and no message for it is waiting.
const Source = struct {
    ctx: ?*anyopaque,
    bytes: ?BytesHandler = null,
    done: Handler,
    /// The pipe read, or the process waited on.
    handle: HANDLE,
    thread: ?HANDLE = null,
    /// Set by `cancel`, to end a process wait.
    stop: ?HANDLE = null,
    canceled: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(2),

    fn release(s: *Source) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        if (s.thread) |t| _ = CloseHandle(t);
        if (s.stop) |e| _ = CloseHandle(e);
        gpa.destroy(s);
    }

    /// From the thread: runs on the main thread soon (holding a reference).
    fn post(s: *Source, msg: u32, chunk: ?*Chunk) bool {
        _ = s.refs.fetchAdd(1, .acq_rel);
        const lp: isize = if (chunk) |ch| @bitCast(@intFromPtr(ch)) else @bitCast(@intFromPtr(s));
        if (w.PostMessageW(hwnd.?, msg, @intFromPtr(s), lp) != 0) return true;
        s.release();
        return false;
    }
};

const Chunk = struct { len: usize, data: [64 * 1024]u8 };

/// A watch: its handler runs on the main thread until it is canceled.
pub const Watch = struct {
    source: *Source,

    /// Stops the watch (from the main thread) and waits for its thread
    /// to end; its handlers aren't called after this.
    pub fn cancel(wt: Watch) void {
        const s = wt.source;
        s.canceled.store(true, .release);
        if (s.stop) |e| _ = SetEvent(e);
        if (s.thread) |t| {
            // A read about to start misses one cancel; try until it ends.
            while (WaitForSingleObject(t, 10) == timeout) _ = CancelSynchronousIo(t);
        }
        s.release();
    }
};

var hwnd: ?w.HWND = null;

fn proc_(h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        WM_BYTES => {
            const s: *Source = @ptrFromInt(wp);
            const ch: *Chunk = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (!s.canceled.load(.acquire)) s.bytes.?(s.ctx, ch.data[0..ch.len]);
            gpa.destroy(ch);
            s.release();
        },
        WM_DONE => {
            const s: *Source = @ptrFromInt(wp);
            if (!s.canceled.load(.acquire)) s.done(s.ctx);
            s.release();
        },
        WM_CALL => {
            const func: Handler = @ptrFromInt(wp);
            func(@ptrFromInt(@as(usize, @bitCast(lp))));
        },
        else => return w.DefWindowProcW(h, msg, wp, lp),
    }
    return 0;
}

/// Makes the message window; on the main thread, before `post` is used.
pub fn prepare() !void {
    try window();
}

/// From any thread: `func(ctx)` runs on the main thread soon. False if
/// the window isn't made yet (`prepare`) or the post failed.
pub fn post(ctx: ?*anyopaque, func: Handler) bool {
    const h = hwnd orelse return false;
    return w.PostMessageW(h, WM_CALL, @intFromPtr(func), @bitCast(@intFromPtr(ctx))) != 0;
}

/// The message-only window, made on the main thread the first time.
fn window() !void {
    if (hwnd != null) return;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("nanoui.fdwatch");
    const inst = w.GetModuleHandleW(null);
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = proc_, .hInstance = inst, .lpszClassName = class });
    hwnd = w.CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, @ptrFromInt(@as(usize, @bitCast(HWND_MESSAGE))), null, inst, null) orelse return error.Window;
}

fn readThread(param: ?*anyopaque) callconv(.winapi) u32 {
    const s: *Source = @ptrCast(@alignCast(param));
    while (!s.canceled.load(.acquire)) {
        const ch = gpa.create(Chunk) catch break;
        var n: u32 = 0;
        if (ReadFile(s.handle, &ch.data, ch.data.len, &n, null) == 0 or n == 0) {
            gpa.destroy(ch);
            break;
        }
        ch.len = n;
        if (!s.post(WM_BYTES, ch)) gpa.destroy(ch);
    }
    // The end (or an error, or a cancel): once.
    if (!s.canceled.load(.acquire)) _ = s.post(WM_DONE, null);
    s.release();
    return 0;
}

fn waitThread(param: ?*anyopaque) callconv(.winapi) u32 {
    const s: *Source = @ptrCast(@alignCast(param));
    const hs = [2]HANDLE{ s.handle, s.stop.? };
    if (WaitForMultipleObjects(2, &hs, 0, 0xFFFFFFFF) == 0) _ = s.post(WM_DONE, null);
    s.release();
    return 0;
}

fn start(s: *Source, func: *const fn (?*anyopaque) callconv(.winapi) u32) !Watch {
    s.thread = CreateThread(null, 64 * 1024, func, s, 0, null) orelse {
        if (s.stop) |e| _ = CloseHandle(e);
        gpa.destroy(s);
        return error.Thread;
    };
    return .{ .source = s };
}

/// Reads `handle` (a pipe, a pseudo console's output) until its end:
/// `on_bytes(ctx, bytes)` runs on the main thread with what each read got,
/// then `on_end(ctx)` once. The caller keeps and closes the handle, after
/// canceling.
pub fn reader(handle: HANDLE, ctx: ?*anyopaque, on_bytes: BytesHandler, on_end: Handler) !Watch {
    try window();
    const s = try gpa.create(Source);
    s.* = .{ .ctx = ctx, .bytes = on_bytes, .done = on_end, .handle = handle };
    return start(s, readThread);
}

/// Calls `handler(ctx)` on the main thread when the process (its handle)
/// exits.
pub fn exited(process: HANDLE, ctx: ?*anyopaque, handler: Handler) !Watch {
    try window();
    const s = try gpa.create(Source);
    s.* = .{ .ctx = ctx, .done = handler, .handle = process, .stop = CreateEventW(null, 1, 0, null) orelse {
        gpa.destroy(s);
        return error.Event;
    } };
    return start(s, waitThread);
}

/// File descriptors are a POSIX idea; on Windows, `reader` reads pipes.
pub fn readable(fd: anytype, ctx: ?*anyopaque, handler: Handler) !Watch {
    _ = fd;
    _ = ctx;
    _ = handler;
    return error.Unsupported;
}

extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attrs: ?*anyopaque, size: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) w.BOOL;

const Seen = struct {
    bytes: std.ArrayList(u8) = .empty,
    ended: bool = false,
    fn onBytes(ctx: ?*anyopaque, b: []const u8) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.bytes.appendSlice(std.testing.allocator, b) catch {};
    }
    fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.ended = true;
    }
};

test "a pipe read on the main thread to its end; a canceled watch is quiet" {
    var r: HANDLE = undefined;
    var wr: HANDLE = undefined;
    try std.testing.expect(CreatePipe(&r, &wr, null, 0) != 0);
    var seen: Seen = .{};
    defer seen.bytes.deinit(std.testing.allocator);
    const watch = try reader(r, &seen, Seen.onBytes, Seen.onEnd);
    var n: u32 = 0;
    _ = WriteFile(wr, "hello ", 6, &n, null);
    _ = WriteFile(wr, "world", 5, &n, null);
    _ = CloseHandle(wr);
    var waited: usize = 0;
    while (!seen.ended and waited < 200) : (waited += 1) @import("loop.zig").runFor(0.01);
    watch.cancel();
    _ = CloseHandle(r);
    try std.testing.expect(seen.ended);
    try std.testing.expectEqualStrings("hello world", seen.bytes.items);

    // Canceled while it waits: no handler, and the thread ends.
    var r2: HANDLE = undefined;
    var w2: HANDLE = undefined;
    try std.testing.expect(CreatePipe(&r2, &w2, null, 0) != 0);
    var quiet: Seen = .{};
    const idle = try reader(r2, &quiet, Seen.onBytes, Seen.onEnd);
    @import("loop.zig").runFor(0.05);
    idle.cancel();
    _ = CloseHandle(w2);
    _ = CloseHandle(r2);
    @import("loop.zig").runFor(0.05);
    try std.testing.expect(!quiet.ended and quiet.bytes.items.len == 0);
}
