//! Synthetic probes for the original lifecycle contracts after the Nano port.
const std = @import("std");
const testing = std.testing;
const App = @import("app.zig").App;
const question = @import("app_question.zig");
const queue = @import("app_queue.zig");
const layout = @import("app_tab_layout.zig");

fn scene(a: *App, text: []const u8) !void {
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}
fn transcript(a: *App, text: []const u8) !void {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer p.deinit();
    try a.transcript.apply(p.value);
}
fn chats(a: *App) !void {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"a","title":"Synthetic archive","archived":true},{"id":"b","title":"Synthetic active","archived":false}]
    , .{});
    defer p.deinit();
    try a.chats.replace(p.value);
}
fn ask(a: *App) !void {
    a.select("a", null);
    try transcript(a,
        \\{"reset":[{"id":"assistant","role":"assistant","parts":[{"kind":"input","requestId":"question","resolved":false,"questions":[{"id":"q","question":"Synthetic question","options":[]}]}]}]}
    );
    question.syncWizard(a);
    a.composer.set("Synthetic answer kept for retry");
}
fn lastCall(a: *const App, method: []const u8) !?u64 {
    var found: ?u64 = null;
    for (a.engine.sent.items) |frame| {
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer p.deinit();
        if (std.mem.eql(u8, p.value.object.get("method").?.string, method)) found = @intCast(p.value.object.get("id").?.integer);
    }
    return found;
}

test "deep lifecycle an explicit empty boot canvas defeats late saved restoration" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try chats(&a);
    a.settings.apply("{\"openTabs\":[\"a\"],\"lastChatId\":\"a\"}");
    a.replaceCurrent(null);
    a.restoreTabs();
    try testing.expect(a.selected == null);
}

test "deep lifecycle authoritative deletion cannot resurrect a parked tab on activation or close" {
    for ([_]bool{ false, true }) |close_current| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        try chats(&a);
        a.tabs.setCurrent("a");
        a.select("a", null);
        a.newTab();
        a.tabs.setCurrent("b");
        a.select("b", null);
        a.tabs_ready = true;
        a.chats_synced = true; // at least one authoritative metadata publication
        const remaining = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[{\"id\":\"b\",\"title\":\"Synthetic surviving chat\"}]", .{});
        defer remaining.deinit();
        try a.chats.replace(remaining.value);
        if (close_current) a.closeTab(1) else a.showTab(0);
        try testing.expect(a.selected == null);
        try testing.expect(a.tabs.find("a") == null);
    }
}

test "deep lifecycle fresh Git canvases reset shared checkout and ref but parked drafts keep their picks" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.new_checkout_local = true;
    a.new_ref = try a.gpa.dupe(u8, "synthetic-private-base");
    a.composer.set("Original canvas draft");
    a.newTab();
    try testing.expect(!a.new_checkout_local);
    try testing.expect(a.new_ref == null);
    a.showTab(0);
    try testing.expect(a.new_checkout_local);
    try testing.expectEqualStrings("synthetic-private-base", a.new_ref.?);
    try testing.expectEqualStrings("Original canvas draft", a.composer.text());
    a.splitPane(.horizontal);
    try testing.expect(!a.new_checkout_local);
    try testing.expect(a.new_ref == null);
    a.focusPane(0);
    try testing.expect(a.new_checkout_local);
    try testing.expectEqualStrings("synthetic-private-base", a.new_ref.?);
}

test "deep lifecycle rejected local send restores a prompt never an agent question answer" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try ask(&a);
    a.composer.set("");
    const feedback = @import("app_send_feedback.zig");
    const pending = try feedback.begin(&a, "a", "message", "Failed synthetic prompt");
    pending.onReply(0, .{ .err = "Synthetic send rejection" });
    feedback.reap(&a);
    try testing.expectEqualStrings("", a.composer.text());
    try testing.expectEqualStrings("Failed synthetic prompt", a.draft_stash.items);
}

test "deep lifecycle answers and dismissals use the real QueueCommand protocol" {
    for ([_]bool{ false, true }) |dismiss| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        try scene(&a, "{\"QueueCommand\":{}}");
        try ask(&a);
        if (dismiss) question.dismiss(&a) else question.advance(&a);
        try testing.expect((try lastCall(&a, "QueueCommand")) != null);
        _ = a.engine.pump();
        try testing.expect(a.question_drafts.find("a", "question").?.phase == .answered);
    }
}

test "deep lifecycle question answer attachments use committed refs and survive command failure" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, "{\"QueueCommand\":{\"$err\":\"Synthetic rejection\"}}");
    try ask(&a);
    const attachments = @import("app_attachments.zig");
    try attachments.stage(&a, "synthetic.txt", "Synthetic bytes");
    const item = a.attachments.items.items[0];
    item.path = try a.gpa.dupe(u8, "/synthetic/committed.txt");
    item.status = .ready;
    question.advance(&a);
    var attached = false;
    for (a.engine.sent.items) |frame| if (std.mem.indexOf(u8, frame, "/synthetic/committed.txt") != null) {
        attached = true;
    };
    try testing.expect(attached);
    try testing.expectEqual(@as(usize, 0), attachments.count(&a));
    _ = a.engine.pump();
    question.syncWizard(&a);
    try testing.expect(a.wizard != null);
    try testing.expectEqualStrings("Synthetic answer kept for retry", a.composer.text());
    try testing.expectEqual(@as(usize, 1), attachments.count(&a));
    try testing.expect(attachments.ready(&a));
}

test "deep lifecycle superseded questions cannot reappear when the newer question resolves" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try ask(&a);
    question.suspendQuestion(&a);
    try transcript(&a,
        \\{"reset":[{"id":"old","role":"assistant","parts":[{"kind":"input","requestId":"question","resolved":false,"questions":[{"id":"q","question":"Old synthetic question","options":[]}]}]},{"id":"new","role":"assistant","parts":[{"kind":"input","requestId":"new-question","resolved":true,"questions":[{"id":"q","question":"New synthetic resolved question","options":[]}]}]}]}
    );
    question.syncWizard(&a);
    try testing.expect(a.wizard == null);
    try testing.expect(a.question_drafts.find("a", "question") == null);
}

test "deep lifecycle an unanswered question command times out without losing the answer" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, "{\"QueueCommand\":{}}");
    try ask(&a);
    question.advance(&a); // don't pump the queued reply: model a lost response
    try testing.expect(a.wizard == null);
    _ = question.tick(&a, 31);
    question.syncWizard(&a);
    try testing.expect(a.wizard != null);
    try testing.expectEqualStrings("Synthetic answer kept for retry", a.composer.text());
    // The old command's eventual reply must not close the retry editor.
    _ = a.engine.pump();
    question.syncWizard(&a);
    try testing.expect(a.wizard != null);
}

test "deep lifecycle acknowledged but unresolved question recovers its answer after safety timeout" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, "{\"QueueCommand\":{}}");
    try ask(&a);
    question.advance(&a);
    _ = a.engine.pump();
    question.syncWizard(&a);
    try testing.expect(a.wizard == null);
    _ = question.tick(&a, 6);
    question.syncWizard(&a);
    try testing.expect(a.wizard != null);
    try testing.expectEqualStrings("Synthetic answer kept for retry", a.composer.text());
}

test "deep lifecycle question command timeout cannot replace another chat answer" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, "{\"QueueCommand\":{}}");
    try ask(&a);
    question.advance(&a);
    a.select("b", null);
    a.composer.set("Unrelated new chat draft");
    _ = question.tick(&a, 31);
    try testing.expectEqualStrings("Unrelated new chat draft", a.composer.text());
    try testing.expect(a.question_drafts.find("a", "question").?.phase == .draft);
}

test "deep lifecycle navigation releases queue lease and ignores old finish acknowledgement" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a,
        \\{"BeginQueuedMessageEdit":{"$seq":[{"outcome":"acquired","leaseId":"lease-a","baseTextHash":"hash-a","text":"Queued a"},{"outcome":"acquired","leaseId":"lease-b","baseTextHash":"hash-b","text":"Queued b"}]},"FinishQueuedMessageEdit":{"outcome":"committed"}}
    );
    a.select("a", null);
    a.caps.edit_lease = true;
    queue.beginEdit(&a, "row-a");
    _ = a.engine.pump();
    a.composer.set("Revised queue a");
    queue.finishEdit(&a, .commit);
    const old = (try lastCall(&a, "FinishQueuedMessageEdit")).?;
    a.select("b", null);
    try testing.expect(!a.engine.mux.pending.contains(old));
    // A best-effort cancel must name the OLD chat and lease, not b.
    const release = (try lastCall(&a, "FinishQueuedMessageEdit")).?;
    try testing.expect(release != old);
    queue.beginEdit(&a, "row-b");
    _ = a.engine.pump();
    try testing.expect(a.queue_edit != null);
    try testing.expectEqualStrings("lease-b", a.queue_edit.?.lease);
    try testing.expectEqualStrings("Queued b", a.composer.text());
}

test "deep lifecycle reselecting a chat never discards its active queue editor" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a,
        \\{"BeginQueuedMessageEdit":{"outcome":"acquired","leaseId":"lease-a","baseTextHash":"hash-a","text":"Queued a"}}
    );
    a.select("a", null);
    a.caps.edit_lease = true;
    queue.beginEdit(&a, "row-a");
    _ = a.engine.pump();
    a.composer.set("Unfinished queue edit");
    a.select("a", null);
    try testing.expect(a.queue_edit != null);
    try testing.expectEqualStrings("Unfinished queue edit", a.composer.text());
}

test "deep lifecycle archived saved selections and split peers restore as references" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try chats(&a);
    a.settings.setTabLayout(
        \\{"version":1,"tabs":[{"chat":"a","split":{"focus":0,"shares":[1,1],"panes":[{}, {"chat":"b"}]}}]}
    );
    try testing.expect(layout.restore(&a));
    try testing.expect(a.selected != null);
    try testing.expectEqualStrings("a", a.selected.?);
    try testing.expect(a.findChat("a").?.archived);
    try testing.expectEqualStrings("b", a.tabs.layout().?.panes.items[1].?);
    try testing.expect((try lastCall(&a, "Mutate")) == null);
}

test "deep lifecycle archived openTabs fallback restores without unarchiving" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try chats(&a);
    a.settings.apply("{\"openTabs\":[\"a\",\"b\"],\"lastChatId\":\"a\"}");
    a.restoreTabs();
    try testing.expect(a.selected != null);
    try testing.expectEqualStrings("a", a.selected.?);
    try testing.expect(a.findChat("a").?.archived);
}

test "deep lifecycle restored geometry normalizes large shares and rejects invisible ratios" {
    for ([_][]const u8{ "[3.0e38,3.0e38]", "[3.0e38,1.0e-45]" }) |shares| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        try chats(&a);
        const json = try std.fmt.allocPrint(testing.allocator, "{{\"version\":1,\"tabs\":[{{\"chat\":\"b\",\"split\":{{\"focus\":0,\"shares\":{s},\"panes\":[{{}},{{\"chat\":\"a\"}}]}}}}]}}", .{shares});
        defer testing.allocator.free(json);
        a.settings.setTabLayout(json);
        try testing.expect(layout.restore(&a));
        if (a.tabs.layout()) |split| {
            var sum: f64 = 0;
            for (split.shares.items) |share| {
                try testing.expect(std.math.isFinite(share));
                try testing.expect(share > 0);
                sum += share;
            }
            try testing.expectApproxEqAbs(@as(f64, 1), sum, 1e-6);
        }
        try testing.expectEqualStrings("b", a.selected.?);
    }
}

test "deep lifecycle live progress and remote pending ownership end when panes hide" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    const progress = @import("app_progress.zig");
    const feedback = @import("app_send_feedback.zig");
    a.tabs.setCurrent("a");
    a.select("a", null);
    try testing.expect(try a.tabs.split(.horizontal));
    a.tabs.setCurrent("b");
    a.select("b", null);
    const pending = try feedback.begin(&a, "a", "remote", "Synthetic remote pending");
    pending.remote = true;
    pending.finished = true;
    _ = progress.tick(&a, 0);
    try testing.expectEqual(@as(usize, 2), a.live_progress.feeds.items.len);
    _ = progress.tick(&a, 1);
    try testing.expectEqual(@as(usize, 2), a.live_progress.feeds.items.len);
    a.tabs.layout().?.zoomed = true;
    _ = progress.tick(&a, 2);
    try testing.expectEqual(@as(usize, 1), a.live_progress.feeds.items.len);
    try testing.expectEqualStrings("b", a.live_progress.feeds.items[0].chat);
    try testing.expect(pending.withdrawn);
    feedback.reap(&a);
    a.view.settings_open = true;
    _ = progress.tick(&a, 3);
    try testing.expectEqual(@as(usize, 0), a.live_progress.feeds.items.len);
}

test "deep lifecycle question and queue remain opaque across quiet frames resize and remount" {
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try transcript(&h.a,
        \\{"reset":[{"id":"assistant","role":"assistant","parts":[{"kind":"input","requestId":"stable","resolved":false,"questions":[{"id":"q","question":"Synthetic stable question","options":[]}]}]}]}
    );
    const rows = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"row","text":"Synthetic stable queued prompt"}]
    , .{});
    defer rows.deinit();
    try h.a.queue.replace(rows.value);
    for ([_][2]f32{ .{ 1200, 780 }, .{ 760, 520 }, .{ 1200, 780 } }) |size| {
        h.t.resize(size[0], size[1]);
        h.t.settle(0.4);
        for (0..5) |_| {
            h.t.advance(0.2);
            for ([_][]const u8{ "Synthetic stable question", "Synthetic stable queued prompt" }) |caption| {
                var visible = false;
                for (h.t.ctx.nodes.items, 0..) |node, ix| switch (node.content) {
                    .text => |text| if (std.mem.eql(u8, text.str, caption)) {
                        var opacity: f32 = 1;
                        var parent: u32 = @intCast(ix);
                        while (parent != std.math.maxInt(u32)) {
                            opacity *= h.t.ctx.nodes.items[parent].style.opacity;
                            parent = h.t.ctx.nodes.items[parent].parent;
                        }
                        try testing.expect(opacity > 0.9);
                        visible = true;
                    },
                    else => {},
                };
                try testing.expect(visible);
            }
        }
    }
    h.a.select("b", null);
    h.t.settle(0.2);
    h.a.select("a", null);
    try transcript(&h.a,
        \\{"reset":[{"id":"assistant","role":"assistant","parts":[{"kind":"input","requestId":"stable","resolved":false,"questions":[{"id":"q","question":"Synthetic stable question","options":[]}]}]}]}
    );
    h.t.settle(0.4);
    try testing.expect(h.t.hasText("Synthetic stable question"));
}

test "deep lifecycle duplicate saved chat identities are restored only once" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try chats(&a);
    a.settings.setTabLayout(
        \\{"version":1,"tabs":[{"chat":"b","split":{"focus":0,"shares":[1,1],"panes":[{"tabs":[{}, {"chat":"a"}]},{"chat":"b"}]}},{"chat":"a"}]}
    );
    try testing.expect(layout.restore(&a));
    var b: usize = 0;
    var archived: usize = 0;
    for (a.tabs.items.items, 0..) |id, ix| {
        if (id) |s| {
            if (std.mem.eql(u8, s, "b")) b += 1;
            if (std.mem.eql(u8, s, "a")) archived += 1;
        }
        if (a.tabs.splits.items[ix]) |split| {
            for (split.panes.items) |pane| if (pane) |s| {
                if (std.mem.eql(u8, s, "b")) b += 1;
                if (std.mem.eql(u8, s, "a")) archived += 1;
            };
            for (split.groups[0..split.panes.items.len]) |group| for (group.items.items) |slot| if (slot.chat) |s| {
                if (std.mem.eql(u8, s, "b")) b += 1;
                if (std.mem.eql(u8, s, "a")) archived += 1;
            };
        }
    }
    try testing.expectEqual(@as(usize, 1), b);
    try testing.expectEqual(@as(usize, 1), archived);
}
