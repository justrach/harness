//! Compact transcript mode and the final answer's divider, on a synthetic
//! turn: no engine, account or saved chats.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, compact: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.settings.set(.transcript_compact_mode, compact);
        h.a.openChat("synthetic-compact", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 900, .dark = true });
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, turn, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

const turn =
    \\{"reset":[
    \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Tidy the synthetic fixtures"}]},
    \\ {"id":"a","role":"assistant","status":"complete","durationMs":125400,"parts":[
    \\  {"id":"n","kind":"text","text":"Looking at the synthetic fixtures first."},
    \\  {"id":"r","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"fixtures/synthetic.json"}},
    \\  {"id":"x","kind":"tool","resolved":true,"call":{"kind":"exec","command":"zig build test"}},
    \\  {"id":"t","kind":"text","text":"The synthetic fixtures are tidy now."}]}]}
;

test "compact mode folds the turn's work under one Worked-for line and keeps the answer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.snap("compact-closed");
    try testing.expect(h.t.hasText("Worked for 2m 5s"));
    try testing.expect(h.t.containsText("The synthetic fixtures are tidy now."));
    // The narration and the calls are inside the closed line.
    try testing.expect(!h.t.containsText("Looking at the synthetic fixtures first."));
    try testing.expect(!h.t.containsText("zig build test"));
    // The work line says how long it worked; the divider doesn't repeat it.
    var count: usize = 0;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "Worked for 2m 5s")) {
            count += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(!h.t.hasText("Final answer"));

    try h.t.clickText("Worked for 2m 5s");
    h.t.settle(1);
    h.snap("compact-open");
    try testing.expect(h.t.containsText("Looking at the synthetic fixtures first."));
    try testing.expect(h.t.containsText("The synthetic fixtures are tidy now."));
}

test "without compact mode the answer starts under a Worked-for divider" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.snap("detailed");
    try testing.expect(h.t.containsText("Looking at the synthetic fixtures first."));
    try testing.expect(h.t.hasText("Worked for 2m 5s"));
    const label = h.t.findText("Worked for 2m 5s").?;
    const answer = for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.indexOf(u8, tx.str, "tidy now") != null) break n.rect,
        else => {},
    } else return error.MissingAnswer;
    // GPUI: the label, 12 under it the divider, 12 under that the answer.
    try testing.expect(answer.y > label.y + label.h + 20);
}
