//! Private, one-shot metrics delivery. The caller supplies an already-sanitized
//! anonymous aggregate, and calls this only on its background worker. No retry,
//! persistent connection, response content, credentials, cookies, or logging.
const std = @import("std");
const builtin = @import("builtin");
const objc = if (builtin.os.tag == .macos) @import("nanoui").objc else struct {};

pub const endpoint = "https://otel.codegraff.com/v1/metrics";
pub const max_body_bytes = 128 * 1024;
pub const timeout_seconds = 10;

/// True only after a 2xx response head. Response bodies are never consumed.
/// `gpa` and `io` must support background/concurrent use. This module does not
/// establish consent or sanitize payloads: those are the caller's responsibility.
pub fn post(gpa: std.mem.Allocator, io: std.Io, body: []const u8) bool {
    if (!allowedBody(body.len)) return false;
    if (builtin.os.tag == .macos) return Mac.post(body);
    if (builtin.os.tag == .linux or builtin.os.tag == .windows)
        return portablePost(gpa, io, body);
    return false;
}

fn allowedBody(len: usize) bool {
    return len > 0 and len <= max_body_bytes;
}

fn success(status: u16) bool {
    return status >= 200 and status < 300;
}

const Outcome = union(enum) { sent: bool, expired: void };

fn portablePost(gpa: std.mem.Allocator, io: std.Io, body: []const u8) bool {
    var buffer: [2]Outcome = undefined;
    var race: std.Io.Select(Outcome) = .init(io, &buffer);
    // Cancellation joins both tasks before their stack arguments go away.
    defer race.cancelDiscard();
    // Never fall back to an unbounded request if concurrency is unavailable.
    race.concurrent(.expired, expire, .{io}) catch return false;
    race.concurrent(.sent, sendPortable, .{ gpa, io, body }) catch return false;
    return switch (race.await() catch return false) {
        .sent => |ok| ok,
        .expired => false,
    };
}

fn expire(io: std.Io) void {
    io.sleep(.fromSeconds(timeout_seconds), .awake) catch {};
}

fn sendPortable(gpa: std.mem.Allocator, io: std.Io, body: []const u8) bool {
    // Deliberately use std's head-only HTTP/1.1 API here. The pinned http-zig
    // Session.request buffers the entire response, and its requestH1 fallback
    // uses Client.fetch's redirect defaults and drops the supplied headers.
    // Neither behavior is suitable for a credential-free, bounded POST.
    // std verifies the hostname and the OS CA bundle on Linux and Windows.
    // macOS never analyzes this path: release.zig's native-TLS policy survives.
    var client: std.http.Client = .{
        .allocator = gpa,
        .io = io,
        .read_buffer_size = 8 * 1024,
        .write_buffer_size = 1024,
    };
    defer client.deinit();
    var request = client.request(.POST, std.Uri.parse(endpoint) catch return false, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = .omit,
            .user_agent = .{ .override = "harness-metrics" },
            .accept_encoding = .{ .override = "identity" },
            .content_type = .{ .override = "application/json" },
        },
    }) catch return false;
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var writer = request.sendBodyUnflushed(&.{}) catch return false;
    writer.writer.writeAll(body) catch return false;
    writer.end() catch return false;
    request.connection.?.flush() catch return false;
    const response = request.receiveHead(&.{}) catch return false;
    // Do not drain/decompress/allocate a response body, even on an error or
    // redirect. keep_alive=false makes deinit close, rather than drain, it.
    return success(@backingInt(response.head.status));
}

const Mac = if (builtin.os.tag != .macos) struct {} else struct {
    const State = struct {
        // The delegate can outlive post after a timeout. Its state must not use
        // the caller's allocator (which may be torn down as post returns).
        refs: std.atomic.Value(u32) = .init(1),
        sem: objc.dispatch_semaphore_t,
        finished: bool = false, // accessed only on the serial delegate queue
        ok: bool = false, // published to the caller by the semaphore

        fn release(s: *State) void {
            if (s.refs.fetchSub(1, .acq_rel) != 1) return;
            objc.dispatch_release(@ptrCast(s.sem));
            std.heap.page_allocator.destroy(s);
        }

        fn finish(s: *State, ok: bool) void {
            if (s.finished) return;
            s.ok = ok;
            s.finished = true;
            _ = objc.dispatch_semaphore_signal(s.sem);
        }
    };

    var registration: std.atomic.Value(u8) = .init(0);

    fn delegateClass() objc.Class {
        if (registration.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            _ = objc.defineClass(.{
                .name = "HarnessNanoPrivateMetricsDelegate",
                .protocols = &.{ "NSURLSessionDataDelegate", "NSURLSessionTaskDelegate" },
                .methods = &.{
                    .{ .name = "URLSession:dataTask:didReceiveResponse:completionHandler:", .imp = @ptrCast(&received), .types = "v@:@@@@" },
                    .{ .name = "URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:", .imp = @ptrCast(&redirect), .types = "v@:@@@@@" },
                    .{ .name = "URLSession:task:didCompleteWithError:", .imp = @ptrCast(&completed), .types = "v@:@@@" },
                    .{ .name = "URLSession:didReceiveChallenge:completionHandler:", .imp = @ptrCast(&challenge), .types = "v@:@@@" },
                    .{ .name = "URLSession:task:didReceiveChallenge:completionHandler:", .imp = @ptrCast(&taskChallenge), .types = "v@:@@@@" },
                    .{ .name = "dealloc", .imp = @ptrCast(&dealloc), .types = "v@:" },
                },
            });
            registration.store(2, .release);
        } else {
            while (registration.load(.acquire) != 2) std.atomic.spinLoopHint();
        }
        return objc.class("HarnessNanoPrivateMetricsDelegate");
    }

    // ABI prefix shared by Apple's completion blocks, including system-created
    // blocks: never reinterpret their private captured context as objc.Block.
    const Completion = extern struct {
        isa: *anyopaque,
        flags: i32,
        reserved: i32,
        invoke: *const anyopaque,
    };

    fn received(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, response: objc.Object, block: *Completion) callconv(.c) void {
        const status = objc.msg(objc.NSInteger, response, "statusCode", .{});
        const invoke: *const fn (*Completion, objc.NSInteger) callconv(.c) void = @ptrCast(@alignCast(block.invoke));
        // NSURLSessionResponseCancel: stop at the head. No NSData is buffered
        // and no response-content callback is installed, regardless of length.
        if (objc.getZig(State, self)) |s| s.finish(status >= 200 and status < 300);
        invoke(block, 0);
    }

    fn redirect(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, _: objc.Object, _: objc.Object, block: *Completion) callconv(.c) void {
        const invoke: *const fn (*Completion, ?objc.Object) callconv(.c) void = @ptrCast(@alignCast(block.invoke));
        if (objc.getZig(State, self)) |s| s.finish(false);
        invoke(block, null); // Never forward the POST, even to the same host.
    }

    fn completed(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, _: ?objc.Object) callconv(.c) void {
        // Includes DNS/TLS failures and cancellation before a response head.
        // The NSError is neither examined nor retained.
        if (objc.getZig(State, self)) |s| s.finish(false);
    }

    fn challenge(_: objc.Object, _: objc.SEL, _: objc.Object, c: objc.Object, block: *Completion) callconv(.c) void {
        answerChallenge(c, block);
    }

    fn taskChallenge(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, c: objc.Object, block: *Completion) callconv(.c) void {
        answerChallenge(c, block);
    }

    fn answerChallenge(c: objc.Object, block: *Completion) void {
        const space = objc.msg(objc.Object, c, "protectionSpace", .{});
        const method = objc.msg(?objc.Object, space, "authenticationMethod", .{});
        const trust = std.mem.eql(u8, objc.fromNSString(method), "NSURLAuthenticationMethodServerTrust");
        const invoke: *const fn (*Completion, objc.NSInteger, ?objc.Object) callconv(.c) void = @ptrCast(@alignCast(block.invoke));
        // Default system certificate validation only; cancel every credential
        // challenge, including client certificates, Basic, Digest, and NTLM.
        invoke(block, if (trust) 1 else 2, null);
    }

    fn dealloc(self: objc.Object, _: objc.SEL) callconv(.c) void {
        if (objc.getZig(State, self)) |s| {
            objc.setZig(self, null);
            s.release();
        }
        objc.msgSuper(void, self, objc.class("NSObject"), "dealloc", .{});
    }

    extern "c" fn dispatch_time(when: u64, delta: i64) u64;

    fn post(body: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = std.heap.page_allocator.create(State) catch return false;
        s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
        defer s.release();
        const cls = delegateClass();
        const delegate = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
        _ = s.refs.fetchAdd(1, .monotonic);
        objc.setZig(delegate, s);
        defer objc.release(delegate);
        const config = objc.msg(objc.Object, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
        objc.msg(void, config, "setHTTPCookieStorage:", .{@as(?objc.Object, null)});
        objc.msg(void, config, "setHTTPShouldSetCookies:", .{objc.NO});
        objc.msg(void, config, "setURLCredentialStorage:", .{@as(?objc.Object, null)});
        objc.msg(void, config, "setURLCache:", .{@as(?objc.Object, null)});
        objc.msg(void, config, "setRequestCachePolicy:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, config, "setTimeoutIntervalForRequest:", .{@as(f64, timeout_seconds)});
        objc.msg(void, config, "setTimeoutIntervalForResource:", .{@as(f64, timeout_seconds)});
        objc.msg(void, config, "setWaitsForConnectivity:", .{objc.NO});
        const session = objc.retain(objc.msg(objc.Object, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ config, delegate, @as(?objc.Object, null) }));
        defer objc.release(session);
        // Invalidation breaks session -> delegate retention, on success and
        // timeout alike. Delegate dealloc releases its own heap-state reference.
        defer objc.msg(void, session, "invalidateAndCancel", .{});
        const url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(endpoint)});
        const request = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{url});
        objc.msg(void, request, "setHTTPMethod:", .{objc.nsString("POST")});
        objc.msg(void, request, "setHTTPShouldHandleCookies:", .{objc.NO});
        objc.msg(void, request, "setCachePolicy:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, request, "setTimeoutInterval:", .{@as(f64, timeout_seconds)});
        objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ objc.nsString("application/json"), objc.nsString("Content-Type") });
        // Do not let Foundation's default User-Agent add OS/build identifiers.
        objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ objc.nsString("harness-metrics"), objc.nsString("User-Agent") });
        const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ body.ptr, @as(objc.NSUInteger, body.len) });
        objc.msg(void, request, "setHTTPBody:", .{data});
        const task = objc.msg(objc.Object, session, "dataTaskWithRequest:", .{request});
        objc.msg(void, task, "resume", .{});
        if (objc.dispatch_semaphore_wait(s.sem, dispatch_time(0, timeout_seconds * std.time.ns_per_s)) != 0) return false;
        return s.ok;
    }
};

test "metrics transport body gate has a hard inclusive 128 KiB ceiling" {
    try std.testing.expect(!allowedBody(0));
    try std.testing.expect(allowedBody(1));
    try std.testing.expect(allowedBody(max_body_bytes));
    try std.testing.expect(!allowedBody(max_body_bytes + 1));
    try std.testing.expect(!allowedBody(std.math.maxInt(usize)));
}

test "metrics transport accepts only successful response heads, never redirects" {
    for (0..1000) |status| {
        try std.testing.expectEqual(status >= 200 and status < 300, success(@intCast(status)));
    }
}

test "metrics transport rejects invalid payloads before touching I/O" {
    try std.testing.expect(!post(std.testing.allocator, undefined, ""));
    const oversized: [max_body_bytes + 1]u8 = undefined;
    try std.testing.expect(!post(std.testing.allocator, undefined, &oversized));
}

test "metrics mac delegate survives a caller timeout and releases its own state" {
    if (builtin.os.tag != .macos) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = try std.heap.page_allocator.create(Mac.State);
    s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    const cls = Mac.delegateClass();
    const delegate = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
    _ = s.refs.fetchAdd(1, .monotonic);
    objc.setZig(delegate, s);
    // Synthetic timeout: no network, caller drops its reference before a
    // hypothetical late completion. Only the delegate now owns the state.
    s.release();
    Mac.completed(delegate, objc.sel("URLSession:task:didCompleteWithError:"), delegate, delegate, null);
    try std.testing.expectEqual(@as(u32, 1), s.refs.load(.acquire));
    try std.testing.expectEqual(@as(isize, 0), objc.dispatch_semaphore_wait(s.sem, 0));
    try std.testing.expect(!s.ok);
    // A second callback cannot change the result or signal twice.
    s.finish(true);
    try std.testing.expect(!s.ok);
    try std.testing.expect(objc.dispatch_semaphore_wait(s.sem, 0) != 0);
    objc.release(delegate); // dealloc releases/frees state and semaphore
}

test "metrics mac response head cancels content and redirect block receives nil" {
    if (builtin.os.tag != .macos) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = try std.heap.page_allocator.create(Mac.State);
    s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    defer s.release();
    const cls = Mac.delegateClass();
    const delegate = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
    _ = s.refs.fetchAdd(1, .monotonic);
    objc.setZig(delegate, s);
    defer objc.release(delegate);
    const Capture = struct {
        disposition: objc.NSInteger = -1,
        redirect_request: ?objc.Object,
        fn response(c: *@This(), value: objc.NSInteger) void {
            c.disposition = value;
        }
        fn redirected(c: *@This(), request: ?objc.Object) void {
            c.redirect_request = request;
        }
    };
    var capture: Capture = .{ .redirect_request = delegate };
    const url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString("https://example.invalid/synthetic")});
    const response = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{ url, @as(objc.NSInteger, 204), objc.nsString("HTTP/1.1"), @as(?objc.Object, null) });
    defer objc.release(response);
    var response_block = objc.Block(Capture, &.{objc.NSInteger}).init(&capture, Capture.response);
    Mac.received(delegate, objc.sel("URLSession:dataTask:didReceiveResponse:completionHandler:"), delegate, delegate, response, @ptrCast(&response_block));
    try std.testing.expectEqual(@as(objc.NSInteger, 0), capture.disposition);
    try std.testing.expectEqual(@as(isize, 0), objc.dispatch_semaphore_wait(s.sem, 0));
    try std.testing.expect(s.ok);
    Mac.completed(delegate, objc.sel("URLSession:task:didCompleteWithError:"), delegate, delegate, null);
    try std.testing.expect(s.ok); // deliberate content cancellation isn't failure
    // Reset the synthetic delegate for a separate redirect-only transaction.
    s.finished = false;
    var redirect_block = objc.Block(Capture, &.{?objc.Object}).init(&capture, Capture.redirected);
    Mac.redirect(delegate, objc.sel("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:"), delegate, delegate, response, delegate, @ptrCast(&redirect_block));
    try std.testing.expect(capture.redirect_request == null);
    try std.testing.expectEqual(@as(isize, 0), objc.dispatch_semaphore_wait(s.sem, 0));
    try std.testing.expect(!s.ok);
}
