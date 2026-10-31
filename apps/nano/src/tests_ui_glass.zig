//! Glass is a live material, not merely a saved Appearance switch.
//! All content, windows and accessibility policy here are synthetic.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const testing = std.testing;

fn hasTint(t: *ui.Tester, tint: ui.Color) bool {
    for (t.ctx.nodes.items) |n| if (n.style.background) |bg| {
        if (std.meta.eql(bg, tint)) return true;
    };
    return false;
}

test "Frosted glass changes the composer material live and opaque removes it" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = true;
    a.openChat("synthetic-glass", null);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(0.3);
    try testing.expectEqual(@as(f32, 1), t.ctx.theme.background.a);
    const solid = t.ctx.theme.surface;
    a.settings.setText("surface", "frosted");
    t.frame();
    try testing.expectEqual(@as(f32, 0), t.ctx.theme.background.a);
    try testing.expect(t.ctx.theme.surface.a < 1);
    try testing.expect(hasTint(&t, t.ctx.theme.surface));
    const p = try t.render(testing.allocator);
    defer p.deinit(testing.allocator);
    // An empty part of the page must let the native material through;
    // checking styles alone missed the renderer's opaque alpha clear.
    const x: usize = @intFromFloat(900 * t.scale);
    const y: usize = @intFromFloat(200 * t.scale);
    const alpha = p.bytes[(y * p.width + x) * 4 + 3];
    try testing.expect(alpha > 0 and alpha < 255);
    // Empty space below the header must not gain a darker/tinted stripe.
    const fade_y: usize = @intFromFloat(50 * t.scale);
    try testing.expectEqual(alpha, p.bytes[(fade_y * p.width + x) * 4 + 3]);
    // The translucent input must not expose its own two shadow layers.
    const input = a.view.composer_anchor.?;
    const ix: usize = @intFromFloat((input.x + input.w / 2) * t.scale);
    const iy: usize = @intFromFloat((input.y + input.h / 2) * t.scale);
    const tint = t.ctx.theme.surface;
    const shell = @import("surface_palette.zig").apply(@import("theme.zig").colors(true), true).shell;
    const expected_alpha = tint.a + shell.a * (1 - tint.a);
    try testing.expectApproxEqAbs(expected_alpha * 255, @as(f32, @floatFromInt(p.bytes[(iy * p.width + ix) * 4 + 3])), 2);
    a.settings.setText("surface", "opaque");
    t.frame();
    try testing.expectEqual(@as(f32, 1), t.ctx.theme.background.a);
    try testing.expectEqualDeep(solid, t.ctx.theme.surface);
}

test "Reduce Transparency removes all glass without changing the saved preference" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = false;
    a.settings.setText("surface", "frosted");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{});
    defer t.deinit();
    try testing.expectEqual(@as(f32, 0), t.ctx.theme.background.a);
    a.glass.reduced_transparency = true;
    t.frame();
    try testing.expectEqual(@as(f32, 1), t.ctx.theme.background.a);
    try testing.expectEqual(@as(f32, 1), t.ctx.theme.surface.a);
    try testing.expectEqualStrings("frosted", a.settings.text("surface").?);
    a.glass.reduced_transparency = false;
    t.frame();
    try testing.expectEqual(@as(f32, 0), t.ctx.theme.background.a);
}

const Probe = struct {
    changes: usize = 0,
    fn changed(ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.changes += 1;
    }
};

test "hidden macOS window uses Harness's native material and restores an opaque layer" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const window = objc.msg(objc.Object, objc.alloc("NSWindow"), "initWithContentRect:styleMask:backing:defer:", .{
        objc.CGRect{ .size = .{ .width = 480, .height = 360 } }, @as(objc.NSUInteger, 1), @as(objc.NSUInteger, 2), objc.NO,
    });
    objc.msg(void, window, "setReleasedWhenClosed:", .{objc.NO});
    defer objc.release(window);
    const layer = objc.new("CAMetalLayer");
    defer objc.release(layer);
    var probe: Probe = .{};
    const native = try @import("surface_native.zig").Native.create(testing.allocator, window, layer, .{ .ctx = &probe, .changed = Probe.changed }, .{ .reduce_transparency = false, .observe = false });
    defer native.destroy();
    try testing.expect(!objc.msg(objc.BOOL, window, "isVisible", .{}));
    try testing.expect(native.sync(true, false));
    const effect = native.effect.?;
    try testing.expectEqual(@as(objc.NSInteger, 21), objc.msg(objc.NSInteger, effect, "material", .{}));
    try testing.expectEqual(@as(objc.NSInteger, 0), objc.msg(objc.NSInteger, effect, "blendingMode", .{}));
    try testing.expectEqual(@as(objc.NSInteger, 1), objc.msg(objc.NSInteger, effect, "state", .{}));
    try testing.expect(!objc.msg(objc.BOOL, window, "isOpaque", .{}));
    try testing.expect(!objc.msg(objc.BOOL, layer, "isOpaque", .{}));
    // Resizing and dark/light transitions retain the same native view.
    try testing.expect(native.sync(true, true));
    try testing.expectEqual(effect, native.effect.?);
    const appearance = objc.msg(objc.Object, effect, "appearance", .{});
    try testing.expectEqualStrings("NSAppearanceNameDarkAqua", objc.fromNSString(objc.msg(objc.Object, appearance, "name", .{})));
    native.setReduced(true);
    try testing.expectEqual(@as(usize, 1), probe.changes);
    try testing.expect(!native.sync(true, true));
    try testing.expect(objc.msg(objc.BOOL, layer, "isOpaque", .{}));
    try testing.expect(objc.msg(objc.BOOL, effect, "isHidden", .{}));
    native.setReduced(false);
    try testing.expect(native.sync(true, true));
    try testing.expect(!native.sync(false, true));
    try testing.expect(objc.msg(objc.BOOL, window, "isOpaque", .{}));
    try testing.expect(!objc.msg(objc.BOOL, window, "isVisible", .{}));
}
