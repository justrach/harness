//! Textures the app gives a frame (`ui.texture`, a video's frames): the
//! CPU renderer draws what Metal draws, a CVPixelBuffer draws as its bytes
//! do, and `uv` shows only that part of it (a zoom).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");

const w = 64;
const h = 48;

/// A test card: a gradient with a white square in its top-left quarter.
fn card() [w * h * 4]u8 {
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        const white = x >= 4 and x < 20 and y >= 4 and y < 20;
        px[i + 0] = if (white) 255 else @intCast(x * 4); // b
        px[i + 1] = if (white) 255 else @intCast(y * 5); // g
        px[i + 2] = if (white) 255 else 200; // r
        px[i + 3] = 255;
    };
    return px;
}

const Scene = struct {
    source: ui.Texture,
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(10);
        defer root.end();
        ui.texture(c, .{ .width = .{ .px = 128 }, .height = .{ .px = 96 }, .radius = 12 }, s.source, s.uv, 1);
    }
};

fn at(p: @import("gpu.zig").Pixels, scale: f32, x: f32, y: f32) [4]u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 ..][0..4].*;
}

test "a texture draws the same on the CPU and with Metal; uv shows a part" {
    const gpa = testing.allocator;
    const px = card();
    var s: Scene = .{ .source = .{ .width = w, .height = h, .bgra = &px } };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 160, .height = 120 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    // The white square at the card's top left (texels 4 to 20 of 64, 48).
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(shown, t.scale, 10 + 12 * 2, 10 + 12 * 2));
    // A corner, rounded away: the background shows.
    try testing.expect(at(shown, t.scale, 11, 11)[2] != 200);
    if (!text.portable) {
        var pictures = t.text.images.pictures();
        pictures.textures = t.ctx.textures.items;
        const cpu = try gpa.alloc(u8, shown.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = shown.width, .height = shown.height }, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, t.scale, t.theme.background);
        var total: u64 = 0;
        for (cpu, shown.bytes) |a, b| total += if (a > b) a - b else b - a;
        try testing.expect(@as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu.len)) < 1.5);
    }
    // Zoomed: uv the top-left quarter, so the square fills more of the box.
    s.uv = .{ 0, 0, 0.5, 0.5 };
    t.settle(0.1);
    const zoomed = try t.render(gpa);
    defer zoomed.deinit(gpa);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(zoomed, t.scale, 10 + 50, 10 + 50));
}

extern "c" fn CVPixelBufferCreate(allocator: ?*anyopaque, width: usize, height: usize, format: u32, attrs: ?*anyopaque, out: *?*anyopaque) i32;
extern "c" fn CVPixelBufferLockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: *anyopaque) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: *anyopaque) usize;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" const kCVPixelBufferMetalCompatibilityKey: *anyopaque;
extern "c" const kCVPixelBufferIOSurfacePropertiesKey: *anyopaque;

test "a CVPixelBuffer draws as its bytes do" {
    if (text.portable) return error.SkipZigTest;
    const objc = @import("../objc.zig");
    const gpa = testing.allocator;
    const px = card();
    const keys = [2]*anyopaque{ kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey };
    const values = [2]objc.Object{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) };
    const attrs = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ @as(*const anyopaque, &values), @as(*const anyopaque, &keys), @as(objc.NSUInteger, 2) });
    var pb: ?*anyopaque = null;
    try testing.expectEqual(@as(i32, 0), CVPixelBufferCreate(null, w, h, std.mem.readInt(u32, "BGRA", .big), @ptrCast(attrs), &pb));
    defer CFRelease(pb.?);
    _ = CVPixelBufferLockBaseAddress(pb.?, 0);
    const base = CVPixelBufferGetBaseAddress(pb.?).?;
    const stride = CVPixelBufferGetBytesPerRow(pb.?);
    for (0..h) |y| @memcpy(base[y * stride ..][0 .. w * 4], px[y * w * 4 ..][0 .. w * 4]);
    _ = CVPixelBufferUnlockBaseAddress(pb.?, 0);

    var s: Scene = .{ .source = .{ .width = w, .height = h, .bgra = &px } };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 160, .height = 120 });
    defer t.deinit();
    t.settle(0.1);
    const from_bytes = try t.render(gpa);
    defer from_bytes.deinit(gpa);
    s.source = .{ .width = w, .height = h, .pixel_buffer = pb };
    t.settle(0.1);
    const from_buffer = try t.render(gpa);
    defer from_buffer.deinit(gpa);
    try testing.expectEqualSlices(u8, from_bytes.bytes, from_buffer.bytes);
}
