//! Native-gesture rubber banding exercised through the production transcript.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Fixture = struct {
    a: App,
    box: u64 = 0,

    fn draw(f: *@This(), c: *ui.Context) void {
        f.a.markdown_cache.beginFrame();
        f.box = @import("view_transcript.zig").entries(c, &f.a, @import("theme.zig").colors(true), &f.a.transcript, c.size.w, false, 0).box;
    }

    fn init(f: *@This()) !void {
        @import("theme.zig").registerFonts();
        f.* = .{ .a = .init(testing.allocator, testing.io, 1) };
        errdefer f.a.deinit();
        f.a.openChat("synthetic-bounce", null);
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(testing.allocator);
        try json.appendSlice(testing.allocator, "{\"reset\":[");
        for (0..24) |i| {
            if (i > 0) try json.appendSlice(testing.allocator, ",");
            try json.print(testing.allocator,
                \\{{"id":"reply-{d}","role":"assistant","status":"complete","parts":[{{"id":"text","kind":"text","text":"## Synthetic reply {d}\n\nA completed conversation still responds to native trackpad gestures at its bottom edge.\n\nAnother paragraph keeps this fixture taller than the viewport."}}]}}
            , .{ i, i });
        }
        try json.appendSlice(testing.allocator, "]}");
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json.items, .{});
        defer parsed.deinit();
        try f.a.transcript.apply(parsed.value);
    }

    fn bodyY(f: *const @This(), t: *ui.Tester) f32 {
        for (t.ctx.nodes.items) |n| {
            if (n.id == f.box) return t.ctx.node(n.first_child).rect.y;
        }
        unreachable;
    }
};

fn warm(f: *Fixture, t: *ui.Tester) !void {
    try t.init(testing.allocator, .init(f, Fixture.draw), .{ .width = 1000, .height = 700, .dark = true });
    t.settle(2);
    try testing.expect(t.ctx.scroll_max.get(f.box).? > 700);
    try testing.expect(t.ctx.scroll_follow.get(f.box).?);
}

/// Match AppKit's existing phase ownership, including its persistent holding
/// bit: clearEdges resets the per-frame phase, not fingers still on the pad.
fn gesture(t: *ui.Tester, phase: ui.ScrollPhase, dy: f32) void {
    t.ctx.input.precise = true;
    t.ctx.input.scroll_phase = phase;
    t.ctx.scroll_holding = phase == .began or phase == .changed;
    if (dy != 0) {
        t.scroll(500, 350, dy);
    } else t.frame();
}

fn overscroll(f: *const Fixture, t: *const ui.Tester) f32 {
    return t.ctx.overscroll.get(f.box) orelse 0;
}

test "transcript scroll bounce starts responsively and increasingly resists long pulls" {
    var f: Fixture = undefined;
    try f.init();
    defer f.a.deinit();
    var t: ui.Tester = undefined;
    try warm(&f, &t);
    defer t.deinit();
    const base = f.bodyY(&t);
    const max = t.ctx.scroll_max.get(f.box).?;
    gesture(&t, .began, -40);
    const first = overscroll(&f, &t);
    // The old linear 0.35 multiplier moved only 14pt. A small pull should
    // feel attached to the fingers, then stiffen instead of running away.
    try testing.expect(first > 18 and first < 24);
    try testing.expectApproxEqAbs(base - first, f.bodyY(&t), 0.1);
    try testing.expectEqual(max, t.ctx.scroll.get(f.box).?);
    try testing.expect(t.ctx.scroll_follow.get(f.box).?);
    gesture(&t, .changed, -40);
    const second = overscroll(&f, &t);
    try testing.expect(second > first);
    try testing.expect(second - first < first);
    // A frame between native events must not begin the return spring.
    t.frame();
    try testing.expectApproxEqAbs(second, overscroll(&f, &t), 0.001);
    gesture(&t, .changed, 80);
    try testing.expectApproxEqAbs(@as(f32, 0), overscroll(&f, &t), 0.001);
    gesture(&t, .changed, -80);
    // Native event coalescing must not change the resistance curve.
    try testing.expectApproxEqAbs(second, overscroll(&f, &t), 0.001);
}

test "transcript scroll bounce bounds bottom displacement and springs home without idle wakeups" {
    var f: Fixture = undefined;
    try f.init();
    defer f.a.deinit();
    var t: ui.Tester = undefined;
    try warm(&f, &t);
    defer t.deinit();
    const base = f.bodyY(&t);
    gesture(&t, .began, -20_000);
    const pulled = overscroll(&f, &t);
    try testing.expect(pulled > 100 and pulled <= 160);
    try testing.expectApproxEqAbs(base - pulled, f.bodyY(&t), 0.1);
    gesture(&t, .ended, 0);
    try testing.expect(overscroll(&f, &t) > 0);
    try testing.expect(overscroll(&f, &t) < pulled);
    try testing.expect(t.ctx.animating);
    t.settle(2);
    try testing.expectEqual(@as(f32, 0), overscroll(&f, &t));
    try testing.expectApproxEqAbs(base, f.bodyY(&t), 0.1);
    try testing.expect(t.ctx.scroll_follow.get(f.box).?);
    t.frame();
    try testing.expect(!t.ctx.animating);
    try testing.expect(t.ctx.frame_in == null);
}

test "transcript scroll bounce reverses a pull before releasing bottom follow on upscroll" {
    var f: Fixture = undefined;
    try f.init();
    defer f.a.deinit();
    var t: ui.Tester = undefined;
    try warm(&f, &t);
    defer t.deinit();
    const max = t.ctx.scroll_max.get(f.box).?;
    gesture(&t, .began, -80);
    gesture(&t, .changed, 80);
    try testing.expectApproxEqAbs(@as(f32, 0), overscroll(&f, &t), 0.001);
    try testing.expectApproxEqAbs(max, t.ctx.scroll.get(f.box).?, 0.001);
    gesture(&t, .changed, 24);
    try testing.expectApproxEqAbs(max - 24, t.ctx.scroll.get(f.box).?, 0.01);
    try testing.expect(!t.ctx.scroll_follow.get(f.box).?);
    try testing.expectApproxEqAbs(@as(f32, 0), overscroll(&f, &t), 0.001);
}

test "transcript scroll bounce leaves discrete wheels unbounced" {
    var f: Fixture = undefined;
    try f.init();
    defer f.a.deinit();
    var t: ui.Tester = undefined;
    try warm(&f, &t);
    defer t.deinit();
    const max = t.ctx.scroll_max.get(f.box).?;
    t.scroll(500, 350, -120);
    try testing.expectEqual(max, t.ctx.scroll.get(f.box).?);
    try testing.expectEqual(@as(f32, 0), overscroll(&f, &t));
    t.scroll(500, 350, 24);
    try testing.expectEqual(max - 24, t.ctx.scroll.get(f.box).?);
    try testing.expect(!t.ctx.scroll_follow.get(f.box).?);
}

test "transcript scroll bounce responds once when momentum reaches the bottom" {
    for ([_]bool{ false, true }) |reduced| {
        var f: Fixture = undefined;
        try f.init();
        defer f.a.deinit();
        var t: ui.Tester = undefined;
        try warm(&f, &t);
        defer t.deinit();
        t.ctx.reduced_motion = reduced;
        t.ctx.reduce_motion = reduced;
        const base = f.bodyY(&t);
        const max = t.ctx.scroll_max.get(f.box).?;
        gesture(&t, .began, 24);
        gesture(&t, .ended, 0);
        gesture(&t, .momentum, -120);
        const impact = overscroll(&f, &t);
        try testing.expectEqual(max, t.ctx.scroll.get(f.box).?);
        try testing.expect(t.ctx.scroll_follow.get(f.box).?);
        if (reduced) {
            try testing.expectEqual(@as(f32, 0), impact);
        } else {
            try testing.expect(impact > 16 and impact < 64);
            try testing.expectApproxEqAbs(base - impact, f.bodyY(&t), 0.1);
            gesture(&t, .momentum, -80);
            try testing.expect(overscroll(&f, &t) < impact);
        }
        t.settle(2);
        try testing.expectEqual(@as(f32, 0), overscroll(&f, &t));
        try testing.expectApproxEqAbs(base, f.bodyY(&t), 0.1);
        // Ordinary scrolling flashes the overlay scroller on a delayed timer;
        // advance through that hold too, not only the actively running spring.
        t.advance(2);
        try testing.expect(!t.ctx.animating);
        try testing.expect(t.ctx.frame_in == null);
    }
}

fn bouncePixels(full_tree: bool) ![6]u64 {
    var f: Fixture = undefined;
    try f.init();
    defer f.a.deinit();
    f.a.offscreen = full_tree;
    var t: ui.Tester = undefined;
    try warm(&f, &t);
    defer t.deinit();
    const pulses = [_]struct { phase: ui.ScrollPhase, dy: f32 }{
        .{ .phase = .began, .dy = 48 },
        .{ .phase = .ended, .dy = 0 },
        .{ .phase = .momentum, .dy = -240 },
        .{ .phase = .momentum, .dy = -80 },
        .{ .phase = .none, .dy = 0 },
        .{ .phase = .none, .dy = 0 },
    };
    var hashes: [6]u64 = undefined;
    for (pulses, 0..) |pulse, i| {
        gesture(&t, pulse.phase, pulse.dy);
        if (i == 5) t.settle(2);
        const pixels = try t.render(testing.allocator);
        defer pixels.deinit(testing.allocator);
        hashes[i] = std.hash.Wyhash.hash(0, pixels.bytes);
        if (std.c.getenv("NANO_SCROLL_SNAP_DIR")) |dir| {
            var path: [1024]u8 = undefined;
            try t.screenshot(try std.fmt.bufPrint(&path, "{s}/bounce-{s}-{d}.png", .{ std.mem.span(dir), if (full_tree) "full" else "culled", i }));
        }
    }
    return hashes;
}

test "transcript scroll bounce culling preserves pixels through impact and recovery" {
    const full = try bouncePixels(true);
    const culled = try bouncePixels(false);
    try testing.expectEqualSlices(u64, &full, &culled);
}

test "transcript scroll bounce respects Reduce Motion on release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.a.deinit();
    var t: ui.Tester = undefined;
    try warm(&f, &t);
    defer t.deinit();
    t.ctx.reduced_motion = true;
    t.ctx.reduce_motion = true;
    const base = f.bodyY(&t);
    gesture(&t, .began, -80);
    try testing.expect(overscroll(&f, &t) > 0);
    gesture(&t, .ended, 0);
    try testing.expectEqual(@as(f32, 0), overscroll(&f, &t));
    try testing.expectApproxEqAbs(base, f.bodyY(&t), 0.1);
    t.settle(2);
    try testing.expect(!t.ctx.animating);
    try testing.expect(t.ctx.frame_in == null);
}
