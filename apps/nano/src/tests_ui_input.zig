//! Native text-input events, not only synthetic shortcuts: spaces and
//! Return must work in the composer and the appearance controls.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const appearance = @import("view_settings_appearance.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        theme.registerFonts();
        theme.light_id = "codegraff-light";
        theme.dark_id = "codegraff-dark";
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        appearance.setMode(&h.a, .light);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"input","deviceId":"synthetic","title":"Synthetic input"}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("input", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{
            .width = 1200,
            .height = 880,
            .scale = 2,
            .dark = false,
            .theme = theme.ui(false),
        });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn caretX(h: *const Harness) !f32 {
        const mc = @import("view_composer.zig").message_caret;
        for (h.t.ctx.nodes.items) |n| {
            if (n.content == .none and n.style.absolute and n.style.width == .px and
                n.style.width.px == mc.width and n.style.height == .px and n.style.height.px == 22.75 - 2 * mc.inset)
                return n.rect.x;
        }
        return error.NoComposerCaret;
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

// A real pinned NanoUIView, never ordered on screen. The app/runtime is
// synthetic: no engine startup or persisted settings.
const NativeInput = struct {
    const nanoui = @import("nanoui");
    const objc = nanoui.objc;
    runtime: nanoui.App,
    window: *nanoui.Window,
    a: *App,
    delivered_events: usize = 0,

    fn view(n: *NativeInput, c: *ui.Context) void {
        if (c.input.ops.len > 0 or c.input.key != null or c.input.shortcut != null or c.input.chars.len > 0)
            n.delivered_events += 1;
        @import("view.zig").view(n.a, c);
    }

    fn init(n: *NativeInput, a: *App) !void {
        n.a = a;
        n.delivered_events = 0;
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        n.runtime = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .options = .{ .quit_on_last_window_closed = false },
            .nsapp = nsapp,
            .delegate = nsapp, // Unused: no application delegate is installed.
            .flags = .{ .hidden = true },
        };
        // This second context has not inherited the Tester's focus state.
        a.view.focus_composer = true;
        n.window = try n.runtime.newWindow(.{
            .width = 1200,
            .height = 880,
            .visible = false,
            .theme = theme.ui(false),
            .content = .{ .view = .init(n, NativeInput.view) },
        });
        try testing.expect(!objc.msg(objc.BOOL, n.window.nswindow, "isVisible", .{}));
    }

    fn deinit(n: *NativeInput) void {
        // Other tests may re-enter AppKit later. Close with a live loop so
        // NanoUI defers freeing any surface with an outstanding native tick,
        // then drain that callback while this fixture is still alive.
        n.runtime.running = true;
        n.window.close();
        nanoui.runFor(0.1);
        n.runtime.running = false;
        n.runtime.windows.deinit(testing.allocator);
    }

    const Route = enum { view, window, application };

    fn key(n: *NativeInput, chars: []const u8, code: u16, flags: objc.NSUInteger) void {
        n.routedKey(.view, chars, code, flags);
    }

    fn routedKey(n: *NativeInput, route: Route, chars: []const u8, code: u16, flags: objc.NSUInteger) void {
        const s = n.window.surface.?;
        // Hidden surfaces normally defer frames until visible. Allow just
        // this event's synchronous frame without showing/activating a window.
        if (route != .window) s.ctx.frame = 0;
        const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
            @as(objc.NSUInteger, 10),                                         objc.CGPoint{},          flags,                @as(f64, 0),
            objc.msg(objc.NSInteger, n.window.nswindow, "windowNumber", .{}), @as(?objc.Object, null), objc.nsString(chars), objc.nsString(chars),
            objc.NO,                                                          code,
        });
        if (route != .view) if (n.runtime.main_menu) |menu|
            std.debug.assert(!objc.msg(objc.BOOL, menu.ns, "performKeyEquivalent:", .{event}));
        // In-process dispatch: NOT NSEvent posting, CGEvent or the live app.
        switch (route) {
            .view => objc.msg(void, s.nsview, "keyDown:", .{event}),
            .window => HiddenWindowRouting.send(n.window.nswindow, event),
            .application => n.runningApplicationKey(event),
        }
    }

    const ApplicationEvent = struct {
        native: *NativeInput,
        event: objc.Object,

        fn dispatch(ctx: ?*anyopaque) callconv(.c) void {
            const e: *ApplicationEvent = @ptrCast(@alignCast(ctx.?));
            objc.msg(void, e.native.runtime.nsapp, "sendEvent:", .{e.event});
            // NanoUI posts only an application-defined wake-up to stop its
            // own run loop. The synthetic KEY is never posted anywhere.
            e.native.runtime.quit();
        }
    };

    fn runningApplicationKey(n: *NativeInput, event: objc.Object) void {
        const old_policy = objc.msg(objc.NSInteger, n.runtime.nsapp, "activationPolicy", .{});
        _ = objc.msg(objc.BOOL, n.runtime.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 2)});
        defer _ = objc.msg(objc.BOOL, n.runtime.nsapp, "setActivationPolicy:", .{old_policy});
        var dispatch: ApplicationEvent = .{ .native = n, .event = event };
        objc.dispatchMain(&dispatch, ApplicationEvent.dispatch);
        n.runtime.stopping = false;
        n.runtime.run() catch @panic("hidden native application run failed");
    }
};

// Supply only the surface's visibility/key-status queries for headless
// NSWindow routing with normal frame counts. sendEvent: and keyDown:
// remain their real methods. Nothing is ordered/activated on the desktop.
const HiddenWindowRouting = struct {
    const objc = @import("nanoui").objc;
    extern "c" fn object_getClass(obj: objc.Object) objc.Class;
    extern "c" fn object_setClass(obj: objc.Object, cls: objc.Class) objc.Class;
    extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;
    extern "c" fn objc_allocateClassPair(parent: objc.Class, name: [*:0]const u8, extra: usize) ?objc.Class;
    extern "c" fn objc_registerClassPair(cls: objc.Class) void;
    extern "c" fn class_addMethod(cls: objc.Class, sel: objc.SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
    fn yes(_: objc.Object, _: objc.SEL) callconv(.c) bool {
        return true;
    }

    fn occlusionState(_: objc.Object, _: objc.SEL) callconv(.c) objc.NSUInteger {
        return 2;
    }

    fn subclass(parent: objc.Class, comptime name: [:0]const u8, methods: []const objc.Method) objc.Class {
        if (objc_getClass(name)) |cls| return cls;
        // No ivars: preserve the original object's instance layout.
        const cls = objc_allocateClassPair(parent, name, 0) orelse @panic("class allocation failed");
        for (methods) |m| std.debug.assert(class_addMethod(cls, objc.sel(m.name), m.imp, m.types));
        objc_registerClassPair(cls);
        return cls;
    }

    fn send(window: objc.Object, event: objc.Object) void {
        const original = object_getClass(window);
        const cls = subclass(original, "NanoHiddenRoutingWindow", &.{
            .{ .name = "isKeyWindow", .imp = &yes, .types = "B@:" },
            .{ .name = "occlusionState", .imp = &occlusionState, .types = "Q@:" },
        });
        _ = object_setClass(window, cls);
        defer _ = object_setClass(window, original);
        objc.msg(void, window, "sendEvent:", .{event});
    }
};

const ComposerGeometry = struct {
    pill: ui.Rect,
    field: ui.Rect,
    footer: ui.Rect,
    sidebar: ui.Rect,
    tab: ui.Rect,

    fn capture(h: *Harness) !ComposerGeometry {
        const composer = @import("view_composer.zig");
        var field_index: ?u32 = null;
        for (h.t.ctx.nodes.items, 0..) |n, i| {
            if (n.id == h.a.view.composer_id) field_index = @intCast(i);
        }
        var at = field_index orelse return error.NoComposerField;
        const field = h.t.ctx.node(at).rect;
        while (h.t.ctx.node(at).style.radius != composer.radius) {
            if (at == 0) return error.NoComposerSurface;
            at = h.t.ctx.node(at).parent;
        }
        const pill = h.t.ctx.node(at).rect;
        var footer: ?ui.Rect = null;
        var tab: ?ui.Rect = null;
        const label: []const u8 = if (h.a.selected == null) "New tab" else "Synthetic input";
        for (h.t.ctx.nodes.items) |n| {
            if (@abs(n.rect.x - pill.x) < 1 and @abs(n.rect.w - pill.w) < 1 and n.rect.h == 24) footer = n.rect;
            switch (n.content) {
                .text => |t| if (std.mem.eql(u8, t.str, label) and n.rect.y < 42 and n.rect.x >= h.a.view.sidebar_width) {
                    tab = n.rect;
                },
                else => {},
            }
        }
        return .{
            .pill = pill,
            .field = field,
            .footer = footer orelse return error.NoComposerFooter,
            .sidebar = h.t.findText("All projects") orelse return error.NoSidebarChrome,
            .tab = tab orelse return error.NoTopTabChrome,
        };
    }

    fn expectAnchored(g: ComposerGeometry, before: ComposerGeometry) !void {
        // Use the nodes laid out THIS frame, not composer_anchor (last frame).
        try testing.expectEqualDeep(before.sidebar, g.sidebar);
        try testing.expectEqualDeep(before.tab, g.tab);
        try testing.expectApproxEqAbs(before.pill.x, g.pill.x, 0.5);
        try testing.expectApproxEqAbs(before.pill.w, g.pill.w, 0.5);
        try testing.expectApproxEqAbs(before.pill.y + before.pill.h, g.pill.y + g.pill.h, 0.5);
        try testing.expectApproxEqAbs(g.pill.y + g.pill.h + @import("view_session_footer.zig").gap, g.footer.y, 0.5);
        try testing.expect(g.field.y >= g.pill.y);
        try testing.expect(g.field.y + g.field.h <= g.pill.y + g.pill.h - 32);
    }
};

test "composer multiline geometry stays bottom anchored on every frame in drafts and docked panes" {
    const Scenario = enum { docked, draft, narrow_docked, narrow_draft, stacked_docked, stacked_draft };
    for (std.enums.values(Scenario)) |scenario| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.a.settings.setText("composerSendBehavior", "mod-enter");
        switch (scenario) {
            .draft, .narrow_draft => h.a.newTab(),
            .stacked_draft => h.a.splitPane(.vertical),
            .stacked_docked => {
                h.a.splitPane(.vertical);
                h.a.focusPane(0);
            },
            else => {},
        }
        if (scenario == .narrow_docked or scenario == .narrow_draft) h.t.resize(600 + @import("window_chrome.zig").trailing, 320);
        h.t.settle(1);
        h.t.textOps(&.{.{ .insert = "one suffix" }});
        h.t.settle(1);
        const before = try ComposerGeometry.capture(&h);
        const id = h.a.view.composer_id;
        h.t.textOps(&.{.{ .command = .move_line_start }});
        for (0..3) |_| h.t.textOps(&.{.{ .command = .move_right }});
        // Native Return with the user's newline preference, in the MIDDLE
        // of the draft: rebuilding the field must not send the caret to EOF.
        h.t.textOps(&.{.{ .command = .insert_newline }});
        try testing.expectEqualStrings("one\n suffix", h.a.composer.text());
        try (try ComposerGeometry.capture(&h)).expectAnchored(before);
        h.t.textOps(&.{.{ .insert = "two" }});
        try testing.expectEqualStrings("one\ntwo suffix", h.a.composer.text());
        try testing.expectEqual(id, h.a.view.composer_id);
        try testing.expectEqual(id, h.t.ctx.focus);
        try testing.expectEqual(@as(usize, 7), h.a.view.composer_caret);
        // Observe the transition frames, not only settle()'s final picture.
        for (0..8) |_| {
            try (try ComposerGeometry.capture(&h)).expectAnchored(before);
            h.t.frame();
        }
        try testing.expect((try ComposerGeometry.capture(&h)).pill.h > before.pill.h);
        h.t.textOps(&.{.{ .command = .move_line_end }});
        for (0..8) |_| {
            h.t.textOps(&.{.{ .command = .insert_line_break }});
            try (try ComposerGeometry.capture(&h)).expectAnchored(before);
        }
        const grown = try ComposerGeometry.capture(&h);
        for (0..8) |_| {
            h.t.frame();
            const next = try ComposerGeometry.capture(&h);
            try next.expectAnchored(before);
            try testing.expectEqualDeep(grown.pill, next.pill);
            try testing.expectEqual(id, h.t.ctx.focus);
        }
        // Collapsing back to one line follows the same anchor and identity.
        h.t.textOps(&.{.{ .command = .select_all }});
        h.t.textOps(&.{.{ .insert = "short" }});
        try testing.expectEqual(id, h.a.view.composer_id);
        try testing.expectEqual(id, h.t.ctx.focus);
        const compact = try ComposerGeometry.capture(&h);
        try testing.expectApproxEqAbs(@as(f32, 49), compact.pill.h, 0.5);
        try testing.expectApproxEqAbs(before.pill.y, compact.pill.y, 0.5);
    }
}

test "composer native Return keyDown preserves Shift through AppKit interpretation" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const objc = @import("nanoui").objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    var native: NativeInput = undefined;
    try native.init(&h.a);
    defer native.deinit();
    native.key("one suffix", 0, 0);
    try testing.expectEqualStrings("one suffix", h.a.composer.text());
    const id = h.a.view.composer_id;
    // Select the middle word using native movement/selection selectors.
    for (0..7) |_| native.key("\u{f702}", 123, 0);
    for (0..6) |_| native.key("\u{f703}", 124, 1 << 17);
    native.key("\r", 36, 1 << 17);
    try testing.expectEqualStrings("one\nx", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    try testing.expectEqual(id, h.a.view.composer_id);
    try testing.expectEqual(id, native.window.surface.?.ctx.focus);
    native.key("two", 0, 0);
    try testing.expectEqualStrings("one\ntwox", h.a.composer.text());
    native.key("\r", 36, 0);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    h.a.settings.setText("composerSendBehavior", "mod-enter");
    native.key("new", 0, 0);
    native.key("\r", 36, 0);
    try testing.expectEqualStrings("new\n", h.a.composer.text());
    native.key("\r", 36, 1 << 20);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(@as(usize, 2), h.a.pending_sends.items.len);
    try testing.expect(!objc.msg(objc.BOOL, native.window.nswindow, "isVisible", .{}));
}

fn expectNativeRouting(route: NativeInput.Route) !void {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const objc = @import("nanoui").objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    var native: NativeInput = undefined;
    try native.init(&h.a);
    defer native.deinit();
    const nsapp = native.runtime.nsapp;
    const old_menu = objc.msg(?objc.Object, nsapp, "mainMenu", .{});
    const old_windows_menu = objc.msg(?objc.Object, nsapp, "windowsMenu", .{});
    if (old_menu) |m| _ = objc.retain(m);
    if (old_windows_menu) |m| _ = objc.retain(m);
    defer {
        objc.msg(void, nsapp, "setMainMenu:", .{old_menu});
        objc.msg(void, nsapp, "setWindowsMenu:", .{old_windows_menu});
        if (native.runtime.main_menu) |m| m.destroy();
        if (old_menu) |m| objc.release(m);
        if (old_windows_menu) |m| objc.release(m);
    }
    // Install exactly the production menu, including its key equivalents.
    try @import("native_menu.zig").install(&native.runtime, &h.a);
    native.key("Synthetic routed message", 0, 0);
    try testing.expectEqualStrings("Synthetic routed message", h.a.composer.text());
    native.window.surface.?.ctx.input.shift = false;
    const frame_before = native.window.surface.?.ctx.frame;
    const events_before = native.delivered_events;
    native.routedKey(route, "\r", 36, 1 << 17);
    if (route == .application and native.delivered_events == events_before) {
        // A hidden/inactive NSApplication may ignore the key completely.
        // Do NOT report that as passing application-level input coverage.
        try testing.expectEqualStrings("Synthetic routed message", h.a.composer.text());
        try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
        return error.SkipZigTest;
    }
    if (route == .window) try testing.expect(native.window.surface.?.ctx.frame > frame_before);
    try testing.expectEqualStrings("Synthetic routed message\n", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    try testing.expect(native.window.surface.?.ctx.input.shift);
    native.routedKey(route, "\r", 36, 0);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    h.a.settings.setText("composerSendBehavior", "mod-enter");
    native.routedKey(route, "next", 0, 0);
    native.routedKey(route, "\r", 36, 0);
    try testing.expectEqualStrings("next\n", h.a.composer.text());
    native.routedKey(route, "\r", 36, 1 << 20);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(@as(usize, 2), h.a.pending_sends.items.len);
    try testing.expect(!objc.msg(objc.BOOL, native.window.nswindow, "isVisible", .{}));
}

test "composer native routing preserves Shift Return through NSWindow with production menus" {
    try expectNativeRouting(.window);
}

test "composer native routing through NSApplication requires actual event delivery" {
    try expectNativeRouting(.application);
}

test "composer native Return still sends by default while Shift Return inserts a newline" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // A fixture transport, never a live engine or real persisted chat.
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    h.t.textOps(&.{.{ .insert = "Synthetic message" }});
    // AppKit may produce insertNewline: for Shift-Return, not the
    // already-translated insertLineBreak:. Exercise the modifier too.
    h.t.ctx.input.shift = true;
    h.t.textOps(&.{.{ .command = .insert_newline }});
    h.t.ctx.input.shift = false;
    try testing.expectEqualStrings("Synthetic message\n", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    h.t.textOps(&.{.{ .command = .insert_newline }});
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    h.a.settings.setText("composerSendBehavior", "mod-enter");
    h.t.textOps(&.{.{ .insert = "Synthetic modified submit" }});
    try testing.expect(h.t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(@as(usize, 2), h.a.pending_sends.items.len);
}

test "native composer spaces advance the caret before the next word is typed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.textOps(&.{.{ .insert = "Synthetic" }});
    const before = try h.caretX();
    h.t.textOps(&.{.{ .insert = " " }});
    try testing.expectEqualStrings("Synthetic ", h.a.composer.text());
    const one = try h.caretX();
    h.t.textOps(&.{.{ .insert = " " }});
    const two = try h.caretX();
    h.snap("composer-trailing-spaces");
    try testing.expect(one > before + 2);
    try testing.expect(two > one + 2);
    h.t.textOps(&.{.{ .insert = "website" }});
    try testing.expectEqualStrings("Synthetic  website", h.a.composer.text());
    h.t.textOps(&.{.{ .command = .move_line_start }});
    h.t.textOps(&.{.{ .insert = " " }});
    try testing.expectEqualStrings(" Synthetic  website", h.a.composer.text());
}

test "a long pasted paragraph expands the composer instead of painting over its controls" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const phrase = "Synthetic pasted text must stay inside the input, above the model and send controls. ";
    var buffer: [phrase.len * 18]u8 = undefined;
    for (0..18) |i| @memcpy(buffer[i * phrase.len ..][0..phrase.len], phrase);
    const paragraph: []const u8 = &buffer;
    h.t.textOps(&.{.{ .insert = paragraph }});
    h.t.settle(0.3);
    try testing.expectEqualStrings(paragraph, h.a.composer.text());
    h.snap("composer-pasted-paragraph");
    const pill = h.a.view.composer_anchor.?;
    if (!(pill.h > 100)) std.debug.print("\nlong paste: pill={any}, expanded={}, animating={}, frame_in={any}\n", .{ pill, h.a.view.composer_expanded, h.t.ctx.animating, h.t.ctx.frame_in });
    try testing.expect(pill.h > 100);
    const field = h.t.ctx.rects.get(h.a.view.composer_id) orelse return error.NoComposerField;
    if (!(field.y >= pill.y)) std.debug.print("\nlong paste: field starts above pill: field={any}, pill={any}, animating={}, frame_in={any}\n", .{ field, pill, h.t.ctx.animating, h.t.ctx.frame_in });
    try testing.expect(field.y >= pill.y);
    if (!(field.y + field.h <= pill.y + pill.h - 32)) std.debug.print("\nlong paste: field overlaps controls: field={any}, pill={any}, animating={}, frame_in={any}\n", .{ field, pill, h.t.ctx.animating, h.t.ctx.frame_in });
    try testing.expect(field.y + field.h <= pill.y + pill.h - 32);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.textOps(&.{.{ .command = .select_all }});
    h.t.textOps(&.{.{ .insert = "Short again" }});
    h.t.settle(0.3);
    try testing.expectEqualStrings("Short again", h.a.composer.text());
    if (@abs(h.a.view.composer_anchor.?.h - 49) > 1) std.debug.print("\nshort again: pill={any}, expanded={}, animating={}, frame_in={any}\n", .{ h.a.view.composer_anchor.?, h.a.view.composer_expanded, h.t.ctx.animating, h.t.ctx.frame_in });
    try testing.expectApproxEqAbs(@as(f32, 49), h.a.view.composer_anchor.?.h, 1);
}

const ClipboardFixture = struct {
    text: []const u8 = "",
    image: bool = false,
    reads: usize = 0,

    fn read(raw: ?*anyopaque, gpa: std.mem.Allocator) !?@import("app_attachments.zig").Paste {
        const self: *ClipboardFixture = @ptrCast(@alignCast(raw.?));
        self.reads += 1;
        if (self.image) return .{ .image = try gpa.dupe(u8, @embedFile("icons/project-default.png")) };
        return .{ .text = try gpa.dupe(u8, self.text) };
    }
};

test "composer Paste preserves paragraphs, replaces the selection, and leaves other fields alone" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var clipboard: ClipboardFixture = .{ .text = "First synthetic paragraph\r\n\r\nSecond paragraph\nLast line" };
    h.a.attachments.source = .{ .ctx = &clipboard, .read = ClipboardFixture.read };
    h.t.textOps(&.{.{ .insert = "replace this" }});
    h.t.textOps(&.{.{ .command = .select_all }});
    try testing.expect(h.t.shortcut(.{ .key = 'v', .cmd = true }));
    h.t.settle(0.3);
    try testing.expectEqualStrings("First synthetic paragraph\n\nSecond paragraph\nLast line", h.a.composer.text());
    try testing.expectEqual(@as(usize, 1), clipboard.reads);
    try testing.expect(h.a.view.composer_anchor.?.h > 100);
    h.snap("composer-pasted-paragraphs");
    h.t.ctx.focus = 0;
    try testing.expect(!h.t.shortcut(.{ .key = 'v', .cmd = true }));
    try testing.expectEqual(@as(usize, 1), clipboard.reads);
}

test "a paste beyond the inline limit is kept losslessly as a text attachment" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var bytes: [20 * 1024]u8 = undefined;
    @memset(&bytes, 'x');
    @memcpy(bytes[bytes.len - 12 ..], "complete end");
    var clipboard: ClipboardFixture = .{ .text = &bytes };
    h.a.attachments.source = .{ .ctx = &clipboard, .read = ClipboardFixture.read };
    h.t.textOps(&.{.{ .insert = "Keep this introduction" }});
    try testing.expect(h.t.shortcut(.{ .key = 'v', .cmd = true }));
    h.t.settle(0.3);
    try testing.expectEqualStrings("Keep this introduction", h.a.composer.text());
    try testing.expectEqual(@as(usize, 1), @import("app_attachments.zig").count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("pasted-text.txt", item.name);
    try testing.expectEqualSlices(u8, &bytes, item.bytes);
    // Its tile is the file's icon: the text was never decoded as a picture.
    for (h.t.text.images.decoded.values()) |d| try testing.expect(d != null);
}

test "image Paste stages one removable preview and enables image-only send after upload" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"UploadChunk":{},"UploadCommit":{"path":"/synthetic/uploads/image.png"},"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    var clipboard: ClipboardFixture = .{ .image = true };
    h.a.attachments.source = .{ .ctx = &clipboard, .read = ClipboardFixture.read };
    try testing.expect(h.t.shortcut(.{ .key = 'v', .cmd = true }));
    h.t.settle(0.3);
    const attachments = @import("app_attachments.zig");
    try testing.expectEqual(@as(usize, 1), clipboard.reads);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    try testing.expect(attachments.ready(&h.a));
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expect(h.t.hasText("image.png"));
    h.snap("composer-pasted-image");
    h.a.send();
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    try testing.expect(std.mem.indexOf(u8, h.a.pending_sends.items[0].part.text.items, "/synthetic/uploads/image.png") != null);
}

test "native Return activates the command palette dark theme result" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // Test the theme repaint independently of its default glass treatment.
    h.a.settings.setText("surface", "opaque");
    _ = h.t.shortcut(.{ .key = 'k', .cmd = true });
    h.t.textOps(&.{.{ .insert = "dark" }});
    try testing.expect(h.t.hasText("Switch to dark theme"));
    h.t.textOps(&.{.{ .command = .insert_newline }});
    h.snap("palette-native-dark");
    try testing.expectEqual(true, h.a.dark.?);
    try testing.expectEqualDeep(theme.ui(true).background, h.t.ctx.theme.background);
    try testing.expect(h.a.view.palette.open);
    h.t.textOps(&.{.{ .command = .insert_newline }});
    // The old dark-only query has no matching action after switching.
    try testing.expectEqual(true, h.a.dark.?);
}

test "shortcut Return repaints the selected appearance in the same frame" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.settings.setText("surface", "opaque");
    _ = h.t.shortcut(.{ .key = 'k', .cmd = true });
    h.t.textOps(&.{.{ .insert = "theme" }});
    _ = h.t.shortcut(.{ .key = ui.Shortcut.enter });
    try testing.expectEqual(true, h.a.dark.?);
    try testing.expectEqualDeep(theme.ui(true).background, h.t.ctx.theme.background);
}

test "the theme picker opens and applies a palette without an unrelated input" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .appearance;
    h.t.settle(1);
    const alternate = for (@import("themes.zig").all()) |v| {
        if (!v.dark and !std.mem.eql(u8, v.id, "codegraff-light")) break v;
    } else return error.NoAlternateLightTheme;
    try h.t.clickText("Codegraff Light");
    try testing.expect(h.a.view.theme_menu != null);
    h.snap("theme-picker-open");
    try testing.expect(h.t.hasText(alternate.name));
    try h.t.clickText(alternate.name);
    h.snap("theme-picker-selected");
    try testing.expect(h.a.view.theme_menu == null);
    try testing.expectEqualStrings(alternate.id, h.a.settings.themeId(false));
    const colors = @import("surface_palette.zig").apply(alternate.colors, alternate.colors.recommended_frosted);
    const background: ui.Color = if (colors.frosted) .transparent else colors.shell;
    try testing.expectEqualDeep(background, h.t.ctx.theme.background);
    try testing.expectEqualDeep(colors.composer, h.t.ctx.theme.surface);
}
