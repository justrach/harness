//! The same public AppKit material Harness uses: UnderWindowBackground.
//! No emulated lens, desktop capture, per-frame blur, or idle timer.
const std = @import("std");
const objc = @import("nanoui").objc;

extern "c" var NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification: objc.Object;
extern "c" var NSAppearanceNameAqua: objc.Object;
extern "c" var NSAppearanceNameDarkAqua: objc.Object;

pub const Events = struct {
    ctx: *anyopaque,
    changed: *const fn (*anyopaque) void,
};
pub const Options = struct {
    /// Synthetic tests supply this and never consult personal preferences.
    reduce_transparency: ?bool = null,
    observe: bool = true,
};

pub const Native = struct {
    gpa: std.mem.Allocator,
    window: objc.Object,
    layer: objc.Object,
    effect: ?objc.Object = null,
    observer: ?objc.Object = null,
    center: ?objc.Object = null,
    events: Events,
    reduced: bool,
    enabled: bool = false,
    dark: ?bool = null,

    pub fn create(gpa: std.mem.Allocator, window: objc.Object, layer: objc.Object, events: Events, options: Options) !*Native {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Native);
        self.* = .{ .gpa = gpa, .window = window, .layer = layer, .events = events, .reduced = options.reduce_transparency orelse systemReduced() };
        if (options.observe) {
            const cls = objc.defineClass(.{ .name = "HarnessNanoSurfaceObserver", .methods = &.{
                .{ .name = "displayOptionsChanged:", .imp = &displayChanged, .types = "v@:@" },
                .{ .name = "applyDisplayOptions:", .imp = &applyDisplayOptions, .types = "v@:@" },
            } });
            const observer = objc.msg(objc.Object, cls, "new", .{});
            objc.setZig(observer, self);
            self.observer = observer;
            const workspace = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
            const center = objc.msg(objc.Object, workspace, "notificationCenter", .{});
            self.center = center;
            objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("displayOptionsChanged:"), NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification, @as(?objc.Object, null) });
        }
        return self;
    }

    pub fn destroy(self: *Native) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (self.observer) |observer| {
            objc.setZig(observer, null);
            if (self.center) |center| objc.msg(void, center, "removeObserver:", .{observer});
            objc.release(observer);
        }
        _ = self.sync(false, self.dark orelse false);
        if (self.effect) |effect| {
            objc.msg(void, effect, "removeFromSuperview", .{});
            objc.release(effect);
        }
        self.gpa.destroy(self);
    }

    /// Changes native properties only on a material/appearance transition.
    /// An unavailable backing view fails closed to the opaque palette.
    pub fn sync(self: *Native, requested: bool, dark: bool) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        var enabled = requested and !self.reduced;
        if (enabled and self.effect == null) {
            const content = objc.msg(objc.Object, self.window, "contentView", .{});
            if (objc.msg(?objc.Object, content, "superview", .{})) |parent| {
                const effect = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{objc.msg(objc.CGRect, content, "frame", .{})});
                // gpui_macos/window.rs uses exactly these public AppKit enums.
                objc.msg(void, effect, "setMaterial:", .{@as(objc.NSInteger, 21)});
                objc.msg(void, effect, "setBlendingMode:", .{@as(objc.NSInteger, 0)});
                objc.msg(void, effect, "setState:", .{@as(objc.NSInteger, 1)});
                objc.msg(void, effect, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
                objc.msg(void, parent, "addSubview:positioned:relativeTo:", .{ effect, @as(objc.NSInteger, -1), content });
                self.effect = effect;
            } else enabled = false;
        }
        if (self.effect) |effect| {
            if (self.dark == null or self.dark.? != dark) {
                const name = if (dark) NSAppearanceNameDarkAqua else NSAppearanceNameAqua;
                const appearance = objc.msg(objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{name});
                objc.msg(void, effect, "setAppearance:", .{appearance});
            }
            if (enabled != self.enabled) objc.msg(void, effect, "setHidden:", .{!enabled});
        }
        self.dark = dark;
        if (enabled != self.enabled) {
            objc.msg(void, self.window, "setOpaque:", .{!enabled});
            const color = objc.msg(objc.Object, objc.class("NSColor"), if (enabled) "clearColor" else "windowBackgroundColor", .{});
            objc.msg(void, self.window, "setBackgroundColor:", .{color});
            objc.msg(void, self.layer, "setOpaque:", .{!enabled});
            self.enabled = enabled;
        }
        return enabled;
    }

    /// Also used by hidden-window tests: changing accessibility policy is
    /// immediate, event-driven and leaves the user's chosen setting intact.
    pub fn setReduced(self: *Native, reduced: bool) void {
        if (self.reduced == reduced) return;
        self.reduced = reduced;
        self.events.changed(self.events.ctx);
    }
};

fn systemReduced() bool {
    const workspace = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(objc.BOOL, workspace, "accessibilityDisplayShouldReduceTransparency", .{});
}

fn displayChanged(observer: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    _ = objc.getZig(Native, observer) orelse return;
    // AppKit view/window changes and UI redraws belong to the main thread.
    objc.msg(void, observer, "performSelectorOnMainThread:withObject:waitUntilDone:", .{ objc.sel("applyDisplayOptions:"), @as(?objc.Object, null), objc.NO });
}

fn applyDisplayOptions(observer: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const self = objc.getZig(Native, observer) orelse return;
    self.setReduced(systemReduced());
}
