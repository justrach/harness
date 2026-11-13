//! Bundled, inert Luau scenes. No user scripts, plugin installation or host
//! capabilities. Native NanoUI springs own frames; Lua runs only on input change.
const std = @import("std");
const ui = @import("nanoui").ui;
const luau = @import("nanoui_luau");
const Settings = @import("settings.zig").Store;
const Allocator = std.mem.Allocator;
pub const Scene = enum { none, dusk, dunes };
pub const Reach = enum { off, subtle, normal };

pub fn scene(settings: *const Settings) Scene {
    return std.meta.stringToEnum(Scene, settings.text("newChatWallpaper") orelse "none") orelse .none;
}
pub fn reach(settings: *const Settings) Reach {
    return std.meta.stringToEnum(Reach, settings.text("wallpaperParallax") orelse "subtle") orelse .subtle;
}

pub fn source(which: Scene) []const u8 {
    return switch (which) {
        .none => "return function() return ui.layer{id='empty'} end",
        .dusk => @embedFile("wallpapers/dusk.luau"),
        .dunes => @embedFile("wallpapers/dunes.luau"),
    };
}

const Cache = struct {
    key: u64 = 0,
    frame: u64 = 0,
    arena: ?std.heap.ArenaAllocator = null,
    input: ?luau.Input = null,
    tree: ?luau.Node = null,
    fn clear(self: *Cache) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

pub const State = struct {
    vm: ?*luau.Runtime = null,
    which: Scene = .none,
    failed: bool = false,
    evaluations: usize = 0,
    // Separate leases keep two split panes from freeing each other's tree.
    caches: [8]Cache = @splat(.{}),

    pub fn deinit(self: *State) void {
        if (self.vm) |vm| vm.destroy();
        for (&self.caches) |*cache| cache.clear();
        self.* = .{};
    }

    pub fn prepare(self: *State, gpa: Allocator, which: Scene) void {
        if (which == self.which) return;
        self.deinit();
        self.which = which;
        if (which != .none) self.vm = luau.Runtime.create(gpa, source(which)) catch {
            self.failed = true;
            return;
        };
    }

    pub fn render(self: *State, c: *ui.Context, gpa: Allocator, key: u64, input: luau.Input) ?luau.Node {
        if (self.failed) return null;
        const vm = self.vm orelse return null;
        var slot: ?*Cache = null;
        for (&self.caches) |*cache| if (cache.key == key and cache.arena != null) {
            slot = cache;
            break;
        };
        if (slot == null) for (&self.caches) |*cache| {
            if (cache.arena == null or cache.frame + 1 < c.frame) {
                cache.clear();
                cache.key = key;
                cache.arena = .init(gpa);
                slot = cache;
                break;
            }
        };
        const cache = slot orelse return null;
        if (cache.input) |old| if (std.meta.eql(old, input)) {
            cache.frame = c.frame;
            return cache.tree;
        };
        // A repeated host key in one frame must not release an earlier tree.
        if (cache.tree != null and cache.frame == c.frame) {
            self.evaluations += 1;
            return vm.render(c.alloc(), input) catch {
                self.failed = true;
                return null;
            };
        }
        _ = cache.arena.?.reset(.retain_capacity);
        self.evaluations += 1;
        cache.tree = vm.render(cache.arena.?.allocator(), input) catch {
            self.failed = true;
            return null;
        };
        cache.input = input;
        cache.frame = c.frame;
        return cache.tree;
    }
};

/// A decorative background under the new-chat content. It has no hit regions,
/// cannot steal composer input, and never runs on established conversations.
pub fn background(c: *ui.Context, state: *State, gpa: Allocator, settings: *const Settings, host: ui.Div, width: f32, height: f32, dark: bool) void {
    const which = scene(settings);
    state.prepare(gpa, which);
    if (which == .none) return;
    const rect = c.rects.get(host.id()) orelse ui.Rect{ .x = 0, .y = 0, .w = width, .h = height };
    const mode = settings.text("reduceMotion") orelse "system";
    const reduced = if (std.mem.eql(u8, mode, "on")) true else if (std.mem.eql(u8, mode, "off")) false else c.reduced_motion or c.reduce_motion;
    const p = pointer(rect, c.input.mouse, reach(settings), reduced);
    const input: luau.Input = .{
        .width = width,
        .height = height,
        .pointer_x = p.x,
        .pointer_y = p.y,
        .dark = dark,
        .reduced_motion = reduced,
    };
    const node = state.render(c, gpa, host.id(), input) orelse return;
    ui.key(c, "new-chat-wallpaper");
    const box = ui.div(c).absolute().size(width, height).clip().opacity(if (dark) 0.42 else 0.26);
    defer box.end();
    // Scope the existing Appearance preference to this decorative subtree;
    // don't overwrite the system's Reduce Motion state for other views.
    const system = c.reduced_motion;
    const local = c.reduce_motion;
    c.reduced_motion = reduced;
    c.reduce_motion = reduced;
    defer {
        c.reduced_motion = system;
        c.reduce_motion = local;
    }
    luau.draw(c, node);
}

pub fn pointer(rect: ui.Rect, at: ui.Point, amount: Reach, reduced: bool) ui.Point {
    if (reduced or amount == .off or !rect.contains(at) or rect.w <= 0 or rect.h <= 0) return .{ .x = 0.5, .y = 0.5 };
    const gain: f32 = if (amount == .subtle) 0.45 else 1;
    return .{
        .x = 0.5 + ((at.x - rect.x) / rect.w - 0.5) * gain,
        .y = 0.5 + ((at.y - rect.y) / rect.h - 0.5) * gain,
    };
}
