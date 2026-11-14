//! A native window is disposable; the engine, workspace and unsent drafts
//! belong to the long-lived Harness App, including while no window is open.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const file_editor = @import("app_file_editor.zig");

// Posted callbacks carry no borrowed Lifecycle pointer. Teardown unlinks its
// owner before the next event, so a delayed close cannot outlive App storage.
var deferred_head: ?*Lifecycle = null;
var deferred_scheduled = false;

pub const Lifecycle = struct {
    state: *App,
    native: ?*nanoui.App = null,
    navigation: ?*@import("app_external_navigation.zig").State = null,
    pending_exit: ?file_editor.Intent = null,
    pending_next: ?*Lifecycle = null,
    exit_queued: bool = false,

    pub fn options(self: *Lifecycle) nanoui.AppOptions {
        return .{
            .name = "Harness",
            // Other desktops keep their existing last-window quit behavior.
            .quit_on_last_window_closed = builtin.os.tag != .macos,
            .ctx = self,
            .on_reopen = reopen,
            .on_open_urls = openURLs,
            .should_terminate = shouldTerminate,
        };
    }

    fn reopen(ctx: ?*anyopaque) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx orelse return));
        self.open() catch |err| std.log.err("Could not reopen Harness window: {s}", .{@errorName(err)});
    }

    fn showExternal(ctx: *anyopaque) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx));
        self.open() catch |err| std.log.err("Could not open Harness window: {s}", .{@errorName(err)});
    }

    fn openURLs(ctx: ?*anyopaque, urls: []const []const u8) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx orelse return));
        const navigation = self.navigation orelse return;
        if (self.native) |native| if (native.stopping) return;
        self.bindNavigation();
        showExternal(self);
        for (urls) |url| navigation.openURL(self.state, url);
    }

    fn notificationActivated(ctx: *anyopaque, chat: []const u8, workspace: []const u8) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx));
        const navigation = self.navigation orelse return;
        if (self.native) |native| if (native.stopping) return;
        self.bindNavigation();
        // Mount a surface even while identity/chat authority is pending;
        // later engine redraws must have a window in which to settle it.
        showExternal(self);
        navigation.openTarget(self.state, chat, workspace);
    }

    fn bindNavigation(self: *Lifecycle) void {
        const navigation = self.navigation orelse return;
        navigation.presenter = .{ .ctx = self, .show = showExternal };
        @import("native_notification.zig").setActivationHandler(.{ .ctx = self, .activate = notificationActivated });
    }

    fn shouldClose(ctx: *anyopaque, window: *nanoui.Window) bool {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx));
        if (self.state.window != window) return true;
        return file_editor.requestExit(self.state, .window, .{ .ctx = self, .func = finishWindowClose });
    }

    fn shouldTerminate(ctx: ?*anyopaque) bool {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx orelse return true));
        if (self.native == null) return true;
        return file_editor.requestExit(self.state, .quit, .{ .ctx = self, .func = finishQuit });
    }

    fn finishWindowClose(ctx: *anyopaque) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx));
        self.deferExit(.window);
    }

    fn finishQuit(ctx: *anyopaque) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx));
        self.deferExit(.quit);
    }

    fn deferExit(self: *Lifecycle, intent: file_editor.Intent) void {
        if (self.native == null) return;
        self.pending_exit = intent;
        if (!self.exit_queued) {
            self.exit_queued = true;
            self.pending_next = deferred_head;
            deferred_head = self;
        }
        if (!deferred_scheduled) {
            deferred_scheduled = true;
            if (comptime builtin.os.tag == .macos) {
                nanoui.App.soon(null, drainExits);
            } else if (!nanoui.App.onMain(null, drainExits)) {
                deferred_scheduled = false;
            }
        }
    }

    fn cancelDeferred(self: *Lifecycle) void {
        var cursor = &deferred_head;
        while (cursor.*) |item| {
            if (item == self) {
                cursor.* = item.pending_next;
                break;
            }
            cursor = &item.pending_next;
        }
        self.pending_next = null;
        self.pending_exit = null;
        self.exit_queued = false;
    }

    fn closed(ctx: *anyopaque, window: *nanoui.Window) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx));
        if (self.state.window != window) return;
        // on_close runs before nanoui frees Window and its native parent.
        // Keep conversation-owned browser state, but detach its old NSView.
        self.state.window = null;
        self.detachPresentation();
    }

    pub fn open(self: *Lifecycle) !void {
        const native = self.native orelse return;
        if (native.stopping) return;
        self.bindNavigation();
        if (self.state.window) |window| {
            // nanoui's imperative show/focus bypass its hidden creation flag.
            // Snapshot/script runs must remain hidden, including Dock callbacks.
            if (!native.flags.hidden) {
                window.show();
                window.focus();
            }
            return;
        }
        const size = self.state.settings.windowSize();
        self.state.window = try native.newWindow(.{
            .title = "Harness",
            .width = size.width,
            .height = size.height,
            .min_width = 760,
            .min_height = 480,
            .title_bar = .hidden,
            .theme = theme.ui(nanoui.isDark()),
            .on_close = .{ .ctx = self, .func = closed },
            .should_close = .{ .ctx = self, .func = shouldClose },
            .content = .{ .view = blk: {
                var view = nanoui.ui.View.init(self.state, @import("view.zig").view);
                view.after_frame = @import("performance.zig").completed;
                break :blk view;
            } },
        });
    }

    /// Called before App.deinit, even when startup fails. Closing its surface
    /// here also prevents native teardown from holding an already-freed view.
    pub fn detach(self: *Lifecycle) void {
        const native = self.native orelse return;
        file_editor.cancelExit(self.state);
        self.cancelDeferred();
        native.options.should_terminate = null;
        native.options.on_reopen = null;
        native.options.on_open_urls = null;
        native.options.ctx = null;
        @import("native_notification.zig").clearActivationHandler(self);
        if (self.navigation) |navigation| if (navigation.presenter) |presenter| {
            if (presenter.ctx == @as(*anyopaque, @ptrCast(self))) navigation.presenter = null;
        };
        for (native.windows.items) |window| {
            if (window != self.state.window) continue;
            window.on_close = null;
            window.should_close = null;
            self.state.window = null;
            self.detachPresentation();
            window.close();
            break;
        }
        self.state.window = null;
        self.native = null;
    }

    fn detachPresentation(self: *Lifecycle) void {
        if (comptime builtin.os.tag != .macos) return;
        // The glass observer and material own this particular window/layer,
        // unlike browser documents. Recreate them lazily for the next window.
        @import("app_surface.zig").deinit(self.state);
        self.state.glass.native = null;
        for (self.state.panels.tabs.items) |tab| if (tab.browser) |browser| detachBrowser(browser);
        for (self.state.panels.retired.items) |tab| if (tab.browser) |browser| detachBrowser(browser);
        if (self.state.panels.pending_browser) |browser| detachBrowser(browser);
    }

    fn detachBrowser(browser: *@import("app_browser.zig").Browser) void {
        if (comptime builtin.os.tag != .macos) return;
        if (browser.native) |native| {
            native.show(false);
            nanoui.objc.msg(void, native.view, "removeFromSuperview", .{});
            native.attached = false;
            native.rect = null;
        }
    }
};

fn drainExits(_: ?*anyopaque) callconv(.c) void {
    deferred_scheduled = false;
    while (deferred_head) |self| {
        deferred_head = self.pending_next;
        self.pending_next = null;
        self.exit_queued = false;
        const intent = self.pending_exit orelse continue;
        self.pending_exit = null;
        const native = self.native orelse continue;
        if (native.stopping) continue;
        const completion: file_editor.Completion = .{ .ctx = self, .func = if (intent == .quit) Lifecycle.finishQuit else Lifecycle.finishWindowClose };
        // Another editor can become dirty after the dialog's render callback.
        // Revalidate on the next event before disposing its native surface.
        if (!file_editor.requestExit(self.state, intent, completion)) continue;
        if (intent == .quit) native.quit() else if (self.state.window) |window| window.close();
    }
}

test "file editor Linux native window close can be vetoed before disposal" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Probe = struct {
        calls: usize = 0,
        fn veto(ctx: *anyopaque, _: *nanoui.Window) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return false;
        }
    };
    var probe: Probe = .{};
    var window: nanoui.Window = .{ .app = undefined, .gtkwindow = null, .should_close = .{ .ctx = &probe, .func = Probe.veto } };
    window.close();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(!window.closed);
}

test "external navigation lifecycle registers native URL delivery" {
    var state: App = .init(std.testing.allocator, std.testing.io, 1);
    defer state.deinit();
    var lifecycle: Lifecycle = .{ .state = &state };
    try std.testing.expect(lifecycle.options().on_open_urls != null);
}

test "external navigation real native URL delegate reopens hidden window and focuses parked split without replacement" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    @import("theme.zig").registerFonts();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var h: @import("tests_ui_tab_strip.zig").Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.account.scope = .local;
    h.a.chats_synced = true;
    h.a.splitPane(.horizontal);
    h.a.openChat("b", null);
    h.a.newTab();
    h.a.composer.set("Synthetic external source draft");
    var navigation: @import("app_external_navigation.zig").State = .{};
    defer navigation.deinit(testing.allocator);
    var lifecycle: Lifecycle = .{ .state = &h.a, .navigation = &navigation };
    const native = try testNative(&arena, &env, &lifecycle);
    defer native.destroy();
    lifecycle.native = native;
    defer lifecycle.detach();
    var buffer: [256]u8 = undefined;
    const url = @import("view_chat_menu.zig").conversationLink(&buffer, "b", "local").?;
    const nsurl = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)});
    const urls = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{nsurl});
    objc.msg(void, native.delegate, "application:openURLs:", .{ native.nsapp, urls });
    try testing.expect(h.a.window != null);
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, h.a.window.?.nswindow, "isVisible", .{}));
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
    try testing.expect(h.a.tabs.find("a") != null);
    try testing.expectEqualStrings("Synthetic external source draft", h.a.tabs.drafts.items[1].?.text);
    objc.msg(void, native.delegate, "application:openURLs:", .{ native.nsapp, urls });
    try testing.expectEqual(@as(usize, 1), native.windows.items.len);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    lifecycle.detach();
    try testing.expect(native.options.on_open_urls == null);
    try testing.expect(navigation.presenter == null);
}

test "warm native reopen: real close and Dock delegate preserve the same workspace" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var state: App = .init(testing.allocator, testing.io, 1);
    defer state.deinit();
    // No engine socket, settings file or real data. A scene makes requests
    // observable without dialing anything, including if reopen regresses.
    state.offscreen = true;
    state.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    state.engine.state = .connected;
    state.composer.set("Synthetic parked draft");
    @import("app_drafts.zig").leave(&state);
    state.newTab();
    state.composer.set("Synthetic active draft");
    const tab_count = state.tabs.items.items.len;
    const request_count = state.engine.sent.items.len;
    const mux_id = state.engine.mux.next_id;
    var lifecycle: Lifecycle = .{ .state = &state };
    const native = try testNative(&arena, &env, &lifecycle);
    defer native.destroy();
    lifecycle.native = native;
    defer lifecycle.detach();
    try lifecycle.open();
    // Exercise real conversation-owned WebKit and window-owned glass too.
    // The browser uses its test-only nonpersistent store; no URL is loaded.
    const browser = try testing.allocator.create(@import("app_browser.zig").Browser);
    browser.* = .{ .app = &state, .parent = try testing.allocator.dupe(u8, "synthetic-chat") };
    try state.panels.tabs.append(testing.allocator, .{ .kind = .browser, .browser = browser });
    const changed = struct {
        fn noop(_: *anyopaque) void {}
    }.noop;
    browser.native = try @import("browser_native.zig").Native.create(testing.allocator, testing.io, "", .{ .ctx = browser, .changed = changed });
    const browser_native = browser.native.?;
    const browser_rect: nanoui.ui.Rect = .{ .x = 10, .y = 10, .w = 100, .h = 100 };
    browser_native.mount(objc.msg(objc.Object, state.window.?.nswindow, "contentView", .{}), browser_rect);
    state.glass.native = try @import("surface_native.zig").Native.create(testing.allocator, state.window.?.nswindow, state.window.?.surface.?.renderer.layer, .{ .ctx = &state, .changed = changed }, .{ .reduce_transparency = false, .observe = false });
    try testing.expect(state.glass.native.?.sync(true, true));
    // Keep the old NSWindow alive to prove replacement, not allocator-address
    // reuse, after Window itself has been freed by nanoui's close callback.
    const old_nswindow = state.window.?.nswindow;
    _ = objc.retain(old_nswindow);
    defer objc.release(old_nswindow);
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, old_nswindow, "isVisible", .{}));
    // running exercises the last-window quit policy, not just an option bool.
    native.running = true;
    defer native.running = false;
    objc.msg(void, old_nswindow, "performClose:", .{@as(?objc.Object, null)});
    try testing.expectEqual(@as(usize, 0), native.windows.items.len);
    try testing.expect(!native.stopping);
    try testing.expect(state.window == null);
    try testing.expect(state.glass.native == null);
    try testing.expect(browser.native == browser_native);
    try testing.expect(!browser_native.attached);
    try testing.expect(!browser_native.visible);
    try testing.expect(browser_native.rect == null);
    try testing.expect(objc.msg(?objc.Object, browser_native.view, "superview", .{}) == null);
    try testing.expectEqualStrings("Synthetic active draft", state.composer.text());
    try testing.expectEqualStrings("Synthetic parked draft", state.drafts.get("").?);
    const handled = objc.msg(objc.BOOL, native.delegate, "applicationShouldHandleReopen:hasVisibleWindows:", .{ native.nsapp, objc.NO });
    try testing.expectEqual(objc.NO, handled);
    try testing.expect(state.window != null);
    try testing.expectEqual(@as(usize, 1), native.windows.items.len);
    try testing.expect(state.window.?.nswindow != old_nswindow);
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, state.window.?.nswindow, "isVisible", .{}));
    // The exact same WebKit document can mount onto the replacement parent.
    const new_parent = objc.msg(objc.Object, state.window.?.nswindow, "contentView", .{});
    browser_native.mount(new_parent, browser_rect);
    try testing.expectEqual(new_parent, objc.msg(?objc.Object, browser_native.view, "superview", .{}).?);
    // Duplicate reopen while a window exists must not create another one.
    _ = objc.msg(objc.BOOL, native.delegate, "applicationShouldHandleReopen:hasVisibleWindows:", .{ native.nsapp, objc.NO });
    try testing.expectEqual(@as(usize, 1), native.windows.items.len);
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, state.window.?.nswindow, "isVisible", .{}));
    try testing.expectEqual(tab_count, state.tabs.items.items.len);
    try testing.expectEqualStrings("Synthetic parked draft", state.tabs.drafts.items[0].?.text);
    try testing.expect(state.engine.up());
    try testing.expectEqualStrings("Synthetic active draft", state.composer.text());
    try testing.expectEqualStrings("Synthetic parked draft", state.drafts.get("").?);
    try testing.expectEqual(request_count, state.engine.sent.items.len);
    try testing.expectEqual(mux_id, state.engine.mux.next_id);
    try testing.expect(state.engine.thread == null);
    try testing.expect(!state.engine.stopping.load(.acquire));
    // The actual Quit delegate must still stop a warm, windowless app.
    state.window.?.close();
    const response = objc.msg(objc.NSUInteger, native.delegate, "applicationShouldTerminate:", .{native.nsapp});
    try testing.expectEqual(@as(objc.NSUInteger, 0), response);
    try testing.expect(native.stopping);
    _ = objc.msg(objc.BOOL, native.delegate, "applicationShouldHandleReopen:hasVisibleWindows:", .{ native.nsapp, objc.NO });
    try testing.expect(state.window == null);
    lifecycle.detach();
    try testing.expect(native.options.ctx == null);
    try testing.expect(native.options.on_reopen == null);
}

test "file editor production native lifecycle vetoes Quit and defers window disposal safely" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    for ([_]bool{ false, true }) |quitting| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        var h: @import("tests_ui_tab_strip.zig").Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"ReadWorkspaceFile":{"checkoutId":"synthetic-checkout","path":"notes.txt","text":"original","contentHash":"synthetic-hash","size":8,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"status":"written","file":{"path":"notes.txt","contentHash":"synthetic-new-hash","size":12}}}
        , .{});
        h.a.engine.state = .connected;
        @import("app_files.zig").openFile(&h.a, "notes.txt");
        _ = h.a.engine.pump();
        const e = h.a.panels.tabs.items[h.a.panels.active].editor.?;
        e.buffer.set("explicit edit");
        e.changed();
        var lifecycle: Lifecycle = .{ .state = &h.a };
        const native = try testNative(&arena, &env, &lifecycle);
        defer native.destroy();
        lifecycle.native = native;
        defer lifecycle.detach();
        try lifecycle.open();
        const trigger = struct {
            fn request(runtime: *nanoui.App, state: *App, quit: bool) void {
                if (quit) {
                    _ = objc.msg(objc.NSUInteger, runtime.delegate, "applicationShouldTerminate:", .{runtime.nsapp});
                } else objc.msg(void, state.window.?.nswindow, "performClose:", .{@as(?objc.Object, null)});
            }
        }.request;
        trigger(native, &h.a, quitting);
        try testing.expect(!native.stopping and h.a.window != null);
        try testing.expect(h.a.panels.file_close.intent != null);
        file_editor.decide(&h.a, .cancel);
        try testing.expect(e.dirty());
        trigger(native, &h.a, quitting);
        if (quitting) {
            // Pause presentation while issuing the write: a native redraw
            // otherwise pumps this eager scene's acknowledgement immediately.
            // The real window and captured file owner remain unchanged.
            const window = h.a.window;
            h.a.window = null;
            file_editor.decide(&h.a, .save);
            h.a.window = window;
            try testing.expect(e.pending != null and !native.stopping);
            _ = h.a.engine.pump();
            try testing.expect(!native.stopping); // completion is deferred beyond rendering
        } else {
            file_editor.decide(&h.a, .discard);
            try testing.expect(h.a.window != null);
            e.buffer.set("later edit before disposal");
            e.changed();
            nanoui.runFor(0.05);
            try testing.expect(h.a.window != null);
            try testing.expectEqual(file_editor.Intent.window, h.a.panels.file_close.intent.?);
            file_editor.decide(&h.a, .discard);
        }
        nanoui.runFor(0.05);
        if (quitting) {
            try testing.expect(native.stopping);
            try testing.expect(!e.dirty());
        } else {
            try testing.expect(h.a.window == null);
            try testing.expect(!native.stopping);
        }
        lifecycle.detach();
        try testing.expect(deferred_head == null);
        nanoui.runFor(0.01); // detached queued callbacks have no borrowed owner
    }
}

fn testNative(arena: *std.heap.ArenaAllocator, env: *std.process.Environ.Map, lifecycle: *Lifecycle) !*nanoui.App {
    return nanoui.App.create(@as(std.process.Init, .{
        .minimal = .{ .environ = .empty, .args = .{ .vector = &.{ "warm-reopen-test", "--nanoui-hidden" } } },
        .arena = arena,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = env,
        .preopens = .empty,
    }), lifecycle.options());
}

test "warm native reopen: detach live window callbacks before App deinit" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var state: App = .init(testing.allocator, testing.io, 1);
    var state_live = true;
    defer if (state_live) state.deinit();
    state.offscreen = true;
    var lifecycle: Lifecycle = .{ .state = &state };
    const native = try testNative(&arena, &env, &lifecycle);
    defer native.destroy();
    lifecycle.native = native;
    defer lifecycle.detach();
    try lifecycle.open();
    lifecycle.detach();
    try testing.expectEqual(@as(usize, 0), native.windows.items.len);
    try testing.expect(state.window == null);
    try testing.expect(native.options.ctx == null);
    try testing.expect(native.options.on_reopen == null);
    state.deinit();
    state_live = false;
    // Real delegate messages after teardown must never reach a dead App.
    _ = objc.msg(objc.BOOL, native.delegate, "applicationShouldHandleReopen:hasVisibleWindows:", .{ native.nsapp, objc.NO });
    _ = objc.msg(objc.NSUInteger, native.delegate, "applicationShouldTerminate:", .{native.nsapp});
    try testing.expectEqual(@as(usize, 0), native.windows.items.len);
    try testing.expect(native.stopping);
}
