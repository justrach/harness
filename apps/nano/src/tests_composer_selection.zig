//! Composer gestures use synthetic drafts and the Tester's private clipboard.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;
const first = "First synthetic paragraph stays separate.";
const sentence = "A café paragraph wraps across the composer with enough synthetic words to occupy several visual lines.";
const middle = sentence ++ " Its complete text must remain selected.";
const last = "Last synthetic paragraph stays separate.";
const prompt = first ++ "\n\n" ++ middle ++ "\n\n" ++ last;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *@This(), text: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = false;
        h.a.openChat("synthetic-selection", null);
        h.a.composer.set(text);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{
            .width = 1000,
            .height = 1000,
            .scale = 2,
            .dark = false,
            .theme = @import("theme.zig").ui(false),
        });
        h.t.settle(1);
    }

    fn deinit(h: *@This()) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn point(h: *@This(), needle: []const u8) !ui.Point {
        for (h.t.ctx.nodes.items) |n| {
            if (n.content != .text) continue;
            const text = n.content.text;
            const at = std.mem.indexOf(u8, text.str, needle) orelse continue;
            return .{
                .x = n.rect.x + h.t.ctx.text.width(text.str[0..at], text.style) + 2,
                .y = n.rect.y + n.rect.h / 2,
            };
        }
        return error.SyntheticComposerTextMissing;
    }

    fn press(h: *@This(), needle: []const u8, clicks: u32) !ui.Point {
        const p = try h.point(needle);
        h.t.moveTo(p.x, p.y);
        h.t.ctx.input.click_count = clicks;
        h.t.ctx.pointerDown();
        h.t.frame();
        return p;
    }

    fn expectSelected(h: *@This(), expected: []const u8) !void {
        const e = h.t.ctx.edits.get(h.t.ctx.focus) orelse return error.ComposerEditMissing;
        try testing.expectEqualStrings(expected, h.a.composer.text()[@min(e.anchor, e.caret)..@max(e.anchor, e.caret)]);
    }

    fn snap(h: *@This(), name: []const u8) !void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try h.t.screenshot(path);
    }
};

test "composer selection held double click selects the whole word" {
    var h: Harness = undefined;
    try h.init("Synthetic paragraph");
    defer h.deinit();
    const p = try h.press("graph", 2);
    h.t.advance(0.2);
    try h.snap("composer-double-click-word");
    try h.expectSelected("paragraph");
    h.t.move(p.x + 1, p.y);
    try h.expectSelected("paragraph");
    h.t.up();
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings("paragraph", h.t.clipboard.items);
}

test "composer selection double click owns both edges of Unicode words and graphemes" {
    for ([_][]const u8{ "café", "a\u{301}", "👩‍💻", "👍🏽" }) |token| {
        var h: Harness = undefined;
        const text = try std.fmt.allocPrint(testing.allocator, "Start {s} end.", .{token});
        defer testing.allocator.free(text);
        try h.init(text);
        defer h.deinit();
        const p = try h.point(token);
        const width = h.t.ctx.text.width(token, .{ .size = 14, .line_height = 22.75 });
        for ([_]f32{ 0.01, 0.49, 0.51, 0.99 }) |fraction| {
            h.t.moveTo(p.x - 2 + width * fraction, p.y);
            h.t.ctx.input.click_count = 2;
            h.t.ctx.pointerDown();
            h.t.frame();
            h.t.advance(0.1);
            h.t.up();
            try h.expectSelected(token);
        }
    }
}

test "composer selection triple click selects the complete wrapped sentence" {
    var h: Harness = undefined;
    try h.init(prompt);
    defer h.deinit();
    _ = try h.press("café", 3);
    h.t.advance(0.2);
    try h.snap("composer-triple-click-sentence");
    try h.expectSelected(sentence);
    h.t.up();
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(sentence, h.t.clipboard.items);
}

test "composer selection four clicks select the complete wrapped paragraph" {
    var h: Harness = undefined;
    try h.init(prompt);
    defer h.deinit();
    _ = try h.press("café", 4);
    h.t.advance(0.2);
    try h.snap("composer-four-click-paragraph");
    try h.expectSelected(middle);
    h.t.up();
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(middle, h.t.clipboard.items);
    h.t.typeText("Replacement");
    try testing.expectEqualStrings(first ++ "\n\nReplacement\n\n" ++ last, h.a.composer.text());
    _ = h.t.shortcut(.{ .key = 'z', .cmd = true });
    try testing.expectEqualStrings(prompt, h.a.composer.text());
}

test "composer selection clicks never select all and Cmd A includes offscreen text" {
    var h: Harness = undefined;
    const long_prompt = prompt ++ "\n\n" ++ middle ++ "\n\n" ++ last ++ "\n\n" ++ middle;
    try h.init(long_prompt);
    defer h.deinit();
    try testing.expect((h.t.ctx.scroll_max.get(h.a.view.composer_id) orelse 0) > 0);
    for ([_]u32{ 2, 3, 4, 5, 8 }) |clicks| {
        _ = try h.press("café", clicks);
        h.t.advance(0.2);
        try h.expectSelected(if (clicks == 2) "café" else if (clicks == 3) sentence else middle);
        h.t.up();
    }
    _ = h.t.shortcut(.{ .key = 'a', .cmd = true });
    try h.expectSelected(long_prompt);
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(long_prompt, h.t.clipboard.items);
}

test "composer selection expanded Write editor shares word sentence paragraph and Cmd A" {
    var h: Harness = undefined;
    try h.init(prompt);
    defer h.deinit();
    @import("view_write.zig").open(&h.a);
    h.t.settle(1);
    for ([_]u32{ 2, 3, 4, 5, 8 }) |clicks| {
        _ = try h.press("café", clicks);
        h.t.advance(0.2);
        const expected = if (clicks == 2) "café" else if (clicks == 3) sentence else middle;
        try h.expectSelected(expected);
        h.t.up();
        h.t.textOps(&.{.{ .command = .copy }});
        try testing.expectEqualStrings(expected, h.t.clipboard.items);
    }
    _ = h.t.shortcut(.{ .key = 'a', .cmd = true });
    try h.expectSelected(prompt);
    h.t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings(prompt, h.t.clipboard.items);
}

test "composer selection paragraph drag extends whole units in both directions" {
    var h: Harness = undefined;
    try h.init(prompt);
    defer h.deinit();
    _ = try h.press("café", 4);
    const end = try h.point("Last");
    h.t.move(end.x, end.y);
    try h.expectSelected(middle ++ "\n\n" ++ last);
    const start = try h.point("First");
    h.t.move(start.x, start.y);
    try h.expectSelected(first ++ "\n\n" ++ middle);
    h.t.up();
    _ = try h.press("café", 1);
    try h.expectSelected("");
    h.t.move(end.x, end.y);
    const e = h.t.ctx.edits.get(h.a.view.composer_id).?;
    try testing.expect(e.anchor > 0 and e.caret < prompt.len);
    h.t.up();
}
