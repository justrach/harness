//! Canvases (`ui.canvas`): lines, dashes, triangles and polygons drawn
//! where they should be, clipped to their box, the same on the CPU as with
//! Metal, and a polygon's triangles meeting without a seam; a pinch over
//! one (a map's zoom).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const gpu = @import("gpu.zig");

const P = ui.Point;
const red: ui.Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
const blue: ui.Color = .{ .r = 0, .g = 0, .b = 1, .a = 1 };

pub const Scene = struct {
    pub fn view(_: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(10);
        defer root.end();
        const cv = ui.canvas(c, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 }, .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
        // A thick line across the top, a dashed one under it.
        cv.line(.{ .x = 10, .y = 10 }, .{ .x = 190, .y = 10 }, .{ .width = 6, .color = red });
        cv.line(.{ .x = 10, .y = 30 }, .{ .x = 190, .y = 30 }, .{ .width = 4, .color = blue, .dash = .{ 10, 10 } });
        // A diagonal, running off the box's right edge (clipped).
        cv.line(.{ .x = 20, .y = 140 }, .{ .x = 260, .y = 50 }, .{ .width = 2, .color = blue });
        // An L, filled: its two halves meet along an inner edge.
        const l = [_]P{ .{ .x = 20, .y = 50 }, .{ .x = 80, .y = 50 }, .{ .x = 80, .y = 70 }, .{ .x = 40, .y = 70 }, .{ .x = 40, .y = 120 }, .{ .x = 20, .y = 120 } };
        cv.fill(&l, red);
        cv.circle(.{ .x = 150, .y = 100 }, 12, blue);
    }
};

fn at(p: gpu.Pixels, scale: f32, x: f32, y: f32) [4]u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 ..][0..4].*;
}

// BGRA.
fn isRed(px: [4]u8) bool {
    return px[2] > 240 and px[0] < 15 and px[1] < 15;
}
fn isBlue(px: [4]u8) bool {
    return px[0] > 240 and px[2] < 15 and px[1] < 15;
}
fn isWhite(px: [4]u8) bool {
    return px[0] > 240 and px[1] > 240 and px[2] > 240;
}

test "a canvas draws lines, dashes, a filled polygon and a circle where they are" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 240, .height = 180 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    // The box is at 10, 10.
    try testing.expect(isRed(at(shown, t.scale, 10 + 100, 10 + 10)));
    try testing.expect(isWhite(at(shown, t.scale, 10 + 100, 10 + 16)));
    // Dashes: on from 10 to 20, off from 20 to 30.
    try testing.expect(isBlue(at(shown, t.scale, 10 + 15, 10 + 30)));
    try testing.expect(isWhite(at(shown, t.scale, 10 + 25, 10 + 30)));
    // The L: both arms filled, the notch between them empty.
    try testing.expect(isRed(at(shown, t.scale, 10 + 70, 10 + 60)));
    try testing.expect(isRed(at(shown, t.scale, 10 + 30, 10 + 110)));
    try testing.expect(isWhite(at(shown, t.scale, 10 + 60, 10 + 100)));
    try testing.expect(isBlue(at(shown, t.scale, 10 + 150, 10 + 100)));
    // Clipped at the box's right edge (x 210): the diagonal stops there.
    try testing.expect(!isBlue(at(shown, t.scale, 225, 10 + 62)));
}

test "every pixel inside a filled polygon is wholly filled: no seams between its triangles" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 240, .height = 180 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    // Inside the L by more than a pixel from its outline.
    var y: f32 = 10 + 51.5;
    while (y < 10 + 119) : (y += 0.5) {
        var x: f32 = 10 + 21.5;
        const right: f32 = if (y < 10 + 69) 10 + 79 else 10 + 39;
        while (x < right) : (x += 0.5) {
            const px = at(shown, t.scale, x, y);
            if (!isRed(px)) {
                std.debug.print("seam at {d}, {d}: {any}\n", .{ x, y, px });
                return error.Seam;
            }
        }
    }
}

test "a canvas draws the same on the CPU as with Metal" {
    if (text.portable) return error.SkipZigTest;
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 240, .height = 180 });
    defer t.deinit();
    t.settle(0.1);
    const metal = try t.render(gpa);
    defer metal.deinit(gpa);
    const cpu_bytes = try gpa.alloc(u8, metal.bytes.len);
    defer gpa.free(cpu_bytes);
    const cpu: gpu.Pixels = .{ .bytes = cpu_bytes, .width = metal.width, .height = metal.height };
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, t.text.images.pictures(), t.scale, t.theme.background);
    var total: u64 = 0;
    var off: usize = 0;
    var worst: u8 = 0;
    for (metal.bytes, cpu.bytes) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
        if (d > 8) off += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(metal.bytes.len));
    if (mean >= 0.05 or off * 1000 >= metal.bytes.len) std.debug.print("canvas: mean {d}, worst {d}, off {d} of {d}\n", .{ mean, worst, off, metal.bytes.len });
    try testing.expect(mean < 0.05);
    // Edges may round differently; no more than one channel in a thousand.
    try testing.expect(off * 1000 < metal.bytes.len);
}

const Pinched = struct {
    zoom: f32 = 1,
    pan: ui.Point = .{},
    at: ui.Point = .{},

    pub fn view(p: *Pinched, c: *ui.Context) void {
        if (c.input.zoom != 1 or c.input.pan.x != 0 or c.input.pan.y != 0) {
            p.zoom *= c.input.zoom;
            p.pan = .{ .x = p.pan.x + c.input.pan.x, .y = p.pan.y + c.input.pan.y };
            p.at = c.input.mouse;
        }
        _ = ui.canvas(c, .{ .width = .fill, .height = .fill });
    }
};

test "a pinch comes to the view once, as a zoom and a pan about its middle" {
    const gpa = testing.allocator;
    var p: Pinched = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&p, Pinched.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.frame();
    t.pinch(60, 80, 2, 5, -3);
    t.pinch(60, 80, 1.5, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 3), p.zoom, 1e-5);
    try testing.expectEqual(ui.Point{ .x = 5, .y = -3 }, p.pan);
    try testing.expectEqual(ui.Point{ .x = 60, .y = 80 }, p.at);
    // Consumed: the next frame sees none.
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 3), p.zoom, 1e-5);
}
