//! Synthetic-only responsiveness, consent and completed-frame integration.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const perf = @import("performance.zig");
const stats = @import("perf_stats.zig");
const testing = std.testing;
const cohort: stats.Cohort = .{ .interaction = .scroll, .panes = .single, .renderer = .metal };

fn count(w: *const stats.Window, metric: stats.Metric) u32 {
    var result: u32 = 0;
    for (w.cells[@backingInt(metric)]) |panes| for (panes) |renderers| for (renderers) |h| {
        result += h.count;
    };
    return result;
}

test "desktop performance consent defaults off and invalidates buffered work" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try testing.expect(!a.settings.get(.share_desktop_responsiveness));
    // The previous placeholder preference is not consent for new collection.
    a.settings.set(.share_performance_stats, true);
    try testing.expect(!a.settings.get(.share_desktop_responsiveness));
    const s = &a.performance;
    s.sample(1, true, cohort, 1, 2, 3, true);
    try testing.expect(s.window.empty());
    s.consent(true, 1000);
    const generation = s.generation.load(.acquire);
    s.sample(1, true, cohort, 1, 2, 3, true);
    try testing.expectEqual(@as(u32, 1), count(&s.window, .cpu));
    s.consent(false, 2000);
    try testing.expect(s.window.empty());
    try testing.expect(s.previous_time == null);
    try testing.expect(s.generation.load(.acquire) != generation);
    s.consent(true, 3000);
    try testing.expect(s.window.empty());
}

test "desktop performance excludes idle background resume and cohort changes from cadence" {
    var s: perf.State = .{};
    defer s.deinit();
    s.consent(true, 1000);
    s.sample(1, true, cohort, 1, 2, 3, true);
    s.sample(1.01, true, cohort, 1, 2, 3, true);
    try testing.expectEqual(@as(u32, 1), count(&s.window, .interval));
    s.sample(20, true, cohort, 1, 2, 3, true); // resumed after idle
    s.sample(20.01, false, cohort, 1, 2, 3, true);
    s.sample(20.02, true, cohort, 1, 2, 3, true);
    var different = cohort;
    different.panes = .many;
    s.sample(20.03, true, different, 1, 2, 3, true);
    s.sample(20.04, true, different, 1, 2, 3, false);
    s.sample(20.05, true, different, 1, 2, 3, true);
    try testing.expectEqual(@as(u32, 1), count(&s.window, .interval));
    try testing.expectEqual(@as(u32, 7), count(&s.window, .cpu));
}

test "desktop performance observes current completed CPU stats once per actual frame" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.performance.available = true; // Explicit test seam; no transport in tests.
    a.settings.set(.share_desktop_responsiveness, true);
    var view = ui.View.init(&a, @import("view.zig").view);
    view.after_frame = perf.completed;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, view, .{ .width = 900, .height = 700 });
    defer t.deinit();
    const before = count(&a.performance.window, .cpu);
    t.frame();
    try testing.expectEqual(before + 1, count(&a.performance.window, .cpu));
    var sum: f64 = 0;
    for (a.performance.window.cells[@backingInt(stats.Metric.cpu)]) |panes| for (panes) |renderers| for (renderers) |h| {
        sum += h.sum;
    };
    try testing.expect(sum >= t.ctx.stats.build_ms + t.ctx.stats.layout_ms + t.ctx.stats.paint_ms);
    a.settings.set(.share_desktop_responsiveness, false);
    t.frame();
    try testing.expect(a.performance.window.empty());
    a.settings.set(.share_desktop_responsiveness, true);
    a.offscreen = true;
    t.frame();
    try testing.expect(a.performance.window.empty());
}

test "desktop performance hook also counts retained scroll frames without rebuilding" {
    const Probe = struct {
        builds: u32 = 0,
        completed: u32 = 0,
        retained: bool = false,
        fn draw(p: *@This(), c: *ui.Context) void {
            p.builds += 1;
            const box = c.open(.{ .direction = .column, .width = .fill, .height = .fill, .scroll = true }, null);
            defer c.end();
            _ = box;
            for (0..50) |_| ui.text(c, "Synthetic scroll row", .{ .size = 14 });
        }
        fn after(ptr: *anyopaque, c: *ui.Context) void {
            const p: *@This() = @ptrCast(@alignCast(ptr));
            p.completed += 1;
            p.retained = c.stats.retained;
        }
    };
    @import("theme.zig").registerFonts();
    var probe: Probe = .{};
    var view = ui.View.init(&probe, Probe.draw);
    view.after_frame = Probe.after;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, view, .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.frame();
    const builds = probe.builds;
    const completed = probe.completed;
    t.scroll(200, 150, -12);
    try testing.expect(probe.retained);
    try testing.expectEqual(builds, probe.builds);
    try testing.expectEqual(completed + 1, probe.completed);
}

test "desktop performance matches every Lean policy vector" {
    const policy = @import("performance_policy.zig");
    try testing.expectEqual(@as(usize, 22), policy.bucket_bounds);
    try testing.expectEqual(@as(usize, 240), policy.histogram_cells);
    try testing.expectEqual(@as(usize, 5520), policy.counter_slots);
    try testing.expectEqual(@as(u32, 1_000_000), policy.capacity);
    try testing.expectEqual(@as(i64, 600_000), policy.interval_ms);
    const vectors = @embedFile("telemetry_policy_vectors.csv");
    const crlf = try std.mem.replaceOwned(u8, testing.allocator, vectors, "\n", "\r\n");
    defer testing.allocator.free(crlf);
    // Git may check out text fixtures with CRLF on Windows. Both encodings
    // must refine the same Lean policy, with all 704 cases exercised.
    for ([_][]const u8{ vectors, crlf }) |encoded| {
        var lines = std.mem.tokenizeAny(u8, encoded, "\r\n");
        var n: usize = 0;
        while (lines.next()) |line| {
            var columns = std.mem.splitScalar(u8, line, ',');
            var v: [11]i64 = undefined;
            for (&v) |*x| x.* = try std.fmt.parseInt(i64, columns.next() orelse return error.ShortProofVector, 10);
            try testing.expect(columns.next() == null);
            try testing.expectEqual(v[8] == 1, policy.shouldRecord(v[0] == 1, v[1] == 1, v[2] == 1));
            try testing.expectEqual(@as(u8, @intCast(v[9])), policy.updateCount(v[0] == 1, v[1] == 1, v[2] == 1, v[3] == 1));
            try testing.expectEqual(v[10] == 1, policy.shouldPublish(v[0] == 1, v[1] == 1, v[4] == 1, v[5] == 1, v[6], v[7]));
            // The real recorder must refine the policy's four/five-update plan.
            var s: perf.State = .{};
            s.consent(v[0] == 1, 0);
            if (v[3] == 1) s.sample(1, v[1] == 1, cohort, 1, 2, 3, true);
            const before = count(&s.window, .cpu) * 4 + count(&s.window, .interval);
            s.sample(if (v[2] == 1) 1.01 else std.math.nan(f64), v[1] == 1, cohort, 1, 2, 3, true);
            const after = count(&s.window, .cpu) * 4 + count(&s.window, .interval);
            try testing.expectEqual(@as(u32, @intCast(v[9])), after - before);
            n += 1;
        }
        try testing.expectEqual(@as(usize, 704), n);
    }
    for ([_]u32{ 0, 1, policy.capacity - 1, policy.capacity, std.math.maxInt(u32) }) |value| {
        try testing.expectEqual(value, policy.nextCount(value, false));
        try testing.expect(policy.nextCount(value, true) <= policy.capacity);
    }
}

test "desktop performance hot path needs no allocator and never waits for a busy worker" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var s: perf.State = .{};
    defer s.deinit();
    s.gpa = failing.allocator();
    s.io = testing.io;
    // A deterministic paused consumer: the producer's real handoff is tested,
    // with no worker thread and no HTTP request. Teardown sees worker=null.
    s.worker_started = true;
    s.consent(true, 0);
    s.sample(1, true, cohort, 1, 2, 3, true);
    try testing.expect(!s.publish(true, perf.interval_ms - 1));
    try testing.expect(!s.publish(false, perf.interval_ms));
    try testing.expect(s.publish(true, perf.interval_ms));
    try testing.expectEqual(@as(u32, 1), s.phase.load(.acquire));
    try testing.expect(s.window.empty());
    s.phase.store(2, .release); // Network could remain blocked indefinitely.
    const pending_before = s.queued.window;
    for (0..10_000) |i| {
        s.sample(2 + @as(f64, @floatFromInt(i)) / 120, true, cohort, 1, 2, 3, true);
        try testing.expect(!s.publish(true, 10 * perf.interval_ms));
    }
    try testing.expectEqualDeep(pending_before, s.queued.window);
    try testing.expectEqual(perf.interval_ms, s.attempted_ms);
    s.phase.store(0, .release); // Success OR failure frees exactly one slot.
    try testing.expect(s.publish(true, 10 * perf.interval_ms));
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    s.consent(false, 11 * perf.interval_ms);
    try testing.expect(s.window.empty());
    try testing.expect(!s.publish(true, 12 * perf.interval_ms));
}

test "desktop performance sleeping worker shuts down without queued UI callbacks" {
    var s: perf.State = .{};
    s.start(testing.allocator, testing.io);
    try testing.expect(s.worker_started);
    s.deinit();
    try testing.expect(!s.worker_started);
    try testing.expect(s.worker == null);
}

test "desktop performance recorder has bounded measured overhead independent of history" {
    var s: perf.State = .{};
    defer s.deinit();
    s.consent(true, 0);
    const clock = std.Io.Clock.awake;
    const iterations: usize = 50_000;
    const start = clock.now(testing.io).toNanoseconds();
    for (0..iterations) |i| {
        s.sample(@as(f64, @floatFromInt(i)) / 120, true, cohort, 1, 2, 3, true);
    }
    const ns = clock.now(testing.io).toNanoseconds() - start;
    const us = @as(f64, @floatFromInt(ns)) / 1000 / @as(f64, iterations);
    std.debug.print("\nSynthetic telemetry recorder: {d:.3} us/sample; window={d} bytes (not an FPS or whole-frame bound)\n", .{ us, @sizeOf(stats.Window) });
    // Very generous regression alarm, not a cross-machine real-time promise.
    // Structural bounds, no-allocation tests and Lean carry the shape guarantee.
    try testing.expect(us < 100);
    try testing.expect(@sizeOf(stats.Window) < 64 * 1024);
    try testing.expect(@sizeOf(perf.State) < 128 * 1024);
    try testing.expectEqual(@as(u32, iterations), count(&s.window, .cpu));
}
