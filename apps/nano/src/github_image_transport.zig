//! Credential-free, bounded image GETs for a background worker only. No UI,
//! cookies, persistent cache, subprocesses, logging, or unchecked redirects.
//! Raster signature/decoder validation is the caller's responsibility.
const std = @import("std");
const builtin = @import("builtin");
const image_url = @import("github_image_url.zig");
const objc = if (builtin.os.tag == .macos) @import("nanoui").objc else struct {};

pub const max_bytes: usize = 4 * 1024 * 1024;
const timeout_seconds = 15;
const max_redirects = 3;

fn validateRedirect(url: []const u8, redirects: usize) !void {
    if (redirects >= max_redirects) return error.TooManyImageRedirects;
    if (!image_url.allowed(url)) return error.ImageRedirectRejected;
}

fn resolveRedirect(gpa: std.mem.Allocator, base: []const u8, location: []const u8, redirects: usize) ![]u8 {
    if (location.len == 0 or location.len > 8192) return error.ImageRedirectRejected;
    // Reject ambiguous/control-bearing Location values before URI resolution.
    for (location) |ch| if (ch <= 0x20 or ch == 0x7f or ch == '\\') return error.ImageRedirectRejected;
    var storage: [32 * 1024]u8 = undefined;
    @memcpy(storage[0..location.len], location);
    var remaining: []u8 = &storage;
    const resolved = std.Uri.resolveInPlace(try std.Uri.parse(base), location.len, &remaining) catch return error.ImageRedirectRejected;
    const url = try std.fmt.allocPrint(gpa, "{f}", .{resolved});
    errdefer gpa.free(url);
    try validateRedirect(url, redirects);
    return url;
}

/// Returns bytes owned by `gpa`. Both `gpa` and `io` must support concurrent
/// background use. Consent and raster sniffing belong to the caller.
pub fn fetch(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    if (!image_url.allowed(url)) return error.DisallowedImageUrl;
    if (builtin.os.tag == .macos) return Mac.fetch(gpa, url);
    if (builtin.os.tag == .linux or builtin.os.tag == .windows)
        return portableFetch(gpa, io, url);
    return error.UnsupportedPlatform;
}

fn boundedLength(current: usize, incoming: usize) !usize {
    // Subtraction first: even adversarial lengths cannot wrap the addition.
    if (current > max_bytes or incoming > max_bytes - current) return error.ImageTooLarge;
    return current + incoming;
}

fn appendBounded(body: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    const length = try boundedLength(body.items.len, bytes.len);
    if (length > body.capacity) {
        const capacity = @min(max_bytes, @max(length, @max(@as(usize, 8 * 1024), body.capacity * 2)));
        // ArrayList's geometric-growth helper can overshoot the ceiling. Choose
        // the capacity ourselves, and validate the length before any allocation.
        try body.ensureTotalCapacityPrecise(gpa, capacity);
    }
    body.appendSliceAssumeCapacity(bytes);
}

const Outcome = union(enum) { done: void, expired: void };
const PortableResult = struct {
    body: ?[]u8 = null,
    failure: anyerror = error.FetchFailed,
};

fn portableFetch(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var result: PortableResult = .{};
    var buffer: [2]Outcome = undefined;
    var race: std.Io.Select(Outcome) = .init(io, &buffer);
    // One timer covers the complete redirect chain, not 15 seconds per hop.
    // Cancellation joins both tasks before their stack arguments go away.
    // The result is stored separately from Select's discarded completion: a
    // simultaneous timeout/success must not leak the successful owned body.
    var joined = false;
    defer if (!joined) race.cancelDiscard();
    race.concurrent(.expired, expire, .{io}) catch return error.ConcurrencyUnavailable;
    race.concurrent(.done, receivePortable, .{ gpa, io, url, &result }) catch return error.ConcurrencyUnavailable;
    const outcome = race.await() catch {
        race.cancelDiscard();
        joined = true;
        if (result.body) |body| gpa.free(body);
        return error.FetchCancelled;
    };
    race.cancelDiscard();
    joined = true;
    if (outcome == .expired) {
        if (result.body) |body| gpa.free(body);
        return error.ImageFetchTimeout;
    }
    return result.body orelse return result.failure;
}

fn expire(io: std.Io) void {
    io.sleep(.fromSeconds(timeout_seconds), .awake) catch {};
}

fn receivePortable(gpa: std.mem.Allocator, io: std.Io, url: []const u8, result: *PortableResult) void {
    result.body = getPortable(gpa, io, url) catch |err| {
        result.failure = err;
        return;
    };
}

fn getPortable(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    // std verifies hostname + the OS CA bundle on Linux/Windows. This path is
    // not analyzed on macOS, which must use native TLS. No shared client state.
    var client: std.http.Client = .{
        .allocator = gpa,
        .io = io,
        .read_buffer_size = 8 * 1024,
        .write_buffer_size = 1024,
    };
    defer client.deinit();
    var current = try gpa.dupe(u8, url);
    defer gpa.free(current);
    var redirects: usize = 0;
    while (true) {
        const hop = try portableHop(&client, gpa, current, redirects);
        switch (hop) {
            .body => |body| return body,
            .redirect => |next| {
                gpa.free(current);
                current = next;
                redirects += 1;
            },
        }
    }
}

const PortableHop = union(enum) { body: []u8, redirect: []u8 };

fn portableHop(client: *std.http.Client, gpa: std.mem.Allocator, url: []const u8, redirects: usize) !PortableHop {
    // A fresh request on every hop: never reuse server-supplied headers or
    // forward Authorization, cookies, Referer, or any other request metadata.
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = .omit,
            .user_agent = .{ .override = "harness-images" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    const status = @backingInt(response.head.status);
    switch (status) {
        301, 302, 303, 307, 308 => {
            const location = response.head.location orelse return error.ImageRedirectRejected;
            return .{ .redirect = try resolveRedirect(gpa, url, location, redirects) };
        },
        else => {},
    }
    if (status < 200 or status >= 300) return error.InvalidImageResponse;
    if (response.head.content_length) |length| {
        if (length > max_bytes) return error.ImageTooLarge;
    }
    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var chunk: [8 * 1024]u8 = undefined;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        try appendBounded(&body, gpa, chunk[0..n]);
    }
    if (body.items.len == 0) return error.EmptyImage;
    return .{ .body = try body.toOwnedSlice(gpa) };
}

const Mac = if (builtin.os.tag != .macos) struct {} else struct {
    const State = struct {
        // Late callbacks after timeout may outlive the caller's allocator.
        refs: std.atomic.Value(u32) = .init(1),
        sem: objc.dispatch_semaphore_t,
        body: std.ArrayList(u8) = .empty,
        finished: bool = false, // serial NSURLSession delegate queue only
        accepted: bool = false,
        redirects: usize = 0,
        failure: ?anyerror = error.FetchFailed, // published by semaphore

        fn release(s: *State) void {
            if (s.refs.fetchSub(1, .acq_rel) != 1) return;
            s.body.deinit(std.heap.page_allocator);
            objc.dispatch_release(@ptrCast(s.sem));
            std.heap.page_allocator.destroy(s);
        }

        fn finish(s: *State, failure: ?anyerror) void {
            if (s.finished) return;
            s.failure = failure;
            s.finished = true;
            _ = objc.dispatch_semaphore_signal(s.sem);
        }
    };

    var registration: std.atomic.Value(u8) = .init(0);

    fn delegateClass() objc.Class {
        if (registration.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            _ = objc.defineClass(.{
                .name = "HarnessNanoGitHubImageDelegate",
                .protocols = &.{ "NSURLSessionDataDelegate", "NSURLSessionTaskDelegate" },
                .methods = &.{
                    .{ .name = "URLSession:dataTask:didReceiveResponse:completionHandler:", .imp = @ptrCast(&received), .types = "v@:@@@@" },
                    .{ .name = "URLSession:dataTask:didReceiveData:", .imp = @ptrCast(&receivedData), .types = "v@:@@@" },
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
        return objc.class("HarnessNanoGitHubImageDelegate");
    }

    const Completion = extern struct {
        isa: *anyopaque,
        flags: i32,
        reserved: i32,
        invoke: *const anyopaque,
    };

    fn received(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, response: objc.Object, block: *Completion) callconv(.c) void {
        const invoke: *const fn (*Completion, objc.NSInteger) callconv(.c) void = @ptrCast(@alignCast(block.invoke));
        var allow = false;
        if (objc.getZig(State, self)) |s| {
            if (!s.finished) {
                const status = objc.msg(objc.NSInteger, response, "statusCode", .{});
                const length = objc.msg(i64, response, "expectedContentLength", .{});
                if (status < 200 or status >= 300) {
                    s.finish(error.InvalidImageResponse);
                } else if (length > max_bytes) {
                    s.finish(error.ImageTooLarge);
                } else {
                    s.accepted = true;
                    allow = true;
                }
            }
        }
        invoke(block, if (allow) 1 else 0); // NSURLSessionResponseAllow / Cancel
    }

    fn receivedData(self: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object, data: objc.Object) callconv(.c) void {
        const s = objc.getZig(State, self) orelse return;
        if (s.finished) return;
        if (!s.accepted) {
            s.finish(error.InvalidImageResponse);
            objc.msg(void, task, "cancel", .{});
            return;
        }
        const length = objc.msg(objc.NSUInteger, data, "length", .{});
        // Check NSData's length before even forming a slice, and before growth.
        _ = boundedLength(s.body.items.len, length) catch {
            s.finish(error.ImageTooLarge);
            objc.msg(void, task, "cancel", .{});
            return;
        };
        if (length == 0) return;
        const bytes = objc.msg([*]const u8, data, "bytes", .{});
        appendBounded(&s.body, std.heap.page_allocator, bytes[0..length]) catch |err| {
            s.finish(err);
            objc.msg(void, task, "cancel", .{});
        };
    }

    fn redirect(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, _: objc.Object, proposed: objc.Object, block: *Completion) callconv(.c) void {
        const invoke: *const fn (*Completion, ?objc.Object) callconv(.c) void = @ptrCast(@alignCast(block.invoke));
        const s = objc.getZig(State, self) orelse return invoke(block, null);
        if (s.finished) return invoke(block, null);
        const url = objc.msg(?objc.Object, proposed, "URL", .{}) orelse {
            s.finish(error.ImageRedirectRejected);
            return invoke(block, null);
        };
        const absolute = objc.msg(?objc.Object, url, "absoluteString", .{});
        validateRedirect(objc.fromNSString(absolute), s.redirects) catch |err| {
            s.finish(err);
            return invoke(block, null);
        };
        s.redirects += 1;
        s.accepted = false;
        // Do not copy NSURLSession's proposed request: it can carry inherited
        // cookies/auth/Referer. Only its separately validated URL survives.
        invoke(block, freshRequest(url));
    }

    fn freshRequest(url: objc.Object) objc.Object {
        const request = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{url});
        objc.msg(void, request, "setHTTPMethod:", .{objc.nsString("GET")});
        objc.msg(void, request, "setHTTPShouldHandleCookies:", .{objc.NO});
        objc.msg(void, request, "setCachePolicy:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, request, "setTimeoutInterval:", .{@as(f64, timeout_seconds)});
        objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ objc.nsString("harness-images"), objc.nsString("User-Agent") });
        objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ objc.nsString("identity"), objc.nsString("Accept-Encoding") });
        return request;
    }

    fn completed(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, failure: ?objc.Object) callconv(.c) void {
        if (objc.getZig(State, self)) |s| {
            if (failure != null) return s.finish(error.FetchFailed);
            if (!s.accepted) return s.finish(error.InvalidImageResponse);
            if (s.body.items.len == 0) return s.finish(error.EmptyImage);
            s.finish(null);
        }
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
        // System trust validation only. Reject client certs, Basic/Digest/NTLM,
        // proxy credentials, and every other authentication challenge.
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

    fn fetch(gpa: std.mem.Allocator, url_text: []const u8) ![]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = try std.heap.page_allocator.create(State);
        s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
        defer s.release();
        const delegate = objc.msg(objc.Object, objc.msg(objc.Object, delegateClass(), "alloc", .{}), "init", .{});
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
        // Break session -> delegate retention on success, failure, and timeout.
        defer objc.msg(void, session, "invalidateAndCancel", .{});
        const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url_text)}) orelse return error.DisallowedImageUrl;
        const request = freshRequest(url);
        const task = objc.msg(objc.Object, session, "dataTaskWithRequest:", .{request});
        objc.msg(void, task, "resume", .{});
        // This single wait bounds the entire task, including every redirect.
        if (objc.dispatch_semaphore_wait(s.sem, dispatch_time(0, timeout_seconds * std.time.ns_per_s)) != 0)
            return error.ImageFetchTimeout;
        if (s.failure) |err| return err;
        // The published body is immutable after finish. Copy to the caller's
        // allocator; late callbacks retain only page-allocated delegate state.
        return try gpa.dupe(u8, s.body.items);
    }
};

test "GitHub image redirects resolve only allowlisted HTTPS destinations and cap all hops" {
    const base = "https://github.com/user-attachments/assets/synthetic-id";
    for ([_][]const u8{
        "https://raw.githubusercontent.com/synthetic/image.png",
        "https://github-production-user-asset-6210df.s3.amazonaws.com/synthetic.png?signature=synthetic",
        "https://github-production-repository-file-5c1aeb.s3.amazonaws.com/synthetic.png?signature=synthetic",
        "/user-attachments/assets/next-id",
        "next-id",
        "//user-images.githubusercontent.com/synthetic/image.png",
    }) |location| {
        for (0..max_redirects) |count| {
            const resolved = try resolveRedirect(std.testing.allocator, base, location, count);
            defer std.testing.allocator.free(resolved);
            try std.testing.expect(image_url.allowed(resolved));
            if (std.mem.eql(u8, location, "next-id") or location[0] == '/') {
                try std.testing.expect(std.mem.startsWith(u8, resolved, "https://"));
            } else try std.testing.expectEqualStrings(location, resolved);
        }
        try std.testing.expectError(error.TooManyImageRedirects, resolveRedirect(std.testing.allocator, base, location, max_redirects));
    }
    const relative = try resolveRedirect(std.testing.allocator, base, "../assets/next-id?signature=synthetic", 0);
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("https://github.com/user-attachments/assets/next-id?signature=synthetic", relative);
    for ([_][]const u8{
        "https://example.invalid/image.png",                         "https://localhost/image.png",                                                             "https://127.0.0.1/image.png",
        "http://raw.githubusercontent.com/synthetic/image.png",      "file:///synthetic.png",                                                                   "https://user:password@raw.githubusercontent.com/synthetic/image.png",
        "https://raw.githubusercontent.com:443/synthetic/image.png", "//example.invalid/image.png",                                                             "../../../login",
        "https://github.com/login",                                  "https://github-production-user-asset-6210df.s3.amazonaws.com.evil.invalid/synthetic.png", "https://raw.githubusercontent.com\\@example.invalid/image.png",
        "\r\nLocation: synthetic",                                   "",
    }) |location| try std.testing.expectError(error.ImageRedirectRejected, resolveRedirect(std.testing.allocator, base, location, 0));
}

test "GitHub image mac redirect delegate refuses unsafe destinations without I/O" {
    if (builtin.os.tag != .macos) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const Capture = struct {
        request: ?objc.Object = null,
        fn redirected(c: *@This(), request: ?objc.Object) void {
            c.request = request;
        }
    };
    for ([_][]const u8{
        "https://example.invalid/image.png",                    "https://localhost/image.png", "https://127.0.0.1/image.png",
        "http://raw.githubusercontent.com/synthetic/image.png", "file:///synthetic.png",       "https://user:password@raw.githubusercontent.com/synthetic/image.png",
        "https://github.com/login",
    }) |destination| {
        const s = try std.heap.page_allocator.create(Mac.State);
        s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
        defer s.release();
        const delegate = objc.msg(objc.Object, objc.msg(objc.Object, Mac.delegateClass(), "alloc", .{}), "init", .{});
        _ = s.refs.fetchAdd(1, .monotonic);
        objc.setZig(delegate, s);
        defer objc.release(delegate);
        const url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(destination)});
        const request = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{url});
        var capture: Capture = .{ .request = request };
        var block = objc.Block(Capture, &.{?objc.Object}).init(&capture, Capture.redirected);
        Mac.redirect(delegate, objc.sel("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:"), delegate, delegate, delegate, request, @ptrCast(&block));
        try std.testing.expect(capture.request == null);
        try std.testing.expect(s.failure.? == error.ImageRedirectRejected);
        try std.testing.expectEqual(@as(usize, 0), s.redirects);
    }
}

test "GitHub image transport rejects disallowed URLs before touching I/O" {
    try std.testing.expectError(error.DisallowedImageUrl, fetch(std.testing.allocator, undefined, "https://example.invalid/image.png"));
    try std.testing.expectError(error.DisallowedImageUrl, fetch(std.testing.allocator, undefined, "file:///synthetic.png"));
}

test "GitHub image transport byte ceiling is inclusive and overflow safe" {
    try std.testing.expectEqual(@as(usize, max_bytes), try boundedLength(max_bytes - 1, 1));
    try std.testing.expectEqual(@as(usize, max_bytes), try boundedLength(0, max_bytes));
    try std.testing.expectError(error.ImageTooLarge, boundedLength(max_bytes, 1));
    try std.testing.expectError(error.ImageTooLarge, boundedLength(1, std.math.maxInt(usize)));
    try std.testing.expectError(error.ImageTooLarge, boundedLength(std.math.maxInt(usize), 0));
}

test "GitHub image transport refuses growth before allocating past its ceiling" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    const bytes = try std.testing.allocator.alloc(u8, max_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 42);
    try appendBounded(&body, std.testing.allocator, bytes);
    try std.testing.expect(body.capacity <= max_bytes);
    const previous_ptr = body.items.ptr;
    try std.testing.expectError(error.ImageTooLarge, appendBounded(&body, std.testing.allocator, "x"));
    try std.testing.expectEqual(@as(usize, max_bytes), body.items.len);
    try std.testing.expect(body.items.ptr == previous_ptr);
    try std.testing.expectEqualSlices(u8, bytes, body.items);
}

test "GitHub image mac delegate streams bytes within its ceiling" {
    if (builtin.os.tag != .macos) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = try std.heap.page_allocator.create(Mac.State);
    s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    defer s.release();
    const delegate = objc.msg(objc.Object, objc.msg(objc.Object, Mac.delegateClass(), "alloc", .{}), "init", .{});
    _ = s.refs.fetchAdd(1, .monotonic);
    objc.setZig(delegate, s);
    defer objc.release(delegate);
    const Capture = struct {
        disposition: objc.NSInteger = -1,
        request: ?objc.Object,
        fn response(c: *@This(), value: objc.NSInteger) void {
            c.disposition = value;
        }
        fn redirected(c: *@This(), request: ?objc.Object) void {
            c.request = request;
        }
    };
    var capture: Capture = .{ .request = delegate };
    const url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString("https://raw.githubusercontent.com/synthetic/image.png")});
    const response = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{ url, @as(objc.NSInteger, 200), objc.nsString("HTTP/1.1"), @as(?objc.Object, null) });
    defer objc.release(response);
    var response_block = objc.Block(Capture, &.{objc.NSInteger}).init(&capture, Capture.response);
    Mac.received(delegate, objc.sel("URLSession:dataTask:didReceiveResponse:completionHandler:"), delegate, delegate, response, @ptrCast(&response_block));
    try std.testing.expectEqual(@as(objc.NSInteger, 1), capture.disposition);
    const bytes = "synthetic";
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) });
    Mac.receivedData(delegate, objc.sel("URLSession:dataTask:didReceiveData:"), delegate, delegate, data);
    Mac.completed(delegate, objc.sel("URLSession:task:didCompleteWithError:"), delegate, delegate, null);
    try std.testing.expectEqual(@as(isize, 0), objc.dispatch_semaphore_wait(s.sem, 0));
    try std.testing.expect(s.failure == null);
    try std.testing.expectEqualSlices(u8, bytes, s.body.items);
}

test "GitHub image redirects accept an allowlisted attachment destination" {
    if (builtin.os.tag != .macos) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = try std.heap.page_allocator.create(Mac.State);
    s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    defer s.release();
    const delegate = objc.msg(objc.Object, objc.msg(objc.Object, Mac.delegateClass(), "alloc", .{}), "init", .{});
    _ = s.refs.fetchAdd(1, .monotonic);
    objc.setZig(delegate, s);
    defer objc.release(delegate);
    const Capture = struct {
        request: ?objc.Object = null,
        fn redirected(c: *@This(), request: ?objc.Object) void {
            c.request = request;
        }
    };
    var capture: Capture = .{};
    var block = objc.Block(Capture, &.{?objc.Object}).init(&capture, Capture.redirected);
    const url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString("https://github-production-user-asset-6210df.s3.amazonaws.com/synthetic.png?signature=synthetic")});
    const request = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{url});
    // Inherited metadata must not survive, even for a same-origin redirect.
    objc.msg(void, request, "setHTTPMethod:", .{objc.nsString("POST")});
    for ([_][]const u8{ "Authorization", "Proxy-Authorization", "Cookie", "Referer", "X-Synthetic" }) |header|
        objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ objc.nsString("synthetic"), objc.nsString(header) });
    for ([_][]const u8{
        "https://github.com/user-attachments/assets/synthetic-next",
        "https://raw.githubusercontent.com/synthetic/image.png",
        "https://github-production-user-asset-6210df.s3.amazonaws.com/synthetic.png?signature=synthetic",
    }, 0..) |destination, i| {
        const next_url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(destination)});
        objc.msg(void, request, "setURL:", .{next_url});
        capture.request = null;
        Mac.redirect(delegate, objc.sel("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:"), delegate, delegate, delegate, request, @ptrCast(&block));
        const clean = capture.request orelse return error.ExpectedRedirectRequest;
        try std.testing.expect(clean != request);
        const clean_url = objc.msg(objc.Object, clean, "URL", .{});
        try std.testing.expectEqualStrings(destination, objc.fromNSString(objc.msg(?objc.Object, clean_url, "absoluteString", .{})));
        try std.testing.expectEqual(i + 1, s.redirects);
        try std.testing.expect(!s.finished);
        try std.testing.expectEqualStrings("GET", objc.fromNSString(objc.msg(?objc.Object, clean, "HTTPMethod", .{})));
        try std.testing.expect(!objc.msg(objc.BOOL, clean, "HTTPShouldHandleCookies", .{}));
        try std.testing.expect(objc.msg(?objc.Object, clean, "HTTPBody", .{}) == null);
        for ([_][]const u8{ "Authorization", "Proxy-Authorization", "Cookie", "Referer", "X-Synthetic" }) |header|
            try std.testing.expect(objc.msg(?objc.Object, clean, "valueForHTTPHeaderField:", .{objc.nsString(header)}) == null);
    }
    Mac.redirect(delegate, objc.sel("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:"), delegate, delegate, delegate, request, @ptrCast(&block));
    try std.testing.expect(capture.request == null);
    try std.testing.expect(s.failure.? == error.TooManyImageRedirects);
    try std.testing.expectEqual(@as(usize, max_redirects), s.redirects);
}

test "GitHub image mac delegate owns bytes after caller timeout and ignores late completion" {
    if (builtin.os.tag != .macos) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = try std.heap.page_allocator.create(Mac.State);
    s.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    const delegate = objc.msg(objc.Object, objc.msg(objc.Object, Mac.delegateClass(), "alloc", .{}), "init", .{});
    _ = s.refs.fetchAdd(1, .monotonic);
    objc.setZig(delegate, s);
    defer objc.release(delegate);
    s.release(); // synthetic timeout: only the delegate retains its state
    try appendBounded(&s.body, std.heap.page_allocator, "synthetic image bytes");
    s.accepted = true;
    s.finish(error.ImageTooLarge);
    Mac.completed(delegate, objc.sel("URLSession:task:didCompleteWithError:"), delegate, delegate, null);
    try std.testing.expectEqual(@as(u32, 1), s.refs.load(.acquire));
    try std.testing.expect(s.failure.? == error.ImageTooLarge);
    try std.testing.expectEqual(@as(isize, 0), objc.dispatch_semaphore_wait(s.sem, 0));
    try std.testing.expect(objc.dispatch_semaphore_wait(s.sem, 0) != 0);
}
