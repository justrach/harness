//! Real WebKit, hidden and with synthetic pages and an ephemeral data store.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const testing = std.testing;

const Probe = struct {
    changes: usize = 0,
    fn changed(ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.changes += 1;
    }
};

fn prepareAppKit() void {
    _ = nanoui.objc.msg(nanoui.objc.Object, nanoui.objc.class("NSApplication"), "sharedApplication", .{});
}

test "the native Browser renders a generated page without injecting an app bridge" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    prepareAppKit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const id = "0123456789abcdef0123456789abcdef";
    try tmp.dir.createDirPath(testing.io, ".graff/views");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".graff/views/" ++ id ++ ".html", .data = "<!doctype html><title>Synthetic generated page</title><script>document.title='Synthetic page ready'</script><p>Only made-up data.</p>" });
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    var probe: Probe = .{};
    const native = try @import("browser_native.zig").Native.create(testing.allocator, testing.io, home, .{ .ctx = &probe, .changed = Probe.changed });
    defer native.destroy();
    const parent = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = 520, .height = 600 } }});
    defer objc.release(parent);
    native.mount(parent, .{ .x = 0, .y = 38, .w = 520, .h = 500 });
    try testing.expect(native.visible);
    native.navigate("graff-view://html/" ++ id);
    nanoui.runFor(3);
    try testing.expectEqualStrings("Synthetic page ready", native.title());
    try testing.expect(probe.changes > 0);
    const config = objc.msg(objc.Object, native.view, "configuration", .{});
    const content = objc.msg(objc.Object, config, "userContentController", .{});
    const scripts = objc.msg(objc.Object, content, "userScripts", .{});
    try testing.expectEqual(@as(objc.NSUInteger, 0), objc.msg(objc.NSUInteger, scripts, "count", .{}));
    native.show(false);
    try testing.expect(!native.visible);
    try testing.expect(objc.msg(objc.BOOL, native.view, "isHidden", .{}));
}

const Http = struct {
    server: std.Io.net.Server,
    served: std.atomic.Value(bool) = .init(false),

    fn run(h: *Http) void {
        var fds = [_]std.posix.pollfd{.{ .fd = h.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if ((std.posix.poll(&fds, 5000) catch return) <= 0) return;
        const stream = h.server.accept(testing.io) catch return;
        defer stream.close(testing.io);
        var bytes: [4096]u8 = undefined;
        var buffers = [_][]u8{&bytes};
        _ = stream.readWithControl(testing.io, &buffers, &.{}) catch return;
        const page = "<!doctype html><title>Synthetic localhost preview</title><p>A local fixture, not a user project.</p>";
        var buf: [1024]u8 = undefined;
        var writer = stream.writer(testing.io, &buf);
        writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ page.len, page }) catch return;
        writer.interface.flush() catch return;
        h.served.store(true, .release);
    }
};

test "the native Browser loads a real localhost HTTP preview without an engine" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    prepareAppKit();
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var http: Http = .{ .server = try addr.listen(testing.io, .{}) };
    defer http.server.deinit(testing.io);
    const thread = try std.Thread.spawn(.{}, Http.run, .{&http});
    defer thread.join();
    var probe: Probe = .{};
    const native = try @import("browser_native.zig").Native.create(testing.allocator, testing.io, "", .{ .ctx = &probe, .changed = Probe.changed });
    defer native.destroy();
    const address = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/", .{http.server.socket.address.getPort()});
    defer testing.allocator.free(address);
    native.navigate(address);
    nanoui.runFor(3);
    try testing.expect(http.served.load(.acquire));
    try testing.expectEqualStrings("Synthetic localhost preview", native.title());
    try testing.expectEqualStrings(address, native.url());
}
