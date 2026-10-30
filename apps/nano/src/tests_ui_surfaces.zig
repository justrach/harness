//! Side surfaces opened from a transcript, using synthetic engine replies.
// Browser and agent fixtures never connect to the user's engine.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.openChat("synthetic-parent", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1400, .height = 900, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn transcript(h: *Harness, text: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
    }
};

test "a linked agent stays visible and opens its transcript without changing the parent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"WatchDocMessages":{"$items":[{"reset":[{"id":"child-answer","role":"assistant","status":"streaming","parts":[{"id":"text","kind":"text","text":"Synthetic child is checking the links"}]}]}]}}
    , .{});
    h.a.engine.state = .connected;
    try h.transcript(
        \\{"reset":[{"id":"parent-answer","role":"assistant","status":"complete","parts":[
        \\ {"id":"read","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"synthetic.zig"}},
        \\ {"id":"spawn","kind":"tool","resolved":true,"subagentRef":"synthetic-parent--sub--spawn","subagentStatus":"running","call":{"kind":"unknown","name":"Agent: Audit synthetic links"}}]}]}
    );
    // The whole Agent row is the link, including its original bot icon,
    // not only the task-title text. The label is 16 points right of it.
    try testing.expect(h.t.hasText("Audit synthetic links"));
    const label = h.t.findText("Agent") orelse return error.MissingAgentLabel;
    h.t.click(label.x - 16, label.y + label.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqualStrings("synthetic-parent", h.a.selected.?);
    try testing.expect(h.t.hasText("Synthetic child is checking the links"));
    if (std.c.getenv("NANO_AGENT_SNAPSHOT")) |path| try h.t.screenshot(std.mem.span(path));
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try h.t.clickText("Audit synthetic links");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    var watches: usize = 0;
    for (h.a.engine.sent.items) |request| {
        if (std.mem.indexOf(u8, request, "synthetic-parent--sub--spawn") != null) watches += 1;
    }
    try testing.expectEqual(@as(usize, 1), watches);
}

test "finished MCP agents use their frozen transcript and the original Harness bot icon" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"FetchToolBlob":{"text":"[{\"id\":\"answer\",\"role\":\"assistant\",\"status\":\"complete\",\"parts\":[{\"id\":\"text\",\"kind\":\"text\",\"text\":\"Synthetic frozen findings\"}]}]"}}
    , .{});
    h.a.engine.state = .connected;
    try h.transcript(
        \\{"reset":[{"id":"parent-answer","role":"assistant","status":"complete","parts":[
        \\ {"id":"spawn","kind":"tool","resolved":true,"subagentRef":"synthetic-parent--sub--frozen","subagentStatus":"done","call":{"kind":"mcp","server":"synthetic","tool":"Agent","input":{"description":"Review synthetic icons"}}}]}]}
    );
    try h.t.clickText("Review synthetic icons");
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Synthetic frozen findings"));
    try testing.expectEqual(@as(usize, 1), h.a.engine.sent.items.len);
    try testing.expect(std.mem.indexOf(u8, h.a.engine.sent.items[0], "synthetic-parent/synthetic-parent--sub--frozen") != null);
    try testing.expect(h.a.panels.tabs.items[0].agent.?.loaded);
}

test "a stray subagent ref on a command does not offer an agent surface" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.transcript(
        \\{"reset":[{"id":"answer","role":"assistant","parts":[{"id":"command","kind":"tool","resolved":true,
        \\ "subagentRef":"never-created","subagentStatus":"done","call":{"kind":"exec","command":"printf synthetic"},"output":"Synthetic command result"}]}]}
    );
    try h.t.clickText("Ran 1 command");
    h.t.settle(0.1);
    try h.t.clickText("Run");
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Synthetic command result"));
    try testing.expect(!h.a.panels.host_open);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
}

test "closing a subagent cancels its pending feed before retiring the rendered rows" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"WatchDocMessages":{"$items":[{"reset":[]}]}}
    , .{});
    h.a.engine.state = .connected;
    try h.transcript(
        \\{"reset":[{"id":"answer","role":"assistant","parts":[{"id":"spawn","kind":"tool","subagentRef":"synthetic-child",
        \\ "subagentStatus":"running","call":{"kind":"unknown","name":"Agent: Synthetic pending feed"}}]}]}
    );
    const surfaces = @import("app_subagents.zig");
    surfaces.open(&h.a, "synthetic-parent", &h.a.transcript.entries.items[0].parts.items[0]);
    surfaces.settleFrame(&h.a);
    const id = h.a.panels.tabs.items[0].agent.?.watch.?;
    @import("app_panels.zig").closeTab(&h.a, 0);
    try testing.expect(!h.a.engine.mux.pending.contains(id));
    try testing.expectEqual(@as(usize, 1), h.a.panels.retired.items.len);
    surfaces.settleFrame(&h.a);
    _ = h.a.tick(20); // Late queued replies find no handler or freed context.
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), h.a.panels.retired.items.len);
}

test "the native side-surface picker offers Browser and accepts localhost addresses" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.panels.host_open = true;
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Browser"));
    try h.t.clickText("Browser");
    h.t.settle(0.1);
    try h.t.clickText("Website or localhost");
    h.t.typeText("localhost:31997");
    h.t.key(.enter);
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("http://localhost:31997/"));
    try testing.expectEqualStrings("synthetic-parent", h.a.selected.?);
}

test "a transcript web link opens a new Browser surface in its parent conversation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.transcript(
        \\{"reset":[{"id":"answer","role":"assistant","parts":[{"id":"text","kind":"text","text":"[Open synthetic preview](http://localhost:31997/preview)"}]}]}
    );
    const r = h.t.findText("Open synthetic preview") orelse return error.SyntheticLinkMissing;
    h.t.click(r.x + 8, r.y + 8);
    h.t.settle(0.1);
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expect(h.t.hasText("http://localhost:31997/preview"));
}

test "browser activations reject unsafe links and discard stale conversation targets" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const browser = @import("app_browser.zig");
    for ([_][]const u8{ "javascript:alert(1)", "file:///synthetic", "https://user:pass@example.com/", "https://example.com/\\path" }) |url| browser.openLink(&h.a, "synthetic-parent", url);
    try testing.expect(h.a.panels.pending_browser == null);
    browser.openLink(&h.a, "synthetic-parent", "http://localhost:31997/");
    h.a.openChat("another-synthetic-chat", null);
    h.t.settle(0.1);
    try testing.expect(h.a.panels.pending_browser == null);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
}

test "generated-page chips open only their local host's validated page and lock navigation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-parent","deviceId":"synthetic-local","title":"Synthetic browser fixture","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.device_id = try testing.allocator.dupe(u8, "synthetic-remote");
    try h.transcript(
        \\{"reset":[{"id":"answer","role":"assistant","parts":[{"id":"page","kind":"tool","resolved":true,
        \\ "call":{"kind":"unknown","name":"render_html"},"view":{"kind":"html","id":"0123456789abcdef0123456789abcdef"}}]}]}
    );
    try h.t.clickText("render_html");
    h.t.settle(0.1);
    try testing.expect(h.a.panels.pending_browser == null);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    testing.allocator.free(h.a.device_id.?);
    h.a.device_id = try testing.allocator.dupe(u8, "synthetic-local");
    try h.t.clickText("render_html");
    h.t.settle(0.1);
    const b = h.a.panels.tabs.items[0].browser.?;
    try testing.expectEqualStrings("graff-view://html/0123456789abcdef0123456789abcdef", b.url);
    b.navigate("https://example.com/");
    try testing.expectEqualStrings("graff-view://html/0123456789abcdef0123456789abcdef", b.url);
    // ui.Tester never starts WebKit, even after opening a Browser tab.
    try testing.expect(b.native == null);
}
