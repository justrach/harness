//! Split panes with real transcript rows, not just clickable blank space.
//! All data is synthetic; no engine or account is opened.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const testing = std.testing;

const frame =
    \\{"reset":[
    \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic question"}]},
    \\ {"id":"a","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic reply in the other pane."}]}
    \\]}
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"a","deviceId":"d","title":"Synthetic chat","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("a", null);
        try load(&h.a.transcript);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
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

    fn load(t: *@import("transcript.zig").Transcript) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try t.apply(parsed.value);
    }
};

test "splitting and focusing keep the loaded transcript without another engine replay" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const entries = h.a.transcript.entries.items.ptr;
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    const p = h.a.peer("a").?;
    try testing.expectEqual(@as(usize, 2), p.transcript.entries.items.len);
    try testing.expectEqual(entries, p.transcript.entries.items.ptr);
    try testing.expect(p.transcript.complete);
    const reply = h.t.findText("Synthetic reply in the other pane.") orelse return error.ReplyMissing;
    try testing.expect(reply.y > 40 and reply.y + reply.h < 780);
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expectEqual(entries, h.a.transcript.entries.items.ptr);
    try testing.expectEqual(@as(usize, 2), h.a.transcript.entries.items.len);
    try testing.expect(h.a.transcript.complete);
    const composer = h.a.view.composer_anchor orelse return error.ComposerMissing;
    const chrome = @import("panel_chrome.zig");
    const first = chrome.paneSpan(h.a.view.chrome.chat_width, 0.5, 2, true);
    try testing.expect(composer.x >= h.a.view.chrome.x + 1 and composer.x + composer.w < h.a.view.chrome.x + first);
    try testing.expect(composer.y > 40 and composer.y + composer.h < 780);
    _ = h.t.shortcut(.{ .key = ']', .cmd = true });
    h.t.settle(1);
    try testing.expectEqual(entries, h.a.peer("a").?.transcript.entries.items.ptr);
}

test "clicking a peer message focuses its pane and accepts typing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    // Supply the peer's asynchronous reply explicitly: this test isolates
    // hit routing even on a build that still discards the outgoing rows.
    if (h.a.peer("a").?.transcript.entries.items.len == 0) try Harness.load(&h.a.peer("a").?.transcript);
    h.t.settle(1);
    try h.t.clickText("Synthetic reply in the other pane.");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.t.typeText("Synthetic draft");
    h.t.settle(1);
    try testing.expectEqualStrings("Synthetic draft", h.a.composer.text());
}

test "a live transcript subscription keeps delivering through promotion and demotion" {
    // A subscription can have started in either outlet. Focus must move
    // its data and route subsequent deltas without cancel/re-subscribe.
    for ([_]bool{ false, true }) |started_as_peer| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        if (!started_as_peer) a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
        a.engine.state = .connected;
        a.openChat("a", null);
        try Harness.load(&a.transcript);
        a.splitPane(.horizontal);
        if (started_as_peer) a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
        a.syncPeers();
        const id = a.peer("a").?.watch orelse return error.SubscriptionMissing;
        var len = "Synthetic reply in the other pane.".len;
        for ([_][]const u8{ " More.", " Again.", " Last." }, 0..) |text, phase| {
            if (phase == 1) a.focusPane(0);
            if (phase == 2) a.focusPane(1);
            len += text.len;
            const update = try std.json.Stringify.valueAlloc(testing.allocator, .{
                .id = id,
                .item = .{ .append = &.{.{ .entry = "a", .part = "p", .text = text, .len = len }}, .count = 2 },
            }, .{});
            defer testing.allocator.free(update);
            try a.engine.mux.dispatch(update);
            const t = if (phase == 1) &a.transcript else &a.peer("a").?.transcript;
            try testing.expectEqual(len, t.entries.items[1].parts.items[0].text.items.len);
            try testing.expect(t.complete);
        }
        var subscriptions: usize = 0;
        for (a.engine.sent.items) |request| {
            if (std.mem.indexOf(u8, request, "WatchDocMessages") != null) subscriptions += 1;
        }
        try testing.expectEqual(@as(usize, 1), subscriptions);
    }
}

test "a link in a split is not squeezed to an equal share" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1500, 780);
    h.a.splitPane(.horizontal);
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.tabs.layout().?.panes.items.len);
    @import("app_browser.zig").openLink(&h.a, "a", "http://localhost:31997/split");
    h.t.settle(1);
    const chrome = @import("panel_chrome.zig");
    const each_chat = chrome.paneSpan(h.a.view.chrome.chat_width, 1.0 / 3.0, 3, true);
    try testing.expect(h.a.view.chrome.host_width > each_chat);
    try testing.expectApproxEqAbs(@as(f32, 520), h.a.view.chrome.host_width, 0.5);
}

test "closing a split page leaves no empty panel to close again" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    h.t.settle(1);
    const before_chat_width = h.a.view.chrome.chat_width;
    @import("app_browser.zig").openLink(&h.a, "a", "http://localhost:31997/split");
    h.t.settle(1);
    try testing.expect(h.a.panels.host_open);
    @import("app_panels.zig").closeTab(&h.a, 0);
    h.t.settle(1);
    try testing.expect(!h.a.panels.host_open);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expectEqual(before_chat_width, h.a.view.chrome.chat_width);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
}

fn applyFrame(t: *@import("transcript.zig").Transcript, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
}

fn textTop(h: *Harness, text: []const u8) !f32 {
    return (h.t.findText(text) orelse {
        std.debug.print("missing text: {s}\n", .{text});
        return error.TextMissing;
    }).y;
}

test "a message sent while the turn works sits where it arrived, with later work under it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try applyFrame(&h.a.transcript,
        \\{"reset":[
        \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic question"}]},
        \\ {"id":"a","role":"assistant","status":"streaming","parts":[{"id":"p0","kind":"text","text":"Synthetic work before the message."}]}
        \\]}
    );
    h.t.settle(1);
    // The engine writes the message at the document's end at once...
    try applyFrame(&h.a.transcript,
        \\{"upsert":[{"after":"a","entry":{"id":"s","role":"user","status":"complete","parts":[{"id":"t0","kind":"text","text":"Synthetic steer"}]}}],"count":3}
    );
    h.t.settle(1);
    // ...and keeps streaming the running reply into the entry before it.
    try applyFrame(&h.a.transcript,
        \\{"upsert":[{"after":"u","entry":{"id":"a","role":"assistant","status":"streaming","parts":[
        \\ {"id":"p0","kind":"text","text":"Synthetic work before the message."},
        \\ {"id":"p1","kind":"text","text":"Synthetic work after the message."}]}}],"count":3}
    );
    h.t.settle(1);
    {
        const before = try textTop(&h, "Synthetic work before the message.");
        const message = try textTop(&h, "Synthetic steer");
        const after = try textTop(&h, "Synthetic work after the message.");
        try testing.expect(before < message);
        try testing.expect(message < after);
        h.snap("steer-mid-turn");
    }
    // The agent takes the message: the reply ends and the next one starts
    // after it. Each piece keeps its place; a split pane draws the same.
    try applyFrame(&h.a.transcript,
        \\{"upsert":[
        \\ {"after":"u","entry":{"id":"a","role":"assistant","status":"complete","durationMs":4000,"parts":[
        \\  {"id":"p0","kind":"text","text":"Synthetic work before the message."},
        \\  {"id":"p1","kind":"text","text":"Synthetic work after the message."}]}},
        \\ {"after":"s","entry":{"id":"b","role":"assistant","status":"streaming","parts":[{"id":"p0","kind":"text","text":"Synthetic reply to the steer."}]}}
        \\],"count":4}
    );
    for ([_]bool{ false, true }) |split| {
        if (split) h.a.splitPane(.horizontal);
        h.t.settle(1);
        const before = try textTop(&h, "Synthetic work before the message.");
        const message = try textTop(&h, "Synthetic steer");
        const after = try textTop(&h, "Synthetic work after the message.");
        const reply = try textTop(&h, "Synthetic reply to the steer.");
        try testing.expect(before < message);
        try testing.expect(message < after);
        try testing.expect(after < reply);
        if (!split) h.snap("steer-taken");
    }
}

fn textParent(h: *Harness, label: []const u8) !ui.Rect {
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, label)) return h.t.ctx.node(node.parent).rect,
        else => {},
    };
    std.debug.print("missing text: {s}\n", .{label});
    return error.TextMissing;
}

const question_options = [_][]const u8{ "Stop here: keep everything else", "Also remove the merged local leftovers", "Remove the merged remote branches too" };

test "an agent's long question keeps its options and buttons inside a split pane" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // Twelve paragraphs: taller than the window on their own.
    try applyFrame(&h.a.transcript,
        \\{"reset":[
        \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic request"}]},
        \\ {"id":"ask","role":"assistant","status":"complete","parts":[{"kind":"input","id":"r1","requestId":"r1","resolved":false,
        \\  "questions":[{"id":"q1","header":"Cleanup","question":"Synthetic opening line.\n\nThis synthetic paragraph says what was already removed and why each of those removals was safe to make without asking anyone first.\n\nThis synthetic paragraph lists what is left that looks old but needs a decision, because removing it means deleting something that cannot be brought back.\n\nThis synthetic paragraph names the branches that differ from their remote copies and the worktrees that still hold files nobody has committed.\n\nThis synthetic paragraph explains which of them are kept regardless, and how many uncommitted files each one of those still has in it.\n\nThis synthetic paragraph repeats the trade-off between a tidy list of branches and the risk of losing work that only exists in one place.\n\nThis synthetic paragraph describes what the remote would look like after each of the choices offered under this question.\n\nThis synthetic paragraph notes that nothing has been pushed, deleted remotely or rewritten so far, whatever is chosen next.\n\nThis synthetic paragraph says how long each choice would take and what would be reported once it had finished.\n\nThis synthetic paragraph covers the worktrees outside the repository, which were only inspected and never changed.\n\nThis synthetic paragraph is the last piece of background before the question itself is asked.\n\nSynthetic closing line.",
        \\   "options":["Stop here: keep everything else","Also remove the merged local leftovers","Remove the merged remote branches too"]}]}]}
        \\]}
    );
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expect(h.a.wizard != null);
    for ([_]f32{ 780, 560 }) |window_h| {
        h.t.resize(1200, window_h);
        h.t.settle(1);
        if (window_h == 780) h.snap("question-split-pane");
        // The answer's controls are all in the window, under the title bar.
        const submit = try textParent(&h, "Submit");
        const cancel = try textParent(&h, "Cancel question");
        try testing.expect(submit.y + submit.h <= window_h - 16);
        try testing.expect(cancel.y + cancel.h <= window_h - 16);
        var above = submit.y;
        var i = question_options.len;
        while (i > 0) {
            i -= 1;
            const row = try textParent(&h, question_options[i]);
            try testing.expect(row.y >= 40);
            try testing.expect(row.y + row.h <= above);
            above = row.y;
        }
        // The question gives way instead: it starts in view and scrolls to
        // its end, above the options.
        const opening = h.t.findText("Synthetic opening line.") orelse return error.TextMissing;
        try testing.expect(opening.y >= 40 and opening.y + opening.h <= above);
        const before = h.t.findText("Synthetic closing line.") orelse return error.TextMissing;
        try testing.expect(before.y >= above);
        h.t.scroll(opening.x + 8, opening.y + 4, -4000);
        h.t.settle(1);
        const closing = h.t.findText("Synthetic closing line.") orelse return error.TextMissing;
        try testing.expect(closing.y >= 40 and closing.y + closing.h <= above + 0.5);
        h.t.scroll(opening.x + 8, opening.y + 4, 4000);
        h.t.settle(1);
    }
}

test "a question's transcript chip ends inside a narrow pane" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try applyFrame(&h.a.transcript,
        \\{"reset":[
        \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic request"}]},
        \\ {"id":"ask","role":"assistant","status":"complete","parts":[{"kind":"input","id":"r1","requestId":"r1","resolved":false,
        \\  "questions":[{"id":"q1","header":"Cleanup","question":"This synthetic question is long enough to run past the right edge of a narrow split pane if nothing shortens it","options":["Yes","No"]}]}]}
        \\]}
    );
    h.a.splitPane(.horizontal);
    h.a.focusPane(0);
    for ([_]f32{ 1200, 900 }) |window_w| {
        h.t.resize(window_w, 780);
        h.t.settle(1);
        // The bubble is right-aligned in the column the chip is in.
        const bubble = try textParent(&h, "Synthetic request");
        const column_right = bubble.x + bubble.w;
        const chip = try textParent(&h, "Question");
        try testing.expect(chip.x + chip.w <= column_right + 0.5);
        // What it says after the question is whole, or left out.
        if (h.t.findText("Waiting for you")) |waiting| try testing.expect(waiting.x + waiting.w <= chip.x + chip.w - 8 + 0.5);
        if (window_w == 1200) h.snap("question-chip-narrow-pane");
    }
}
