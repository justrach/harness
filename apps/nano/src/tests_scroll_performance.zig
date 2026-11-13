//! Shape and cost of production transcript scrolling, entirely offscreen.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Fixture = struct {
    a: App,
    fn draw(f: *@This(), c: *ui.Context) void {
        f.a.markdown_cache.beginFrame();
        _ = @import("view_transcript.zig").entries(c, &f.a, @import("theme.zig").colors(true), &f.a.transcript, c.size.w, false, 0);
    }
    fn init(f: *@This(), force_full: bool) !void {
        f.a = .init(testing.allocator, testing.io, 1);
        f.a.offscreen = force_full;
        f.a.dark = true;
        f.a.openChat("synthetic-scroll", null);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try text.appendSlice(testing.allocator, "{\"reset\":[");
        for (0..160) |i| {
            if (i > 0) try text.appendSlice(testing.allocator, ",");
            try text.print(testing.allocator,
                \\{{"id":"reply-{d}","role":"assistant","status":"complete","parts":[{{"id":"text","kind":"text","text":"## Synthetic answer {d}\n\nA measured transcript should keep its content and stable scroll position. **Native Markdown** still supports selection and copy.\n\n- Reuse measured row heights\n- Preserve the viewport\n- Keep actual visible content mounted\n\nAnother paragraph of synthetic explanation, deliberately repeated in a long conversation."}}]}}
            , .{ i, i });
        }
        try text.appendSlice(testing.allocator, "]}");
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text.items, .{});
        defer parsed.deinit();
        try f.a.transcript.apply(parsed.value);
    }
};
const Sample = struct { nodes: usize, ms: f64, retained: bool, scroll: f32, max: f32, pixels: u64 };
const Scenario = enum { wheel, jump, resize };
fn sample(force_full: bool, scenario: Scenario) !Sample {
    var f: Fixture = undefined;
    try f.init(force_full);
    defer f.a.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.draw), .{ .width = 1000, .height = 700, .dark = true });
    defer t.deinit();
    t.frame();
    t.frame();
    const box = for (t.ctx.nodes.items) |node| {
        if (node.style.scroll and node.rect.h > 500) break node.id;
    } else return error.NoTranscriptViewport;
    // A real wheel path, not a benchmark that only writes an offset.
    t.scroll(500, 350, 24);
    t.scroll(500, 350, 24);
    const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    for (0..24) |_| t.scroll(500, 350, 4);
    const elapsed = std.Io.Clock.awake.now(testing.io).toNanoseconds() - start;
    switch (scenario) {
        .wheel => {},
        // One frame must mount the destination, not a blank spacer there.
        .jump => t.scroll(500, 350, 10_000),
        .resize => {
            t.size.w = 760;
            t.frame();
            t.frame();
        },
    }
    const pixels = try t.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
    if (std.c.getenv("NANO_SCROLL_SNAP_DIR")) |raw| {
        var path: [1024]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&path, "{s}/{s}-{s}.png", .{ std.mem.span(raw), if (force_full) "full" else "live", @tagName(scenario) }));
    }
    return .{
        .nodes = t.ctx.nodes.items.len,
        .ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / 24,
        .retained = t.ctx.stats.retained,
        .scroll = t.ctx.scroll.get(box).?,
        .max = t.ctx.scroll_max.get(box).?,
        .pixels = std.hash.Wyhash.hash(0, pixels.bytes),
    };
}

test "transcript scroll cost tracks the viewport instead of all warmed history" {
    @import("theme.zig").registerFonts();
    const full = try sample(true, .wheel);
    const live = try sample(false, .wheel);
    std.debug.print("\nSynthetic transcript scroll: full={d:.2}ms/{d} nodes, live={d:.2}ms/{d} nodes, retain={}\n", .{ full.ms, full.nodes, live.ms, live.nodes, live.retained });
    // Generous ratios, not a flaky wall-clock 8.33ms assertion on CI.
    try testing.expect(live.nodes * 5 < full.nodes);
    try testing.expect(live.ms * 3 < full.ms);
    try testing.expectApproxEqAbs(full.max, live.max, 1);
    try testing.expectApproxEqAbs(full.scroll, live.scroll, 1);
    try testing.expectEqual(full.pixels, live.pixels);
}

test "transcript scroll culling yields to native text selection and copy" {
    @import("theme.zig").registerFonts();
    var f: Fixture = undefined;
    try f.init(false);
    defer f.a.deinit();
    f.a.view.sidebar_open = false;
    var t: ui.Tester = undefined;
    // Selection ownership belongs to the production shell's pre-tree input
    // dispatch, not the entries-only timing fixture.
    try t.init(testing.allocator, .init(&f.a, @import("view.zig").view), .{ .width = 1000, .height = 700, .dark = true });
    defer t.deinit();
    t.frame();
    t.frame();
    const culled = t.ctx.nodes.items.len;
    const rect = for (t.ctx.nodes.items) |node| {
        if (node.content == .text and node.content.text.str.len > 40 and node.rect.y > 24 and node.rect.y + node.rect.h < 650 and node.rect.w > 150) break node.rect;
    } else return error.NoVisibleSelectableParagraph;
    t.drag(rect.x + 3, rect.y + 8, rect.x + 120, rect.y + 8);
    try testing.expect(t.ctx.selection.anchor != null);
    t.frame();
    try testing.expect(t.ctx.nodes.items.len > culled * 5);
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expect(t.clipboard.items.len > 0);
}

test "transcript scroll spacers preserve the destination pixels after a large jump and width change" {
    @import("theme.zig").registerFonts();
    for ([_]Scenario{ .jump, .resize }) |scenario| {
        const full = try sample(true, scenario);
        const live = try sample(false, scenario);
        try testing.expectApproxEqAbs(full.max, live.max, 1);
        try testing.expectApproxEqAbs(full.scroll, live.scroll, 1);
        try testing.expectEqual(full.pixels, live.pixels);
    }
}
