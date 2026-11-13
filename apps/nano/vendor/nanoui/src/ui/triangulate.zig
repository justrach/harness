//! Polygons to triangles, by clipping ears: on its own (only `types.zig`
//! beside it), so tools building data can use it without the rest of the
//! UI (`ui.triangulate`, `ui.Canvas.fill`).
const std = @import("std");
const types = @import("types.zig");

pub const Point = types.Point;

pub const Triangle = struct {
    /// Indices of its corners.
    v: [3]u32,
    /// Which of its edges are the polygon's outline (see `Canvas.triangle`).
    smooth: u3 = 0,
};

/// A simple polygon (no holes; either way round) as triangles, by
/// clipping ears: each corner that bulges outwards with no other corner
/// inside the triangle it makes is cut off in turn. Edges on the outline
/// are marked smooth.
pub fn triangulate(gpa: std.mem.Allocator, points: []const Point) ![]Triangle {
    const n = points.len;
    if (n < 3) return &.{};
    var out: std.ArrayList(Triangle) = try .initCapacity(gpa, n - 2);
    errdefer out.deinit(gpa);
    // The corners left, as a ring.
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    const prev = try gpa.alloc(u32, n);
    defer gpa.free(prev);
    for (0..n) |k| {
        next[k] = @intCast((k + 1) % n);
        prev[k] = @intCast((k + n - 1) % n);
    }
    var area: f32 = 0;
    for (0..n) |k| area += cross(points[k], points[(k + 1) % n], .{});
    const side: f32 = if (area < 0) -1 else 1;

    var left = n;
    var cur: u32 = 0;
    var tried: usize = 0;
    while (left > 3) {
        const a = prev[cur];
        const b = next[cur];
        if (isEar(points, prev, next, a, cur, b, side) or tried > left) {
            try out.append(gpa, tri(n, a, cur, b));
            next[a] = b;
            prev[b] = a;
            left -= 1;
            tried = 0;
            cur = b;
        } else {
            tried += 1;
            cur = b;
        }
    }
    try out.append(gpa, tri(n, prev[cur], cur, next[cur]));
    return out.toOwnedSlice(gpa);
}

fn cross(o: Point, a: Point, b: Point) f32 {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

/// The triangle `a`, `b`, `p`, its edges along the outline (consecutive
/// corners of the `n`) smooth.
fn tri(n: usize, a: u32, b: u32, p: u32) Triangle {
    const outline = struct {
        fn f(count: usize, x: u32, y: u32) bool {
            return (x + 1) % count == y or (y + 1) % count == x;
        }
    }.f;
    var smooth: u3 = 0;
    if (outline(n, a, b)) smooth |= 1;
    if (outline(n, b, p)) smooth |= 2;
    if (outline(n, p, a)) smooth |= 4;
    return .{ .v = .{ a, b, p }, .smooth = smooth };
}

fn isEar(points: []const Point, prev: []const u32, next: []const u32, a: u32, b: u32, p: u32, side: f32) bool {
    const pa = points[a];
    const pb = points[b];
    const pp = points[p];
    // Bulging outwards (as the polygon turns), not flat.
    if (side * cross(pa, pb, pp) <= 0) return false;
    // No other corner left inside it.
    var k = next[p];
    while (k != a) : (k = next[k]) {
        const q = points[k];
        if (q.x == pa.x and q.y == pa.y or q.x == pb.x and q.y == pb.y or q.x == pp.x and q.y == pp.y) continue;
        if (side * cross(pa, pb, q) >= 0 and side * cross(pb, pp, q) >= 0 and side * cross(pp, pa, q) >= 0) return false;
    }
    _ = prev;
    return true;
}

test "a square is two triangles, its outline smooth and its diagonal not" {
    const sq = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const tris = try triangulate(std.testing.allocator, &sq);
    defer std.testing.allocator.free(tris);
    try std.testing.expectEqual(@as(usize, 2), tris.len);
    var smooth_edges: usize = 0;
    for (tris) |t| smooth_edges += @popCount(t.smooth);
    try std.testing.expectEqual(@as(usize, 4), smooth_edges);
}

test "a concave polygon's triangles cover its area exactly" {
    // An L, clockwise on the screen and then the other way.
    const l = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 30 }, .{ .x = 0, .y = 30 } };
    var rev: [l.len]Point = undefined;
    for (l, 0..) |p, k| rev[l.len - 1 - k] = p;
    for ([_][]const Point{ &l, &rev }) |poly| {
        const tris = try triangulate(std.testing.allocator, poly);
        defer std.testing.allocator.free(tris);
        try std.testing.expectEqual(poly.len - 2, tris.len);
        var area: f32 = 0;
        for (tris) |t| area += @abs(cross(poly[t.v[0]], poly[t.v[1]], poly[t.v[2]])) / 2;
        try std.testing.expectApproxEqAbs(@as(f32, 400), area, 0.01);
    }
}
