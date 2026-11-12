//! Regression probes use only made-up chats, inputs and RPC replies.
const std = @import("std");
const App = @import("app.zig").App;
const question = @import("app_question.zig");
const queue = @import("app_queue.zig");
const drafts = @import("app_drafts.zig");
const testing = std.testing;

const input =
    \\{"reset":[{"id":"ask","role":"assistant","parts":[{"kind":"input","id":"input","requestId":"request","resolved":false,"questions":[
    \\{"id":"choice","header":"Choice","question":"Choose a synthetic option","options":["One","Two"],"multiSelect":true},
    \\{"id":"text","header":"Text","question":"Describe the synthetic plan","options":[],"multiline":true}]}]}]}
;

fn apply(a: *App, json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
}

fn open(a: *App) !void {
    a.select("synthetic-a", null);
    try apply(a, input);
    question.syncWizard(a);
}

fn scene(a: *App, json: []const u8) !void {
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
}

test "retention question page choices and typed answer survive chat navigation (#478)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try open(&a);
    question.pick(&a, 1);
    question.advance(&a);
    a.composer.set("unfinished synthetic answer");
    a.select("synthetic-b", null);
    a.composer.set("other chat draft");
    a.select("synthetic-a", null);
    try apply(&a, input);
    question.syncWizard(&a);
    try testing.expectEqual(@as(usize, 1), a.wizard.?.page);
    try testing.expectEqualStrings("unfinished synthetic answer", a.composer.text());
    try testing.expectEqualSlices(u8, &.{1}, a.wizard.?.picks[0].items);
}

test "retention question same request id in different chats never shares question answers (#478)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try open(&a);
    a.composer.set("answer for a");
    a.select("synthetic-b", null);
    try apply(&a, input);
    question.syncWizard(&a);
    try testing.expectEqualStrings("", a.composer.text());
    a.composer.set("answer for b");
    a.select("synthetic-a", null);
    try apply(&a, input);
    question.syncWizard(&a);
    try testing.expectEqualStrings("answer for a", a.composer.text());
}

test "retention question pending input survives a later assistant message (#479)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try open(&a);
    try apply(&a,
        \\{"reset":[{"id":"ask","role":"assistant","parts":[{"kind":"input","requestId":"request","resolved":false,"questions":[{"id":"q","question":"Still waiting","options":["Yes"]}]}]},{"id":"later","role":"assistant","parts":[{"kind":"text","text":"Later status"}]}]}
    );
    try testing.expect(question.pendingInput(&a) != null);
}

test "retention question failed RespondInput keeps same request and answer retryable (#479)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try open(&a);
    question.pick(&a, 0);
    question.advance(&a);
    a.composer.set("keep this answer on failure");
    // No engine: RespondInput calls its handler synchronously with not connected.
    question.advance(&a);
    question.syncWizard(&a);
    try testing.expect(question.pendingInput(&a) != null);
    try testing.expect(a.wizard != null);
    try testing.expectEqual(@as(usize, 1), a.wizard.?.page);
    try testing.expectEqualStrings("keep this answer on failure", a.composer.text());
}

test "retention question delayed answer failure belongs to original chat and request (#479)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, "{\"QueueCommand\":{\"$err\":\"Synthetic failure\"}}");
    try open(&a);
    question.pick(&a, 1);
    question.advance(&a);
    a.composer.set("original answer");
    question.advance(&a);
    a.select("synthetic-b", null);
    try apply(&a, input);
    question.syncWizard(&a);
    a.composer.set("new chat answer");
    _ = a.engine.pump();
    try testing.expectEqualStrings("new chat answer", a.composer.text());
    a.select("synthetic-a", null);
    try apply(&a, input);
    question.syncWizard(&a);
    try testing.expect(a.wizard != null);
    try testing.expectEqualStrings("original answer", a.composer.text());
}

test "retention question recall handoff restores original draft (#347)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.select("synthetic-a", null);
    try apply(&a,
        \\{"reset":[{"id":"old","role":"user","parts":[{"kind":"text","text":"Earlier synthetic prompt"}]}]}
    );
    a.composer.set("original unsent draft");
    const recalled = (try a.prompt_nav.step(a.gpa, a.transcript.entries.items, a.composer.text(), -1)).?;
    a.composer.set(recalled);
    try scene(&a, "{\"QueueCommand\":{}}");
    try apply(&a, input);
    question.syncWizard(&a);
    question.dismiss(&a);
    _ = a.engine.pump();
    try testing.expectEqualStrings("original unsent draft", a.composer.text());
    try testing.expect(!a.prompt_nav.active());
}

test "retention question queue editor suspends and restores exact question draft (#479)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a,
        \\{"BeginQueuedMessageEdit":{"outcome":"acquired","leaseId":"lease","baseTextHash":"hash","text":"Queued synthetic message"},"FinishQueuedMessageEdit":{"outcome":"cancelled"}}
    );
    try open(&a);
    a.caps.edit_lease = true;
    a.composer.set("unfinished question answer");
    queue.beginEdit(&a, "synthetic-row");
    _ = a.engine.pump();
    try testing.expect(a.queue_edit != null);
    try testing.expect(a.wizard == null);
    question.syncWizard(&a);
    try testing.expectEqualStrings("Queued synthetic message", a.composer.text());
    queue.finishEdit(&a, .cancel);
    _ = a.engine.pump();
    question.syncWizard(&a);
    try testing.expect(a.wizard != null);
    try testing.expectEqualStrings("unfinished question answer", a.composer.text());
}

test "retention question recall queue editor handoff restores original draft (#347)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.select("synthetic-a", null);
    try scene(&a,
        \\{"BeginQueuedMessageEdit":{"outcome":"acquired","leaseId":"lease","baseTextHash":"hash","text":"Queued synthetic message"},"FinishQueuedMessageEdit":{"outcome":"cancelled"}}
    );
    try apply(&a,
        \\{"reset":[{"id":"old","role":"user","parts":[{"kind":"text","text":"Earlier synthetic prompt"}]}]}
    );
    a.caps.edit_lease = true;
    a.composer.set("draft before queue edit");
    a.composer.set((try a.prompt_nav.step(a.gpa, a.transcript.entries.items, a.composer.text(), -1)).?);
    queue.beginEdit(&a, "synthetic-row");
    _ = a.engine.pump();
    try testing.expectEqualStrings("Queued synthetic message", a.composer.text());
    queue.finishEdit(&a, .cancel);
    _ = a.engine.pump();
    try testing.expectEqualStrings("draft before queue edit", a.composer.text());
    try testing.expect(!a.prompt_nav.active());
}

test "retention question late queue edit acquisition cannot replace another chat answer (#479)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a,
        \\{"BeginQueuedMessageEdit":{"outcome":"acquired","leaseId":"lease","baseTextHash":"hash","text":"Old chat queue text"}}
    );
    try open(&a);
    a.caps.edit_lease = true;
    queue.beginEdit(&a, "synthetic-row");
    a.select("synthetic-b", null);
    try apply(&a, input);
    question.syncWizard(&a);
    a.composer.set("new chat question answer");
    _ = a.engine.pump();
    try testing.expect(a.queue_edit == null);
    try testing.expect(a.wizard != null);
    try testing.expectEqualStrings("new chat question answer", a.composer.text());
}

test "retention question acknowledged answer suppression is chat scoped and resolved drafts expire (#479)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, "{\"QueueCommand\":{}}");
    try open(&a);
    question.pick(&a, 0);
    question.advance(&a);
    a.composer.set("synthetic answer");
    question.advance(&a);
    question.syncWizard(&a);
    try testing.expect(a.wizard == null); // in flight: no duplicate submission
    _ = a.engine.pump();
    question.syncWizard(&a);
    try testing.expect(a.wizard == null); // acknowledged, awaiting transcript
    a.select("synthetic-b", null);
    try apply(&a, input);
    question.syncWizard(&a);
    try testing.expect(a.wizard != null);
    a.select("synthetic-a", null);
    try apply(&a,
        \\{"reset":[{"id":"ask","role":"assistant","parts":[{"kind":"input","requestId":"request","resolved":true,"questions":[{"id":"choice","question":"Resolved","options":["One"]}]}]}]}
    );
    question.syncWizard(&a);
    try testing.expect(a.question_drafts.find("synthetic-a", "request") == null);
}

test "retention question actions use the real queued command wire contract" {
    for ([_]bool{ false, true }) |dismiss| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        try scene(&a, "{\"QueueCommand\":{}}");
        try open(&a);
        if (dismiss) {
            question.dismiss(&a);
        } else {
            question.pick(&a, 0);
            question.advance(&a);
            a.composer.set("synthetic real command answer");
            question.advance(&a);
        }
        const frame = a.engine.sent.items[a.engine.sent.items.len - 1];
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("QueueCommand", parsed.value.object.get("method").?.string);
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("synthetic-a", params.get("chatId").?.string);
        const command = params.get("command").?.object;
        try testing.expectEqualStrings(if (dismiss) "dismissInput" else "respondInput", command.get("kind").?.string);
        try testing.expectEqualStrings("request", command.get("requestId").?.string);
        _ = a.engine.pump();
        question.syncWizard(&a);
        try testing.expect(a.wizard == null);
    }
}

test "retention checkout and ref belong to parked canvas (#595)" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.new_checkout_local = true;
    a.new_ref = try a.gpa.dupe(u8, "synthetic-base");
    const d = try drafts.canvas(&a);
    a.new_checkout_local = false;
    a.gpa.free(a.new_ref.?);
    a.new_ref = try a.gpa.dupe(u8, "other-base");
    drafts.adopt(&a, d);
    try testing.expect(a.new_checkout_local);
    try testing.expectEqualStrings("synthetic-base", a.new_ref.?);
}

test "retention startup fences typed and attachment intent on latest source (#797)" {
    for ([_]bool{ false, true }) |attachment| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-saved","title":"Saved synthetic chat"}]
        , .{});
        defer chats.deinit();
        try a.chats.replace(chats.value);
        a.settings.apply("{\"openTabs\":[\"synthetic-saved\"]}");
        if (attachment) try @import("app_attachments.zig").stage(&a, "synthetic.txt", "synthetic attachment") else a.composer.set("typed synthetic draft");
        a.restoreTabs();
        try testing.expect(a.tabs_ready);
        try testing.expect(a.selected == null);
        if (attachment) try testing.expectEqual(@as(usize, 1), @import("app_attachments.zig").count(&a)) else try testing.expectEqualStrings("typed synthetic draft", a.composer.text());
    }
}
