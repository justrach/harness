//! Easing curves for tweens, as gpui-motion's (and Motion's) names them:
//! each gives its value and its derivative at t in [0, 1], so a tween can
//! hand its velocity on when a spring takes over.
const std = @import("std");

pub const Easing = union(enum) {
    linear,
    /// Cubic.
    ease_in,
    ease_out,
    /// Cubic smoothstep: still at both ends.
    ease_in_out,
    circ_in,
    circ_out,
    circ_in_out,
    /// Overshooting.
    back_in,
    back_out,
    back_in_out,
    /// A step back, then an exponential rush.
    anticipate,
    /// CSS's cubic-bezier(x1, y1, x2, y2); x1 and x2 in [0, 1].
    bezier: [4]f32,

    /// The curve's value and derivative at `t`.
    pub fn sample(e: Easing, t_in: f32) [2]f32 {
        const t = std.math.clamp(t_in, 0, 1);
        return switch (e) {
            .linear => .{ t, 1 },
            .ease_in => .{ t * t * t, 3 * t * t },
            .ease_out => .{ 1 - (1 - t) * (1 - t) * (1 - t), 3 * (1 - t) * (1 - t) },
            .ease_in_out => .{ t * t * (3 - 2 * t), 6 * t * (1 - t) },
            .circ_in => blk: {
                const root = @sqrt(@max(1 - t * t, 1e-12));
                break :blk .{ 1 - root, t / root };
            },
            .circ_out => blk: {
                const u = t - 1;
                const root = @sqrt(@max(1 - u * u, 1e-12));
                break :blk .{ root, (1 - t) / root };
            },
            .circ_in_out => halves(.circ_in, .circ_out, t),
            .back_out => blk: {
                const u = t - 1;
                break :blk .{ 1 + 2.70158 * u * u * u + 1.70158 * u * u, 8.10474 * u * u + 3.40316 * u };
            },
            .back_in => blk: {
                const s = Easing.sample(.back_out, 1 - t);
                break :blk .{ 1 - s[0], s[1] };
            },
            .back_in_out => halves(.back_in, .back_out, t),
            .anticipate => if (t < 0.5) blk: {
                const s = Easing.sample(.back_in, t * 2);
                break :blk .{ s[0] * 0.5, s[1] };
            } else blk: {
                const decay = std.math.pow(f32, 2, -20 * (t - 0.5));
                break :blk .{ 1 - 0.5 * decay, 10 * std.math.ln2 * decay };
            },
            .bezier => |p| bezier(p, t),
        };
    }

    /// CSS's named curves.
    pub const css_ease: Easing = .{ .bezier = .{ 0.25, 0.1, 0.25, 1 } };
    pub const css_ease_in: Easing = .{ .bezier = .{ 0.42, 0, 1, 1 } };
    pub const css_ease_out: Easing = .{ .bezier = .{ 0, 0, 0.58, 1 } };
    pub const css_ease_in_out: Easing = .{ .bezier = .{ 0.42, 0, 0.58, 1 } };
};

/// The first curve over [0, 0.5], the second over [0.5, 1].
fn halves(first: Easing, second: Easing, t: f32) [2]f32 {
    if (t < 0.5) {
        const s = first.sample(t * 2);
        return .{ s[0] * 0.5, s[1] };
    }
    const s = second.sample(t * 2 - 1);
    return .{ 0.5 + s[0] * 0.5, s[1] };
}

/// A cubic Bézier from (0, 0) to (1, 1): x is solved for t (Newton, then
/// bisection where it stalls), then y is read there.
fn bezier(p: [4]f32, x: f32) [2]f32 {
    const x1 = std.math.clamp(p[0], 0, 1);
    const x2 = std.math.clamp(p[2], 0, 1);
    const y1 = p[1];
    const y2 = p[3];
    const curve = struct {
        fn at(a: f32, b: f32, t: f32) f32 {
            // 3(1-t)²t a + 3(1-t)t² b + t³
            const u = 1 - t;
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
        }
        fn slope(a: f32, b: f32, t: f32) f32 {
            const u = 1 - t;
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b);
        }
    };
    var t = x;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const err = curve.at(x1, x2, t) - x;
        if (@abs(err) < 1e-6) break;
        const d = curve.slope(x1, x2, t);
        if (@abs(d) < 1e-6) break;
        t -= err / d;
    }
    if (t < 0 or t > 1 or @abs(curve.at(x1, x2, t) - x) > 1e-4) {
        var lo: f32 = 0;
        var hi: f32 = 1;
        t = x;
        i = 0;
        while (i < 40) : (i += 1) {
            if (curve.at(x1, x2, t) < x) lo = t else hi = t;
            t = (lo + hi) / 2;
        }
    }
    const dx = curve.slope(x1, x2, t);
    const dy = curve.slope(y1, y2, t);
    return .{ curve.at(y1, y2, t), if (@abs(dx) < 1e-6) 0 else dy / dx };
}

test "easings start at 0 and end at 1" {
    const all = [_]Easing{ .linear, .ease_in, .ease_out, .ease_in_out, .circ_in, .circ_out, .circ_in_out, .back_in, .back_out, .back_in_out, .anticipate, Easing.css_ease, Easing.css_ease_in_out };
    for (all) |e| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), e.sample(0)[0], 1e-3);
        try std.testing.expectApproxEqAbs(@as(f32, 1), e.sample(1)[0], 1e-3);
    }
    // Back out overshoots; ease in out is half way at half time.
    var most: f32 = 0;
    var t: f32 = 0;
    while (t <= 1) : (t += 0.01) most = @max(most, Easing.sample(.back_out, t)[0]);
    try std.testing.expect(most > 1.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), Easing.sample(.ease_in_out, 0.5)[0], 1e-6);
}

test "a cubic-bezier matches its linear case and its derivative" {
    const lin: Easing = .{ .bezier = .{ 0.25, 0.25, 0.75, 0.75 } };
    for ([_]f32{ 0.1, 0.37, 0.5, 0.9 }) |x| try std.testing.expectApproxEqAbs(x, lin.sample(x)[0], 1e-3);
    // The derivative agrees with a finite difference.
    const e = Easing.css_ease;
    const h: f32 = 1e-3;
    const fd = (e.sample(0.4 + h)[0] - e.sample(0.4 - h)[0]) / (2 * h);
    try std.testing.expectApproxEqAbs(fd, e.sample(0.4)[1], 2e-2);
}
