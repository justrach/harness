//! Outlines to coverage, as font-rs does it: each line adds its signed
//! area to the cells it crosses, and one running sum along the buffer
//! turns those into how much of each pixel is inside. Curves are flattened
//! into lines first. Exact for non-overlapping contours, which glyphs and
//! icons are; antialiased with no supersampling.
const std = @import("std");
const font = @import("font.zig");

pub const Raster = struct {
    w: usize,
    h: usize,
    acc: []f32,
    /// The pen, and where the contour began (to close it).
    x: f32 = 0,
    y: f32 = 0,
    sx: f32 = 0,
    sy: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, w: usize, h: usize) !Raster {
        const acc = try gpa.alloc(f32, w * h + 4);
        @memset(acc, 0);
        return .{ .w = w, .h = h, .acc = acc };
    }

    pub fn deinit(r: *Raster, gpa: std.mem.Allocator) void {
        gpa.free(r.acc);
    }

    /// The sink an outline draws into, its coordinates in pixels (y down).
    pub fn sink(r: *Raster) font.Sink {
        return .{ .ctx = r, .move = move, .line = lineTo, .quad = quadTo, .close = close };
    }

    fn of(ctx: *anyopaque) *Raster {
        return @ptrCast(@alignCast(ctx));
    }

    fn move(ctx: *anyopaque, x: f32, y: f32) void {
        const r = of(ctx);
        r.x = x;
        r.y = y;
        r.sx = x;
        r.sy = y;
    }

    fn lineTo(ctx: *anyopaque, x: f32, y: f32) void {
        const r = of(ctx);
        r.line(r.x, r.y, x, y);
        r.x = x;
        r.y = y;
    }

    fn quadTo(ctx: *anyopaque, cx: f32, cy: f32, x: f32, y: f32) void {
        const r = of(ctx);
        const ddx = r.x - 2 * cx + x;
        const ddy = r.y - 2 * cy + y;
        const dev = ddx * ddx + ddy * ddy;
        if (dev < 0.333) return lineTo(ctx, x, y);
        const n: usize = 1 + @as(usize, @intFromFloat(@floor(@sqrt(@sqrt(3 * dev)))));
        const x0 = r.x;
        const y0 = r.y;
        var px = x0;
        var py = y0;
        for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const mt = 1 - t;
            const nx = mt * mt * x0 + 2 * mt * t * cx + t * t * x;
            const ny = mt * mt * y0 + 2 * mt * t * cy + t * t * y;
            r.line(px, py, nx, ny);
            px = nx;
            py = ny;
        }
        r.x = x;
        r.y = y;
    }

    /// A cubic curve, for icons' paths (glyphs have quadratics only).
    pub fn cubicTo(r: *Raster, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        const d1 = @abs(r.x - 2 * c1x + c2x) + @abs(r.y - 2 * c1y + c2y);
        const d2 = @abs(c1x - 2 * c2x + x) + @abs(c1y - 2 * c2y + y);
        const n: usize = 1 + @as(usize, @intFromFloat(@floor(@sqrt(3 * @max(d1, d2)))));
        const x0 = r.x;
        const y0 = r.y;
        var px = x0;
        var py = y0;
        for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const mt = 1 - t;
            const nx = mt * mt * mt * x0 + 3 * mt * mt * t * c1x + 3 * mt * t * t * c2x + t * t * t * x;
            const ny = mt * mt * mt * y0 + 3 * mt * mt * t * c1y + 3 * mt * t * t * c2y + t * t * t * y;
            r.line(px, py, nx, ny);
            px = nx;
            py = ny;
        }
        r.x = x;
        r.y = y;
    }

    fn close(ctx: *anyopaque) void {
        const r = of(ctx);
        if (r.x != r.sx or r.y != r.sy) r.line(r.x, r.y, r.sx, r.sy);
        r.x = r.sx;
        r.y = r.sy;
    }

    pub fn moveTo(r: *Raster, x: f32, y: f32) void {
        move(r, x, y);
    }

    pub fn lineToPoint(r: *Raster, x: f32, y: f32) void {
        lineTo(r, x, y);
    }

    pub fn closePath(r: *Raster) void {
        close(r);
    }

    /// Adds a line's signed area to the cells it crosses.
    pub fn line(r: *Raster, ax: f32, ay: f32, bx: f32, by: f32) void {
        if (ay == by) return;
        const dir: f32 = if (ay < by) 1 else -1;
        const p0x, const p0y, const p1x, const p1y = if (ay < by) .{ ax, ay, bx, by } else .{ bx, by, ax, ay };
        const wf: f32 = @floatFromInt(r.w);
        const dxdy = (p1x - p0x) / (p1y - p0y);
        var x = p0x;
        if (p0y < 0) x -= p0y * dxdy;
        const y_start: usize = @intFromFloat(@max(0, p0y));
        const y_end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(r.h)), @ceil(p1y)));
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, p1y) - @max(yf, p0y);
            const xnext = x + dxdy * dy;
            const d = dy * dir;
            // Kept inside the row: what lies left of it still covers it.
            const x0 = std.math.clamp(@min(x, xnext), 0, wf - 0.001);
            const x1 = std.math.clamp(@max(x, xnext), 0, wf - 0.001);
            const line_start = y * r.w;
            const x0f = @floor(x0);
            const x1c = @ceil(x1);
            const x0i: usize = @intFromFloat(x0f);
            const x1i: usize = @intFromFloat(x1c);
            if (x1i <= x0i + 1) {
                const xm = 0.5 * (x0 + x1) - x0f;
                r.acc[line_start + x0i] += d - d * xm;
                r.acc[line_start + x0i + 1] += d * xm;
            } else {
                const s = 1 / (x1 - x0);
                const fr0 = x0 - x0f;
                const a0 = 0.5 * s * (1 - fr0) * (1 - fr0);
                const fr1 = x1 - x1c + 1;
                const am = 0.5 * s * fr1 * fr1;
                r.acc[line_start + x0i] += d * a0;
                if (x1i == x0i + 2) {
                    r.acc[line_start + x0i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - fr0);
                    r.acc[line_start + x0i + 1] += d * (a1 - a0);
                    for (x0i + 2..x1i - 1) |xi| r.acc[line_start + xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    r.acc[line_start + x1i - 1] += d * (1 - a2 - am);
                }
                r.acc[line_start + x1i] += d * am;
            }
            x = xnext;
        }
    }

    /// The coverage of each pixel, 0 to 255, into `out` (w × h).
    pub fn coverage(r: *const Raster, out: []u8) void {
        var sum: f32 = 0;
        for (out[0 .. r.w * r.h], r.acc[0 .. r.w * r.h]) |*o, a| {
            sum += a;
            o.* = @intFromFloat(@min(1, @abs(sum)) * 255 + 0.5);
        }
    }
};

test "a square and a triangle, antialiased" {
    const gpa = std.testing.allocator;
    var r = try Raster.init(gpa, 8, 8);
    defer r.deinit(gpa);
    // A square from (2, 2) to (6, 6), and half a pixel's edge at x = 6.5.
    r.moveTo(2, 2);
    r.lineToPoint(6.5, 2);
    r.lineToPoint(6.5, 6);
    r.lineToPoint(2, 6);
    r.closePath();
    var out: [64]u8 = undefined;
    r.coverage(&out);
    try std.testing.expectEqual(@as(u8, 255), out[3 * 8 + 3]);
    try std.testing.expectEqual(@as(u8, 0), out[1 * 8 + 3]);
    try std.testing.expectEqual(@as(u8, 128), out[3 * 8 + 6]);
    try std.testing.expectEqual(@as(u8, 0), out[3 * 8 + 7]);
}
