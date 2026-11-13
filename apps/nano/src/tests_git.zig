//! Real native views and engine frames, with synthetic checkout identities.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const git = @import("app_git.zig");
const panels = @import("app_panels.zig");
const views = @import("view_git.zig");
const chats =
    \\[{"id":"a","deviceId":"local","title":"Navigation polish","spaceId":"local-project","cwd":"/synthetic/fieldnotes","branch":"feature/navigation","archived":false,"sourceContext":{"checkoutId":"co-a","repoRoot":"/synthetic/fieldnotes","cwd":"/synthetic/fieldnotes","branch":"feature/navigation"}},
    \\ {"id":"b","deviceId":"remote","title":"Remote work","spaceId":"remote-project","cwd":"/synthetic/remote-project","branch":"feature/remote","archived":false,"sourceContext":{"checkoutId":"co-b","repoRoot":"/synthetic/remote-project","cwd":"/synthetic/remote-project","branch":"feature/remote"}},
    \\ {"id":"peer","deviceId":"local","title":"Shared work","spaceId":"local-project","cwd":"/synthetic/fieldnotes","branch":"feature/navigation","archived":false,"sourceContext":{"checkoutId":"co-a","repoRoot":"/synthetic/fieldnotes","cwd":"/synthetic/fieldnotes","branch":"feature/navigation"}},
    \\ {"id":"worker","parentChatId":"a","deviceId":"local","title":"Internal worker","cwd":"/synthetic/worker","branch":"worker","archived":false,"sourceContext":{"checkoutId":"co-worker","repoRoot":"/synthetic/fieldnotes","cwd":"/synthetic/worker","branch":"worker"}}]
;
const reply =
    \\{"ListGitHistory":{"$seq":[
    \\ {"commits":[{"sha":"abc123456789","subject":"Polish project navigation","authorName":"Demo Developer","authorEmail":"demo@example.invalid","authoredAt":"2026-11-01T12:00:00Z","parentShas":["def456"],"refs":[{"kind":"branch","label":"feature/navigation"}]}],"headSha":"abc123456789","nextCursor":50,"comparison":{"base":"origin/main","ahead":2,"behind":1}},
    \\ {"commits":[{"sha":"def456789012","subject":"Add synthetic fixtures","authorName":"Demo Developer","authoredAt":"2026-10-31T12:00:00Z"}],"nextCursor":null},
    \\ {"$err":"synthetic failure"}]}}
;
fn setup(h: *Harness, dark: bool) !void {
    try h.init(dark);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
    defer parsed.deinit();
    try h.a.chats.replace(parsed.value);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    h.a.engine.state = .connected;
}
fn screenshot(h: *Harness, name: []const u8) !void {
    const raw = std.c.getenv("NANO_GIT_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(raw), name });
    try h.t.screenshot(path);
}
fn request(h: *Harness, method: []const u8) !std.json.Parsed(std.json.Value) {
    var i = h.a.engine.sent.items.len;
    while (i > 0) {
        i -= 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, h.a.engine.sent.items[i], .{});
        if (std.mem.eql(u8, parsed.value.object.get("method").?.string, method)) return parsed;
        parsed.deinit();
    }
    return error.NoRequest;
}

test "native git surface loads paged history routes hosts and never mutates a checkout" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try setup(&h, dark);
        defer h.deinit();
        h.t.settle(0.1);
        try screenshot(&h, if (dark) "before-dark" else "before-light");
        h.a.panels.host_open = true;
        h.a.panels.active = h.a.panels.tabs.items.len;
        h.t.settle(0.1);
        try h.t.clickText("Git history");
        h.t.settle(0.3);
        try testing.expect(h.t.hasText("Polish project navigation"));
        try testing.expect(h.t.hasText("HEAD"));
        try testing.expect(h.t.hasText("2 ahead · 1 behind origin/main (local refs)"));
        try screenshot(&h, if (dark) "git-dark" else "git-light");
        var local = try request(&h, "ListGitHistory");
        defer local.deinit();
        const params = local.value.object.get("params").?.object;
        try testing.expectEqualStrings("/synthetic/fieldnotes", params.get("cwd").?.string);
        try testing.expect(params.get("targetDeviceId") == null);
        try h.t.clickText("Next");
        h.t.settle(0.2);
        try testing.expect(h.t.hasText("Add synthetic fixtures"));
        try testing.expectEqual(@as(usize, 50), h.a.panels.history.cursor);
        const calls = h.a.engine.sent.items.len;
        h.t.settle(10);
        try testing.expectEqual(calls, h.a.engine.sent.items.len);
        // Switch before the next host frame arrives: no old checkout data.
        h.a.openChatInTab("b");
        h.t.settle(0.2);
        var remote = try request(&h, "ListGitHistory");
        defer remote.deinit();
        const routed = remote.value.object.get("params").?.object;
        try testing.expectEqualStrings("remote", routed.get("targetDeviceId").?.string);
        try testing.expectEqualStrings("/synthetic/remote-project", routed.get("cwd").?.string);
        try testing.expect(!h.t.hasText("Polish project navigation"));
        for (h.a.engine.sent.items) |frame| {
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
            defer parsed.deinit();
            const method = parsed.value.object.get("method").?.string;
            try testing.expect(!std.mem.eql(u8, method, "SwitchRef"));
            try testing.expect(!std.mem.eql(u8, method, "DiscardWorkingTree"));
            try testing.expect(!std.mem.eql(u8, method, "MergeChangeRequest"));
        }
    }
}

test "native git surface ignores late pages after navigation or same-chat checkout changes" {
    var h: Harness = undefined;
    try setup(&h, true);
    defer h.deinit();
    git.open(&h.a, .git);
    const old = h.a.panels.history.pending.?;
    h.a.openChatInTab("b");
    const new = h.a.panels.history.pending.?;
    try testing.expect(old != new);
    const stale = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"ok\":{{\"commits\":[]}}}}", .{old});
    defer testing.allocator.free(stale);
    try h.a.engine.mux.dispatch(stale);
    try testing.expectEqual(new, h.a.panels.history.pending.?);
    _ = h.a.engine.pump();
    try testing.expect(h.a.panels.history.pending == null);
    const replacement = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"b","deviceId":"remote","title":"New checkout","cwd":"/synthetic/another-checkout","branch":"other","archived":false}]
    , .{});
    defer replacement.deinit();
    try h.a.chats.replace(replacement.value);
    panels.chatsArrived(&h.a);
    try testing.expect(h.a.panels.history.snapshot == null);
    var changed = try request(&h, "ListGitHistory");
    defer changed.deinit();
    try testing.expectEqualStrings("/synthetic/another-checkout", changed.value.object.get("params").?.object.get("cwd").?.string);
}

test "native git surface explicit refresh recovers invalid pages without leaking provider output" {
    var h: Harness = undefined;
    try setup(&h, true);
    defer h.deinit();
    git.open(&h.a, .git);
    _ = h.a.engine.pump();
    git.load(&h.a, 0);
    const id = h.a.panels.history.pending.?;
    const frame = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"ok\":{{\"commits\":false}}}}", .{id});
    defer testing.allocator.free(frame);
    try h.a.engine.mux.dispatch(frame);
    try testing.expect(h.a.panels.history.error_text != null);
    try testing.expect(h.a.panels.history.snapshot != null);
    git.load(&h.a, 0);
    _ = h.a.engine.pump();
    try testing.expect(h.a.panels.history.error_text != null);
    try testing.expect(std.mem.indexOf(u8, h.a.panels.history.error_text.?, "synthetic failure") == null);
    try testing.expectEqual(@as(usize, 0), git.previousCursor(0));
    try testing.expectEqual(@as(usize, 50), git.previousCursor(100));
}

fn storePR(h: *Harness, id: []const u8, number: u64) !void {
    const chat = h.a.findChat(id).?;
    const src = chat.source.?;
    const key: @import("change_requests.zig").WatchKey = .{ .device_id = chat.device_id.?, .cwd = src.repo_root, .branch = src.branch, .checkout_id = src.checkout_id };
    const url = try std.fmt.allocPrint(testing.allocator, "https://example.invalid/demo/fieldnotes/pull/{d}", .{number});
    defer testing.allocator.free(url);
    try h.a.change_requests.client.store(key, .{
        .checkout_id = src.checkout_id,
        .device_id = key.device_id,
        .cwd = key.cwd,
        .branch = key.branch,
        .change_request = .{ .provider = "github", .number = number, .title = "Polish project navigation", .url = url, .state = .open, .base_ref = "main", .head_ref = src.branch },
    });
}

test "native git surface close cancels requests and releases its owned page" {
    var h: Harness = undefined;
    try setup(&h, true);
    defer h.deinit();
    git.open(&h.a, .git);
    const id = h.a.panels.history.pending.?;
    panels.closeTab(&h.a, h.a.panels.active);
    try testing.expect(!h.a.engine.mux.pending.contains(id));
    _ = h.a.engine.pump();
    try testing.expect(h.a.panels.history.snapshot == null);
    try testing.expect(h.a.panels.history.target == null);
    git.open(&h.a, .git);
    _ = h.a.engine.pump();
    try testing.expect(h.a.panels.history.snapshot != null);
    panels.closeTab(&h.a, h.a.panels.active);
    try testing.expect(h.a.panels.history.snapshot == null);
    try testing.expect(h.a.panels.history.target == null);
}

test "native github surface scopes and deduplicates session PRs and keeps merge explicit" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try setup(&h, dark);
        defer h.deinit();
        try storePR(&h, "a", 42);
        try storePR(&h, "b", 99);
        try storePR(&h, "worker", 100);
        const items = try views.sessionPullRequests(&h.a, testing.allocator);
        defer testing.allocator.free(items);
        try testing.expectEqual(@as(usize, 1), items.len);
        try testing.expectEqualStrings("a", items[0].chat_id);
        git.open(&h.a, .github);
        h.t.settle(0.2);
        try testing.expect(h.t.hasText("Session pull requests"));
        try testing.expect(h.t.hasText("Polish project navigation"));
        try testing.expect(h.t.hasText("Open on GitHub"));
        try testing.expect(h.a.change_requests.busy == null);
        try screenshot(&h, if (dark) "github-dark" else "github-light");
        h.a.openChatInTab("b");
        h.t.settle(0.1);
        try testing.expect(!h.t.hasText("#42"));
    }
}
