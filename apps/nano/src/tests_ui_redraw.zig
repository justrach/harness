//! #814: synthetic working rows must not repeatedly parse an unchanged transcript.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const md = @import("markdown.zig");
const highlight = @import("highlight.zig");
const testing = std.testing;

fn fixture(a: *App, t: *ui.Tester) !void {
    @import("theme.zig").registerFonts();
    a.* = .init(testing.allocator, testing.io, 1);
    a.offscreen = true;
    a.dark = true;
    a.view.sidebar_open = false;
    a.settings.set(.transcript_compact_mode, false);
    a.openChat("synthetic", null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"answer","kind":"text","text":"# Synthetic reply\n\nA **complete** answer with `inline code`.\n\n```zig\nconst answer: u32 = 42;\n// Unchanged code\n```"}]}]}
    , .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
    try t.init(testing.allocator, .init(a, @import("view.zig").view), .{ .width = 900, .height = 700, .dark = true });
    t.settle(1);
}

test "#814 unchanged animation frames avoid markdown and syntax work by at least 5x" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try fixture(&a, &t);
    defer a.deinit();
    defer t.deinit();
    md.test_parse_calls = 0;
    highlight.test_line_calls = 0;
    // Six animation ticks, with no text, palette or width changes.
    for (0..6) |_| t.frame();
    const warm_parses = md.test_parse_calls;
    const warm_lines = highlight.test_line_calls;
    // The old path parses and highlights on every frame. Compare actual
    // work against that path, independent of machine speed and scheduler.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const colors = @import("theme.zig").colors(true);
    for (0..6) |_| {
        _ = md.parse(arena.allocator(), "# Synthetic reply\n\nA **complete** answer.", .{ .code = colors.accent, .code_bg = colors.accent_wash, .link = colors.text, .muted = colors.muted });
        var state: highlight.State = .{};
        _ = highlight.line(arena.allocator(), "const answer: u32 = 42;", "zig", colors.syntax, &state);
    }
    try testing.expect((md.test_parse_calls - warm_parses) >= @max(1, warm_parses) * 5);
    try testing.expect((highlight.test_line_calls - warm_lines) >= @max(1, warm_lines) * 5);
    try testing.expect(t.containsText("Synthetic reply"));
    try testing.expect(t.containsText("const answer: u32 = 42;"));
}

test "#814 visible working indicators schedule at most two whole-window frames per second" {
    @import("theme.zig").registerFonts();
    var state: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&state, struct {
        fn view(_: *u8, c: *ui.Context) void {
            @import("view_kit.zig").snake(c, @import("theme.zig").colors(true));
        }
    }.view), .{ .width = 900, .height = 700, .dark = true });
    defer t.deinit();
    t.frame();
    const tick = t.ctx.frame_in orelse return error.MissingWorkingTick;
    try testing.expect(tick >= 0.5);
}

test "#814 a different working chat builds at least 5x fewer transcript nodes" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try fixture(&a, &t);
    defer a.deinit();
    defer t.deinit();
    // Measure the intentionally full fixture tree as the reference. The
    // ordinary settled live path now culls too, even before another chat works.
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(testing.allocator);
    try history.appendSlice(testing.allocator, "{\"reset\":[");
    for (0..600) |i| {
        if (i > 0) try history.appendSlice(testing.allocator, ",");
        try history.print(testing.allocator, "{{\"id\":\"a{d}\",\"role\":\"assistant\",\"status\":\"complete\",\"parts\":[{{\"id\":\"p\",\"kind\":\"text\",\"text\":\"Synthetic paragraph {d} with **bold** words.\\n\\nAnother paragraph.\"}}]}}", .{ i, i });
    }
    try history.appendSlice(testing.allocator, "]}");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, history.items, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
    t.settle(1);
    const full_nodes = t.ctx.nodes.items.len;
    // Exercise the on-screen culling path with no engine or personal data.
    a.offscreen = false;
    const sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"other-synthetic","status":"working"}]
    , .{});
    defer sessions.deinit();
    try a.sessions.replace(sessions.value);
    t.settle(1);
    try testing.expect(full_nodes >= t.ctx.nodes.items.len * 5);
    try testing.expect(t.containsText("Synthetic paragraph 599"));
}
