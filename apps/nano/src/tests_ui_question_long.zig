//! A long agent question scrolls in its panel: the options, answer box and
//! buttons stay reachable, and the transcript stays in sight.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, height: f32) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.settings.set(.transcript_compact_mode, false);
        h.a.offscreen = true;
        h.a.dark = false;
        h.a.view.sidebar_open = false;
        h.a.openChat("synthetic-question", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = height, .dark = false });
        h.t.settle(1);
        // A status report in the question, as an agent writes one.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(testing.allocator);
        try body.appendSlice(testing.allocator, "Synthetic status report opening line.\\n\\n");
        for (0..40) |i| try body.print(testing.allocator, "- Synthetic finding number {d} goes on for long enough to fill a line of the card.\\n", .{i});
        const frame = try std.fmt.allocPrint(testing.allocator,
            \\{{"reset":[{{"id":"earlier","role":"user","parts":[{{"id":"p","kind":"text","text":"Synthetic earlier prompt"}}]}},
            \\ {{"id":"ask","role":"assistant","status":"complete","parts":[{{"kind":"input","id":"r1","requestId":"r1","resolved":false,
            \\  "questions":[{{"id":"q1","header":"Agent question","question":"{s}","options":["Synthetic first option","Synthetic last option"]}},
            \\   {{"id":"q2","header":"Agent question","question":"{s}","options":["Synthetic page two option"]}}]}}]}}]}}
        , .{ body.items, body.items });
        defer testing.allocator.free(frame);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
        try testing.expect(h.a.wizard != null);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// `NANO_SNAP_DIR=dir zig build test` saves what the test saw.
    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }

    /// Inside the window, so it can be seen and clicked.
    fn onScreen(h: *Harness, label: []const u8, height: f32) bool {
        const r = h.t.findText(label) orelse return false;
        return r.y >= 0 and r.y + r.h <= height;
    }

    /// The question's scrolling box: it paints after the transcript's.
    fn bodyRect(h: *Harness) !ui.Rect {
        var last: ?ui.Rect = null;
        for (h.t.ctx.hits.items) |hit| if (hit.scroll) {
            last = hit.rect;
        };
        return last orelse error.NoScrollBox;
    }

    fn wheel(h: *Harness, r: ui.Rect, dy: f32) void {
        const x = r.x + r.w / 2;
        const y = r.y + r.h / 2;
        h.t.moveTo(x, y);
        h.t.scroll(x, y, dy);
        h.t.settle(1);
    }

    /// The question's scroll offset.
    fn offset(h: *Harness) f32 {
        var most: f32 = 0;
        var it = h.t.ctx.scroll.valueIterator();
        while (it.next()) |v| most = @max(most, v.*);
        return most;
    }
};

test "a long question leaves its buttons and the transcript on screen, in tall and short windows" {
    for ([_]f32{ 800, 420 }) |height| {
        var h: Harness = undefined;
        try h.init(height);
        defer h.deinit();
        try testing.expect(h.onScreen("Cancel question", height));
        try testing.expect(h.onScreen("Next", height));
        // The transcript keeps room above it, at its end: the question's chip.
        try testing.expect(h.onScreen("Question", height));
        const box = try h.bodyRect();
        try testing.expect(h.t.findText("Question").?.y + 20 <= box.y);
        try testing.expect(box.h >= 40);
        // The panel is its body and what's under it, within GPUI's share.
        const foot = h.t.findText("Next").?;
        try testing.expect(foot.y + foot.h + 22 - box.y <= @max(height * 0.55, 220));
        h.snap(if (height == 800) "question-long" else "question-long-short");
    }
}

test "the wheel reads a long question to its options, which still pick, and the buttons hold still" {
    var h: Harness = undefined;
    try h.init(800);
    defer h.deinit();
    const next = h.t.findText("Next").?;
    const last_y = h.t.findText("Synthetic last option").?.y;
    h.wheel(try h.bodyRect(), -100_000);
    try testing.expect(h.offset() > 0);
    const opt = h.t.findText("Synthetic last option").?;
    const box = try h.bodyRect();
    try testing.expect(opt.y < last_y);
    try testing.expect(opt.y >= box.y and opt.y + opt.h <= box.y + box.h);
    try testing.expectEqual(next.y, h.t.findText("Next").?.y);
    h.snap("question-long-end");
    try h.t.clickText("Synthetic last option");
    h.t.settle(1);
    try testing.expect(h.a.wizard.?.picked(1) or h.a.wizard.?.page == 1);
}

test "a new page of questions starts at the top, also going back" {
    var h: Harness = undefined;
    try h.init(800);
    defer h.deinit();
    h.wheel(try h.bodyRect(), -100_000);
    try testing.expect(h.offset() > 0);
    try h.t.clickText("Synthetic last option");
    h.t.settle(1);
    h.a.wizard.?.advance_at = null;
    if (h.a.wizard.?.page == 0) h.a.wizardAdvance();
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.wizard.?.page);
    try testing.expectEqual(@as(f32, 0), h.offset());
    try testing.expect(h.onScreen("Back", 800));
    h.wheel(try h.bodyRect(), -100_000);
    try testing.expect(h.offset() > 0);
    try h.t.clickText("Back");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.wizard.?.page);
    try testing.expectEqual(@as(f32, 0), h.offset());
}

test "a long typed answer doesn't push the question or buttons away" {
    var h: Harness = undefined;
    try h.init(420);
    defer h.deinit();
    h.a.composer.set("Synthetic answer\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline");
    h.t.settle(1);
    try testing.expect(h.onScreen("Next", 420));
    try testing.expect((try h.bodyRect()).h >= 40);
}
