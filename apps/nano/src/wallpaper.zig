//! Original native geometry. No scripting runtime, assets, or animation loop:
//! NanoUI's existing motion store owns the per-pane spring state and frames.
const std = @import("std");
const ui = @import("nanoui").ui;
const Settings = @import("settings.zig").Store;
pub const Scene = enum { none, dusk, dunes };
pub const Reach = enum { off, subtle, normal };

pub fn scene(settings: *const Settings) Scene {
    return std.meta.stringToEnum(Scene, settings.text("newChatWallpaper") orelse "none") orelse .none;
}
pub fn reach(settings: *const Settings) Reach {
    return std.meta.stringToEnum(Reach, settings.text("wallpaperParallax") orelse "subtle") orelse .subtle;
}

pub const Layer = struct {
    id: []const u8,
    rect: ui.Rect,
    color: u24,
    radius: f32 = 0,
    opacity: f32 = 1,
    depth: f32 = 0,
};

/// Value-owned geometry: separate panes need no VM, tree cache or allocator.
pub fn layers(which: Scene, w: f32, h: f32, dark: bool) [5]Layer {
    return switch (which) {
        .none => unreachable, // The host skips disabled wallpapers entirely.
        .dusk => .{
            .{ .id = "sky", .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .color = if (dark) 0x30304d else 0xd9d4ed },
            .{ .id = "moon", .rect = .{ .x = w * 0.76, .y = h * 0.12, .w = 76, .h = 76 }, .radius = 38, .color = if (dark) 0xe4ceb1 else 0xfff1cf, .opacity = 0.65, .depth = 0.2 },
            .{ .id = "far", .rect = .{ .x = -w * 0.22, .y = h * 0.43, .w = w * 1.1, .h = h * 1.4 }, .radius = w * 0.44, .color = if (dark) 0x656088 else 0xb7afce, .depth = 0.6 },
            .{ .id = "middle", .rect = .{ .x = w * 0.43, .y = h * 0.54, .w = w, .h = h * 1.2 }, .radius = w * 0.35, .color = if (dark) 0x494766 else 0x979ab7, .depth = 1 },
            .{ .id = "near", .rect = .{ .x = -w * 0.12, .y = h * 0.77, .w = w * 1.3, .h = h * 1.2 }, .radius = w * 0.38, .color = if (dark) 0x353b51 else 0x818da8, .depth = 1.5 },
        },
        .dunes => .{
            .{ .id = "sky", .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .color = if (dark) 0x494038 else 0xf3dfc3 },
            .{ .id = "sun", .rect = .{ .x = w * 0.71, .y = h * 0.13, .w = 92, .h = 92 }, .radius = 46, .color = if (dark) 0xdbb476 else 0xe9ad61, .opacity = 0.6, .depth = 0.15 },
            .{ .id = "far", .rect = .{ .x = w * 0.15, .y = h * 0.42, .w = w * 1.2, .h = h * 1.7 }, .radius = w * 0.47, .color = if (dark) 0x8f7055 else 0xdeb684, .depth = 0.5 },
            .{ .id = "middle", .rect = .{ .x = -w * 0.42, .y = h * 0.56, .w = w * 1.3, .h = h * 1.6 }, .radius = w * 0.5, .color = if (dark) 0x75503c else 0xc3926c, .depth = 0.9 },
            .{ .id = "near", .rect = .{ .x = w * 0.22, .y = h * 0.74, .w = w * 1.3, .h = h * 1.6 }, .radius = w * 0.45, .color = if (dark) 0x523e34 else 0xa37c66, .depth = 1.5 },
        },
    };
}

/// Non-interactive decoration, drawn only by the new-chat canvas.
pub fn background(c: *ui.Context, settings: *const Settings, host: ui.Div, width: f32, height: f32, dark: bool) void {
    const which = scene(settings);
    if (which == .none) return;
    const rect = c.rects.get(host.id()) orelse ui.Rect{ .x = 0, .y = 0, .w = width, .h = height };
    const mode = settings.text("reduceMotion") orelse "system";
    const reduced = if (std.mem.eql(u8, mode, "on")) true else if (std.mem.eql(u8, mode, "off")) false else c.reduced_motion or c.reduce_motion;
    const p = pointer(rect, c.input.mouse, reach(settings), reduced);
    ui.key(c, "new-chat-wallpaper");
    const box = ui.div(c).absolute().size(width, height).clip().opacity(if (dark) 0.42 else 0.26);
    defer box.end();
    // Scope the Appearance preference without changing other views' policy.
    const system = c.reduced_motion;
    const local = c.reduce_motion;
    c.reduced_motion = reduced;
    c.reduce_motion = reduced;
    defer {
        c.reduced_motion = system;
        c.reduce_motion = local;
    }
    ui.key(c, @tagName(which));
    const art = ui.div(c).absolute().size(width, height);
    defer art.end();
    for (layers(which, width, height, dark)) |layer| {
        ui.key(c, layer.id);
        const motion = ui.motion.frame(c, .{
            .target = .{ .x = (0.5 - p.x) * 22 * layer.depth, .y = (0.5 - p.y) * 12 * layer.depth },
            .transition = .{ .spring = .{ .stiffness = 140, .damping = 20 } },
        });
        const shape = ui.div(c).absolute().offset(layer.rect.x, layer.rect.y).size(layer.rect.w, layer.rect.h)
            .rounded(layer.radius).opacity(layer.opacity).bg(ui.Color.hex(layer.color)).motion(motion);
        shape.end();
    }
}

pub fn pointer(rect: ui.Rect, at: ui.Point, amount: Reach, reduced: bool) ui.Point {
    if (reduced or amount == .off or !rect.contains(at) or rect.w <= 0 or rect.h <= 0) return .{ .x = 0.5, .y = 0.5 };
    const gain: f32 = if (amount == .subtle) 0.45 else 1;
    return .{
        .x = 0.5 + ((at.x - rect.x) / rect.w - 0.5) * gain,
        .y = 0.5 + ((at.y - rect.y) / rect.h - 0.5) * gain,
    };
}
