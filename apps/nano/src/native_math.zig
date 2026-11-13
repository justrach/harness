//! Native TeX layout using the retained bounded desktop math engine.
//! The helper owns its embedded STIX font and emits only trusted outlines and
//! rules, painted by nanoui (not HTML, a webview, or a linear text substitute).
const std = @import("std");
const Color = @import("nanoui").ui.Color;

const Output = extern struct {
    svg: [*]const u8,
    len: usize,
    width: f32,
    height: f32,
    ascent: f32,
    depth: f32,
    owner: ?*anyopaque,
};
extern fn harness_math_layout(source: [*]const u8, len: usize, display: bool, size: f32, color: u32, out: *Output) callconv(.c) bool;
extern fn harness_math_free(owner: ?*anyopaque) callconv(.c) void;

pub const Equation = struct {
    svg: []const u8,
    width: f32,
    height: f32,
    ascent: f32,
    depth: f32,
};

/// Source, token, AST, stack, output dimensions and cache sizes are all bounded
/// in the native helper. Unsupported/malformed input returns null verbatim.
pub fn layout(arena: std.mem.Allocator, source: []const u8, display: bool, size: f32, color: Color) ?Equation {
    var out: Output = undefined;
    var rgba: u32 = 0;
    for ([_]f32{ color.r, color.g, color.b, color.a }) |v| {
        if (!std.math.isFinite(v)) return null;
        rgba = (rgba << 8) | @as(u32, @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255)));
    }
    if (!harness_math_layout(source.ptr, source.len, display, size, rgba, &out)) return null;
    defer harness_math_free(out.owner);
    const svg = arena.dupe(u8, out.svg[0..out.len]) catch return null;
    return .{ .svg = svg, .width = out.width, .height = out.height, .ascent = out.ascent, .depth = out.depth };
}
