//! Shared pane-local image gestures. Interpolate inverse scale with the center
//! so the image point beneath the pointer stays put throughout a zoom.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const State = struct {
    inverse: f32 = 1,
    center: ui.Point = .{ .x = 0.5, .y = 0.5 },
};

fn bounded(center: ui.Point, inverse: f32) ui.Point {
    const half = inverse * 0.5;
    return .{
        .x = std.math.clamp(center.x, half, 1 - half),
        .y = std.math.clamp(center.y, half, 1 - half),
    };
}

pub fn update(c: *ui.Context, cache: anytype, hovered: bool, picture: ui.Rect) [4]f32 {
    const shown = &cache.inspection;
    if (hovered) {
        // Own wheel input even at the zoom bounds: never scroll the page below.
        c.wants_wheel = true;
        const factor = @exp(std.math.clamp(c.input.scroll.y * 0.006, -2, 2)) * c.input.zoom;
        if (std.math.isFinite(factor) and factor > 0 and factor != 1) {
            cache.zoom = std.math.clamp(cache.zoom * factor, 1, 4);
            const inverse = 1 / cache.zoom;
            cache.center = bounded(.{
                .x = shown.center.x + (c.input.mouse.x - picture.x - picture.w / 2) / picture.w * (shown.inverse - inverse),
                .y = shown.center.y + (c.input.mouse.y - picture.y - picture.h / 2) / picture.h * (shown.inverse - inverse),
            }, inverse);
            c.changed = true;
        }
        if (c.input.pressed) {
            // Grabbing an animating image starts from its visible position.
            cache.zoom = 1 / shown.inverse;
            cache.center = shown.center;
            cache.drag = c.input.mouse;
        }
    }
    if (!c.input.down) cache.drag = null;
    if (cache.drag) |last| {
        cache.center.x -= (c.input.mouse.x - last.x) / (picture.w * cache.zoom);
        cache.center.y -= (c.input.mouse.y - last.y) / (picture.h * cache.zoom);
        cache.drag = c.input.mouse;
    }
    const inverse = 1 / cache.zoom;
    cache.center = bounded(cache.center, inverse);
    const delta = @max(@abs(shown.inverse - inverse), @max(@abs(shown.center.x - cache.center.x), @abs(shown.center.y - cache.center.y)));
    if (c.reduced_motion or cache.drag != null or delta < 0.0001) {
        shown.* = .{ .inverse = inverse, .center = cache.center };
    } else {
        const alpha = 1 - @exp(-std.math.clamp(c.dt, 0.001, 0.05) / 0.065);
        shown.inverse += (inverse - shown.inverse) * alpha;
        shown.center.x += (cache.center.x - shown.center.x) * alpha;
        shown.center.y += (cache.center.y - shown.center.y) * alpha;
        c.animationFrame();
    }
    const half = shown.inverse * 0.5;
    return .{ shown.center.x - half, shown.center.y - half, shown.center.x + half, shown.center.y + half };
}
