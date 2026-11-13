//! Native controls over synthetic engine frames; no Git process or real data.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const git = @import("app_git.zig");
const flow = @import("app_git_workflow.zig");
const panels = @import("app_panels.zig");
const initial =
    \\{"checkoutId":"checkout-demo","checksum":"snapshot-1","branch":"feature/navigation","headSha":"abc123456789","upstream":{"remote":"origin","branch":"feature/navigation"},"files":[{"path":"navigation.zig","indexStatus":"M","worktreeStatus":"M"},{"path":"notes.md","indexStatus":"?","worktreeStatus":"?"}]}
;
fn setup(h: *Harness, dark: bool) !void {
    try h.init(dark);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"a","deviceId":"local","title":"Navigation polish","spaceId":"local-project","cwd":"/synthetic/fieldnotes","branch":"feature/navigation","archived":false},
        \\ {"id":"b","deviceId":"remote","title":"Remote work","spaceId":"remote-project","cwd":"/synthetic/remote","branch":"feature/remote","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    const scene = try std.fmt.allocPrint(testing.allocator, "{{\"ListGitHistory\":{{\"commits\":[{{\"sha\":\"abc123456789\",\"subject\":\"Polish navigation\",\"authorName\":\"Demo Developer\",\"authoredAt\":\"2026-11-01\"}}]}},\"GetCheckoutGitState\":{s},\"ApplyCheckoutGitAction\":{s}}}", .{ initial, initial });
    defer testing.allocator.free(scene);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
    h.a.engine.state = .connected;
    git.open(&h.a, .git);
    h.t.settle(0.1);
}
fn deliver(h: *Harness, body: []const u8) !void {
    const frame = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"ok\":{s}}}", .{ h.a.panels.git_workflow.pending.?, body });
    defer testing.allocator.free(frame);
    try h.a.engine.mux.dispatch(frame);
}
fn load(h: *Harness) !void {
    flow.show(&h.a);
    try deliver(h, initial);
    h.t.settle(0.1);
}
fn lastRequest(h: *Harness) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, h.a.engine.sent.items[h.a.engine.sent.items.len - 1], .{});
}
fn assertAction(h: *Harness, kind: []const u8, checksum: []const u8) !void {
    var frame = try lastRequest(h);
    defer frame.deinit();
    try testing.expectEqualStrings("ApplyCheckoutGitAction", frame.value.object.get("method").?.string);
    const p = frame.value.object.get("params").?.object;
    try testing.expectEqualStrings("a", p.get("chatId").?.string);
    try testing.expectEqualStrings("checkout-demo", p.get("checkoutId").?.string);
    try testing.expectEqualStrings(checksum, p.get("expectedChecksum").?.string);
    try testing.expectEqualStrings(kind, p.get("action").?.object.get("kind").?.string);
}
fn screenshot(h: *Harness, name: []const u8) !void {
    const raw = std.c.getenv("NANO_GIT_WORKFLOW_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(raw), name });
    try h.t.screenshot(path);
}

test "native git workflow displays only exact fixed host errors" {
    try testing.expectEqualStrings("An agent is active in this working tree", flow.friendlyError("An agent is active in this working tree", true));
    const private = "An agent is active in this working tree: private transport details";
    try testing.expect(std.mem.indexOf(u8, flow.friendlyError(private, true), "private") == null);
    try testing.expect(std.mem.indexOf(u8, flow.friendlyError("secret remote URL", false), "secret") == null);
}

test "native git workflow stages exact files and commits only after confirmation" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try setup(&h, dark);
        defer h.deinit();
        try screenshot(&h, if (dark) "before-dark" else "before-light");
        try h.t.clickText("Staging");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("Staged (1)"));
        try testing.expect(h.t.hasText("Unstaged (2)"));
        try testing.expect(h.t.hasText("navigation.zig"));
        const file_rect = h.t.findText("navigation.zig").?;
        const unstage_rect = h.t.findText("Unstage").?;
        try testing.expect(@abs(file_rect.y - unstage_rect.y) < 20);
        try testing.expect(h.t.hasText("notes.md"));
        try screenshot(&h, if (dark) "changes-dark" else "changes-light");
        const calls = h.a.engine.sent.items.len;
        flow.fileAction(&h.a, ":(glob)*", true); // Never send unlisted paths.
        flow.arm(&h.a, .commit); // Empty message cannot arm.
        try testing.expect(h.a.panels.git_workflow.confirm == null);
        try testing.expectEqual(calls, h.a.engine.sent.items.len);
        flow.fileAction(&h.a, "notes.md", true);
        try assertAction(&h, "stage", "snapshot-1");
        var frame = try lastRequest(&h);
        defer frame.deinit();
        try testing.expectEqualStrings("notes.md", frame.value.object.get("params").?.object.get("action").?.object.get("path").?.string);
        flow.fileAction(&h.a, "navigation.zig", false); // Busy: exactly one action.
        try testing.expectEqual(calls + 1, h.a.engine.sent.items.len);
        try deliver(&h,
            \\{"checkoutId":"checkout-demo","checksum":"snapshot-2","branch":"feature/navigation","headSha":"abc123456789","files":[{"path":"notes.md","indexStatus":"A","worktreeStatus":" "}]}
        );
        h.t.settle(0.1);
        h.a.panels.git_workflow.message.set("Document navigation");
        h.t.settle(0.1);
        const before_commit = h.a.engine.sent.items.len;
        try h.t.clickText("Commit staged…");
        h.t.settle(0.1);
        try testing.expectEqual(before_commit, h.a.engine.sent.items.len);
        try testing.expect(h.t.hasText("Commit 1 staged file?"));
        try screenshot(&h, if (dark) "commit-confirmation-dark" else "commit-confirmation-light");
        try h.t.clickText("Cancel");
        try testing.expectEqual(before_commit, h.a.engine.sent.items.len);
        try h.t.clickText("Commit staged…");
        try h.t.clickText("Confirm commit");
        try assertAction(&h, "commit", "snapshot-2");
        h.t.settle(0.1);
        try testing.expectEqualStrings("", h.a.panels.git_workflow.message.text());
        try testing.expect(h.t.hasText("Staged changes committed."));
        try testing.expect(!flow.canCommit(&h.a));
    }
}

test "native git workflow unstage preserves intent and push requires destination confirmation" {
    var h: Harness = undefined;
    try setup(&h, true);
    defer h.deinit();
    try load(&h);
    try h.t.clickText("Unstage");
    try assertAction(&h, "unstage", "snapshot-1");
    h.t.settle(0.1);
    const calls = h.a.engine.sent.items.len;
    try h.t.clickText("Push…");
    h.t.settle(0.1);
    try testing.expectEqual(calls, h.a.engine.sent.items.len);
    try testing.expect(h.t.hasText("Push feature/navigation to origin/feature/navigation?"));
    try screenshot(&h, "push-confirmation-dark");
    try h.t.clickText("Confirm push");
    try assertAction(&h, "push", "snapshot-1");
    try testing.expect(h.t.hasText("Push completed."));
    flow.arm(&h.a, .push);
    flow.confirm(&h.a);
    const frame = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"err\":\"private remote error must not appear\"}}", .{h.a.panels.git_workflow.pending.?});
    defer testing.allocator.free(frame);
    try h.a.engine.mux.dispatch(frame);
    h.t.settle(0.1);
    try testing.expect(h.a.panels.git_workflow.error_text != null);
    try testing.expect(!h.t.hasText("private remote error must not appear"));
    try testing.expect(!flow.canAct(&h.a));
    const failed_calls = h.a.engine.sent.items.len;
    h.t.settle(3);
    flow.arm(&h.a, .push);
    try testing.expectEqual(failed_calls, h.a.engine.sent.items.len); // No retry/poll.
    flow.load(&h.a);
    try deliver(&h,
        \\{"checkoutId":"checkout-demo","checksum":"snapshot-4","files":[],"blockedReason":"Resolve merge conflicts first."}
    );
    h.t.settle(0.1);
    try testing.expect(!flow.canAct(&h.a));
    try testing.expect(!flow.canPush(&h.a));
}

test "native git workflow resets drafts confirmations and late replies on checkout change and close" {
    var h: Harness = undefined;
    try setup(&h, true);
    defer h.deinit();
    try load(&h);
    h.a.panels.git_workflow.message.set("Must not cross chats");
    flow.arm(&h.a, .push);
    h.a.openChatInTab("b");
    try testing.expectEqualStrings("", h.a.panels.git_workflow.message.text());
    try testing.expect(h.a.panels.git_workflow.confirm == null);
    flow.show(&h.a);
    const old = h.a.panels.git_workflow.pending.?;
    var req = try lastRequest(&h);
    defer req.deinit();
    try testing.expectEqualStrings("remote", req.value.object.get("params").?.object.get("targetDeviceId").?.string);
    const replacement = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"b","deviceId":"remote","title":"Another checkout","cwd":"/synthetic/another","branch":"other","archived":false}]
    , .{});
    defer replacement.deinit();
    try h.a.chats.replace(replacement.value);
    panels.chatsArrived(&h.a);
    try testing.expect(h.a.panels.git_workflow.pending.? != old);
    const stale = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"ok\":{s}}}", .{ old, initial });
    defer testing.allocator.free(stale);
    try h.a.engine.mux.dispatch(stale);
    try testing.expect(h.a.panels.git_workflow.snapshot == null);
    const active = h.a.panels.git_workflow.pending.?;
    panels.closeTab(&h.a, h.a.panels.active);
    try testing.expect(!h.a.engine.mux.pending.contains(active));
    try testing.expect(h.a.panels.git_workflow.target == null);
    try testing.expect(h.a.panels.git_workflow.snapshot == null);
}
