//! Original selection/gesture retention exercised through the native tree.
//! Synthetic documents only; clipboard is ui.Tester's in-memory clipboard.
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
        h.a.offscreen = true;
        h.a.dark = true;
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"selection-a","deviceId":"fixture","title":"Synthetic selection"},
            \\  {"id":"selection-b","deviceId":"fixture","title":"Synthetic neighbor"} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("selection-a", null);
        try load(&h.a.transcript);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn snap(h: *Harness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try h.t.screenshot(path);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn apply(t: *@import("transcript.zig").Transcript, frame: []const u8) !void {
        var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer p.deinit();
        try t.apply(p.value);
    }

    fn load(t: *@import("transcript.zig").Transcript) !void {
        try apply(t,
            \\{"reset":[
            \\ {"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic prompt suffix"}]},
            \\ {"id":"a","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"First synthetic paragraph.\n\nSecond synthetic paragraph."}]}]}
        );
    }

    fn select(h: *Harness, text: []const u8, start: usize, end: usize) !void {
        const n = textNode(&h.t.ctx, text) orelse return error.TextNodeMissing;
        const r = h.t.ctx.rects.get(h.t.ctx.nodes.items[n].id) orelse return error.TextMissing;
        const st = h.t.ctx.nodes.items[n].content.text.style;
        const x1 = r.x + h.t.ctx.text.width(text[0..start], st);
        const x2 = r.x + h.t.ctx.text.width(text[0..end], st);
        h.t.drag(x1, r.y + r.h / 2, x2, r.y + r.h / 2);
        h.t.settle(0.1);
    }

    fn split(h: *Harness) !void {
        h.a.splitPane(.horizontal);
        h.t.settle(1);
        try testing.expect(h.a.peer("selection-a") != null);
    }
};

fn textNode(c: *ui.Context, text: []const u8) ?u32 {
    var found: ?u32 = null;
    for (c.nodes.items, 0..) |n, ix| if (n.content == .text and std.mem.eql(u8, n.content.text.str, text)) {
        found = @intCast(ix);
    };
    return found;
}

fn glyphX(layout: anytype, at: usize) f32 {
    for (layout.glyphs) |glyph| if (glyph.index >= at) return glyph.x;
    return layout.width;
}

fn copy(h: *Harness) void {
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
}

test "retention 348 URL-only inline code keeps code styling and excludes commands" {
    const md = @import("markdown.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pal: md.Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };
    for ([_][]const u8{ "`https://example.com/path?q=synthetic`", "`` https://example.com/path?q=synthetic ``" }) |source| {
        const blocks = md.parse(arena.allocator(), source, pal);
        const p = blocks[0].paragraph;
        try testing.expectEqual(@as(usize, 1), p.links.len);
        try testing.expectEqualStrings("https://example.com/path?q=synthetic", p.links[0].url);
        try testing.expectEqualStrings(p.text, p.links[0].url);
        try testing.expect(p.spans[0].mono);
        try testing.expectEqual(pal.code_bg, p.spans[0].background.?);
        try testing.expectEqual(pal.code, p.spans[0].color.?);
    }
    for ([_][]const u8{ "`curl https://example.com`", "`https://example.com extra`", "`javascript:alert(1)`", "`file:///synthetic`" }) |source| {
        const p = md.parse(arena.allocator(), source, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 0), p.links.len);
        try testing.expect(p.spans[0].mono);
    }
}

const legacy_peer = "[Message from Harness chat Synthetic sender. Reply to it with the Harness `send_message` tool, chat synthetic-sender.]\n\nSynthetic coordination body.";

fn setQueue(h: *Harness, text: []const u8) !void {
    const frame = try std.json.Stringify.valueAlloc(testing.allocator, &.{.{ .id = "queued", .text = text }}, .{});
    defer testing.allocator.free(frame);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
    defer parsed.deinit();
    try h.a.queue.replace(parsed.value);
}

test "retention peer legacy queued envelopes cannot initiate composer edits" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set("Human draft stays intact");
    h.a.caps.edit_lease = true;
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    h.a.engine.state = .connected;
    try setQueue(&h, legacy_peer);
    h.a.queueBeginEdit("queued");
    try testing.expect(h.a.queue.items[0].agent);
    try testing.expect(h.a.queue_begin == null);
    try testing.expectEqualStrings("Human draft stays intact", h.a.composer.text());
    for (h.a.engine.sent.items) |request| try testing.expect(std.mem.indexOf(u8, request, "BeginQueuedMessageEdit") == null);
    var preview: [400]u8 = undefined;
    try testing.expectEqualStrings("Synthetic sender: Synthetic coordination body.", @import("queue.zig").oneLine(&preview, legacy_peer));
}

test "retention peer acquired lease revalidates text and updated row before touching human draft" {
    for ([_]bool{ false, true }) |changed_queue| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.a.composer.set("Human draft stays intact");
        h.a.caps.edit_lease = true;
        const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{
            .BeginQueuedMessageEdit = .{ .outcome = "acquired", .leaseId = "synthetic-lease", .baseTextHash = "synthetic-hash", .text = if (changed_queue) "Initially human row" else legacy_peer },
            .FinishQueuedMessageEdit = .{ .outcome = "cancelled" },
        }, .{});
        defer testing.allocator.free(scene);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
        h.a.engine.state = .connected;
        try setQueue(&h, "Initially human row");
        h.a.queueBeginEdit("queued");
        if (changed_queue) try setQueue(&h, legacy_peer);
        try testing.expect(h.a.engine.pump());
        try testing.expect(h.a.queue_edit == null);
        try testing.expectEqualStrings("Human draft stays intact", h.a.composer.text());
        try testing.expectEqualStrings(if (changed_queue) legacy_peer else "Initially human row", h.a.queue.items[0].text);
        var cancelled = false;
        for (h.a.engine.sent.items) |request| {
            if (std.mem.indexOf(u8, request, "FinishQueuedMessageEdit") != null and std.mem.indexOf(u8, request, "\"cancel\"") != null) cancelled = true;
        }
        try testing.expect(cancelled);
    }
}

test "retention peer delivery has visible sender and body without human prompt rail tick" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"peer","role":"user","parts":[{"id":"p","kind":"text","text":"[Message from Harness chat Synthetic sender. Sender chat: synthetic-sender. Agent coordination, not a human request.]\n\nSynthetic coordination body."}]}]}
    );
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Agent message · Synthetic sender"));
    try testing.expect(h.t.hasText("Synthetic coordination body."));
    try testing.expect(!h.t.containsText("Sender chat:"));
    try h.snap("peer-origin-restored");
}

test "retention selection stays in original peer pane during cross-pane drag" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.split();
    h.a.select("selection-b", null);
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"b","role":"assistant","parts":[{"id":"p","kind":"text","text":"Foreign pane text must not join the selection."}]}]}
    );
    h.t.settle(1);
    const origin = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    const foreign = h.t.findText("Foreign pane text must not join the selection.") orelse return error.TextMissing;
    h.t.drag(origin.x + 100, origin.y + origin.h / 2, foreign.x + foreign.w / 2, foreign.y + foreign.h / 2);
    h.t.settle(0.1);
    copy(&h);
    try testing.expect(std.mem.indexOf(u8, h.t.clipboard.items, "Foreign pane") == null);
    try testing.expect(h.t.clipboard.items.len > 0);
}

test "retention selection partial reply and sent prompt copy exact ranges" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.select("First synthetic paragraph.", 6, 15);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
    try h.select("Synthetic prompt suffix", 10, 16);
    copy(&h);
    try testing.expectEqualStrings("prompt", h.t.clipboard.items);
    try h.snap("selection-prompt-restored");
}

test "retention selection spans paragraphs in both directions without stealing composer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const first = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    const second = h.t.findText("Second synthetic paragraph.") orelse return error.TextMissing;
    h.t.drag(first.x, first.y + first.h / 2, second.x + second.w, second.y + second.h / 2);
    h.t.settle(0.1);
    copy(&h);
    try testing.expect(std.mem.indexOf(u8, h.t.clipboard.items, "First synthetic paragraph.") != null);
    try testing.expect(std.mem.indexOf(u8, h.t.clipboard.items, "Second synthetic paragraph.") != null);
    try testing.expect(std.mem.indexOf(u8, h.t.clipboard.items, "Synthetic prompt suffix") == null);
    h.t.drag(second.x + second.w, second.y + second.h / 2, first.x, first.y + first.h / 2);
    h.t.settle(0.1);
    copy(&h);
    try testing.expect(std.mem.indexOf(u8, h.t.clipboard.items, "First synthetic paragraph.") != null);
    h.t.typeText("draft only");
    h.t.settle(0.1);
    // Selecting the editor (including keyboard selection) retires output.
    const editor = h.a.view.composer_anchor orelse return error.ComposerMissing;
    h.t.click(editor.x + editor.w / 2, editor.y + editor.h / 2);
    h.t.settle(0.1);
    h.t.typeText("Synthetic draft");
    _ = h.t.shortcut(.{ .key = 'a', .cmd = true });
    copy(&h);
    try testing.expectEqualStrings(h.a.composer.text(), h.t.clipboard.items);
    try testing.expect(h.t.ctx.selection.anchor == null);
    try h.select("First synthetic paragraph.", 6, 15);
    if (h.t.ctx.edits.get(h.a.view.composer_id)) |edit| try testing.expectEqual(edit.anchor, edit.caret);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
}

test "retention selection offscreen anchor keeps Copy ownership through culling" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.select("First synthetic paragraph.", 6, 15);
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..80) |_| try long.appendSlice(testing.allocator, "Synthetic offscreen continuation paragraph.\n\n");
    const frame = try std.json.Stringify.valueAlloc(testing.allocator, .{
        .upsert = &.{.{ .after = "a", .entry = .{ .id = "tail", .role = "assistant", .parts = &.{.{ .id = "tail-p", .kind = "text", .text = long.items }} } }},
        .count = 3,
    }, .{});
    defer testing.allocator.free(frame);
    try Harness.apply(&h.a.transcript, frame);
    h.t.settle(0.2);
    const scroll = h.a.view.jump_box;
    h.t.ctx.scroll.put(testing.allocator, scroll, h.t.ctx.scroll_max.get(scroll) orelse 0) catch {};
    h.t.frame();
    h.t.settle(0.1);
    try testing.expect(h.t.ctx.selection.anchor != null);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
}

test "retention selection removed output cannot supply stale native Copy in same frame" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.select("First synthetic paragraph.", 6, 15);
    try h.t.clipboard.appendSlice(testing.allocator, "unchanged");
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"replacement","role":"assistant","parts":[{"id":"p","kind":"text","text":"Replacement synthetic output."}]}]}
    );
    h.t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("unchanged", h.t.clipboard.items);
    try testing.expect(h.t.ctx.selection.anchor == null);
}

test "retention selection identical row keys in another window do not share Copy" {
    var first: Harness = undefined;
    try first.init();
    defer first.deinit();
    try first.select("First synthetic paragraph.", 6, 15);
    var second: Harness = undefined;
    try second.init();
    defer second.deinit();
    try second.t.clipboard.appendSlice(testing.allocator, "unchanged");
    copy(&second);
    try testing.expectEqualStrings("unchanged", second.t.clipboard.items);
    copy(&first);
    try testing.expectEqualStrings("synthetic", first.t.clipboard.items);
}

test "retention selection window deactivation invalidates stale copy" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.select("First synthetic paragraph.", 6, 15);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
    h.t.clipboard.clearRetainingCapacity();
    try h.t.clipboard.appendSlice(testing.allocator, "unchanged");
    h.t.ctx.window_focused = false;
    h.t.frame();
    h.t.ctx.window_focused = true;
    h.t.frame();
    copy(&h);
    try testing.expectEqualStrings("unchanged", h.t.clipboard.items);
    try testing.expect(h.t.ctx.selection.anchor == null);
}

test "retention selection chat replacement invalidates stale copy" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.select("First synthetic paragraph.", 6, 15);
    h.a.openChat("selection-b", null);
    h.t.frame();
    try testing.expect(h.t.ctx.selection.anchor == null);
    try h.t.clipboard.appendSlice(testing.allocator, "unchanged");
    copy(&h);
    try testing.expectEqualStrings("unchanged", h.t.clipboard.items);
}

test "retention gesture peer selection survives deferred first-click activation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.split();
    try h.select("First synthetic paragraph.", 6, 15);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
}

test "retention gesture first-click peer Copy runs before pane activation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.split();
    const message = h.t.findText("Second synthetic paragraph.") orelse return error.TextMissing;
    h.t.moveTo(message.x + 8, message.y + message.h / 2);
    h.t.settle(0.1);
    var button: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |n| {
        if (n.content == .image and @abs(n.rect.w - 14) < 0.1 and n.rect.y > message.y + message.h and n.rect.y < message.y + message.h + 60) {
            button = n.rect;
            break;
        }
    }
    const r = button orelse return error.CopyIconMissing;
    h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(0.1);
    try testing.expectEqualStrings("First synthetic paragraph.\n\nSecond synthetic paragraph.", h.t.clipboard.items);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
}

test "retention gesture harmless streaming refresh keeps original activation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.split();
    const r = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    h.t.down(r.x + 5, r.y + 5);
    try Harness.apply(&h.a.peer("selection-a").?.transcript,
        \\{"append":[{"entry":"a","part":"p","text":" More synthetic text.","len":76}],"count":2}
    );
    h.t.frame();
    h.t.up();
    h.t.settle(0.1);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
}

test "retention gesture mismatched mouse button consumes stale activation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.split();
    const r = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    h.t.down(r.x + 5, r.y + 5);
    h.t.ctx.input.button = .middle;
    h.t.up();
    h.t.ctx.input.button = .left;
    h.t.up();
    h.t.settle(0.1);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
}

test "retention gesture empty focused project replacement invalidates peer press" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.split();
    const r = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    h.t.down(r.x + 5, r.y + 5);
    if (h.a.space) |space| testing.allocator.free(space);
    h.a.space = try testing.allocator.dupe(u8, "replacement-synthetic-project");
    h.t.frame();
    h.t.up();
    h.t.settle(0.1);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
}

test "retention gesture rejects replacement peer at same indices" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.split();
    const r = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    h.t.down(r.x + 5, r.y + 5);
    const s = h.a.tabs.layout().?;
    testing.allocator.free(s.panes.items[0].?);
    s.panes.items[0] = try testing.allocator.dupe(u8, "selection-b");
    h.t.frame();
    h.t.up();
    h.t.settle(0.1);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
}

test "retention gesture rejects axis and focus round trips and window departure" {
    for (0..3) |scenario| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.split();
        const r = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
        h.t.down(r.x + 5, r.y + 5);
        switch (scenario) {
            0 => {
                h.a.tabs.layout().?.axis = .vertical;
                h.t.frame();
                h.a.tabs.layout().?.axis = .horizontal;
            },
            1 => {
                h.a.focusPane(0);
                h.t.frame();
                h.a.focusPane(1);
            },
            else => {
                h.t.ctx.window_focused = false;
                h.t.frame();
                h.t.ctx.window_focused = true;
            },
        }
        h.t.frame();
        h.t.up();
        h.t.settle(0.1);
        try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
    }
}

test "deep interface whitespace starts only in the original visible text band" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const first = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    const second = h.t.findText("Second synthetic paragraph.") orelse return error.TextMissing;
    // Empty space below an answer is not a text-selection start target.
    // The original gutter contract permits horizontal whitespace, not a
    // window-wide nearest-text search that can reach another pane/row.
    h.t.drag(second.x - 12, second.y + second.h + 70, first.x + 90, first.y + first.h / 2);
    h.t.settle(0.1);
    try testing.expect(h.t.ctx.selection.anchor == null);
}

test "deep interface horizontal gutters select exact forward and reverse ranges" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const text = "First synthetic paragraph.";
    const index = textNode(&h.t.ctx, text) orelse return error.TextMissing;
    const rect = h.t.ctx.nodes.items[index].rect;
    const style = h.t.ctx.nodes.items[index].content.text.style;
    const prefix = h.t.ctx.text.width("First synthetic", style);
    const full = h.t.ctx.text.width(text, style);
    h.t.drag(rect.x - 12, rect.y + rect.h / 2, rect.x + prefix, rect.y + rect.h / 2);
    h.t.settle(0.1);
    copy(&h);
    try testing.expectEqualStrings("First synthetic", h.t.clipboard.items);
    h.t.drag(rect.x + full + 12, rect.y + rect.h / 2, rect.x + prefix, rect.y + rect.h / 2);
    h.t.settle(0.1);
    copy(&h);
    try testing.expectEqualStrings(" paragraph.", h.t.clipboard.items);
}

test "deep interface link survives hover disclosure and removed selection source" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.select("First synthetic paragraph.", 6, 15);
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"link","role":"assistant","parts":[{"id":"p","kind":"text","text":"[Synthetic link](http://localhost:31997/deep)"}]}]}
    );
    h.t.settle(0.1);
    const r = h.t.findText("Synthetic link") orelse return error.TextMissing;
    h.t.moveTo(r.x + 8, r.y + r.h / 2);
    h.t.settle(0.7);
    h.t.click(r.x + 8, r.y + r.h / 2);
    h.t.settle(0.1);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expectEqualStrings("selection-a", h.a.panels.tabs.items[0].browser.?.parent);
    try testing.expectEqualStrings("http://localhost:31997/deep", h.a.panels.tabs.items[0].browser.?.url);
}

test "deep interface inactive pane link opens under the source owner on first click" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"link","role":"assistant","parts":[{"id":"p","kind":"text","text":"[Synthetic peer link](http://localhost:31997/peer)"}]}]}
    );
    h.t.settle(0.1);
    try h.split();
    const r = h.t.findText("Synthetic peer link") orelse return error.TextMissing;
    h.t.click(r.x + 8, r.y + r.h / 2);
    h.t.settle(0.1);
    try testing.expectEqualStrings("selection-a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expectEqualStrings("selection-a", h.a.panels.tabs.items[0].browser.?.parent);
}

test "deep interface doubleclick preserves whole Unicode graphemes 613" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    for ([_][]const u8{ "a\u{301}", "👍🏽", "🇸🇬", "👩‍💻" }) |cluster| {
        const text = try std.fmt.allocPrint(testing.allocator, "Start {s} end", .{cluster});
        defer testing.allocator.free(text);
        const frame = try std.json.Stringify.valueAlloc(testing.allocator, .{ .reset = &.{.{ .id = "unicode", .role = "assistant", .parts = &.{.{ .id = "p", .kind = "text", .text = text }} }} }, .{});
        defer testing.allocator.free(frame);
        try Harness.apply(&h.a.transcript, frame);
        h.t.settle(0.1);
        const index = textNode(&h.t.ctx, text) orelse return error.TextMissing;
        const node = h.t.ctx.nodes.items[index];
        const style = node.content.text.style;
        const layout = h.t.ctx.text.layout(text, style);
        const left = node.rect.x + glyphX(layout, 6);
        const width = glyphX(layout, 6 + cluster.len) - glyphX(layout, 6);
        // Both sides of the insertion-caret midpoint must choose the
        // clicked grapheme, rather than a previous/following word.
        for ([_]f32{ 0.01, 0.49, 0.51, 0.99 }) |fraction| {
            h.t.doubleClick(left + width * fraction, node.rect.y + node.rect.h / 2);
            h.t.settle(0.1);
            copy(&h);
            try testing.expectEqualStrings(cluster, h.t.clipboard.items);
        }
    }
}

test "deep interface doubleclick keeps identifier Unicode word and punctuation boundaries" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const text = "alpha_beta42, café! 中文.";
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"word-boundaries","role":"assistant","parts":[{"id":"p","kind":"text","text":"alpha_beta42, café! 中文."}]}]}
    );
    h.t.settle(0.1);
    const index = textNode(&h.t.ctx, text) orelse return error.TextMissing;
    const node = h.t.ctx.nodes.items[index];
    const style = node.content.text.style;
    for ([_]struct { start: usize, end: usize, expected: []const u8 }{
        .{ .start = 0, .end = 1, .expected = "alpha_beta42" },
        .{ .start = 11, .end = 12, .expected = "alpha_beta42" },
        .{ .start = 12, .end = 13, .expected = "," },
        .{ .start = 14, .end = 15, .expected = "café" },
        .{ .start = 19, .end = 20, .expected = "!" },
        .{ .start = 21, .end = 24, .expected = "中文" },
    }) |hit| {
        // Shape the complete line: independently measuring a prefix can
        // differ at kerning boundaries and move a .99-edge probe outside
        // the glyph it intends to test.
        const layout = h.t.ctx.text.layout(text, style);
        const left = node.rect.x + glyphX(layout, hit.start);
        const width = glyphX(layout, hit.end) - glyphX(layout, hit.start);
        for ([_]f32{ 0.01, 0.99 }) |fraction| {
            h.t.doubleClick(left + width * fraction, node.rect.y + node.rect.h / 2);
            h.t.settle(0.1);
            copy(&h);
            try testing.expectEqualStrings(hit.expected, h.t.clipboard.items);
        }
    }
}

test "deep interface collapsed prompt does not capture reply doubleclick" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"long-prompt","role":"user","parts":[{"id":"p","kind":"text","text":"Prompt line one\nPrompt line two\nHidden prompt three\nHidden prompt four\nHidden prompt five\nHidden prompt six\nHidden prompt seven\nHidden prompt eight\nHidden prompt nine\nHidden prompt ten"}]},{"id":"reply","role":"assistant","parts":[{"id":"p","kind":"text","text":"Visible synthetic reply."}]}]}
    );
    h.t.settle(1);
    const index = textNode(&h.t.ctx, "Visible synthetic reply.") orelse return error.TextMissing;
    const node = h.t.ctx.nodes.items[index];
    h.t.doubleClick(node.rect.x + h.t.ctx.text.width("Visible syn", node.content.text.style), node.rect.y + node.rect.h / 2);
    h.t.settle(0.1);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
}

test "deep interface thinking folds fit fractional zoom and narrow wrapping" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.a.settings.set(.transcript_compact_mode, false);
    const thought = "Synthetic reasoning wraps across the current narrow pane without clipping its last visual line or losing the following paragraph.\n\nFinal synthetic thought.";
    const frame = try std.json.Stringify.valueAlloc(testing.allocator, .{ .reset = &.{.{ .id = "reasoning", .role = "assistant", .status = "complete", .parts = &.{ .{ .id = "r", .kind = "reasoning", .text = thought }, .{ .id = "p", .kind = "text", .text = "Synthetic reply." } } }} }, .{});
    defer testing.allocator.free(frame);
    try Harness.apply(&h.a.transcript, frame);
    h.t.settle(1);
    try h.t.clickText("Thought process");
    h.t.settle(1);
    for ([_]f32{ 14, 18, 22 }) |font| {
        h.a.settings.setUiFontSize(font);
        for ([_]f32{ 360, 640 }) |width| {
            h.t.resize(width, 700);
            // Fold measurement retargets via frameIn timers, not only the
            // animation bit consumed by Tester.settle.
            h.t.advance(0.4);
            const last = textNode(&h.t.ctx, "Final synthetic thought.") orelse return error.ThoughtTailMissing;
            const node = h.t.ctx.nodes.items[last];
            const reply = textNode(&h.t.ctx, "Synthetic reply.") orelse return error.TextMissing;
            try testing.expectApproxEqAbs(h.t.ctx.nodes.items[reply].content.text.style.size, node.content.text.style.size, 0.01);
            var ix = node.parent;
            while (ix != 0 and !h.t.ctx.nodes.items[ix].style.scroll) : (ix = h.t.ctx.nodes.items[ix].parent) {
                const ancestor = h.t.ctx.nodes.items[ix];
                if (ancestor.style.clip and node.rect.y + node.rect.h > ancestor.rect.y + ancestor.rect.h + 1) {
                    std.debug.print("thinking clip font={d} width={d} leaf={any} clip={any} index={d}\n", .{ font, width, node.rect, ancestor.rect, ix });
                    return error.ThoughtTailClipped;
                }
            }
        }
    }
}

test "deep interface closed and reopened identical child cannot retain old selection ownership" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"WatchDocMessages":{"$items":[{"reset":[{"id":"child-answer","role":"assistant","parts":[{"id":"p","kind":"text","text":"Synthetic child selection."}]}]}]}}
    , .{});
    h.a.engine.state = .connected;
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"parent","role":"assistant","parts":[{"id":"spawn","kind":"tool","subagentRef":"synthetic-child","subagentStatus":"running","call":{"kind":"unknown","name":"Agent: Synthetic child"}}]}]}
    );
    const agents = @import("app_subagents.zig");
    agents.open(&h.a, "selection-a", &h.a.transcript.entries.items[0].parts.items[0]);
    h.t.settle(1);
    try h.select("Synthetic child selection.", 10, 15);
    copy(&h);
    try testing.expectEqualStrings("child", h.t.clipboard.items);
    @import("app_panels.zig").closeTab(&h.a, 0);
    agents.open(&h.a, "selection-a", &h.a.transcript.entries.items[0].parts.items[0]);
    h.t.settle(1);
    try testing.expect(h.t.ctx.selection.anchor == null);
}

test "deep interface closed child link press cannot activate its replacement surface" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"WatchDocMessages":{"$items":[{"reset":[{"id":"child-answer","role":"assistant","parts":[{"id":"p","kind":"text","text":"[Synthetic child link](http://localhost:31997/child)"}]}]}]}}
    , .{});
    h.a.engine.state = .connected;
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"parent","role":"assistant","parts":[{"id":"spawn","kind":"tool","subagentRef":"synthetic-child","subagentStatus":"running","call":{"kind":"unknown","name":"Agent: Synthetic child"}}]}]}
    );
    const agents = @import("app_subagents.zig");
    agents.open(&h.a, "selection-a", &h.a.transcript.entries.items[0].parts.items[0]);
    h.t.settle(1);
    const rect = h.t.findText("Synthetic child link") orelse return error.TextMissing;
    h.t.down(rect.x + 8, rect.y + rect.h / 2);
    @import("app_panels.zig").closeTab(&h.a, 0);
    agents.open(&h.a, "selection-a", &h.a.transcript.entries.items[0].parts.items[0]);
    h.t.advance(0.3);
    h.t.up();
    h.t.advance(0.2);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expect(h.a.panels.tabs.items[0].agent != null);
}

test "deep interface light mode selection paints a visible wash and copies exact text 179" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.dark = false;
    h.t.settle(0.1);
    try h.select("First synthetic paragraph.", 6, 15);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
    const rect = h.t.findText("First synthetic paragraph.") orelse return error.TextMissing;
    var wash = false;
    for (h.t.instances.items) |instance| {
        if (@abs(instance.color[3] - 0.28) < 0.001 and instance.rect[0] >= rect.x and instance.rect[1] >= rect.y - 1 and instance.rect[1] <= rect.y + rect.h and instance.rect[2] > 10) wash = true;
    }
    try testing.expect(wash);
    try h.snap("deep-light-selection-179");
}

test "deep interface question placeholder cannot leak across chat navigation 447" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    h.a.engine.state = .connected;
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"ask","role":"assistant","parts":[{"id":"i","kind":"input","requestId":"request-hint","questions":[{"id":"q","question":"Synthetic question?","options":["One"]}]}]}]}
    );
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Type your own answer, or pick an option above"));
    h.a.openChat("selection-b", null);
    h.t.advance(0.5);
    try testing.expect(h.t.hasText("Do anything…"));
    try testing.expect(!h.t.containsText("Type your own answer"));
    const placeholder = textNode(&h.t.ctx, "Do anything…") orelse return error.PlaceholderMissing;
    const color = h.t.ctx.nodes.items[placeholder].content.text.color;
    try testing.expect(color.a >= 0.5);
}

test "deep interface historical failure stays neutral after current model changes 785" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"old-failure","role":"assistant","parts":[{"id":"e","kind":"error","message":"Synthetic historical failure."}]}]}
    );
    h.t.settle(0.1);
    var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"selection-a","deviceId":"fixture","title":"Synthetic selection","config":{"harness":"graff","model":"new-synthetic-model"}}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Error"));
    try testing.expect(h.t.hasText("Synthetic historical failure."));
    try testing.expect(!h.t.containsText("new-synthetic-model failed"));
}

test "deep interface multiline question answer keeps both document ends visible 48" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.resize(400, 560);
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"ask","role":"assistant","parts":[{"id":"i","kind":"input","requestId":"request-long","questions":[{"id":"q","question":"Synthetic question?","options":["One"]}]}]}]}
    );
    h.t.settle(0.2);
    try h.t.clickText("Type your own answer, or pick an option above");
    const answer = "First synthetic answer line.\nSecond line.\nThird line.\nFourth line.\nFifth line.\nSixth line.\nSeventh line.\nEighth line.\nNinth line.\nTenth line.\nEleventh line.\nLast synthetic answer line.";
    h.t.typeText(answer);
    h.t.advance(0.2);
    try testing.expectEqualStrings(answer, h.a.composer.text());
    for ([_]usize{ answer.len, 0, answer.len }) |offset| {
        h.t.textOps(&.{.{ .select = .{ .anchor = offset, .caret = offset } }});
        h.t.advance(0.1);
        const focused = h.t.ctx.focused_text orelse return error.AnswerNotFocused;
        const field = h.t.ctx.rects.get(focused.id) orelse return error.AnswerNotMounted;
        try testing.expectEqual(offset, focused.caret);
        try testing.expect(focused.caret_rect.y >= field.y - 1);
        try testing.expect(focused.caret_rect.y + focused.caret_rect.h <= field.y + field.h + 1);
        const submit = h.t.findText("Submit") orelse return error.FooterMissing;
        try testing.expect(focused.caret_rect.y + focused.caret_rect.h < submit.y);
    }
}

test "retention question partial copy and replacement request clear stale selection" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"ask","role":"assistant","parts":[{"id":"i","kind":"input","requestId":"request-a","questions":[{"id":"q","header":"Synthetic","question":"Which synthetic option?","options":["One","Two"]}]}]}]}
    );
    h.t.settle(1);
    try h.select("Which synthetic option?", 6, 15);
    copy(&h);
    try testing.expectEqualStrings("synthetic", h.t.clipboard.items);
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"ask","role":"assistant","parts":[{"id":"i","kind":"input","requestId":"request-b","questions":[{"id":"q","header":"Synthetic","question":"Which synthetic option?","options":["One","Two"]}]}]}]}
    );
    h.t.settle(0.1);
    try testing.expect(h.t.ctx.selection.anchor == null);
}

test "retention question narrow short pane keeps live footer reachable" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try Harness.apply(&h.a.transcript,
        \\{"reset":[{"id":"ask","role":"assistant","parts":[{"id":"i","kind":"input","requestId":"request-a","questions":[{"id":"q","header":"Synthetic","question":"Which synthetic option?\n\nLong explanatory synthetic paragraph with enough words to wrap repeatedly in a narrow question pane.","options":["One synthetic choice that wraps","Two synthetic choices that wrap"]}]}]}]}
    );
    // Narrow content pane, not an 80-point remainder behind an open sidebar.
    h.a.view.sidebar_open = false;
    for ([_][2]f32{ .{ 640, 440 }, .{ 480, 400 }, .{ 360, 400 } }) |size| {
        h.t.resize(size[0], size[1]);
        h.t.settle(1);
        const submit = h.t.findText("Submit") orelse return error.FooterMissing;
        const cancel = h.t.findText("Cancel question") orelse return error.FooterMissing;
        try testing.expect(submit.x >= 0 and submit.x + submit.w <= size[0]);
        try testing.expect(cancel.x >= 0 and cancel.x + cancel.w <= size[0]);
        try testing.expect(submit.y >= 40 and submit.y + submit.h < size[1]);
        try testing.expect(cancel.y >= 40 and cancel.y + cancel.h < size[1]);
    }
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    h.a.engine.state = .connected;
    try h.snap("question-short-current-green");
    try h.t.clickText("Cancel question");
    h.t.settle(0.1);
    var dismissals: usize = 0;
    for (h.a.engine.sent.items) |request| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, request, .{});
        defer parsed.deinit();
        const method = parsed.value.object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "QueueCommand")) continue;
        const params = parsed.value.object.get("params") orelse continue;
        const command = params.object.get("command") orelse continue;
        const kind = command.object.get("kind") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "dismissInput")) continue;
        dismissals += 1;
        try testing.expectEqualStrings("selection-a", params.object.get("chatId").?.string);
        try testing.expectEqualStrings("request-a", command.object.get("requestId").?.string);
    }
    try testing.expectEqual(@as(usize, 1), dismissals);
}
