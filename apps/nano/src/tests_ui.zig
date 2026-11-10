//! The window driven as a person would, headlessly (nanoui's Tester), on
//! made-up chats and no engine: the GPUI app's split-pane shortcuts.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;

const testing = std.testing;

const chats =
    \\[{"id":"a","deviceId":"d","title":"Alpha","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Beta","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z"}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        // Each step as its own row: these tests are about the detailed transcript.
        h.a.settings.set(.transcript_compact_mode, false);
        h.a.dark = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        h.a.openChat("a", null);
        // These tests drive the one-list sidebar (its Sessions disclosure,
        // pins dragged to and from it), as GPUI's sidebar tests pick their
        // organization; "By status", the default, has its own test.
        h.a.settings.setText("sidebarOrganization", "inOneList");
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn showTab(h: *Harness, i: usize) void {
        h.a.showTab(i);
        h.t.settle(1);
    }

    fn press(h: *Harness, s: ui.Shortcut) void {
        _ = h.t.shortcut(s);
        h.t.settle(1);
    }

    /// `NANO_SNAP_DIR=dir zig build test` saves what the test saw.
    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "the new-chat canvas keeps the project sidebar and its sessions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.settings.setText("sidebarOrganization", "byProject");
    h.a.offscreen = true;
    h.a.select(null, null);
    h.t.settle(1);
    h.snap("new-chat-sidebar");
    try testing.expect(h.t.hasText("All projects"));
    try testing.expect(h.t.hasText("Alpha"));
    try testing.expect(h.t.hasText("Beta"));
}

fn sidebarChats(h: *Harness, count: usize) !void {
    try sidebarRows(h, count, false, false);
}

fn sidebarRows(h: *Harness, count: usize, branches: bool, grouped: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var rows: std.json.Array = .init(gpa);
    for (0..count) |i| {
        const text = try std.fmt.allocPrint(gpa,
            \\{{"id":"synthetic-{d}","deviceId":"{s}","title":"Synthetic session {d}","cwd":"/synthetic","sourceContext":{{"cwd":"/synthetic","branch":{s}}},"archived":false,"lastMessageAt":"2026-10-03T00:00:00Z"}}
        , .{ i, if (grouped) try std.fmt.allocPrint(gpa, "device-{d}", .{i}) else "d", i, if (branches and i % 2 != 0) "\"feature\"" else "null" });
        try rows.append((try std.json.parseFromSlice(std.json.Value, gpa, text, .{})).value);
    }
    try h.a.chats.replace(.{ .array = rows });
    h.t.settle(1);
}

test "Cmd+L focuses the active composer from the transcript, including a split pane" {
    for ([_]bool{ false, true }) |split| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        if (split) h.press(.{ .key = 'd', .cmd = true });
        h.t.ctx.focus = 0;
        h.press(.{ .key = 'l', .cmd = true });
        try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
        h.t.typeText("Synthetic focused draft");
        try testing.expectEqualStrings("Synthetic focused draft", h.a.composer.text());
    }
}

test "a live ACP thought remains visible before the empty answer receives text" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"assistant","role":"assistant","status":"streaming","parts":[
        \\ {"id":"thought","kind":"reasoning","text":"A synthetic live thought"},
        \\ {"id":"answer","kind":"text","text":""}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Thought process"));
    // macOS deliberately keeps live work behind its disclosure.
    if (@import("builtin").os.tag == .macos) {
        try h.t.clickText("Thought process");
        h.t.settle(1);
    }
    try testing.expect(h.t.hasText("A synthetic live thought"));
}

test "an empty sidebar matches GPUI without a Sessions disclosure" {
    for ([_][]const u8{ "inOneList", "byStatus" }) |organization| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.a.settings.setText("sidebarOrganization", organization);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        h.t.settle(1);
        try testing.expect(h.t.hasText("No sessions yet"));
        try testing.expect(!h.t.hasText("Sessions"));
    }
}

test "By status, the default: Needs you above Today above Earlier, under the project filter alone" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.settings.setText("sidebarOrganization", "byStatus");
    const now = h.a.nowMs();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const iso = struct {
        fn of(a: std.mem.Allocator, ms: i64) ![]const u8 {
            const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
            const day = es.getEpochDay().calculateYearDay();
            const md = day.calculateMonthDay();
            const ds = es.getDaySeconds();
            return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
        }
    }.of;
    const text = try std.fmt.allocPrint(arena.allocator(),
        \\[{{"id":"old","deviceId":"d","title":"Last week's","archived":false,"lastMessageAt":"2026-01-02T00:00:00Z"}},
        \\ {{"id":"new","deviceId":"d","title":"Fresh one","archived":false,"lastMessageAt":"{s}"}},
        \\ {{"id":"ask","deviceId":"d","title":"Has a question","archived":false,"lastMessageAt":"2026-01-01T00:00:00Z"}}]
    , .{try iso(arena.allocator(), now)});
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try h.a.chats.replace(parsed.value);
    const sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator, try std.fmt.allocPrint(arena.allocator(),
        \\[{{"chatId":"ask","status":"awaitingInput","updatedAt":"{s}"}}]
    , .{try iso(arena.allocator(), now)}), .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    h.a.resort();
    h.t.settle(1);
    h.snap("by-status");
    const needs = h.t.findText("Needs you") orelse return error.NoNeedsYou;
    const today = h.t.findText("Today") orelse return error.NoToday;
    const earlier = h.t.findText("Earlier") orelse return error.NoEarlier;
    try testing.expect(needs.y < today.y and today.y < earlier.y);
    try testing.expect(needs.y < (h.t.findText("Has a question") orelse return error.NoRow).y);
    try testing.expect(today.y < (h.t.findText("Fresh one") orelse return error.NoRow).y);
    try testing.expect(earlier.y < (h.t.findText("Last week's") orelse return error.NoRow).y);
    // GPUI dropped the full-width New chat and Search chats rows (shell.rs,
    // 78e69e483): the title bar's + and the filter row's search cover both,
    // and the filter sits right under the tabs.
    try testing.expect(!h.t.hasText("New chat"));
    try testing.expect(!h.t.hasText("Search chats"));
    const filter = h.t.findText("All projects") orelse return error.NoFilter;
    try testing.expect(filter.y < needs.y and filter.y < 38 + 26 + 10 + 40);
}

test "file tool badges preserve Harness identity colors and reuse their cached SVGs" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.a.dark = dark;
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[{"id":"assistant","role":"assistant","status":"complete","parts":[
            \\ {"id":"read-0","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"/work/demo/README.md"}},
            \\ {"id":"read-1","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"/work/demo/Cargo.toml"}},
            \\ {"id":"read-2","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"/work/demo/src/main.rs"}}]}]}
        , .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
        try h.t.clickText("Read 3 files");
        h.t.settle(1);
        h.snap(if (dark) "file-icons-dark" else "file-icons-light");
        var identities: usize = 0;
        var previous_y: ?f32 = null;
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .image => |im| if (im.tint == null) {
                if (previous_y) |y| try testing.expectApproxEqAbs(@as(f32, 32), node.rect.y - y, 0.01);
                previous_y = node.rect.y;
                identities += 1;
            },
            else => {},
        };
        try testing.expectEqual(@as(usize, 3), identities);
        try testing.expect(h.t.hasText("README.md"));
        try testing.expect(h.t.hasText("Cargo.toml"));
        try testing.expect(h.t.hasText("main.rs"));
        const cached = h.t.text.images.decoded.count();
        h.t.frame();
        try testing.expectEqual(cached, h.t.text.images.decoded.count());
    }
}

test "ACP tool output is available from its transcript chip" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"assistant","role":"assistant","status":"complete","parts":[
        \\ {"id":"call","kind":"tool","resolved":true,"isError":false,
        \\ "call":{"kind":"exec","command":"printf synthetic"},"output":"Synthetic ACP tool output"}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    try h.t.clickText("Ran 1 command");
    h.t.settle(1);
    try h.t.clickText("Run");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Synthetic ACP tool output"));
}

test "a working chat shows a trailer even before the agent publishes any parts" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working","startedAt":"2026-10-26T00:00:00Z","updatedAt":"2026-10-26T00:00:00Z"}]
    , .{});
    defer parsed.deinit();
    try h.a.sessions.replace(parsed.value);
    h.a.sessions.items[0].updated_ms = h.a.nowMs();
    h.a.sessions.items[0].started_ms = h.a.nowMs();
    h.t.settle(1);
    // The session, not the arrival of a reasoning/text part, drives liveness.
    var buf: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&buf, "{s}…", .{@import("view_working.zig").word("a", 0)});
    try testing.expect(h.t.hasText(label));
    h.a.sessions.items[0].status = .idle;
    h.t.settle(1);
    try testing.expect(!h.t.hasText(label));
}

test "a quiet active turn says it is waiting for the model" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic slow request"}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working","startedAt":"2026-10-26T00:00:00Z","updatedAt":"2026-10-26T00:00:00Z"}]
    , .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    h.a.sessions.items[0].started_ms = h.a.nowMs() - 90_000;
    h.a.sessions.items[0].updated_ms = h.a.nowMs() - 90_000;
    h.t.settle(1);
    try testing.expect(h.t.containsText("Waiting for the model"));
    try testing.expect(h.t.containsText("no update for 1m 30s"));

    // A stale row after a finished reply is not a running turn.
    var finished = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"a","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic answer"}]}]}
    , .{});
    defer finished.deinit();
    try h.a.transcript.apply(finished.value);
    h.t.settle(1);
    try testing.expect(!h.t.containsText("Waiting for the model"));
}

test "a working trailer names the current plan step and action" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"live","role":"assistant","status":"streaming","parts":[
        \\ {"id":"plan","kind":"tool","resolved":true,"call":{"kind":"todo","items":[
        \\   {"text":"Inspect the saved choice","done":true},
        \\   {"text":"Verify the project grouping","done":false}]}},
        \\ {"id":"run","kind":"tool","resolved":false,"call":{"kind":"exec","command":"zig build test"}}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working","startedAt":"2026-10-26T00:00:00Z","updatedAt":"2026-10-26T00:00:00Z"}]
    , .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    h.a.sessions.items[0].started_ms = h.a.nowMs();
    h.a.sessions.items[0].updated_ms = h.a.nowMs();
    h.t.settle(1);
    try testing.expect(h.t.hasText("Verify the project grouping"));
    try testing.expect(h.t.hasText("Run · zig build test"));
}

test "an ACP reply with more than 256 runs does not lose its final answer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(gpa, "{\"reset\":[{\"id\":\"long-turn\",\"role\":\"assistant\",\"status\":\"complete\",\"parts\":[");
    for (0..130) |i| {
        try text.appendSlice(gpa, try std.fmt.allocPrint(gpa,
            \\{{"id":"tool-{d}","kind":"tool","resolved":true,"call":{{"kind":"readFile","path":"synthetic.zig"}}}},
            \\{{"id":"text-{d}","kind":"text","text":"Synthetic progress"}},
        , .{ i, i }));
    }
    try text.appendSlice(gpa, "{\"id\":\"answer\",\"kind\":\"text\",\"text\":\"The final synthetic answer remains visible\"}]}]}");
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text.items, .{});
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    try testing.expect(h.t.hasText("The final synthetic answer remains visible"));
}

test "an ACP chip lazily fetches its full output from the engine" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"FetchToolBlob":{"text":"Full synthetic ACP tool output"}}
    , .{});
    h.a.engine.state = .connected;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"assistant","role":"assistant","status":"complete","parts":[
        \\ {"id":"call","kind":"tool","resolved":true,"isError":false,
        \\ "call":{"kind":"exec","command":"printf synthetic"},"outputRef":"a/call","outputBytes":4096}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    try h.t.clickText("Ran 1 command");
    h.t.settle(1);
    try h.t.clickText("Run");
    h.t.settle(1);
    try h.t.clickText("Show full output");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Full synthetic ACP tool output"));
    var fetches: usize = 0;
    for (h.a.engine.sent.items) |request| {
        if (std.mem.indexOf(u8, request, "\"method\":\"FetchToolBlob\"") != null) fetches += 1;
    }
    try testing.expectEqual(@as(usize, 1), fetches);
}

test "composer keystrokes only build the sidebar rows in view" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.view.focus_composer = true;
    try sidebarChats(&h, 50);
    h.t.textOps(&.{.{ .insert = "a" }});
    const small_nodes = h.t.ctx.stats.nodes;
    const small_ms = h.t.ctx.stats.build_ms + h.t.ctx.stats.layout_ms + h.t.ctx.stats.paint_ms;
    try sidebarChats(&h, 2000);
    h.t.textOps(&.{.{ .insert = "b" }});
    const large_nodes = h.t.ctx.stats.nodes;
    const large_ms = h.t.ctx.stats.build_ms + h.t.ctx.stats.layout_ms + h.t.ctx.stats.paint_ms;
    try testing.expectEqualStrings("ab", h.a.composer.text());
    std.log.info("composer sidebar: 50 sessions {d} nodes / {d:.2} ms; 2000 sessions {d} nodes / {d:.2} ms", .{ small_nodes, small_ms, large_nodes, large_ms });
    // A large offscreen history must not turn each key into thousands of
    // shaped, laid-out and painted rows. Compare the shape, not a tight
    // wall-clock limit that depends on the machine running the test.
    try testing.expect(large_nodes <= small_nodes * 2);
}

test "sidebar culls whole offscreen groups without changing their extent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // Keep four-digit fixture titles complete; row lookup is not testing fade.
    h.a.settings.setNumber("sidebarWidth", 360);
    h.a.settings.setText("sidebarOrganization", "byDevice");
    try sidebarRows(&h, 50, false, true);
    const small_nodes = h.t.ctx.stats.nodes;
    try sidebarRows(&h, 2000, false, true);
    try testing.expect(h.t.ctx.stats.nodes <= small_nodes * 2);
    const first = h.t.findText("Synthetic session 0") orelse return error.FirstGroupMissing;
    // Each group:14 above,28 header,4 body inset,38 row,2 gap.
    h.t.scroll(100, 300, -86 * 1000);
    const middle = h.t.findText("Synthetic session 1000") orelse return error.JumpGroupMissing;
    try testing.expectApproxEqAbs(first.y, middle.y, 1);
    h.t.scroll(100, 300, -86 * 2000);
    const last = h.t.findText("Synthetic session 1999") orelse return error.LastGroupMissing;
    try testing.expect(last.y >= 0 and last.y < 780);
    try testing.expect(h.t.ctx.stats.nodes <= small_nodes * 2);
}

test "sidebar large wheel jumps and resizes retain mixed-height rows and exact scroll extent" {
    for (0..3) |mode| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        // Isolate row virtualization from grouping and title fading.
        h.a.settings.setNumber("sidebarWidth", 360);
        h.a.settings.setText("sidebarOrganization", "inOneList");
        h.a.settings.set(.sidebar_compact, mode == 0);
        h.a.settings.set(.sidebar_show_project_label, mode == 1);
        h.a.settings.set(.sidebar_show_updated, mode != 2);
        h.a.settings.set(.sidebar_show_harness, mode != 2);
        h.a.settings.set(.sidebar_show_project_icon, false);
        h.a.settings.set(.sidebar_show_branch, true);
        try sidebarRows(&h, 2000, true, false);
        const first = h.t.findText("Synthetic session 0") orelse return error.FirstRowMissing;
        try testing.expect(first.y >= 0 and first.y < 780);
        var rects = h.t.ctx.rects.iterator();
        var body: u64 = 0;
        var extent: f32 = 0;
        while (rects.next()) |entry| {
            const r = entry.value_ptr.*;
            if (r.w == @import("view_sidebar.zig").widthOf(&h.a) - 16 and r.h > extent) {
                body = entry.key_ptr.*;
                extent = r.h;
            }
        }
        const stride: f32 = switch (mode) {
            0, 1 => 40, //38px navigation rows plus2px gaps.
            else => 36, // Branch-only context alternates30/38px rows.
        };
        try testing.expectApproxEqAbs(stride * 2000 - 2, extent, 1);
        // No settle: the input frame itself must build the destination rows,
        // even when the toolkit rebuilds before laying out the wheel result.
        h.t.scroll(100, 300, -stride * 1000);
        const middle = h.t.findText("Synthetic session 1000") orelse return error.JumpRowMissing;
        try testing.expectApproxEqAbs(first.y, middle.y, 1);
        try testing.expectApproxEqAbs(extent, h.t.ctx.rects.get(body).?.h, 1);
        try testing.expect(h.t.ctx.stats.nodes < 1000);
        h.t.resize(1200, 980);
        try testing.expectApproxEqAbs(extent, h.t.ctx.rects.get(body).?.h, 1);
        h.t.scroll(100, 300, -stride * 2000);
        const last = h.t.findText("Synthetic session 1999") orelse return error.LastRowMissing;
        try testing.expect(last.y >= 0 and last.y < 980);
        try testing.expectApproxEqAbs(extent, h.t.ctx.rects.get(body).?.h, 1);
        h.t.scroll(100, 300, stride * 4000);
        const again = h.t.findText("Synthetic session 0") orelse return error.ReturnRowMissing;
        try testing.expectApproxEqAbs(first.y, again.y, 1);
        // The keyed destination is still the same chat after it was culled.
        h.t.click(100, again.y + again.h / 2);
        try testing.expectEqualStrings("synthetic-0", h.a.selected.?);
    }
}

test "⌘D splits the chat to the right, the new pane a new chat with focus; ⌘[ goes back; ⌘W closes the pane" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    const s = h.a.tabs.layout().?;
    try testing.expectEqual(@as(usize, 2), s.panes.items.len);
    try testing.expectEqual(@as(f32, 0.5), s.shares.items[0]);
    try testing.expect(h.a.selected == null);
    // Alpha's pane shows nothing when it has nothing (as GPUI's).
    try testing.expect(!h.t.hasText("Nothing here yet."));
    h.snap("split-right");
    h.press(.{ .key = '[', .cmd = true });
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.press(.{ .key = ']', .cmd = true });
    try testing.expect(h.a.selected == null);
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
}

test "a vertical split supports focusing the pane above and zooming the focused pane" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.splitPane(.vertical);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expect(h.a.tabs.layout().?.axis == .vertical);
    // Across the split's axis: nothing.
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    h.snap("split-down");
    h.press(.{ .key = ui.Shortcut.up, .cmd = true, .alt = true });
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expect(h.a.tabs.layout().?.zoomed);
    try testing.expect(!h.t.hasText("Empty pane"));
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expect(h.t.hasText("Empty pane"));
}

test "clicking the other pane focuses it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    // The left pane's middle: Alpha's.
    h.t.click(256 + (1200 - 256) / 4, 300);
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
}

test "a new pane starts with an empty prompt; each pane and tab keeps its own" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // A new chat with a prompt typed, split: the new pane's is empty, on
    // the same agent; going back finds the prompt as it was left.
    h.press(.{ .key = 't', .cmd = true });
    try testing.expect(h.a.view.open_chooser.open);
    @import("app_open_chooser.zig").chooseProjectless(&h.a);
    h.t.settle(1);
    h.a.composer.set("hey there");
    const harness = try testing.allocator.dupe(u8, h.a.new_harness);
    defer testing.allocator.free(harness);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqualStrings(harness, h.a.new_harness);
    h.a.composer.set("the right pane's");
    h.press(.{ .key = '[', .cmd = true });
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    h.press(.{ .key = ']', .cmd = true });
    try testing.expectEqualStrings("the right pane's", h.a.composer.text());
    // ⌘W: the left pane's prompt comes back with it.
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    // Choosing another top-level tab restores its draft.
    h.a.showTab(0);
    h.t.settle(1);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.composer.set("about alpha");
    h.a.showTab(1);
    h.t.settle(1);
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    h.a.showTab(0);
    h.t.settle(1);
    try testing.expectEqualStrings("about alpha", h.a.composer.text());
}

test "in a narrow pane the starter chips stay inside it above the dock, with room for their icons" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1100, 760);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"s","deviceId":"d","path":"/work/fieldnotes"}]
    , .{});
    defer parsed.deinit();
    try h.a.spaces.replace(parsed.value);
    h.a.select(null, "s");
    for (0..3) |_| h.press(.{ .key = 'd', .cmd = true });
    h.snap("narrow-chips");
    // Current starters are28px wrapped chips ABOVE the input. Their
    // truncated titles must still leave11px padding,13px icon,6px gap.
    const titles = [_][]const u8{ "B", "R", "P", "T" };
    const pill = h.a.view.composer_anchor orelse return error.NoComposer;
    for (titles) |title| {
        const r = for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |t| if (std.mem.startsWith(u8, t.str, title) and node.rect.y + node.rect.h <= pill.y and node.rect.x > pill.x) break node.rect,
            else => {},
        } else return error.StarterChipMissing;
        try testing.expect(r.x - 30 >= pill.x);
        try testing.expect(r.x + r.w + 11 <= pill.x + pill.w);
    }
}

/// Types `s` as AppKit's input system hands it over: an insert per key,
/// a frame each.
fn typeKeys(h: *Harness, s: []const u8) void {
    for (0..s.len) |i| h.t.textOps(&.{.{ .insert = s[i .. i + 1] }});
    h.t.settle(1);
}

test "the composer has the keys after ⌘D, ⌘[ and ⌘]: nothing typed is lost" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.press(.{ .key = 't', .cmd = true });
    try testing.expect(h.a.view.open_chooser.open);
    @import("app_open_chooser.zig").chooseProjectless(&h.a);
    h.t.settle(1);
    typeKeys(&h, "hey there");
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    h.press(.{ .key = 'd', .cmd = true });
    typeKeys(&h, "right");
    try testing.expectEqualStrings("right", h.a.composer.text());
    h.press(.{ .key = '[', .cmd = true });
    // Back where it was left, the caret at its end.
    typeKeys(&h, "!");
    try testing.expectEqualStrings("hey there!", h.a.composer.text());
    h.press(.{ .key = ']', .cmd = true });
    typeKeys(&h, "s");
    try testing.expectEqualStrings("rights", h.a.composer.text());
    h.press(.{ .key = '[', .cmd = true });
    h.a.showTab(0);
    h.t.settle(1);
    typeKeys(&h, "on alpha");
    try testing.expectEqualStrings("on alpha", h.a.composer.text());
}

test "a second line makes the docked composer taller and keeps the keys" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.view.focus_composer = true;
    h.t.settle(1);
    typeKeys(&h, "one");
    h.t.textOps(&.{.{ .command = .insert_line_break }});
    h.t.settle(1);
    typeKeys(&h, "two");
    try testing.expectEqualStrings("one\ntwo", h.a.composer.text());
}

test "Settings › Shortcuts: a chip takes the next keys; a clash is refused, as the GPUI app says" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const shortcuts = @import("shortcuts.zig");
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .shortcuts;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Keyboard shortcuts"));
    try h.t.clickText("Cmd+S");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Press keys…"));
    // While it records, ⌘B is the chip's, not the sidebar's.
    h.press(.{ .key = 'b', .cmd = true, .alt = true });
    try testing.expectEqualStrings("mod-alt-b", h.a.settings.combo(shortcuts.all[0]));
    try testing.expect(h.t.hasText("Cmd+Opt+B"));
    try testing.expect(h.t.hasText("Reset"));
    // The follow-up card above the groups puts Browser under the fold.
    h.t.scroll(700, 400, -400);
    h.t.settle(1);
    try h.t.clickText("Cmd+Shift+R");
    h.t.settle(1);
    h.press(.{ .key = 'b', .cmd = true, .alt = true });
    try testing.expectEqualStrings("mod-shift-r", h.a.settings.combo(shortcuts.all[1]));
    try testing.expect(h.t.hasText("Cmd+Opt+B is already assigned to Save file."));
    h.t.scroll(700, 400, 2000);
    h.t.settle(1);
    try h.t.clickText("Restore defaults");
    h.t.settle(1);
    try testing.expectEqualStrings("mod-s", h.a.settings.combo(shortcuts.all[0]));
}

test "with ⌘ Enter chosen, Enter starts a new line and ⌘↩ sends" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.settings.setText("composerSendBehavior", "mod-enter");
    h.a.view.focus_composer = true;
    h.t.settle(1);
    typeKeys(&h, "one");
    h.t.key(.enter);
    h.t.settle(1);
    typeKeys(&h, "two");
    try testing.expectEqualStrings("one\ntwo", h.a.composer.text());
}

test "Settings › Appearance: Light switches the window, an accent recolours it, the width slider moves the column" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const look = @import("view_settings_appearance.zig");
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .appearance;
    h.t.settle(1);
    try h.t.clickText("Light");
    h.t.settle(1);
    try testing.expectEqual(@as(?bool, false), h.a.dark);
    try testing.expectEqual(look.Mode.light, look.mode(&h.a));
    h.a.settings.setAccent("green");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Green · Controls, glyphs, selections, code, and activity."));
    try testing.expectEqual(@as(u24, 0x15803d), look.presetNamed("green").?.light);
    h.a.settings.setNumber("transcriptWidth", 1008);
    h.t.settle(1);
    try testing.expectEqual(@as(f32, 1008), @import("view_transcript.zig").column_w);
}

test "Settings › Appearance: the dark theme's picker lists the dark themes, and picking one repaints the window" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const theme = @import("theme.zig");
    defer {
        theme.light_id = "codegraff-light";
        theme.dark_id = "codegraff-dark";
    }
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .appearance;
    h.t.settle(1);
    try h.t.clickText("Codegraff Dark");
    h.t.settle(1);
    try testing.expectEqual(@as(?bool, true), h.a.view.theme_menu);
    try testing.expect(h.t.containsText("D\u{200A}A\u{200A}R\u{200A}K"));
    try testing.expect(h.t.hasText("Dracula"));
    // A light theme isn't among the dark ones.
    try testing.expect(!h.t.hasText("Catppuccin Latte"));
    try h.t.clickText("Dracula");
    h.t.settle(1);
    try testing.expect(h.a.view.theme_menu == null);
    try testing.expectEqualStrings("dracula", h.a.settings.themeId(true));
    try testing.expectEqualStrings("dracula", theme.dark_id);
    const dracula = @import("themes.zig").find("dracula").?;
    try testing.expectEqual(dracula.colors.shell, theme.colors(true).shell);
    // The trigger names it now, and the light theme stays Codegraff's.
    try testing.expect(h.t.hasText("Dracula"));
    try testing.expectEqualStrings("codegraff-light", h.a.settings.themeId(false));
}

test "a session dragged from the sidebar onto the right target opens in a new pane to the right" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const beta = h.t.findText("Beta") orelse return error.NoRow;
    // Press on Beta's row, drag over the chat's right edge: the targets show.
    h.t.moveTo(beta.x + 4, beta.y + 4);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = 900, .y = 300 };
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = 1100, .y = 400 };
    h.t.frame();
    try testing.expect(h.t.hasText("Open to the right ◨"));
    try testing.expect(h.t.hasText("Open below ⬓"));
    h.snap("drag-to-split");
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Open to the right ◨"));
    const s = h.a.tabs.layout() orelse return error.NoSplit;
    try testing.expectEqual(tabs_axis.horizontal, s.axis);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqualStrings("a", s.panes.items[0].?);
}

test "the open session dragged onto its own right target: a split with it and a new chat, nothing lost" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // Alpha, the open one, is the row above Beta's (the newest first).
    const beta = h.t.findText("Beta") orelse return error.NoRow;
    h.t.moveTo(beta.x + 4, beta.y + 4 - @import("view_sidebar.zig").row_slot);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = 900, .y = 300 };
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = 1100, .y = 400 };
    h.t.frame();
    try testing.expectEqualStrings("a", h.a.view.drag.id.items);
    try testing.expect(h.t.hasText("Open to the right ◨"));
    h.t.ctx.pointerUp();
    h.t.frame();
    // The release frame's transcript was drawn with Alpha's; opening the
    // split there freed it under the frame's layout (a segfault with a long
    // one). It waits for the next frame's start.
    try testing.expect(h.a.tabs.layout() == null);
    h.t.frame();
    try testing.expect(h.a.tabs.layout() != null);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Open to the right ◨"));
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "a chat let go of mid-frame keeps its transcript until the next frame starts" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.a.transcript.entries.append(testing.allocator, .{ .id = try testing.allocator.dupe(u8, "e1"), .role = .user, .status = .complete });
    h.a.select("b", null);
    // Drawn this frame, laid out after: still there.
    try testing.expectEqual(@as(usize, 1), h.a.retired.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.retired.items[0].entries.items.len);
    try testing.expectEqual(@as(usize, 0), h.a.transcript.entries.items.len);
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), h.a.retired.items.len);
}

test "a drag released off the targets does nothing, and isn't a click" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const beta = h.t.findText("Beta") orelse return error.NoRow;
    h.t.moveTo(beta.x + 4, beta.y + 4);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = beta.x + 40, .y = beta.y + 4 };
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = beta.x + 4, .y = beta.y + 4 };
    h.t.frame();
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

const tabs_axis = @import("tabs.zig").Axis;

/// Presses on `from`, moves (past the drag threshold) to what `to` gives
/// once the drag has laid the sidebar out, and lets go.
fn dragRow(h: *Harness, from: []const u8, comptime to: fn (*Harness) ui.Point) !void {
    // The session row: below the Sessions or Pinned header, not the tab's.
    const r = sessionText(h, from) orelse return error.NoRow;
    h.t.moveTo(r.x + 4, r.y + 4);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = r.x + 4, .y = r.y + 14 };
    h.t.frame();
    h.t.frame();
    h.t.ctx.input.mouse = to(h);
    h.t.frame();
    h.t.frame();
    h.snap(c_name(from));
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
}

fn c_name(from: []const u8) []const u8 {
    return if (std.mem.eql(u8, from, "Alpha")) "pin-drag-alpha" else "pin-drag-beta";
}

fn sessionText(h: *Harness, text: []const u8) ?ui.Rect {
    const head = h.a.view.pin_header orelse h.a.view.sessions_header orelse return null;
    const top = head.y;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| if (std.mem.eql(u8, t.str, text) and n.rect.y > top) return n.rect,
        else => {},
    };
    return null;
}

fn pinnedHeader(h: *Harness) ui.Point {
    const r = h.a.view.pin_header.?;
    return .{ .x = r.x + 20, .y = r.y + r.h / 2 };
}

fn belowFirstPin(h: *Harness) ui.Point {
    const r = h.a.view.pin_rows.?;
    return .{ .x = r.x + 20, .y = r.y + 4 + 29 * 0.75 };
}

fn sessionsHeader(h: *Harness) ui.Point {
    const r = h.a.view.sessions_header.?;
    return .{ .x = r.x + 20, .y = r.y + r.h / 2 };
}

test "sessions dragged onto Pinned are pinned in place, and back to Sessions unpinned" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expect(!h.t.hasText("Pinned"));
    try dragRow(&h, "Beta", pinnedHeader);
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("b", h.a.settings.pins.items[0]);
    try testing.expect(h.t.hasText("Pinned"));
    // Below the first pin's middle: after it.
    try dragRow(&h, "Alpha", belowFirstPin);
    try testing.expectEqual(@as(usize, 2), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[1]);
    try dragRow(&h, "Beta", sessionsHeader);
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[0]);
    // A drag that ends outside the sidebar leaves the pins be.
    try testing.expect(h.a.tabs.layout() == null);
}

/// Hovers a session row and clicks its ⋯ (`{row}-menu`).
fn openRowMenu(h: *Harness, title: []const u8) !void {
    const r = sessionText(h, title) orelse return error.NoRow;
    h.t.moveTo(r.x + 4, r.y + 4);
    h.t.frame();
    // The row's last icon, at its right end.
    var best: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .image => if (n.rect.x < 256 and n.rect.y < r.y + r.h and n.rect.y + n.rect.h > r.y and
            (best == null or n.rect.x > best.?.x))
        {
            best = n.rect;
        },
        else => {},
    };
    const b = best orelse return error.NoMenuButton;
    h.t.click(b.x + b.w / 2, b.y + b.h / 2);
    h.t.settle(1);
}

test "a session's ⋯ menu pins it after the last pin, and unpins it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try openRowMenu(&h, "Beta");
    try testing.expect(h.t.hasText("Rename…"));
    try testing.expect(h.t.hasText("Delete…"));
    h.snap("chat-menu");
    try h.t.clickText("Pin");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Rename…"));
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("b", h.a.settings.pins.items[0]);
    try openRowMenu(&h, "Alpha");
    try h.t.clickText("Pin");
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[1]);
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Unpin");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[0]);
}

test "Copy › Harness conversation link copies the GPUI app's link; a press outside closes the menu" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.device_id = try testing.allocator.dupe(u8, "dev");
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Copy");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Back"));
    try testing.expect(!h.t.hasText("Harness session ID"));
    h.snap("chat-menu-copy");
    try h.t.clickText("Harness conversation link");
    h.t.settle(1);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(@import("view_chat_menu.zig").conversationLink(&buf, "b", "dev").?, h.t.clipboard.items);
    try testing.expectEqualStrings("Harness conversation link copied", h.a.noticeText().?);
    try openRowMenu(&h, "Beta");
    h.t.click(700, 400);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Rename…"));
}

test "Rename… opens its dialog holding the title, Escape closes it; Delete… asks first" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Rename…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Rename session"));
    try testing.expectEqualStrings("Beta", h.a.view.dialogs.name.text());
    // Its field has the keys once the menu under it is gone.
    h.t.typeText(" two");
    h.t.settle(1);
    try testing.expectEqualStrings("Beta two", h.a.view.dialogs.name.text());
    h.snap("rename-dialog");
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.t.hasText("Rename session"));
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Delete…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Delete session?"));
    try testing.expect(h.t.containsText("\u{201C}Beta\u{201D} will be permanently deleted."));
    h.snap("delete-dialog");
    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Delete session?"));
    try testing.expect(h.a.findChat("b") != null);
}

/// A right-click, with a nanoui that has them; the test is skipped before.
fn rightClick(h: *Harness, x: f32, y: f32) !void {
    if (comptime !@hasDecl(ui.Tester, "secondaryClick")) return error.SkipZigTest;
    h.t.secondaryClick(x, y);
}

/// Projects on this device and on one away since September, with a
/// session in each of two.
fn withProjects(h: *Harness) !void {
    const spaces =
        \\[{"id":"s1","deviceId":"d","path":"/work/fieldnotes"},
        \\ {"id":"s2","deviceId":"d","path":"/work/Ledger"},
        \\ {"id":"s3","deviceId":"far","path":"/work/attic"},
        \\ {"id":"s4","deviceId":"d","path":"/work/atlas"}]
    ;
    const devices =
        \\[{"id":"d","name":"Studio","platform":"macos","lastSeenAt":null},
        \\ {"id":"far","name":"Cabin","platform":"linux","lastSeenAt":"2026-09-01T00:00:00Z"}]
    ;
    const in_spaces =
        \\[{"id":"a","deviceId":"d","title":"Alpha","spaceId":"s1","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z","createdAt":"2026-09-01T00:00:00Z"},
        \\ {"id":"b","deviceId":"d","title":"Beta","spaceId":"s2","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z","createdAt":"2026-10-01T00:00:00Z"}]
    ;
    inline for (.{ .{ spaces, &h.a.spaces }, .{ devices, &h.a.devices }, .{ in_spaces, &h.a.chats } }) |l| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, l[0], .{});
        defer parsed.deinit();
        try l[1].replace(parsed.value);
    }
    h.a.resort();
    if (h.a.device_id) |old| testing.allocator.free(old);
    h.a.device_id = try testing.allocator.dupe(u8, "d");
    h.t.settle(1);
}

test "the project menu: All projects, then by name with the away device's last; a search ranks them; ↓ and Return pick one" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    const menus = @import("view_sidebar_menus.zig");
    try h.t.clickText("All projects");
    h.t.settle(1);
    try testing.expect(h.a.view.filter_menu);
    try testing.expect(h.t.hasText("New project"));
    try testing.expect(h.t.hasText("Offline"));
    try testing.expect(h.t.hasText("@ Cabin"));
    h.snap("project-menu");
    const rows = try menus.projectRows(&h.a, testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(menus.Row.all, rows[0]);
    const want = [_][]const u8{ "s4", "s1", "s2", "s3" };
    for (want, rows[1..]) |id, r| try testing.expectEqualStrings(id, r.space);
    // The search takes the keys: "le" puts Ledger first.
    h.t.typeText("le");
    h.t.settle(1);
    // Only the trigger's own label, not the menu's row.
    const trigger = h.a.view.filter_anchor.?;
    try testing.expect(!h.t.hasText("All projects") or h.t.findText("All projects").?.y < trigger.y + trigger.h);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(!h.a.view.filter_menu);
    try testing.expectEqualStrings("s2", h.a.view.filter.?);
    // Only Ledger's session is listed (Alpha stays on as its tab's title).
    try testing.expect(h.t.hasText("Beta"));
    try testing.expect(h.t.findText("Alpha").?.y < 80);
    try testing.expectEqualStrings("s2", h.a.settings.spaceFilter().?);
    // The narrow sidebar fades the selected name beside its device label.
    // Activate the actual trigger, not an assumed untruncated text node.
    const selected_trigger = h.a.view.filter_anchor.?;
    h.t.click(selected_trigger.x + selected_trigger.w / 2, selected_trigger.y + selected_trigger.h / 2);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.view.menus.active);
    h.press(.{ .key = ui.Shortcut.up });
    h.press(.{ .key = ui.Shortcut.up });
    h.press(.{ .key = ui.Shortcut.up });
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(h.a.view.filter == null);
    try testing.expect(h.a.settings.spaceFilter() == null);
}

test "the project menu closes on Escape, and on a press outside; New project is last" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    try h.t.clickText("All projects");
    h.t.settle(1);
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.a.view.filter_menu);
    try h.t.clickText("All projects");
    h.t.settle(1);
    h.t.click(700, 600);
    h.t.settle(1);
    try testing.expect(!h.a.view.filter_menu);
    try testing.expect(h.t.findText("New project") == null);
}

test "the view menu sorts sessions and keeps flat Archived and Compact display choices" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    // Alpha was called last: first.
    try testing.expectEqualStrings("a", h.a.chats.items[0].id);
    const more = h.a.view.more_anchor.?;
    h.t.click(more.x + more.w / 2, more.y + more.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.more_menu);
    try testing.expect(h.t.hasText("Last called"));
    h.snap("view-menu");
    const sort = h.t.findText("Sort").?;
    h.t.moveTo(sort.x + 4, sort.y + sort.h / 2);
    h.t.settle(1);
    try testing.expect(h.t.containsText("S\u{200A}O\u{200A}R\u{200A}T"));
    h.snap("view-menu-sort");
    try h.t.clickText("Created");
    h.t.settle(1);
    try testing.expectEqual(@import("settings.zig").Sort.created, h.a.settings.sort());
    // Beta was made last: first now; the menu stays, its value updated.
    try testing.expect(h.a.view.more_menu);
    try testing.expectEqualStrings("b", h.a.chats.items[0].id);
    try testing.expect(!h.t.hasText("Show"));
    try testing.expect(!h.t.hasText("Project icon"));
    try h.t.clickText("Archived");
    h.t.settle(1);
    try testing.expect(!h.a.settings.get(.sidebar_show_archived));
    // Display switches stay open, and expanded mode reveals detail choices.
    try testing.expect(h.a.view.more_menu);
    try h.t.clickText("Compact");
    h.t.settle(1);
    try testing.expect(!h.a.settings.get(.sidebar_compact));
    try testing.expect(h.t.hasText("Project icon"));
    try testing.expect(h.t.hasText("Agent icon"));
    try testing.expect(!h.a.settings.get(.sidebar_show_archived));
    h.press(.{ .key = ui.Shortcut.escape });
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.a.view.more_menu);
}

test "a right-click on a session's row opens its menu where it's clicked" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    const beta = h.t.findText("Beta").?;
    try rightClick(&h, beta.x + 4, beta.y + beta.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.chat_menu.open);
    try testing.expectEqualStrings("b", h.a.view.chat_menu.id.items);
    try testing.expect(h.t.hasText("Rename…"));
    // Not a click: Beta isn't opened.
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "a project right-clicked in the project menu: Rename… and Remove…, each asking first" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    try h.t.clickText("All projects");
    h.t.settle(1);
    const ledger = h.t.findText("Ledger").?;
    try rightClick(&h, ledger.x + 4, ledger.y + ledger.h / 2);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Rename…"));
    try testing.expect(h.t.hasText("Remove…"));
    h.snap("space-menu");
    try h.t.clickText("Remove…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Remove project?"));
    try testing.expect(h.t.containsText("permanently deletes its 1 session on Studio"));
    h.snap("remove-project");
    // Escape closes the dialog alone; the project menu is still there.
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.t.hasText("Remove project?"));
    try testing.expect(h.a.view.filter_menu);
    const again = h.t.findText("Ledger").?;
    try rightClick(&h, again.x + 4, again.y + again.h / 2);
    h.t.settle(1);
    try h.t.clickText("Rename…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Rename project"));
    try testing.expectEqualStrings("Ledger", h.a.view.dialogs.name.text());
    // The field has the keys, the menu under it gone or not.
    h.t.typeText(" books");
    h.t.settle(1);
    try testing.expectEqualStrings("Ledger books", h.a.view.dialogs.name.text());
    // Return in the field is the dialog's, not the menu's.
    h.t.textOps(&.{.{ .command = .insert_newline }});
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Rename project"));
    try testing.expect(h.a.view.filter == null);
}

test "Organize › By project heads each project's sessions; Compact off shows where each runs" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    h.a.settings.setText("sidebarOrganization", "byProject");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Sessions"));
    try testing.expect(h.t.hasText("fieldnotes"));
    try testing.expect(h.t.hasText("Ledger"));
    // fieldnotes' session was called last: its group first.
    try testing.expect(h.t.findText("fieldnotes").?.y < h.t.findText("Ledger").?.y);
    h.snap("organize-by-project");
    // A group shut says how many it holds.
    try h.t.clickText("Ledger");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Ledger (1)"));
    h.a.settings.setText("sidebarOrganization", "byDevice");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Studio"));
    h.a.settings.setText("sidebarOrganization", "inOneList");
    h.a.settings.set(.sidebar_compact, false);
    // The current default hides project names independently of Compact.
    h.a.settings.set(.sidebar_show_project_label, true);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Ledger"));
    // A local project's name no longer repeats the local device suffix.
    try testing.expect(!h.t.hasText("Ledger @ Studio"));
    h.snap("expanded-rows");
    h.a.settings.set(.sidebar_show_project_label, false);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Ledger"));
}

/// Settings › GitHub CI open, on no engine.
fn openGithubCi(h: *Harness) void {
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .github_ci;
    h.t.settle(1);
}

/// Shows `reply` as the engine's `CodegraffGithubRunners` answer (the GPUI
/// test's `set_runners`).
fn githubRunners(h: *Harness, reply: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    defer parsed.deinit();
    @import("view_settings_github_ci.zig").setRunners(&h.a, parsed.value);
    h.t.settle(1);
}

const github_connected =
    \\{"available": true, "enabled": true,
    \\ "installUrl": "https://github.com/apps/codegraff/installations/new",
    \\ "installations": [{
    \\   "installationId": "4242", "account": "fieldnotes-co", "accountType": "Organization",
    \\   "monthlyBudgetMicroUsd": 50000000, "usedThisMonthMicroUsd": 12500000, "maxConcurrent": 3,
    \\   "repos": [{"fullName": "fieldnotes-co/app", "enabled": true, "defaultSize": "standard", "private": true},
    \\             {"fullName": "fieldnotes-co/docs", "enabled": false}]
    \\ }],
    \\ "recentJobs": [{
    \\   "repo": "fieldnotes-co/app", "workflow": "CI", "jobName": "test",
    \\   "state": "completed", "conclusion": "success", "durationSeconds": 180, "costMicroUsd": 5000,
    \\   "htmlUrl": "https://github.com/fieldnotes-co/app/actions/runs/1/job/2"
    \\ }],
    \\ "sizes": [{"key": "standard", "cpu": 2, "memoryGiB": 4, "pricePerHourMicroUsd": 100000},
    \\           {"key": "large", "cpu": 4, "memoryGiB": 8, "pricePerHourMicroUsd": 200000}]}
;

test "Settings › GitHub CI: without an engine it says so, with Retry and Refresh" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    try testing.expect(h.t.hasText("GitHub CI"));
    try testing.expect(h.t.hasText("Refresh"));
    try testing.expect(h.t.hasText("Engine not connected"));
    try testing.expect(h.t.hasText("Retry"));
    try testing.expect(!h.t.hasText("Connect GitHub"));
    h.snap("github-ci-no-engine");
}

test "Settings › GitHub CI: each answer shows its panel" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    try githubRunners(&h, "null");
    try testing.expect(h.t.hasText("Sign in with Codegraff from the account menu to run GitHub Actions on Codegraff."));
    try testing.expect(!h.t.hasText("Engine not connected"));
    try githubRunners(&h, "{}");
    try testing.expect(h.t.hasText("GitHub CI isn't available on Codegraff yet. This page fills in once it is."));
    try testing.expect(h.t.hasText("Coming soon"));
    try githubRunners(&h, "{\"available\": true, \"enabled\": false}");
    try testing.expect(h.t.hasText("GitHub CI is coming soon to your Codegraff account."));
    try githubRunners(&h, "{\"available\": true, \"enabled\": true}");
    try testing.expect(h.t.hasText("Codegraff didn't send an install link. Try Refresh."));
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installUrl\": \"https://github.com/apps/codegraff/installations/new\"}");
    try testing.expect(h.t.hasText("Run GitHub Actions on Codegraff"));
    try testing.expect(h.t.hasText("Connect GitHub"));
    try testing.expect(h.t.hasText("In a workflow, run a job on Codegraff:"));
    try testing.expect(h.t.hasText("    runs-on: codegraff"));
    try testing.expect(!h.t.hasText("Recent jobs"));
    h.snap("github-ci-not-connected");
    // Copy puts the snippet on the clipboard, and says so for a moment.
    try h.t.clickText("Copy");
    h.t.settle(1);
    try testing.expectEqualStrings(@import("runners.zig").yaml_snippet, h.t.clipboard.items);
    try testing.expect(h.t.hasText("Copied"));
    h.t.advance(2);
    try testing.expect(h.t.hasText("Copy"));

    h.t.resize(1200, 1400);
    try githubRunners(&h, github_connected);
    try testing.expect(!h.t.hasText("Connect GitHub"));
    for ([_][]const u8{
        "fieldnotes-co",
        "Organization · 1 of 2 repositories on",
        "Monthly budget",
        "$12.50 of $50 used this month",
        "Fork pull request budget",
        "Jobs from outside contributors stop at this amount each month.",
        "Concurrent jobs",
        "3",
        "fieldnotes-co/app",
        "Private",
        "Standard · $0.10/h",
        "fieldnotes-co/docs",
        "Connect another account",
        "Recent jobs",
        "fieldnotes-co/app · CI · test",
        "Open on GitHub",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(h.t.hasText("Succeeded · 3m 0s · $0.005"));
    const page = &h.a.view.github_ci;
    try testing.expectEqualStrings("50", page.inputs.items[0].buf.text());
    h.snap("github-ci-connected");
}

test "Settings › GitHub CI: a bad budget is refused in place, and nothing is sent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installations\": [{\"installationId\": \"1\", \"account\": \"studio\"}]}");
    try testing.expect(h.t.hasText("No repositories yet. Choose them in the Codegraff app's settings on GitHub."));
    try testing.expect(h.t.hasText("$0 used this month · no monthly budget"));
    const page = &h.a.view.github_ci;
    page.inputs.items[0].buf.set("twelve");
    try h.t.clickText("Save");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Enter a dollar amount, like 50 or 12.50."));
    try testing.expect(page.busy == null);
    h.snap("github-ci-bad-budget");
    // Editing it again clears the complaint.
    const field = h.t.findText("twelve") orelse return error.NoField;
    h.t.click(field.x + field.w, field.y + field.h / 2);
    h.t.settle(1);
    h.t.typeText("0");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Enter a dollar amount, like 50 or 12.50."));
}

test "Settings › GitHub CI: the concurrent-jobs stepper stays within 1…8; Disconnect asks first; a size opens its menu" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    h.t.resize(1200, 1400);
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installations\": [{\"installationId\": \"1\", \"account\": \"studio\", \"maxConcurrent\": 40, \"repos\": [{\"fullName\": \"studio/site\", \"enabled\": true}]}], \"sizes\": [{\"key\": \"standard\", \"cpu\": 2, \"memoryGiB\": 4, \"pricePerHourMicroUsd\": 100000}]}");
    try testing.expect(h.t.hasText("8"));
    try testing.expect(!h.t.hasText("40"));
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installations\": [{\"installationId\": \"1\", \"account\": \"studio\", \"maxConcurrent\": 0, \"repos\": [{\"fullName\": \"studio/site\", \"enabled\": true}]}], \"sizes\": [{\"key\": \"standard\", \"cpu\": 2, \"memoryGiB\": 4, \"pricePerHourMicroUsd\": 100000}]}");
    try testing.expect(h.t.hasText("1"));
    try h.t.clickText("Disconnect");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Disconnect for good?"));
    // No size named: the first.
    try h.t.clickText("Standard · $0.10/h");
    h.t.settle(1);
    try testing.expect(h.t.containsText("D\u{200A}E\u{200A}F\u{200A}A\u{200A}U\u{200A}L\u{200A}T"));
    try testing.expect(h.t.hasText("Standard · 2 vCPU · 4 GB · $0.10/h"));
    h.snap("github-ci-size-menu");
    h.t.click(700, 1300);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Standard · 2 vCPU · 4 GB · $0.10/h"));
}

/// Settings › Agents open, on no engine.
fn openAgents(h: *Harness) void {
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .harnesses;
    h.t.resize(1200, 1400);
    h.t.settle(1);
}

/// Shows `reply` as the engine's `ListHarnesses` answer.
fn agentList(h: *Harness, reply: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    defer parsed.deinit();
    @import("view_settings_agents.zig").setList(&h.a, parsed.value);
    h.t.settle(1);
}

/// The switch on the row titled `name`: at the card's right edge, level
/// with the middle of the title and the line under it.
fn agentToggle(h: *Harness, name: []const u8, line: []const u8) !void {
    const t = h.t.findText(name) orelse return error.NoRow;
    const m = h.t.findText(line) orelse return error.NoRow;
    const main_w = 1200 - @import("view_sidebar.zig").width;
    const col_w = @min(main_w, 768);
    const right = @import("view_sidebar.zig").width + (main_w - col_w) / 2 + col_w - 24 - 1 - 20;
    h.t.click(right - 16, (t.y + m.y + m.h) / 2);
    h.t.settle(1);
}

test "Settings › Agents: with no engine, the GPUI app's waiting page" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    for ([_][]const u8{
        "Agents",
        "This device",
        "This GUI drives whatever agent is installed on the selected device. A custom build can point at its binary with that agent's *_EXECUTABLE variable. Downloads start only when you choose Install.",
        "Experimental Graff ACP child agents",
        "Session titles",
        "Loading title settings…",
    }) |want| try testing.expect(h.t.hasText(want));
    // Nothing asked, nothing failed: the skeleton waits for an engine.
    try testing.expectEqual(.idle, h.a.view.agents.phase);
    try testing.expect(!h.t.hasText("Engine not connected"));
    try testing.expect(!h.t.hasText("Retry"));
    h.snap("agents-no-engine");
}

const agent_catalog =
    \\[{"id":"codex","name":"Codex","installed":true,"enabled":true},
    \\ {"id":"graff","name":"Graff","installed":true,"canInstall":true,"enabled":false},
    \\ {"id":"pi","name":"Pi","installed":false,"canInstall":false},
    \\ {"id":"cursor","name":"Cursor","installed":true,"enabled":false},
    \\ {"id":"antigravity","name":"Antigravity","installed":true,"enabled":false},
    \\ {"id":"mock","name":"Mock","installed":true}]
;

test "Settings › Agents: each row's blurb, hints and actions, as the GPUI app's" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    for ([_][]const u8{
        "OpenAI's coding agent, driven through the Codex CLI.",
        "codegraff's graff agent over ACP (graff CLI).",
        "Install beta updates the managed Codegraff CLI for new Graff sessions.",
        "Update",
        "Install beta",
        "The pi coding agent (pi CLI).",
        "Install the pi CLI to enable. Install with `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`",
        "Custom build: set PI_EXECUTABLE to that binary.",
        "Off by default — turn on to use",
        "Sign in",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    // The mock is the dev rig's: hidden.
    try testing.expect(!h.t.hasText("Scripted test harness."));
    // Pi can't be installed from here: no Install.
    try testing.expect(!h.t.hasText("Install"));
    h.snap("agents-rows");
}

test "Settings › Agents: the last enabled agent can't be switched off; another can be switched on" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    // Codex is the only one on: its switch does nothing.
    try agentToggle(&h, "Codex", "OpenAI's coding agent, driven through the Codex CLI.");
    try testing.expect(!h.t.hasText("Engine not connected"));
    // Cursor is installed and off: its switch asks the engine (none here).
    try agentToggle(&h, "Cursor", "Cursor's coding agent, driven through the cursor-agent CLI.");
    try testing.expect(h.t.hasText("Engine not connected"));
}

test "Settings › Agents: graff's compact-at pills; a point set elsewhere is named" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    try testing.expect(h.t.hasText("Compact context at"));
    for (@import("agents.zig").compact_choices) |ch| try testing.expect(h.t.hasText(ch.label));
    try testing.expect(h.t.hasText("How full the context window gets before Graff compacts. Applies to new Graff chats; /compact-at 70 changes one chat."));
    @import("view_settings_agents.zig").setCompact(&h.a, 65);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Currently 65%, set on this device."));
    @import("view_settings_agents.zig").setCompact(&h.a, 70);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Currently 70%, set on this device."));
    h.snap("agents-compact-at");
    // A pill saves through the engine; with none, the strip says so.
    try h.t.clickText("50%");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Engine not connected"));
    try testing.expect(!h.a.view.agents.compact_saving);
}

test "Settings › Agents: the device switcher lists each device, this one as You, and retargets the page" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"d2","name":"Workbench","platform":"linux","createdAt":"2026-10-02T00:00:00Z"},
        \\ {"id":"d1","name":"Studio","platform":"macos","createdAt":"2026-10-01T00:00:00Z"}]
    , .{});
    defer parsed.deinit();
    try h.a.devices.replace(parsed.value);
    h.a.device_id = try testing.allocator.dupe(u8, "d1");
    openAgents(&h);
    try agentList(&h, agent_catalog);
    try h.t.clickText("Studio");
    h.t.settle(1);
    try testing.expect(h.t.containsText("D\u{200A}E\u{200A}V\u{200A}I\u{200A}C\u{200A}E\u{200A}S"));
    try testing.expect(h.t.hasText("Workbench"));
    try testing.expect(h.t.hasText("You"));
    // Added first, listed first.
    const studio = h.t.findText("You") orelse return error.NoRow;
    const bench = h.t.findText("Workbench") orelse return error.NoRow;
    try testing.expect(studio.y < bench.y);
    h.snap("agents-device-menu");
    try h.t.clickText("Workbench");
    h.t.settle(1);
    const p = &h.a.view.agents;
    try testing.expectEqualStrings("d2", p.target.?);
    try testing.expect(!p.device_menu);
    // Another device: its rows are read again (and wait for an engine).
    try testing.expectEqual(.idle, p.phase);
    try testing.expect(!h.t.hasText("You"));
    try h.t.clickText("Workbench");
    h.t.settle(1);
    try h.t.clickText("Studio");
    h.t.settle(1);
    try testing.expect(p.target == null);
}

test "Settings › Agents: session titles name the agent and model; the agent list offers those that can title" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"harness\":\"claude-code\",\"model\":null}", .{});
    defer parsed.deinit();
    @import("view_settings_agents.zig").setTitles(&h.a, parsed.value);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Title harness"));
    try testing.expect(h.t.hasText("Automatic (cheapest model)"));
    try testing.expect(!h.t.hasText("Automatic"));
    try h.t.clickText("Claude Code");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Automatic"));
    try testing.expectEqual(@as(?bool, false), h.a.view.agents.title_menu);
}

/// Settings › Accounts open, on no engine.
fn openAccounts(h: *Harness) void {
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .agents;
    h.t.settle(1);
}

/// Shows `reply` as the engine's answer to `which`'s call.
fn accountsReply(h: *Harness, comptime which: []const u8, reply: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    defer parsed.deinit();
    @field(@import("view_settings_accounts.zig"), which)(&h.a, parsed.value);
    h.t.settle(1);
}

test "Settings › Accounts: without an engine, as the GPUI app's: loading cards, ChatGPT unknown, the failure with Click to retry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAccounts(&h);
    for ([_][]const u8{ "Accounts", "Refresh", "CodeGraff", "View usage", "ChatGPT", "Continue with ChatGPT", "Separate from Codex · graff login chatgpt-new", "graff providers", "Engine not connected", "Click to retry" }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(h.t.containsText("Switching rewrites the CLI"));
    try testing.expect(!h.t.hasText("Sign out"));
    try testing.expect(!h.t.hasText("Add account"));
    try testing.expect(!h.t.hasText("Claude Code"));
    // Retrying without an engine fails again, in place.
    try h.t.clickText("Click to retry");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Engine not connected"));
    // Signing in needs an engine: the page says so.
    try h.t.clickText("Continue with ChatGPT");
    h.t.settle(1);
    try testing.expectEqualStrings("Engine not connected", h.a.view.accounts.notice.items);
    try testing.expect(h.a.view.accounts.login.flow == null);
    h.snap("accounts-no-engine");
}

const accounts_snapshot =
    \\{"accounts": [
    \\  {"id": "c1", "harness": "claude-code", "email": "ada@example.com", "planLabel": "Max", "active": true, "switchable": true,
    \\   "usageWindows": [{"label": "5h", "usedFraction": 0.42, "resetsAt": null}, {"label": "Weekly", "usedFraction": 0.86, "resetsAt": null}]},
    \\  {"id": "c2", "harness": "claude-code", "email": "bea@example.com", "planLabel": "Pro", "active": false, "switchable": true},
    \\  {"id": "c3", "harness": "claude-code", "email": null, "displayName": "Kit", "planLabel": null, "active": false, "switchable": false}],
    \\ "warnings": [{"harness": "codex", "message": "Keychain didn't let Harness read the Codex login."}]}
;

test "Settings › Accounts: accounts with plans, Active, meters; empty providers; CodeGraff usage; graff's sign-ins" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1200, 2200);
    openAccounts(&h);
    try accountsReply(&h, "setSnapshot", accounts_snapshot);
    try accountsReply(&h, "setUsage",
        \\{"email": "cg@example.com", "tier": "Team", "credits_micro_usd": 12340000, "spend_30d_micro_usd": 2500000,
        \\ "requests_30d": 31, "key_budget_monthly_micro_usd": 20000000, "key_spend_monthly_micro_usd": 5000000, "key_budget_resets_at": ""}
    );
    try accountsReply(&h, "setGraffLogins",
        \\[{"id": "xai", "name": "xAI", "signedIn": true, "account": "x@example.com"},
        \\ {"id": "kimi", "name": "Kimi", "signedIn": false},
        \\ {"id": "chatgpt-new", "name": "ChatGPT", "signedIn": true, "account": "g@example.com", "planUsage": true}]
    );
    for ([_][]const u8{
        // Three accounts and the CodeGraff sign-in.
        "4",
        "Sign out",
        "cg@example.com",
        "Graff CLI account on this device",
        "$12.34 credits available",
        "$2.50 spent · 31 requests in 30 days",
        // "Key budget", cut at the meter's 48-point label as GPUI's.
        "25% used",
        "Team",
        "Signed in as g@example.com · using your ChatGPT plan",
        "Manage usage",
        "xAI",
        "Signed in as x@example.com",
        "Sign in again",
        "ChatGPT (old Codex)",
        "Not signed in — add a Codex account below",
        "Kimi",
        "Sign in",
        "Claude Code",
        "ada@example.com",
        "Active",
        "Max",
        "5h",
        "42% used",
        "Weekly",
        "86% used",
        "bea@example.com",
        "Pro",
        "Usage unavailable",
        "Switch",
        "Kit",
        "Credentials unavailable",
        "Keychain didn't let Harness read the Codex login.",
        "No Codex login detected on this device — sign in with \u{201C}codex\u{201D} or add an account.",
        "Cursor isn't connected on this device — connect it to run Cursor sessions.",
        "Add account",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(!h.t.hasText("Engine not connected"));
    // The legacy Codex row comes second, after graff's first provider.
    try testing.expect(h.t.findText("xAI").?.y < h.t.findText("ChatGPT (old Codex)").?.y);
    try testing.expect(h.t.findText("ChatGPT (old Codex)").?.y < h.t.findText("Kimi").?.y);
    // The engine's order holds: the active account isn't moved first.
    try testing.expect(h.t.findText("ada@example.com").?.y < h.t.findText("bea@example.com").?.y);
    h.snap("accounts-ready");
    // Switch without an engine leaves the row be.
    try h.t.clickText("Switch");
    h.t.settle(1);
    try testing.expect(h.a.view.accounts.busy_account == null);
}

test "Settings › Accounts: the add-account dialog's paste-code and browser bodies; Copy, then Escape closes it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAccounts(&h);
    const p = &h.a.view.accounts;
    // As StartAgentLogin answers for Claude: open the page, paste the code.
    p.login.flow = .{ .stage = .paste, .harness = .claude_code, .start = .{ .login_id = "l1", .url = "https://example.com/oauth/authorize?state=demo", .mode = .paste_code } };
    p.login.focus_code = true;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Add Claude account"));
    try testing.expect(h.t.hasText("Reopen the authorization page"));
    try testing.expect(h.t.hasText("Or copy this link into any browser"));
    try testing.expect(h.t.hasText("Add account"));
    try testing.expect(h.t.hasText("Cancel"));
    // The field has the keys.
    h.t.typeText("abc123");
    h.t.settle(1);
    try testing.expectEqualStrings("abc123", p.login.code.text());
    h.snap("accounts-paste-code");
    try h.t.clickText("Copy");
    h.t.settle(1);
    try testing.expectEqualStrings("https://example.com/oauth/authorize?state=demo", h.t.clipboard.items);
    try testing.expect(h.t.hasText("Copied"));
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(p.login.flow == null);
    try testing.expect(!h.t.hasText("Add Claude account"));
    // A graff device-code sign-in: the code to confirm, then the wait.
    p.login.flow = .{ .stage = .browser, .harness = .graff, .provider = try testing.allocator.dupe(u8, "xai"), .start = .{ .login_id = "l2", .url = "https://example.com/device", .mode = .browser, .code = "WXYZ-1234" } };
    h.t.settle(1);
    try testing.expect(h.t.hasText("Sign in to xAI"));
    try testing.expect(h.t.hasText("Finish signing in to xAI in your browser. graff saves the login itself, so nothing is copied into Harness."));
    try testing.expect(h.t.hasText("Confirm this code on the page"));
    try testing.expect(h.t.hasText("WXYZ-1234"));
    try testing.expect(h.t.hasText("Waiting for the browser…"));
    h.snap("accounts-browser");
    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(p.login.flow == null);
}

const sandboxes_reply =
    \\{"enabled": true,
    \\ "sandboxes": [
    \\  {"id": "sbx-run", "provider": "fleet", "name": "Field cloud", "state": "running", "harness": true, "keepRunning": false,
    \\   "cpu": 2, "memoryGiB": 4, "pricePerHourMicroUsd": 100000},
    \\  {"id": "sbx-bare", "provider": "fleet", "name": "Half set up", "state": "running", "harness": false},
    \\  {"id": "sbx-nap", "provider": "fleet", "name": "Napping box", "state": "paused", "harness": true},
    \\  {"id": "tmp-7", "provider": "daytona", "state": "paused", "tier": "ephemeral"}],
    \\ "sizes": [
    \\  {"id": "standard", "cpu": 2, "memoryGiB": 4, "diskGiB": 40, "pricePerHourMicroUsd": 100000, "default": true},
    \\  {"id": "large", "cpu": 4, "memoryGiB": 8, "diskGiB": 80, "pricePerHourMicroUsd": 200000}]}
;

test "Settings › Accounts: cloud sandboxes with each one's buttons, Delete asking first, the size choice, and the running strip" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1200, 2400);
    openAccounts(&h);
    try testing.expect(!h.t.hasText("Cloud sandboxes"));
    try accountsReply(&h, "feedSandboxes", sandboxes_reply);
    for ([_][]const u8{
        "Cloud sandboxes",
        "Field cloud",
        "Running · 2 vCPU · 4 GB · $0.10/h",
        "Keep running",
        "Half set up",
        "Running · Harness not set up",
        "Set up Harness",
        "Napping box",
        "Paused — memory and files kept",
        "Start",
        "Temporary sandbox",
        "Paused",
        "Copy ID",
        "Harness cloud",
        "Standard",
        "2 vCPU · 4 GB · 40 GB · $0.10/h",
        "Large",
        "4 vCPU · 8 GB · 80 GB · $0.20/h",
        "Create",
        "Create temporary",
        // The strip in the settings sidebar: two running, so Turn off all.
        "Turn off all",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(h.t.containsText("Cloud sandbox"));
    // Cut to the strip's width: "Billed per second until you turn it off".
    try testing.expect(h.t.containsText("Billed per"));
    h.snap("accounts-sandboxes");
    const cl = &h.a.view.accounts.cloud;
    // Delete asks first; nothing is sent.
    var deletes: usize = 0;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| if (std.mem.eql(u8, t.str, "Delete")) {
            deletes += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 4), deletes);
    try h.t.clickText("Delete");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Delete for good?"));
    try testing.expectEqualStrings("sbx-run", cl.confirm_delete.?);
    try testing.expect(cl.busy == null);
    // Copy ID puts the temporary one's id on the clipboard.
    try h.t.clickText("Copy ID");
    h.t.settle(1);
    try testing.expectEqualStrings("tmp-7", h.t.clipboard.items);
    // The size choice: Standard by default, Large once picked.
    try testing.expect(cl.size == null);
    try h.t.clickText("Large");
    h.t.settle(1);
    try testing.expectEqualStrings("large", cl.size.?);
    // Without an engine, Create starts nothing.
    try h.t.clickText("Create");
    h.t.settle(1);
    try testing.expect(!cl.creating);
    // A Turn off under way reads so, and dims its row's buttons.
    cl.busy = try testing.allocator.dupe(u8, "sbx-run");
    cl.busy_action = "stop";
    h.t.settle(1);
    try testing.expect(h.t.hasText("Turning off…"));
    // Where the feature is off, no card and no strip.
    try accountsReply(&h, "feedSandboxes", "{\"enabled\": false, \"sandboxes\": []}");
    try testing.expect(!h.t.hasText("Cloud sandboxes"));
    try testing.expect(!h.t.hasText("Turn off all"));
}

test "a failed MCP server's problem line keeps its row the height of its text" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"name":"alpha-tools","source":"global","transport":"stdio","origin":"alpha","enabled":true,"state":"failed","error":"the server exited during startup","toolCount":0,"tools":[]},
        \\ {"name":"beta-tools","source":"global","transport":"stdio","origin":"beta","enabled":true,"state":"on_demand","toolCount":2,"tools":[]}]
    , .{});
    defer v.deinit();
    try h.a.mcp.servers.replace(v.value);
    h.a.mcp.phase = .loaded;
    h.a.settings.section = .mcp;
    @import("view_settings.zig").open(&h.a);
    h.t.settle(1);
    const problem = h.t.findText("the server exited during startup").?;
    const next = h.t.findText("beta-tools").?;
    // One line of problem, the row's 14 below, the divider, 14 above the
    // next name: well under 60 (at a word a line it was ~150).
    try testing.expect(next.y - (problem.y + problem.h) < 60);
    h.snap("mcp-failed-row");
}

test "opening a chat marks it seen here at once: its Done gives way to its time (mark_chat_seen)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const chats_ =
        \\[{"id":"a","deviceId":"d","title":"Alpha","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z","lastSeenAt":"2026-10-04T00:00:00Z"},
        \\ {"id":"b","deviceId":"d","title":"Beta","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z"}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats_, .{});
    defer parsed.deinit();
    try h.a.chats.replace(parsed.value);
    h.t.settle(1);
    const ws = @import("workspace.zig");
    try testing.expect(ws.unseen(h.a.findChat("b").?));
    h.a.openChat("b", null);
    h.t.settle(1);
    try testing.expect(!ws.unseen(h.a.findChat("b").?));
}

test "a live snapshot asking for Settings draws it in that frame alone: the window is left as it was" {
    if (comptime !@hasField(ui.Context, "snapshot_request")) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const section = h.a.settings.section;
    h.t.ctx.snapshot_request = "settings:archived";
    h.t.frame();
    try testing.expect(h.t.hasText("Archived sessions"));
    h.t.ctx.snapshot_request = "";
    h.t.settle(1);
    try testing.expect(!h.a.view.settings_open);
    try testing.expectEqual(section, h.a.settings.section);
    try testing.expect(!h.t.hasText("Search settings"));
}

test "a finished turn keeps edit results in its tree while Changes retains review actions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"t","kind":"text","text":"Tidy it"}]},
        \\ {"id":"r","role":"assistant","parts":[
        \\  {"id":"e1","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"src/parser.rs"},"diffStats":[{"path":"src/parser.rs","additions":3,"deletions":1}]},
        \\  {"id":"e2","kind":"tool","resolved":true,"call":{"kind":"writeFile","path":"notes/CHANGELOG.md"},"diff":{"path":"notes/CHANGELOG.md","newText":"a\nb\n"}},
        \\  {"id":"x","kind":"tool","resolved":true,"call":{"kind":"exec","command":"ls"}},
        \\  {"id":"d","kind":"text","text":"Done."}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    h.snap("turn-edit-summary");
    try testing.expect(!h.t.hasText("2 files changed"));
    try testing.expect(!h.t.hasText("Review"));
    try h.t.clickText("Ran 1 command · edited 2 files");
    h.t.settle(1);
    try testing.expect(h.t.hasText("parser.rs"));
    try testing.expect(h.t.hasText("CHANGELOG.md"));
    try testing.expect(h.t.hasText("+3"));
    try testing.expect(h.t.hasText("−1"));
    // Changes is still independently available; the removed composer card
    // must not be restored merely to reach its existing review actions.
    @import("app_panels.zig").addDiffsTab(&h.a);
    h.t.settle(1);
    try testing.expect(h.a.panels.host_open);
    try testing.expect(h.a.panels.activeTab().?.kind == .diffs);
    try testing.expect(!h.t.hasText("Showing"));
    // The working tree's diff ends on GPUI's review footer: Undo asks
    // first, Keep changes closes the pane.
    var d: @import("app_panels.zig").Diff = .{ .arena = .init(testing.allocator), .additions = 1, .deletions = 1 };
    d.files = try @import("diff.zig").parse(d.arena.allocator(),
        \\diff --git a/src/parser.rs b/src/parser.rs
        \\--- a/src/parser.rs
        \\+++ b/src/parser.rs
        \\@@ -1,2 +1,2 @@
        \\ fn parse() {
        \\-    old();
        \\+    new();
        \\
    );
    if (h.a.panels.diff) |*old| old.arena.deinit();
    h.a.panels.diff = d;
    h.a.panels.diff_loading = false;
    h.t.settle(1);
    h.snap("changes-review-footer");
    testing.expect(h.t.containsText("new();")) catch |err| {
        std.debug.print("assertion at {s}:{d}\n", .{ @src().file, @src().line });
        return err;
    };
    try testing.expect(h.t.hasText("Undo reverts every uncommitted file."));
    try h.t.clickText("Undo all changes");
    h.t.settle(1);
    try testing.expect(h.a.panels.discard_confirm);
    try testing.expect(h.t.hasText("Discard working tree changes?"));
    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(!h.a.panels.discard_confirm);
    try h.t.clickText("Keep changes");
    h.t.settle(1);
    try testing.expect(!h.a.panels.host_open);
    try testing.expect(!h.t.hasText("Review"));
    try testing.expect(h.t.hasText("Ran 1 command · edited 2 files"));
}

test "an opened edit step shows its code as a diff, and a thinned one its files" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"t","kind":"text","text":"Tidy it"}]},
        \\ {"id":"r","role":"assistant","parts":[
        \\  {"id":"e1","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"src/lexer.rs"},"diff":{"path":"src/lexer.rs","oldText":"fn lex() {\n    old_token();\n}\n","newText":"fn lex() {\n    new_token();\n}\n"}},
        \\  {"id":"e2","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"src/parser.rs"},"diffStats":[{"path":"src/parser.rs","additions":3,"deletions":1}]},
        \\  {"id":"d","kind":"text","text":"Done."}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.a.settings.set(.transcript_compact_mode, false);
    // The run of steps open, the steps themselves closed: no code yet.
    h.a.view.toggleGroup(h.a.gpa, "r/e1", false);
    // Tool folds schedule bounded 30Hz frames rather than a continuous
    // animation. Advance that clock before clicking the moving row.
    h.t.advance(0.3);
    h.t.settle(1);
    try testing.expect(h.t.hasText("lexer.rs"));
    testing.expect(!h.t.containsText("new_token();")) catch |err| {
        std.debug.print("assertion at {s}:{d}\n", .{ @src().file, @src().line });
        return err;
    };
    try h.t.clickText("lexer.rs");
    h.t.settle(1);
    h.snap("edit-step-diff");
    try testing.expect(h.t.hasText("@@ -1,3 +1,3 @@"));
    testing.expect(h.t.containsText("old_token();")) catch |err| {
        std.debug.print("assertion at {s}:{d}\n", .{ @src().file, @src().line });
        return err;
    };
    testing.expect(h.t.containsText("new_token();")) catch |err| {
        std.debug.print("assertion at {s}:{d}\n", .{ @src().file, @src().line });
        return err;
    };
    try h.t.clickText("parser.rs");
    h.t.settle(1);
    try testing.expect(h.t.hasText("src/parser.rs"));
}

test "the context ring sits at the footer's right; resting on it opens the card of what fills the context" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expect(!h.t.hasText("23%"));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"t","kind":"text","text":"Read the parser"}]},
        \\ {"id":"r","role":"assistant","parts":[
        \\  {"id":"f","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"src/parser.rs"},"outputBytes":36000},
        \\  {"id":"x","kind":"tool","resolved":true,"call":{"kind":"exec","command":"cargo test"},"outputBytes":8000},
        \\  {"id":"d","kind":"text","text":"Done."}]}],
        \\ "contextUsage":{"tokens":46200,"window":200000,"savings":{"handleBytes":96000,"compactedTokens":0,"cacheReadTokens":9000}}}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    const pct = h.t.findText("23%") orelse return error.NoRing;
    const pill = h.a.view.composer_anchor.?;
    try testing.expect(pct.x > pill.x + pill.w / 2 and pct.y > pill.y + pill.h);
    try testing.expect(!h.t.hasText("Context"));
    h.t.moveTo(pct.x + 2, pct.y + 4);
    h.t.frame();
    h.t.advance(0.3);
    try testing.expect(!h.t.hasText("Context"));
    h.t.advance(0.3);
    h.snap("context-card");
    // The counter rolls a character at a time, so each is its own text.
    for ([_][]const u8{ "Context", "reading", "4", "6", "k", "of 200k", "Files", "9.0k", "Commands", "2.0k", "System & other", "153k free of 200k", "24k", "saved by graff", "46,200 / 200,000 tokens", "153,800 tokens remaining" }) |t|
        if (!h.t.hasText(t)) {
            std.debug.print("missing {s}\n", .{t});
            return error.MissingText;
        };
    // It stays while the pointer crosses into it, and goes half a second
    // after the pointer leaves both.
    const card = h.a.view.context.card orelse return error.NoCard;
    h.t.moveTo(card.x + card.w / 2, card.y + card.h / 2);
    h.t.advance(0.7);
    try testing.expect(h.t.hasText("saved by graff"));
    h.t.moveTo(20, 400);
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("saved by graff"));
    h.t.advance(0.4);
    try testing.expect(!h.t.hasText("saved by graff"));
    // GPUI's footer hit area reaches 4 points past the pill's right edge.
    h.t.moveTo(1068, 760);
    h.t.advance(0.7);
    try testing.expect(h.t.hasText("Context"));
}

test "answering a question keeps its text alive through the frame that drew it" {
    // Submit and Cancel run mid-build, after the question and its options
    // were handed to the frame; layout and paint read them next.
    for ([_][]const u8{ "Cancel question", "Submit" }) |button| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[{"id":"ask","role":"assistant","status":"complete","parts":[{"kind":"input","id":"r1","requestId":"r1","resolved":false,
            \\  "questions":[{"id":"q1","header":"Approach","question":"A synthetic question that wraps","options":["First option","Second option"],"multiSelect":true}]}]}]}
        , .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
        if (std.mem.eql(u8, button, "Submit")) try h.t.clickText("First option");
        h.t.settle(1);
        const r = h.t.findText(button) orelse return error.TextNotFound;
        h.t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
        h.t.ctx.input.click_count = 1;
        h.t.ctx.pointerDown();
        h.t.frame();
        h.t.ctx.pointerUp();
        h.t.frame();
        try testing.expect(h.a.wizard == null);
        // Debug fills freed memory with 0xaa; four in a row is never UTF-8.
        for (h.t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| try testing.expect(std.mem.indexOf(u8, tx.str, "\xaa\xaa\xaa\xaa") == null),
            else => {},
        };
        h.t.settle(1);
        try testing.expect(!h.t.hasText("Cancel question"));
    }
}

test "an agent's question shows its Markdown, not its markup" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"ask","role":"assistant","status":"complete","parts":[{"kind":"input","id":"r1","requestId":"r1","resolved":false,
        \\  "questions":[{"id":"q1","header":"Plan","question":"**What happens now** (checked in code):\n\n- `stage.tsx:72` sets `original = active`.\n- The slide loads the **original**.","options":["Go"]}]}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    // The panel's paragraphs, without their markup (the transcript's chip
    // keeps the question's first line as written, as GPUI's does).
    try testing.expect(h.t.hasText("What happens now (checked in code):"));
    try testing.expect(h.t.hasText("stage.tsx:72 sets original = active."));
    try testing.expect(h.t.hasText("The slide loads the original."));
}

test "bottom-docked checkout and ref popovers open upward above the composer footer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var ws_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"ws-1","name":"demo","path":"/work/demo","gitDetected":true}]
    , .{});
    defer ws_parsed.deinit();
    try h.a.spaces.replace(ws_parsed.value);
    if (h.a.space) |old| h.a.gpa.free(old);
    h.a.space = try h.a.gpa.dupe(u8, "ws-1");
    h.a.select(null, null);
    h.t.settle(1);

    try h.t.clickText("New worktree");
    h.t.settle(1);
    const checkout_anchor = h.a.view.checkout_anchor orelse return error.MissingCheckoutAnchor;
    const current_checkout = h.t.findText("Current checkout") orelse return error.MissingCheckoutMenu;
    try testing.expect(current_checkout.y < checkout_anchor.y);

    // Close checkout menu and open Select ref menu with synthetic branches.
    h.a.view.checkout_menu = false;
    try h.a.view.refs.append(h.a.gpa, try h.a.gpa.dupe(u8, "main"));
    try h.a.view.refs.append(h.a.gpa, try h.a.gpa.dupe(u8, "feature/popover-upward"));
    h.a.view.ref_space = try h.a.gpa.dupe(u8, "ws-1");
    h.t.settle(1);
    try h.t.clickText("Select ref");
    h.t.settle(1);
    const ref_anchor = h.a.view.ref_anchor orelse return error.MissingRefAnchor;
    const branch_row = h.t.findText("feature/popover-upward") orelse return error.MissingBranchRow;
    try testing.expect(branch_row.y < ref_anchor.y);
    try h.t.clickText("feature/popover-upward");
    h.t.settle(1);
    try testing.expectEqualStrings("From feature/popover-upward", if (h.t.findText("From feature/popover-upward")) |_| "From feature/popover-upward" else "");
    try testing.expectEqualStrings("feature/popover-upward", h.a.new_ref.?);
}

test "Settings Devices and the sidebar footer surface desktop app updates and auto-restart" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const ver = "99.0.0";
    @memcpy(h.a.release.latest[0..ver.len], ver);
    h.a.release.latest_len = ver.len;
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "dev-local");
    var dev_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"dev-remote","name":"Synthetic Linux Box","platform":"linux","version":"0.2.100","lastSeenAt":"2026-10-03T00:00:00Z"},
        \\ {"id":"dev-local","name":"Synthetic Mac","platform":"macos","version":"0.2.176","lastSeenAt":"2026-10-03T00:00:00Z"}]
    , .{});
    defer dev_parsed.deinit();
    try h.a.devices.replace(dev_parsed.value);
    h.t.settle(1);

    // Sidebar footer surfaces the update row immediately when a newer release is known.
    try testing.expect(h.t.hasText("Update to v99.0.0"));

    // Open Settings -> Devices and verify the update card, button, auto-restart toggle, and remote badge.
    h.a.settings.setSection(.devices);
    @import("view_settings.zig").open(&h.a);
    h.t.settle(1);
    h.snap("settings-devices-update-card");
    try testing.expect(h.t.hasText("Harness v99.0.0 is available."));
    try testing.expect(h.t.hasText("Update to v99.0.0"));
    try testing.expect(h.t.hasText("Restart automatically to install updates"));
    try testing.expect(h.t.hasText("Update available · Details"));
    try testing.expect(h.a.settings.get(.restart_to_install_updates));
    try h.t.clickText("Restart automatically to install updates");
    h.t.settle(1);
    try testing.expect(!h.a.settings.get(.restart_to_install_updates));
}

test "model picker row context badges stay valid through paint and clicking Models back button with reasoning slider never panics" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    h.a.gpa.free(h.a.new_harness);
    h.a.new_harness = try h.a.gpa.dupe(u8, "codex");
    h.a.gpa.free(h.a.models_for);
    h.a.models_for = try h.a.gpa.dupe(u8, "codex");
    var models_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"chatgpt-new/gpt-5.6-sol","label":"gpt-5.6-sol","context":200000,"maker":"openai","billing":"plan","reasoningLevels":["low","medium","high","xhigh"],"defaultReasoningLevel":"high"},
        \\ {"id":"chatgpt-new/gpt-6.1-sol","label":"gpt-6.1-sol","context":1048576,"maker":"openai","billing":"plan","reasoningLevels":["low","medium","high"],"defaultReasoningLevel":"medium"}]
    , .{});
    defer models_parsed.deinit();
    try h.a.models.replace(models_parsed.value);
    h.a.select(null, null);
    h.t.settle(1);
    h.a.togglePicker();
    h.t.settle(1);

    // Context badges ("200k", "1M") are allocated in the frame arena `c.alloc()`,
    // never on a stack buffer that corrupts into `?` before paint.
    try testing.expect(h.t.hasText("200k"));
    try testing.expect(h.t.hasText("1M"));
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| {
            try testing.expect(std.unicode.utf8ValidateSlice(tx.str));
            try testing.expect(std.mem.indexOf(u8, tx.str, "\xaa") == null);
        },
        else => {},
    };

    // Click `gpt-6.1-sol` in the picker list to open the Reasoning page (`levels.len == 3 > 1`).
    try h.t.clickText("gpt-6.1-sol");
    h.t.frame();
    const initial_page_h = h.a.view.model_picker.height;
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.stage != null);
    // Page height opens at its exact natural height without a 2-frame bounce.
    try testing.expect(@abs(h.a.view.model_picker.height - initial_page_h) <= 1.0);

    // Click the slider track to move reasoning from `medium` (1) to `low` (0),
    // release the mouse, and verify the thumb never snaps backward on release.
    const track = h.a.view.model_picker.track orelse return error.MissingSliderTrack;
    h.t.moveTo(track.x + 2, track.y + track.h / 2);
    h.t.ctx.input.click_count = 1;
    h.t.ctx.pointerDown();
    h.t.frame();
    try testing.expectEqual(@as(?usize, 0), h.a.view.model_picker.stage.?.level);
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
    try testing.expectEqual(@as(?usize, 0), h.a.view.model_picker.stage.?.level);

    // Click `<- Models` (`model-page-back`): `back(c, a)` clears `p.stage = null`
    // mid-frame before `slider()` runs; verify it never unwraps `p.stage.?` or
    // leaves freed memory in any text node.
    const back_btn = h.t.findText("Models") orelse return error.MissingBackButton;
    h.t.moveTo(back_btn.x + back_btn.w / 2, back_btn.y + back_btn.h / 2);
    h.t.ctx.input.click_count = 1;
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.pointerUp();
    h.t.frame();
    try testing.expect(h.a.view.model_picker.stage == null);
    try testing.expectEqual(@as(f32, 480), h.a.view.model_picker.height);
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| try testing.expect(std.mem.indexOf(u8, tx.str, "\xaa\xaa\xaa\xaa") == null),
        else => {},
    };
}

test "Cmd+W closes an open file tab before closing a chat tab even when multiple chat tabs are open" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.settings.set(.archive_on_close_chosen, true);
    h.a.settings.set(.archive_sessions_on_close, false);
    h.a.select("c1", "s1");
    h.a.newTab();
    h.a.select("c2", "s1");
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);

    // Open a file tab in the workbench host pane, then click back into the chat
    // composer so `.chat` is the focused surface while the file tab remains open.
    @import("app_files.zig").openFile(&h.a, "src/main.rs");
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    h.a.view.strip.focused = .{ .chat = 0 };
    h.t.settle(1);

    // First Cmd+W closes the open file tab (`src/main.rs`), NOT the chat tab `c2`.
    try testing.expect(h.t.shortcut(.{ .key = 'w', .cmd = true }));
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expect(!h.a.panels.host_open);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("c2", h.a.selected.?);
}

test "Cmd+=, Cmd+-, and Cmd+0 step and reset interface zoom at 120Hz" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.settle(1);
    try testing.expectEqual(@as(f32, 16), h.a.settings.uiFontSize());
    try testing.expectApproxEqAbs(@as(f32, 1.0), h.t.ctx.access.zoom, 0.001);

    try testing.expect(h.t.shortcut(.{ .key = '=', .cmd = true }));
    try testing.expectEqual(@as(f32, 18), h.a.settings.uiFontSize());
    try testing.expectApproxEqAbs(@as(f32, 18.0 / 16.0), h.t.ctx.access.zoom, 0.001);

    try testing.expect(h.t.shortcut(.{ .key = '=', .cmd = true, .shift = true }));
    try testing.expectEqual(@as(f32, 20), h.a.settings.uiFontSize());
    try testing.expectApproxEqAbs(@as(f32, 20.0 / 16.0), h.t.ctx.access.zoom, 0.001);

    try testing.expect(h.t.shortcut(.{ .key = '-', .cmd = true }));
    try testing.expectEqual(@as(f32, 18), h.a.settings.uiFontSize());
    try testing.expectApproxEqAbs(@as(f32, 18.0 / 16.0), h.t.ctx.access.zoom, 0.001);

    try testing.expect(h.t.shortcut(.{ .key = '0', .cmd = true }));
    try testing.expectEqual(@as(f32, 16), h.a.settings.uiFontSize());
    try testing.expectApproxEqAbs(@as(f32, 1.0), h.t.ctx.access.zoom, 0.001);
}

test "clicking the composer model chip opens the Zeron-style compact thinking tier panel and clicking the model subtitle expands upwards into the model list" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    h.a.gpa.free(h.a.new_harness);
    h.a.new_harness = try h.a.gpa.dupe(u8, "codex");
    h.a.gpa.free(h.a.models_for);
    h.a.models_for = try h.a.gpa.dupe(u8, "codex");
    var models_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"chatgpt-new/gpt-6.1-sol","label":"GPT-6.1-Sol","context":1048576,"maker":"openai","billing":"plan","reasoningLevels":["low","medium","high"],"defaultReasoningLevel":"high"},
        \\ {"id":"chatgpt-new/gpt-5.6-sol","label":"GPT-5.6-Sol","context":200000,"maker":"openai","billing":"plan","reasoningLevels":["low","medium","high","xhigh"],"defaultReasoningLevel":"high"}]
    , .{});
    defer models_parsed.deinit();
    try h.a.models.replace(models_parsed.value);
    h.a.setModel("chatgpt-new/gpt-6.1-sol");
    h.a.select(null, null);
    h.t.settle(1);

    // Open the compact thinking tier panel directly from the composer chip action.
    h.a.togglePickerCompact();
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.stage != null);
    try testing.expect(h.a.view.model_picker.stage.?.compact);
    try testing.expectEqual(@as(?usize, 2), h.a.view.model_picker.stage.?.level);
    try testing.expect(h.t.hasText("High"));
    try testing.expect(h.t.hasText("GPT-6.1-Sol"));

    // Drag/click the capsule slider to the first stop (`low`) and verify live update.
    const track = h.a.view.model_picker.track orelse return error.MissingSliderTrack;
    h.t.moveTo(track.x + 2, track.y + track.h / 2);
    h.t.ctx.input.click_count = 1;
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
    try testing.expectEqual(@as(?usize, 0), h.a.view.model_picker.stage.?.level);
    try testing.expectEqualStrings("low", h.a.new_reasoning.?);

    // Click the model subtitle (`GPT-6.1-Sol`) in the compact header (distinct from the composer chip)
    // to expand upwards into the model list.
    const chip = h.a.view.chip_anchor orelse return error.MissingChip;
    var model_btn: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| if (std.mem.eql(u8, t.str, "GPT-6.1-Sol") and (n.rect.y + n.rect.h < chip.y or n.rect.y > chip.y + chip.h)) {
            model_btn = n.rect;
        },
        else => {},
    };
    const btn_rect = model_btn orelse return error.MissingCompactModelButton;
    h.t.click(btn_rect.x + 12, btn_rect.y + 4);
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.stage == null);
    try testing.expect(h.a.view.model_picker.can_return_compact);
    try testing.expect(h.t.hasText("GPT-5.6-Sol"));

    // Pick `GPT-5.6-Sol` from the expanded list and verify it returns to the compact panel with the new model live.
    try h.t.clickText("GPT-5.6-Sol");
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.stage != null);
    try testing.expect(h.a.view.model_picker.stage.?.compact);
    try testing.expectEqualStrings("chatgpt-new/gpt-5.6-sol", h.a.new_model.?);
}

test "Settings Back button and Escape key close Settings and return to the workspace even when search has focus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    @import("view_settings.zig").open(&h.a);
    h.t.settle(1);
    try testing.expect(h.a.view.settings_open);

    // Pressing Escape while `settings-search-field` is focused closes Settings immediately.
    try testing.expect(h.t.shortcut(.{ .key = @import("nanoui").ui.Shortcut.escape }));
    h.t.settle(1);
    try testing.expect(!h.a.view.settings_open);

    // Re-open Settings and click the sidebar `← Back` button.
    @import("view_settings.zig").open(&h.a);
    h.t.settle(1);
    try testing.expect(h.a.view.settings_open);
    try h.t.clickText("Back");
    h.t.settle(1);
    try testing.expect(!h.a.view.settings_open);
}

test "older engine version triggers automatic daemon replacement and mid-frame catalog replacement retires arenas until next frame" {
    const updates = @import("view_updates.zig");
    try testing.expectEqual(updates.EngineVersionAction.replace_old_session, updates.decideEngineVersionAction("0.2.180", "0.2.178", true, false));
    try testing.expectEqual(updates.EngineVersionAction.up_to_date, updates.decideEngineVersionAction("0.2.180", "0.2.180", true, false));
    try testing.expectEqual(updates.EngineVersionAction.up_to_date, updates.decideEngineVersionAction("0.2.180", "0.2.181", true, false));

    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var p1 = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"m1","label":"Model One"}]
    , .{});
    defer p1.deinit();
    var p2 = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"m2","label":"Model Two"}]
    , .{});
    defer p2.deinit();
    try h.a.models.replace(p1.value);
    try h.a.models.replace(p2.value);
    try testing.expect(h.a.models.retired.items.len >= 1);
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), h.a.models.retired.items.len);

    // Clicking the composer model chip when `models_for` is unsynced and the
    // engine is connected triggers `ensureModels` -> `copyModels` mid-frame
    // between `modelChip`'s pre-click width measurement and post-click `rollText`.
    h.a.engine.state = .connected;
    const cat = @import("model_picker.zig").ensureCatalog(&h.a, h.a.target().harness, false).?;
    try cat.models.replace(p1.value);
    cat.loaded = true;
    h.a.retireSlice(h.a.models_for);
    h.a.models_for = &.{};
    h.t.frame();
    const chip = h.a.view.chip_anchor.?;
    h.t.click(chip.x + chip.w * 0.5, chip.y + chip.h * 0.5);
    try testing.expect(h.a.picker == .model);
    try testing.expectEqualStrings("Model One", h.a.modelLabel(h.a.target().model));
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), h.a.models.retired.items.len);
}
