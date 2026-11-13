//! Grouped alpha must match the CPU renderer, including nested opacity and
//! overlapping content. Background-colored overlays and per-primitive opacity
//! cannot produce these pixels over the two different underlying colors.
const std = @import("std");
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const testing = std.testing;

// Force the platform GPU entry points through semantic analysis in compile-only
// cross-target gates. These are never called by an offscreen Tester test.
export fn nanoui_scroll_fade_check_gl(r: *@import("opengl.zig").Renderer, instances: [*]const gpu.Instance, count: usize) void {
    r.draw(instances[0..count], .{ .w = 140, .h = 110 }, 1, .black, 0, 0);
}
fn checkD3d(r: *@import("d3d11.zig").Renderer, instances: [*]const gpu.Instance, count: usize) callconv(.c) void {
    r.draw(instances[0..count], .{ .w = 140, .h = 110 }, 1, .black, null);
}
comptime {
    if (@import("builtin").os.tag == .windows) @export(&checkD3d, .{ .name = "nanoui_scroll_fade_check_d3d" });
}

const Scene = struct {
    opacity: f32 = 1,
    id: u64 = 0,

    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).size(140, 110);
        defer root.end();
        ui.div(c).absolute().size(70, 110).bg(.hex(0x204060)).end();
        ui.div(c).absolute().offset(70, 0).size(70, 110).bg(.hex(0x603020)).end();
        const parent = ui.div(c).absolute().offset(10, 15).size(100, 80).opacity(s.opacity);
        c.node(parent.index).style.group = true;
        defer parent.end();
        const scroll = ui.div(c).size(100, 80).scrollY();
        c.node(scroll.index).style.scroll_edge_fade = 16;
        c.node(scroll.index).style.scroll_bar = false;
        s.id = c.node(scroll.index).id;
        defer scroll.end();
        const content = ui.div(c).size(100, 200).bg(.hex(0x00ff00));
        defer content.end();
        // Red fully covers green here. A per-primitive fade incorrectly lets
        // green show through red at the hidden edge; a grouped mask does not.
        ui.div(c).absolute().offset(20, 0).size(60, 200).bg(.hex(0xff0000)).end();
    }
};

fn rgb(p: gpu.Pixels, x: usize, y: usize) [3]u8 {
    const at = (y * p.width + x) * 4;
    return .{ p.bytes[at + 2], p.bytes[at + 1], p.bytes[at] };
}

test "scroll fade groups match reference pixels with overlapping content and nested opacity" {
    for ([_]f32{ 1, 0.65 }) |opacity| {
        var scene: Scene = .{ .opacity = opacity };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&scene, Scene.view), .{ .width = 140, .height = 110, .scale = 1 });
        defer t.deinit();
        t.settle(0.1);
        try testing.expectEqual(@as(f32, 120), t.ctx.scroll_max.get(scene.id).?);
        const native = try t.render(testing.allocator);
        defer native.deinit(testing.allocator);
        const cpu: gpu.Pixels = .{ .bytes = try testing.allocator.alloc(u8, native.bytes.len), .width = native.width, .height = native.height };
        defer cpu.deinit(testing.allocator);
        raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, .{}, 1, t.ctx.theme.background);
        var error_max: u32 = 0;
        for (native.bytes, cpu.bytes) |a, b| error_max = @max(error_max, @abs(@as(i32, a) - @as(i32, b)));
        try testing.expect(error_max <= 3);
        for ([_]usize{ 40, 80 }) |x| {
            const base: [3]f32 = if (x < 70) .{ 32, 64, 96 } else .{ 96, 48, 32 };
            for ([_]usize{ 16, 55, 93 }) |y| {
                const fade = @min(@as(f32, 1), (95 - (@as(f32, @floatFromInt(y)) + 0.5)) / 16);
                const alpha = fade * opacity;
                const actual = rgb(native, x, y);
                for (0..3) |channel| {
                    const foreground: f32 = if (channel == 0) 255 else 0;
                    const expected = foreground * alpha + base[channel] * (1 - alpha);
                    try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(actual[channel])), 3);
                }
            }
        }
        // A native hit remains at the actual content location, not on a fake
        // duplicated/hidden UI tree used to manufacture the effect.
        try testing.expect(t.ctx.hits.items.len > 0);
    }
}
