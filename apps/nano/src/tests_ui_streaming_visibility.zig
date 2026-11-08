//! A live turn's content must be on screen, not merely present in the
//! retained node tree. Synthetic replies grow, fold, and replace parts.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

fn apply(a: *App, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
}

fn visible(t: *ui.Tester, text: []const u8) !void {
    const rect = t.findText(text) orelse return error.MissingLiveText;
    if (!(rect.h > 0 and rect.y >= 38 and rect.y + rect.h < t.size.h - 80)) {
        std.debug.print("live text outside transcript: y={d} height={d} window={d}\n", .{ rect.y, rect.h, t.size.h });
        return error.LiveTextOutsideViewport;
    }
}

test "a short live turn stays visible when its expanded reasoning shrinks to tool rows" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.settings.set(.transcript_compact_mode, false);
    a.offscreen = true;
    a.dark = false;
    a.view.sidebar_open = false;
    a.openChat("synthetic", null);
    try apply(&a,
        \\{"reset":[
        \\ {"id":"u1","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic first prompt"}]},
        \\ {"id":"a1","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic first answer"}]},
        \\ {"id":"u2","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic second prompt"}]},
        \\ {"id":"a2","role":"assistant","status":"streaming","parts":[{"id":"thought","kind":"reasoning","text":"Synthetic live thought"},{"id":"answer","kind":"text","text":""}]}]}
    );
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 900, .height = 750, .dark = false });
    defer t.deinit();
    t.settle(1);
    try visible(&t, "Synthetic second prompt");
    if (@import("builtin").os.tag == .macos) {
        try t.clickText("Thought process");
        t.settle(1);
    }
    try visible(&t, "Synthetic live thought");

    // A long live thought moves the viewport to its end. Replacing that
    // entry with short tool rows must clamp the old scroll offset.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);
    try frame.appendSlice(testing.allocator,
        \\{"upsert":[{"after":"u2","entry":{"id":"a2","role":"assistant","status":"streaming","parts":[{"id":"thought","kind":"reasoning","text":"
    );
    for (0..80) |_| try frame.appendSlice(testing.allocator, "A synthetic paragraph of live reasoning.\\n\\n");
    try frame.appendSlice(testing.allocator,
        \\Last synthetic live paragraph"},{"id":"answer","kind":"text","text":""}]}}],"count":4}
    );
    try apply(&a, frame.items);
    t.settle(1);
    try testing.expect(t.containsText("Last synthetic live paragraph"));

    try apply(&a,
        \\{"upsert":[{"after":"u2","entry":{"id":"a2","role":"assistant","status":"streaming","parts":[
        \\ {"id":"read1","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"synthetic-one.zig"}},
        \\ {"id":"read2","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"synthetic-two.zig"}},
        \\ {"id":"read3","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"synthetic-three.zig"}},
        \\ {"id":"answer","kind":"text","text":""}]}}],"count":4}
    );
    t.settle(1);
    try visible(&t, "Synthetic second prompt");
    try visible(&t, "Read 3 files");
    t.advance(2);
    try visible(&t, "Read 3 files");

    try apply(&a,
        \\{"append":[{"entry":"a2","part":"answer","text":"Synthetic final reply","len":21}],"count":4}
    );
    t.settle(1);
    try visible(&t, "Synthetic final reply");
}


test "an unfocused window slows loader redraws and an off-screen spinner schedules none" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = true;
    a.view.sidebar_open = false;
    a.openChat("synthetic", null);
    const agents = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"graff","name":"graff","enabled":true}]
    , .{});
    defer agents.deinit();
    try a.harnesses.replace(agents.value);
    const models = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic","label":"Synthetic","maker":"openai"}]
    , .{});
    defer models.deinit();
    try a.models.replace(models.value);
    a.new_harness = try testing.allocator.dupe(u8, "graff");
    a.new_model = try testing.allocator.dupe(u8, "synthetic");
    const sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"synthetic","status":"working","startedAt":"2026-10-03T00:00:00Z","updatedAt":"2026-10-03T00:00:00Z"}]
    , .{});
    defer sessions.deinit();
    try a.sessions.replace(sessions.value);
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(testing.allocator);
    try history.appendSlice(testing.allocator, "{\"reset\":[");
    for (0..40) |i| {
        if (i > 0) try history.appendSlice(testing.allocator, ",");
        try history.print(testing.allocator, "{{\"id\":\"u{d}\",\"role\":\"user\",\"parts\":[{{\"id\":\"p\",\"kind\":\"text\",\"text\":\"Synthetic prompt {d}\"}}]}}", .{ i, i });
    }
    try history.appendSlice(testing.allocator, ",{\"id\":\"live\",\"role\":\"assistant\",\"status\":\"streaming\",\"parts\":[]}]}");
    try apply(&a, history.items);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 900, .height = 420, .dark = true });
    defer t.deinit();
    t.frame();
    const focused = t.ctx.frame_in orelse return error.LoaderNotScheduled;
    try testing.expect(focused <= 1.0 / 15.0 + 0.001);

    t.ctx.input.window_active = false;
    t.frame();
    const unfocused = t.ctx.frame_in orelse return error.BackgroundLoaderNotScheduled;
    try testing.expectApproxEqAbs(focused * @import("view_kit.zig").background_tick_divisor, unfocused, 0.001);

    // Leave the working trailer below the window. GPUI never mounts that
    // row; Nano must not keep redrawing a spinner the reader cannot see.
    const box = for (t.ctx.nodes.items) |n| {
        if (n.style.scroll and n.rect.h > 200) break n.id;
    } else return error.NoTranscriptScroll;
    try t.ctx.scroll.put(t.ctx.gpa, box, 0);
    try t.ctx.scroll_follow.put(t.ctx.gpa, box, false);
    // The frame that applies the scroll still sees the previous on-screen
    // rect. The next one must not paint or schedule the hidden loader.
    t.frame();
    t.frame();
    if (t.containsText("Working out the next step")) {
        var on_screen = false;
        for (t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.indexOf(u8, tx.str, "Working out the next step") != null and n.rect.y + n.rect.h > 0 and n.rect.y < t.size.h) {
                on_screen = true;
            },
            else => {},
        };
        if (on_screen) return error.TrailerStillVisible;
    }
    // The overlay scrollbar lingers after the jump. Once that fade is gone,
    // an off-screen working trailer must not keep a loader tick alive.
    t.advance(1.7);
    try testing.expect(t.ctx.frame_in == null);
}
