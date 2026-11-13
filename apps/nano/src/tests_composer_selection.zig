//! Composer gestures use synthetic drafts and the Tester's private clipboard.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;
const first = "First synthetic paragraph stays separate.";
const middle = "A café paragraph wraps across the composer with enough synthetic words to occupy several visual lines. Its complete text must remain selected.";
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

test "composer selection held double click never truncates at the cursor" {
    var h: Harness = undefined;
    try h.init("Synthetic paragraph");
    defer h.deinit();
    const p = try h.press("graph", 2);
    h.t.advance(0.2);
    try h.snap("composer-held-double-click");
    try h.expectSelected("Synthetic paragraph");
    h.t.move(p.x + 1, p.y);
    try h.expectSelected("Synthetic paragraph");
    h.t.up();
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings("Synthetic paragraph", h.t.clipboard.items);
}

test "composer selection double click selects the complete wrapped paragraph" {
    var h: Harness = undefined;
    try h.init(prompt);
    defer h.deinit();
    _ = try h.press("café", 2);
    h.t.advance(0.2);
    try h.snap("composer-double-click-paragraph");
    try h.expectSelected(middle);
    h.t.up();
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(middle, h.t.clipboard.items);
    h.t.typeText("Replacement");
    try testing.expectEqualStrings(first ++ "\n\nReplacement\n\n" ++ last, h.a.composer.text());
    _ = h.t.shortcut(.{ .key = 'z', .cmd = true });
    try testing.expectEqualStrings(prompt, h.a.composer.text());
}

test "composer selection triple click selects the full prompt including offscreen text" {
    var h: Harness = undefined;
    const long_prompt = prompt ++ "\n\n" ++ middle ++ "\n\n" ++ last ++ "\n\n" ++ middle;
    try h.init(long_prompt);
    defer h.deinit();
    try testing.expect((h.t.ctx.scroll_max.get(h.a.view.composer_id) orelse 0) > 0);
    _ = try h.press("Last", 3);
    h.t.advance(0.2);
    try h.snap("composer-triple-click-prompt");
    try h.expectSelected(long_prompt);
    try testing.expect(h.t.ctx.edits.get(h.a.view.composer_id).?.scroll_y > 0);
    h.t.up();
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(h.a.composer.text(), h.t.clipboard.items);
}

test "composer selection expanded Write editor uses paragraph and full prompt gestures" {
    var h: Harness = undefined;
    try h.init(prompt);
    defer h.deinit();
    @import("view_write.zig").open(&h.a);
    h.t.settle(1);
    _ = try h.press("café", 2);
    h.t.advance(0.2);
    try h.expectSelected(middle);
    h.t.up();
    _ = try h.press("café", 3);
    h.t.advance(0.2);
    try h.expectSelected(prompt);
    h.t.up();
    // Native editors receive Copy as a text-input command.
    h.t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings(prompt, h.t.clipboard.items);
}

test "composer selection paragraph drag extends whole units in both directions" {
    var h: Harness = undefined;
    try h.init(prompt);
    defer h.deinit();
    _ = try h.press("café", 2);
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
