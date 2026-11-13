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
    try testing.expect(native.allowsBackForwardGestures());
    native.navigate("graff-view://html/" ++ id);
    try testing.expect(!native.allowsBackForwardGestures());
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

const App = @import("app.zig").App;
const Browser = @import("app_browser.zig").Browser;

fn zoomKey(menu: *nanoui.Menu, key: []const u8, code: u16) bool {
    const objc = nanoui.objc;
    const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, @as(objc.NSUInteger, 1 << 20), @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), objc.nsString(key), objc.nsString(key), objc.NO, code,
    });
    return objc.msg(objc.BOOL, menu.ns, "performKeyEquivalent:", .{event});
}

fn fixtureBrowser(a: *App, home: []const u8, parent: nanoui.objc.Object, probe: *Probe) !*Browser {
    @import("app_browser.zig").openLink(a, "zoom-fixture", "http://localhost:31997/synthetic");
    @import("app_browser.zig").settleFrame(a);
    const b = a.panels.tabs.items[a.panels.active].browser.?;
    const n = try @import("browser_native.zig").Native.create(testing.allocator, testing.io, home, .{ .ctx = probe, .changed = Probe.changed });
    b.native = n;
    n.mount(parent, .{ .x = 0, .y = 0, .w = 520, .h = 400 });
    n.navigate("graff-view://html/0123456789abcdef0123456789abcdef");
    return b;
}

test "browser zoom shortcuts route native menu and UI keys to the focused visible WebKit page" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    prepareAppKit();
    @import("theme.zig").registerFonts();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".graff/views");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".graff/views/0123456789abcdef0123456789abcdef.html", .data = "<!doctype html><title>Synthetic zoom fixture</title><p>Made-up zoom target.</p>" });
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    const window = objc.msg(objc.Object, objc.alloc("NSWindow"), "initWithContentRect:styleMask:backing:defer:", .{ objc.CGRect{ .size = .{ .width = 520, .height = 400 } }, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 2), objc.NO });
    defer objc.release(window);
    const parent = objc.msg(objc.Object, window, "contentView", .{});
    // The two paths share App's production routing, not test-only zoom logic.
    for ([_]bool{ true, false }) |native_menu| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        a.openChat("zoom-fixture", null);
        var t: nanoui.ui.Tester = undefined;
        try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1400, .height = 900 });
        defer t.deinit();
        t.settle(1);
        var probe: Probe = .{};
        const inactive = try fixtureBrowser(&a, home, parent, &probe);
        inactive.native.?.show(false);
        const focused = try fixtureBrowser(&a, home, parent, &probe);
        nanoui.runFor(3);
        try testing.expectEqualStrings("Synthetic zoom fixture", focused.native.?.title());
        try testing.expectEqualStrings("Synthetic zoom fixture", inactive.native.?.title());
        const config = objc.msg(objc.Object, focused.native.?.view, "configuration", .{});
        const store = objc.msg(objc.Object, config, "websiteDataStore", .{});
        try testing.expect(!objc.msg(objc.BOOL, store, "isPersistent", .{}));
        const items = @import("native_menu.zig").viewItems(&a);
        const menu = try nanoui.Menu.create(testing.allocator, "Fixture", &.{.{ .role = .view_menu, .submenu = &items }});
        defer menu.destroy();
        for ([_]struct { key: []const u8, code: u16, zoom: f64 }{
            .{ .key = "=", .code = 24, .zoom = 1.1 },
            .{ .key = "-", .code = 27, .zoom = 1.0 },
            .{ .key = "=", .code = 24, .zoom = 1.1 },
            .{ .key = "0", .code = 29, .zoom = 1.0 },
        }) |key| {
            if (native_menu) try testing.expect(zoomKey(menu, key.key, key.code)) else try testing.expect(t.shortcut(.{ .key = key.key[0], .cmd = true }));
            try testing.expectApproxEqAbs(key.zoom, focused.native.?.pageZoom(), 1e-12);
            try testing.expectApproxEqAbs(key.zoom, focused.zoom, 1e-12);
            try testing.expectEqual(@as(f32, 16), a.settings.uiFontSize());
            try testing.expectApproxEqAbs(@as(f64, 1), inactive.native.?.pageZoom(), 1e-12);
        }
        // A click in WebKit changes AppKit's responder without a UI event.
        // Native focus must still win even if the strip last focused chat.
        a.view.strip.focused = .{ .chat = 0 };
        try testing.expect(objc.msg(objc.BOOL, window, "makeFirstResponder:", .{focused.native.?.view}));
        if (native_menu) try testing.expect(zoomKey(menu, "=", 24)) else try testing.expect(t.shortcut(.{ .key = '=', .cmd = true }));
        try testing.expectApproxEqAbs(@as(f64, 1.1), focused.native.?.pageZoom(), 1e-12);
        try testing.expectEqual(@as(f32, 16), a.settings.uiFontSize());
        if (native_menu) try testing.expect(zoomKey(menu, "0", 29)) else try testing.expect(t.shortcut(.{ .key = '0', .cmd = true }));
        try testing.expect(objc.msg(objc.BOOL, window, "makeFirstResponder:", .{@as(?objc.Object, null)}));
        // A visible but unfocused browser, a hidden native view, and a closed
        // host panel must not steal app text zoom. Stale host focus is covered.
        for (0..3) |state| {
            a.panels.host_open = state != 2;
            a.view.strip.focused = if (state == 0) .{ .chat = 0 } else .host;
            focused.native.?.show(state != 1);
            if (native_menu) try testing.expect(zoomKey(menu, "=", 24)) else try testing.expect(t.shortcut(.{ .key = '=', .cmd = true }));
            try testing.expectEqual(@as(f32, 18), a.settings.uiFontSize());
            try testing.expectApproxEqAbs(@as(f64, 1), focused.native.?.pageZoom(), 1e-12);
            if (native_menu) try testing.expect(zoomKey(menu, "0", 29)) else try testing.expect(t.shortcut(.{ .key = '0', .cmd = true }));
            try testing.expectEqual(@as(f32, 16), a.settings.uiFontSize());
        }
    }
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
    try testing.expect(native.allowsBackForwardGestures());
    nanoui.runFor(3);
    try testing.expect(http.served.load(.acquire));
    try testing.expectEqualStrings("Synthetic localhost preview", native.title());
    try testing.expectEqualStrings(address, native.url());
    const Native = @import("browser_native.zig").Native;
    native.setZoom(Native.nextZoom(native.pageZoom(), .out));
    try testing.expectApproxEqAbs(@as(f64, 0.9090909090909091), native.pageZoom(), 1e-12);
    native.setZoom(Native.nextZoom(native.pageZoom(), .in));
    try testing.expectApproxEqAbs(@as(f64, 1.0), native.pageZoom(), 1e-12);
    native.setZoom(Native.nextZoom(native.pageZoom(), .in));
    try testing.expectApproxEqAbs(@as(f64, 1.1), native.pageZoom(), 1e-12);
    native.setZoom(Native.nextZoom(native.pageZoom(), .reset));
    try testing.expectApproxEqAbs(@as(f64, 1.0), native.pageZoom(), 1e-12);
}
