//! The requested treatment stays in Settings; accessibility/native support
//! determine the effective material without overwriting that preference.
const builtin = @import("builtin");
const App = @import("app.zig").App;
const Native = if (builtin.os.tag == .macos) @import("surface_native.zig").Native else void;

pub const State = struct {
    native: if (builtin.os.tag == .macos) ?*Native else void = if (builtin.os.tag == .macos) null else {},
    /// Synthetic offscreen scenes never read the machine's preferences.
    reduced_transparency: bool = false,
};

pub fn sync(a: *App, requested: bool, dark: bool) bool {
    if (a.offscreen or a.window == null) return requested and !a.glass.reduced_transparency;
    if (comptime builtin.os.tag == .macos) {
        if (a.glass.native == null) {
            const w = a.window.?;
            const surface = w.surface orelse return false;
            a.glass.native = Native.create(a.gpa, w.nswindow, surface.renderer.layer, .{ .ctx = a, .changed = changed }, .{}) catch return false;
        }
        return a.glass.native.?.sync(requested, dark);
    }
    // No transparent black canvas on platforms without native window blur.
    return false;
}

pub fn deinit(a: *App) void {
    if (comptime builtin.os.tag == .macos) if (a.glass.native) |native| native.destroy();
}

fn changed(ctx: *anyopaque) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    a.redraw();
}
