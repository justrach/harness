//! The prompt rail driven as a person would, headlessly (nanoui's
//! Tester), on a made-up chat: a tick per prompt, the one being read lit,
//! a hover's card, a click that glides the transcript to its prompt.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const sidebar = @import("view_sidebar.zig");
const Node = std.meta.Child(@FieldType(ui.Context, "nodes").Slice);

const testing = std.testing;

const chats =
    \\[{"id":"a","deviceId":"d","title":"Field notes","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z"}]
;

const prompts = [_][]const u8{ "Sketch the onboarding flow", "Now tidy the release notes", "Ship it" };

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, n: usize) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        h.a.openChat("a", null);
        // `n` prompts, each answered at length: more than a window holds.
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(testing.allocator);
        const gpa = testing.allocator;
        try frame.appendSlice(gpa, "{\"reset\":[");
        for (prompts[0..n], 0..) |p, i| {
            if (i > 0) try frame.appendSlice(gpa, ",");
            try frame.print(gpa, "{{\"id\":\"u{d}\",\"role\":\"user\",\"parts\":[{{\"kind\":\"text\",\"id\":\"t\",\"text\":\"{s}\"}}]}},", .{ i, p });
            try frame.print(gpa, "{{\"id\":\"a{d}\",\"role\":\"assistant\",\"parts\":[{{\"kind\":\"text\",\"id\":\"t\",\"text\":\"Reply {d} opens here.", .{ i, i });
            for (0..18) |_| try frame.appendSlice(gpa, "\\n\\nA paragraph of the answer.");
            try frame.appendSlice(gpa, "\"}]}");
        }
        try frame.appendSlice(gpa, "]}");
        var entries = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.items, .{});
        defer entries.deinit();
        try h.a.transcript.apply(entries.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// The rail's ticks, top to bottom: 2-point bars 16 points into the
    /// chat column.
    fn ticks(h: *Harness, out: []Node) []Node {
        var n: usize = 0;
        const left = sidebar.width + 16;
        for (h.t.ctx.nodes.items) |node| {
            if (node.rect.h != 2 or @abs(node.rect.x - left) > 0.5) continue;
            if (n == out.len) break;
            out[n] = node;
            n += 1;
        }
        return out[0..n];
    }

    /// Which tick is lit: the text color at 0.8, not the faint ink.
    fn lit(h: *Harness) ?usize {
        var buf: [16]Node = undefined;
        const text = @import("theme.zig").colors(true).text.alpha(0.8);
        for (h.ticks(&buf), 0..) |node, i| if (std.meta.eql(node.style.background, text)) return i;
        return null;
    }

    fn center(r: ui.Rect) [2]f32 {
        return .{ r.x + r.w / 2, r.y + r.h / 2 };
    }
};

test "the rail: a tick per prompt, 12 points wide, the last lit while the transcript follows its end" {
    var h: Harness = undefined;
    try h.init(3);
    defer h.deinit();
    var buf: [16]Node = undefined;
    const ticks = h.ticks(&buf);
    try testing.expectEqual(@as(usize, 3), ticks.len);
    for (ticks) |n| try testing.expectEqual(@as(f32, 12), n.rect.w);
    // Ticks 13 points apart, the stack in the middle of the window's height.
    try testing.expectEqual(@as(f32, 13), ticks[1].rect.y - ticks[0].rect.y);
    const mid = (ticks[0].rect.y + ticks[2].rect.y + 2) / 2;
    try testing.expect(@abs(mid - 390) < 1);
    try testing.expectEqual(@as(?usize, 2), h.lit());
}

test "hovering a tick grows it and shows its prompt and the opening of its reply" {
    var h: Harness = undefined;
    try h.init(3);
    defer h.deinit();
    var buf: [16]Node = undefined;
    const p = Harness.center(h.ticks(&buf)[0].rect);
    h.t.moveTo(p[0], p[1]);
    h.t.settle(1);
    try testing.expectEqual(@as(f32, 20), h.ticks(&buf)[0].rect.w);
    try testing.expect(h.t.hasText(prompts[0]));
    try testing.expect(h.t.containsText("Reply 0 opens here."));
    h.t.moveTo(600, 300);
    h.t.settle(1);
    try testing.expectEqual(@as(f32, 12), h.ticks(&buf)[0].rect.w);
}

test "clicking a tick glides its prompt to the top of the transcript, and lights it" {
    var h: Harness = undefined;
    try h.init(3);
    defer h.deinit();
    var buf: [16]Node = undefined;
    const p = Harness.center(h.ticks(&buf)[0].rect);
    h.t.click(p[0], p[1]);
    // Halfway through the glide it is on its way, not there.
    h.t.advance(0.25);
    const half = h.t.findText(prompts[0]).?.y;
    h.t.advance(0.5);
    h.t.settle(1);
    const at = h.t.findText(prompts[0]).?;
    // The row's top is at the column's top (under the title bar, as the
    // GPUI list's), the bubble's text 10 into it; a later prompt's row
    // starts at the turn's 16-point gap above its bubble.
    try testing.expect(@abs(at.y - 10) < 4);
    try testing.expect(half < at.y - 20);
    try testing.expectEqual(@as(?usize, 0), h.lit());
    // The second prompt's tick takes it to the second prompt.
    const q = Harness.center(h.ticks(&buf)[1].rect);
    h.t.click(q[0], q[1]);
    h.t.advance(0.6);
    h.t.settle(1);
    try testing.expect(@abs(h.t.findText(prompts[1]).?.y - 26) < 4);
    try testing.expectEqual(@as(?usize, 1), h.lit());
}

test "no rail for a single prompt, nor in a column narrower than 768 points" {
    var h: Harness = undefined;
    try h.init(1);
    defer h.deinit();
    var buf: [16]Node = undefined;
    try testing.expectEqual(@as(usize, 0), h.ticks(&buf).len);
    var g: Harness = undefined;
    try g.init(2);
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.ticks(&buf).len);
    g.t.resize(sidebar.width + 760, 780);
    g.t.settle(1);
    try testing.expectEqual(@as(usize, 0), g.ticks(&buf).len);
}
