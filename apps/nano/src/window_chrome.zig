//! Platform caption geometry and Windows custom-frame controls.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const App = @import("app.zig").App;

pub fn leadingFor(os: std.Target.Os.Tag) f32 {
    return if (os == .macos) 88 else 8;
}
pub fn trailingFor(os: std.Target.Os.Tag) f32 {
    return if (os == .windows) 46 * 3 else 0;
}
pub const leading = leadingFor(builtin.os.tag);
pub const trailing = trailingFor(builtin.os.tag);
pub const Action = enum { minimize, maximize, close };

extern "user32" fn IsZoomed(hwnd: ?*anyopaque) callconv(.winapi) i32;

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    const zoomed = if (a.window) |w| IsZoomed(w.hwnd) != 0 else false;
    if (buttons(c, k, zoomed)) |action| if (a.window) |w| switch (action) {
        .minimize => w.minimize(),
        .maximize => w.zoom(),
        .close => w.close(),
    };
}

/// Kept callable offscreen on every host: tests exercise the actual caption
/// hit targets, including HTMAXBUTTON for Windows 11 Snap Layouts.
pub fn buttons(c: *ui.Context, k: theme.Colors, zoomed: bool) ?Action {
    const lane = ui.div(c).fixed().offset(c.size.w - trailingFor(.windows), 0)
        .size(trailingFor(.windows), 38).row().layer(10);
    defer lane.end();
    var clicked: ?Action = null;
    inline for (.{ Action.minimize, Action.maximize, Action.close }) |action| {
        ui.key(c, @tagName(action));
        const button = ui.div(c).row().size(46, 38).center().control()
            .hover(if (action == .close) ui.Color.hex(0xc42b1c) else k.hover);
        c.node(button.index).style.window_maximize = action == .maximize;
        defer button.end();
        const ink = if (action == .close and button.hovered()) ui.Color.hex(0xffffff) else k.text;
        const glyph = ui.div(c).size(12, 12);
        defer glyph.end();
        switch (action) {
            .minimize => ui.div(c).absolute().offset(1, 6).size(10, 1).bg(ink).end(),
            .maximize => {
                if (zoomed) ui.div(c).absolute().offset(3, 0).size(9, 9).border(ink).borderW(1).end();
                ui.div(c).absolute().offset(1, if (zoomed) 3 else 1).size(9, 9).bg(k.shell).border(ink).borderW(1).end();
            },
            .close => {
                @import("icons.zig").icon(c, .close, 12, ink, 0);
            },
        }
        if (button.clicked()) clicked = action;
    }
    return clicked;
}

test "Windows caption buttons occupy the trailing lane and emit window actions" {
    const Fixture = struct {
        action: ?Action = null,
        zoomed: bool = false,
        fn view(f: *@This(), c: *ui.Context) void {
            if (buttons(c, theme.colors(true), f.zoomed)) |action| f.action = action;
        }
    };
    @import("theme.zig").registerFonts();
    var f: Fixture = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&f, Fixture.view), .{ .width = 760, .height = 480 });
    defer t.deinit();
    t.settle(0.1);
    try std.testing.expectEqual(.maximize, t.ctx.framePartAt(.{ .x = 691, .y = 19 }, true));
    inline for (.{ Action.minimize, Action.maximize, Action.close }, 0..) |action, i| {
        t.click(760 - 138 + 23 + @as(f32, @floatFromInt(i)) * 46, 19);
        try std.testing.expectEqual(action, f.action.?);
        f.action = null;
    }
    f.zoomed = true;
    t.settle(0.1);
    try std.testing.expectEqual(@as(f32, 88), leadingFor(.macos));
    try std.testing.expectEqual(@as(f32, 8), leadingFor(.windows));
    try std.testing.expectEqual(@as(f32, 8), leadingFor(.linux));
    try std.testing.expectEqual(@as(f32, 0), trailingFor(.macos));
    try std.testing.expectEqual(@as(f32, 138), trailingFor(.windows));
}
