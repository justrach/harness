//! Repository browser regressions over synthetic native views and RPC frames.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const git = @import("app_git.zig");
const flow = @import("app_github_repository.zig");
const panels = @import("app_panels.zig");
const repo: flow.Repository = .{ .key = "repo-demo", .host = "github.com", .owner = "demo", .name = "fieldnotes", .url = "https://github.com/demo/fieldnotes" };
const pulls: flow.Page = .{ .repository = repo, .kind = .pulls, .hasNextPage = true, .items = &.{
    .{ .number = 42, .title = "Polish repository navigation", .url = "https://github.com/demo/fieldnotes/pull/42", .state = "open", .author = "demo-author", .updatedAt = "2026-11-13T10:00:00Z" },
} };
const pulls2: flow.Page = .{ .repository = repo, .kind = .pulls, .page = 2, .items = &.{
    .{ .number = 44, .title = "Improve repository search", .url = "https://github.com/demo/fieldnotes/pull/44", .state = "open", .isDraft = true, .author = "demo-reviewer", .updatedAt = "2026-11-12" },
} };
const closed: flow.Page = .{ .repository = repo, .kind = .pulls, .items = &.{
    .{ .number = 48, .title = "Closed synthetic pull request", .url = "https://github.com/demo/fieldnotes/pull/48", .state = "closed", .author = "demo-author", .updatedAt = "2026-11-10" },
} };
const issues: flow.Page = .{ .repository = repo, .kind = .issues, .items = &.{
    .{ .number = 51, .title = "Track keyboard navigation", .url = "https://github.com/demo/fieldnotes/issues/51", .state = "open", .author = "demo-reviewer", .updatedAt = "2026-11-13" },
} };
const detail: flow.Page = .{ .repository = repo, .kind = .pull, .detail = .{
    .number = 42,
    .title = "Polish repository navigation",
    .url = "https://github.com/demo/fieldnotes/pull/42",
    .state = "open",
    .author = "demo-author",
    .createdAt = "2026-11-12",
    .updatedAt = "2026-11-13",
    .body = "Make repository navigation clearer.\n\nSynthetic acceptance criteria:\n- Keep keyboard focus stable.\n- Preserve existing checkout files.\n- Cover navigation with native tests.",
    .headRef = "feature/navigation",
    .baseRef = "main",
    .additions = 18,
    .deletions = 4,
    .changedFiles = 2,
} };
const files: flow.Page = .{ .repository = repo, .kind = .files, .files = &.{
    .{ .filename = "src/navigation.zig", .status = "modified", .additions = 18, .deletions = 4, .patch = "@@ -1,2 +1,3 @@\n-pub const label = \"Old navigation\";\n+pub const label = \"Repository navigation\";\n+pub const keyboard_focus = true;" },
    .{ .filename = "assets/navigation.png", .status = "modified", .additions = 0, .deletions = 0, .patchTruncated = true },
} };
const activity: flow.Page = .{ .repository = repo, .kind = .activity, .hasNextPage = true, .events = &.{
    .{ .id = "event-1", .event = "commented", .author = "demo-reviewer", .createdAt = "2026-11-12", .body = "Please preserve keyboard focus when opening repository items." },
    .{ .id = "event-2", .event = "reviewed", .author = "demo-maintainer", .createdAt = "2026-11-13", .body = "The native flow looks good. Thanks for adding regression coverage." },
} };
const issue_detail: flow.Page = .{ .repository = repo, .kind = .issue, .detail = .{
    .number = 51,
    .title = "Track keyboard navigation",
    .url = "https://github.com/demo/fieldnotes/issues/51",
    .state = "open",
    .author = "demo-reviewer",
    .createdAt = "2026-11-11",
    .updatedAt = "2026-11-13",
    .body = "Synthetic repository issue details—not linked to a session.",
} };
fn setup(h: *Harness, dark: bool, pages: []const flow.Page) !void {
    try h.init(dark);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"a","deviceId":"local","title":"Navigation polish","spaceId":"local-project","cwd":"/synthetic/fieldnotes","branch":"feature/navigation","archived":false},
        \\ {"id":"b","deviceId":"remote","title":"Remote work","spaceId":"remote-project","cwd":"/synthetic/remote","branch":"feature/remote","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{ .BrowseCheckoutGitHub = .{ .@"$seq" = pages } }, .{});
    defer testing.allocator.free(scene);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
    h.a.engine.state = .connected;
    git.open(&h.a, .github);
    h.t.settle(0.1);
}
fn request(h: *Harness) !std.json.Parsed(std.json.Value) {
    var i = h.a.engine.sent.items.len;
    while (i > 0) {
        i -= 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, h.a.engine.sent.items[i], .{});
        if (std.mem.eql(u8, parsed.value.object.get("method").?.string, "BrowseCheckoutGitHub")) return parsed;
        parsed.deinit();
    }
    return error.NoGitHubRequest;
}
fn screenshot(h: *Harness, name: []const u8) !void {
    const raw = std.c.getenv("NANO_GITHUB_REPO_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(raw), name });
    try h.t.screenshot(path);
}

test "repository github browser lists all repository PRs pages filters and issues without polling" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try setup(&h, dark, &.{ pulls, pulls2, pulls, closed, issues });
        defer h.deinit();
        try testing.expect(h.a.panels.github_repository.list == null);
        try h.t.clickText("Repository");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("demo/fieldnotes"));
        try testing.expect(h.t.hasText("Repository-wide"));
        try testing.expect(h.t.hasText("Polish repository navigation"));
        // No session PR was injected: rows really come from repository results.
        try screenshot(&h, if (dark) "repository-dark" else "repository-light");
        const idle_calls = h.a.engine.sent.items.len;
        h.t.settle(3);
        try testing.expectEqual(idle_calls, h.a.engine.sent.items.len);
        try h.t.clickText("Next");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("Improve repository search"));
        var req = try request(&h);
        defer req.deinit();
        const p = req.value.object.get("params").?.object;
        try testing.expectEqual(@as(i64, 2), p.get("page").?.integer);
        try testing.expectEqualStrings("repo-demo", p.get("expectedRepository").?.string);
        try testing.expect(p.get("targetDeviceId") == null);
        try h.t.clickText("Previous");
        try h.t.clickText("Closed");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("Closed synthetic pull request"));
        try h.t.clickText("Issues");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("Track keyboard navigation"));
        var issue_request = try request(&h);
        defer issue_request.deinit();
        try testing.expectEqualStrings("issues", issue_request.value.object.get("params").?.object.get("kind").?.string);
        for (h.a.engine.sent.items) |frame| {
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
            defer parsed.deinit();
            const method = parsed.value.object.get("method").?.string;
            try testing.expect(!std.mem.eql(u8, method, "MergeChangeRequest"));
            try testing.expect(!std.mem.eql(u8, method, "ApplyCheckoutGitAction"));
        }
    }
}

test "repository github browser inspects PR summary code and activity natively" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try setup(&h, dark, &.{ pulls, detail, files, activity });
        defer h.deinit();
        try h.t.clickText("Repository");
        try h.t.clickText("Polish repository navigation");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("feature/navigation → main"));
        try testing.expect(h.t.hasText("2 files · +18 / −4"));
        try screenshot(&h, if (dark) "summary-dark" else "summary-light");
        try h.t.clickText("Code");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("src/navigation.zig"));
        try testing.expect(!h.t.hasText(files.files[0].patch.?));
        try h.t.clickText("src/navigation.zig");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText(files.files[0].patch.?));
        try screenshot(&h, if (dark) "code-dark" else "code-light");
        try h.t.clickText("assets/navigation.png");
        h.t.settle(0.1);
        try testing.expect(!h.t.hasText(files.files[0].patch.?));
        try testing.expect(h.t.hasText("Patch incomplete; open on GitHub for the full diff."));
        try h.t.clickText("Activity");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("demo-reviewer · commented"));
        try testing.expect(h.t.hasText(activity.events[1].body.?));
        try screenshot(&h, if (dark) "activity-dark" else "activity-light");
        const calls = h.a.engine.sent.items.len;
        try h.t.clickText("Summary");
        try testing.expectEqual(calls, h.a.engine.sent.items.len);
        try h.t.clickText("Back to PRs");
        try testing.expectEqual(calls, h.a.engine.sent.items.len);
        try testing.expect(h.t.hasText("Pull requests"));
    }
}

test "repository github browser opens issue details with activity but no PR code controls" {
    var h: Harness = undefined;
    try setup(&h, true, &.{ pulls, issues, issue_detail, activity });
    defer h.deinit();
    try h.t.clickText("Repository");
    try h.t.clickText("Issues");
    try h.t.clickText("Track keyboard navigation");
    try testing.expect(h.t.hasText(issue_detail.detail.?.body));
    try testing.expect(!h.t.hasText("Code"));
    try h.t.clickText("Activity");
    try testing.expect(h.t.hasText("demo-reviewer · commented"));
}

test "repository github browser resets context and ignores late host replies after close" {
    var h: Harness = undefined;
    try setup(&h, true, &.{pulls});
    defer h.deinit();
    flow.show(&h.a);
    const old = h.a.panels.github_repository.pending.?;
    h.a.openChatInTab("b");
    flow.show(&h.a);
    const fresh = h.a.panels.github_repository.pending.?;
    try testing.expect(old != fresh);
    var req = try request(&h);
    defer req.deinit();
    const p = req.value.object.get("params").?.object;
    try testing.expectEqualStrings("b", p.get("chatId").?.string);
    try testing.expectEqualStrings("remote", p.get("targetDeviceId").?.string);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, pulls, .{});
    defer testing.allocator.free(json);
    const stale = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"ok\":{s}}}", .{ old, json });
    defer testing.allocator.free(stale);
    try h.a.engine.mux.dispatch(stale);
    try testing.expect(h.a.panels.github_repository.list == null);
    try testing.expectEqual(fresh, h.a.panels.github_repository.pending.?);
    const replacement = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"b","deviceId":"remote","title":"Another checkout","cwd":"/synthetic/replaced","branch":"other","archived":false}]
    , .{});
    defer replacement.deinit();
    try h.a.chats.replace(replacement.value);
    panels.chatsArrived(&h.a);
    const replaced = h.a.panels.github_repository.pending.?;
    try testing.expect(replaced != fresh);
    try testing.expect(!h.a.engine.mux.pending.contains(fresh));
    panels.closeTab(&h.a, h.a.panels.active);
    try testing.expect(!h.a.engine.mux.pending.contains(replaced));
    try testing.expect(h.a.panels.github_repository.target == null);
}

test "repository github browser masks raw errors rejects changed repo replies and unsafe URLs" {
    var h: Harness = undefined;
    try setup(&h, true, &.{pulls});
    defer h.deinit();
    try h.t.clickText("Repository");
    flow.load(&h.a, .pulls, 2);
    const id = h.a.panels.github_repository.pending.?;
    const err = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"err\":\"private provider output\"}}", .{id});
    defer testing.allocator.free(err);
    try h.a.engine.mux.dispatch(err);
    h.t.settle(0.1);
    try testing.expect(h.a.panels.github_repository.error_text != null);
    try testing.expect(!h.t.hasText("private provider output"));
    flow.refresh(&h.a);
    _ = h.a.engine.pump();
    try testing.expect(h.a.panels.github_repository.error_text == null);
    flow.load(&h.a, .pulls, 2);
    var changed = pulls2;
    changed.repository.key = "another-repository";
    const changed_json = try std.json.Stringify.valueAlloc(testing.allocator, changed, .{});
    defer testing.allocator.free(changed_json);
    const changed_frame = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"ok\":{s}}}", .{ h.a.panels.github_repository.pending.?, changed_json });
    defer testing.allocator.free(changed_frame);
    try h.a.engine.mux.dispatch(changed_frame);
    try testing.expect(h.a.panels.github_repository.error_text != null);
    try testing.expectEqualStrings("repo-demo", h.a.panels.github_repository.repository().?.key);
    var unsafe = repo;
    unsafe.owner = "../escape";
    try testing.expectError(error.InvalidGitHubURL, flow.itemUrl(testing.allocator, unsafe, 42, true));
    unsafe = repo;
    unsafe.host = "untrusted.invalid";
    try testing.expectError(error.InvalidGitHubURL, flow.itemUrl(testing.allocator, unsafe, 42, true));
    const url = try flow.itemUrl(testing.allocator, repo, 42, true);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://github.com/demo/fieldnotes/pull/42", url);
}
