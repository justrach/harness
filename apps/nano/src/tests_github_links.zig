//! Transcript GitHub links use the native, read-only repository panel.
//! All chats, checkout identities, engine replies and destinations are synthetic.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const browser = @import("app_browser.zig");
const flow = @import("app_github_repository.zig");
const panels = @import("app_panels.zig");
const links = @import("github_link.zig");

const pull_url = "https://github.com/demo/other/pull/42";
const issue_url = "https://github.com/demo/other/issues/51";
const repository: flow.Repository = .{
    .key = "github.com/demo/other",
    .host = "github.com",
    .owner = "demo",
    .name = "other",
    .url = "https://github.com/demo/other",
};
const pull: flow.Page = .{ .repository = repository, .kind = .pull, .detail = .{
    .number = 42,
    .title = "A closed pull outside the checkout repository",
    .url = pull_url,
    .state = "closed",
    .author = "demo-author",
    .createdAt = "2026-11-12",
    .updatedAt = "2026-11-13",
    .body = "Synthetic linked repository description.",
    .headRef = "feature/synthetic",
    .baseRef = "main",
} };
const issue: flow.Page = .{ .repository = repository, .kind = .issue, .detail = .{
    .number = 51,
    .title = "A linked issue outside the checkout repository",
    .url = issue_url,
    .state = "closed",
    .author = "demo-author",
    .createdAt = "2026-11-12",
    .updatedAt = "2026-11-13",
    .body = "Synthetic issue description.",
} };
const pulls: flow.Page = .{ .repository = repository, .kind = .pulls };
const files: flow.Page = .{ .repository = repository, .kind = .files, .files = &.{
    .{ .filename = "src/synthetic.zig", .status = "modified", .additions = 1, .deletions = 0, .patch = "@@ -0,0 +1 @@\n+const synthetic = true;" },
} };
const activity: flow.Page = .{ .repository = repository, .kind = .activity, .events = &.{
    .{ .id = "synthetic-event", .event = "commented", .author = "demo-reviewer", .createdAt = "2026-11-13", .body = "Synthetic linked review activity." },
} };

const Opener = struct {
    var count: usize = 0;
    fn open(url: []const u8) bool {
        testing.expectEqualStrings(pull_url, url) catch return false;
        count += 1;
        return true;
    }
};

fn setup(h: *Harness, pages: []const flow.Page) !void {
    try h.init(true);
    const data = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"a","deviceId":"local","title":"Synthetic source","spaceId":"local-project","cwd":"/synthetic/root","branch":"main","sourceContext":{"cwd":"/synthetic/root","branch":"main"},"archived":false},
        \\ {"id":"b","deviceId":"remote","title":"Synthetic peer","spaceId":"remote-project","cwd":"/synthetic/peer","branch":"main","archived":false}]
    , .{});
    defer data.deinit();
    try h.a.chats.replace(data.value);
    const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{ .BrowseCheckoutGitHub = .{ .@"$seq" = pages } }, .{});
    defer testing.allocator.free(scene);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
    h.a.engine.state = .connected;
    h.a.settings.set(.transcript_compact_mode, false);
    const transcript = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"text","kind":"text","text":"[Native pull](https://github.com/demo/other/pull/42)\n\n[Native issue](https://github.com/demo/other/issues/51)"}]}]}
    , .{});
    defer transcript.deinit();
    try h.a.transcript.apply(transcript.value);
    h.t.settle(0.2);
}

fn clickPull(h: *Harness, right: bool) !void {
    const rect = h.t.findText("Native pull") orelse return error.MissingMarkdownPullLink;
    // A rich-text node spans the column; target its link glyphs, not whitespace.
    if (right) h.t.rightClick(rect.x + 8, rect.y + rect.h / 2) else h.t.click(rect.x + 8, rect.y + rect.h / 2);
    h.t.settle(0.2);
}

fn nativeOnly(h: *Harness) !void {
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    try testing.expectEqual(panels.TabKind.github, h.a.panels.tabs.items[0].kind);
    try testing.expect(h.a.panels.tabs.items[0].browser == null);
    try testing.expect(h.a.panels.pending_browser == null);
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqual(@as(usize, 0), Opener.count);
    try testing.expectEqualStrings("a", h.a.selected.?);
    const source = h.a.findChat("a").?;
    try testing.expectEqualStrings("/synthetic/root", source.cwd.?);
    try testing.expectEqualStrings("main", source.branch.?);
    try testing.expectEqualStrings("local-project", source.space_id.?);
    try testing.expectEqualStrings("local", source.device_id.?);
}

fn request(h: *Harness, kind: []const u8, number: ?i64) !void {
    var found = false;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const method = parsed.value.object.get("method").?.string;
        try testing.expect(!std.mem.eql(u8, method, "ApplyCheckoutGitAction"));
        try testing.expect(!std.mem.eql(u8, method, "MergeChangeRequest"));
        try testing.expect(!std.mem.eql(u8, method, "CreateChangeRequest"));
        if (!std.mem.eql(u8, method, "BrowseCheckoutGitHub")) continue;
        const p = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("a", p.get("chatId").?.string);
        try testing.expectEqualStrings("github.com/demo/other", p.get("expectedRepository").?.string);
        const linked = p.get("linkedRepository").?.object;
        try testing.expectEqualStrings("demo", linked.get("owner").?.string);
        try testing.expectEqualStrings("other", linked.get("name").?.string);
        try testing.expectEqual(@as(usize, 2), linked.count());
        for ([_][]const u8{ "url", "cwd", "endpoint", "targetDeviceId" }) |field| try testing.expect(p.get(field) == null);
        if (std.mem.eql(u8, kind, p.get("kind").?.string)) {
            if (number) |n| try testing.expectEqual(n, p.get("number").?.integer);
            found = true;
        }
    }
    try testing.expect(found);
}

fn githubCalls(h: *Harness) !usize {
    var count: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, "BrowseCheckoutGitHub", parsed.value.object.get("method").?.string)) count += 1;
    }
    return count;
}

test "github links default real Markdown click opens another repository closed PR natively without a list or OS browser" {
    const saved = browser.open_external_url;
    browser.open_external_url = Opener.open;
    defer browser.open_external_url = saved;
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{pull});
    defer h.deinit();
    try testing.expect(h.a.settings.get(.open_github_links_in_harness));
    try clickPull(&h, false);
    try nativeOnly(&h);
    try testing.expect(h.t.hasText(pull.detail.?.title));
    try testing.expect(h.t.hasText("#42 · closed"));
    try testing.expect(h.t.hasText("Summary"));
    try testing.expect(h.t.hasText("Code"));
    try testing.expect(h.t.hasText("Activity"));
    if (std.c.getenv("NANO_GITHUB_LINK_SNAP_DIR")) |path| {
        var buf: [1024]u8 = undefined;
        try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/native-transcript-link.png", .{std.mem.span(path)}));
    }
    try testing.expect(h.a.panels.github_repository.list == null);
    try request(&h, "pull", 42);
    try testing.expectEqual(@as(usize, 1), try githubCalls(&h));
    const idle = h.a.engine.sent.items.len;
    h.t.settle(2);
    try testing.expectEqual(idle, h.a.engine.sent.items.len);
}

test "github links preference explicitly on keeps transcript clicks native" {
    const saved = browser.open_external_url;
    browser.open_external_url = Opener.open;
    defer browser.open_external_url = saved;
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{pull});
    defer h.deinit();
    h.a.settings.set(.open_github_links_in_harness, true);
    try clickPull(&h, false);
    try nativeOnly(&h);
    try request(&h, "pull", 42);
}

test "github links preference off opens transcript clicks externally even offscreen" {
    const saved = browser.open_external_url;
    browser.open_external_url = Opener.open;
    defer browser.open_external_url = saved;
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{pull});
    defer h.deinit();
    h.a.settings.set(.open_github_links_in_harness, false);
    h.a.offscreen = true;
    try clickPull(&h, false);
    try testing.expectEqual(@as(usize, 1), Opener.count);
    try testing.expect(h.a.panels.pending_browser == null);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), try githubCalls(&h));
}

test "github links explicit internal action overrides preference off" {
    const saved = browser.open_external_url;
    browser.open_external_url = Opener.open;
    defer browser.open_external_url = saved;
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{pull});
    defer h.deinit();
    h.a.settings.set(.open_github_links_in_harness, false);
    try clickPull(&h, true);
    try h.t.clickText("Open in Harness");
    h.t.settle(0.2);
    try nativeOnly(&h);
    try request(&h, "pull", 42);
}

test "github links second transcript click reuses the native panel for an issue" {
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{ pull, issue });
    defer h.deinit();
    try clickPull(&h, false);
    try nativeOnly(&h);
    h.a.panels.host_open = false;
    h.t.settle(0.1);
    const rect = h.t.findText("Native issue") orelse return error.MissingMarkdownIssueLink;
    h.t.click(rect.x + 8, rect.y + rect.h / 2);
    h.t.settle(0.2);
    try nativeOnly(&h);
    try request(&h, "issue", 51);
    try testing.expect(h.t.hasText(issue.detail.?.title));
    try testing.expect(h.t.hasText("Back to issues"));
    try testing.expect(!h.t.hasText("Code"));
}

test "github child linked PR keeps its item and originating split after neighboring chat focus" {
    var h: Harness = undefined;
    try setup(&h, &.{pull});
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("b", null);
    h.a.focusPane(0);
    flow.openLinked(&h.a, links.parse(pull_url).?);
    h.t.settle(0.2);
    try testing.expect(h.t.hasText(pull.detail.?.title));
    const calls = try githubCalls(&h);
    h.a.focusPane(1);
    h.t.settle(0.2);
    try testing.expect(h.t.hasText(pull.detail.?.title));
    try testing.expectEqual(flow.Kind.pull, h.a.panels.github_repository.kind);
    try testing.expectEqualStrings("a", h.a.panels.github_repository.owner.?);
    try testing.expectEqual(calls, try githubCalls(&h));
    try h.t.clickText("Sessions");
    h.t.settle(0.2);
    try testing.expect(h.t.hasText("Split from Synthetic source"));
    try testing.expect(h.t.hasText("No session-linked pull requests"));
}

test "github links replacing pending detail cancels the old reply and reuses one native tab" {
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{ pull, issue });
    defer h.deinit();
    browser.openInternalLink(&h.a, "a", pull_url);
    browser.settleFrame(&h.a);
    const old = h.a.panels.github_repository.pending orelse return error.MissingPendingLinkedPull;
    browser.openInternalLink(&h.a, "a", issue_url);
    browser.settleFrame(&h.a);
    const fresh = h.a.panels.github_repository.pending orelse return error.MissingPendingLinkedIssue;
    try testing.expect(old != fresh);
    try testing.expect(!h.a.engine.mux.pending.contains(old));
    h.t.settle(0.2);
    try nativeOnly(&h);
    try testing.expect(h.t.hasText(issue.detail.?.title));
    try testing.expect(!h.t.hasText(pull.detail.?.title));
    try testing.expectEqual(flow.Kind.issue, h.a.panels.github_repository.kind);
}

test "github links detail failure Refresh retries detail and Back lazily loads the linked repository list" {
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{ pull, pull, pulls });
    defer h.deinit();
    flow.openLinked(&h.a, links.parse(pull_url).?);
    const id = h.a.panels.github_repository.pending.?;
    const failure = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"err\":\"Synthetic detail failure\"}}", .{id});
    defer testing.allocator.free(failure);
    try h.a.engine.mux.dispatch(failure);
    h.t.settle(0.1);
    try testing.expect(h.a.panels.github_repository.error_text != null);
    try testing.expect(!h.t.hasText("Synthetic detail failure"));
    try testing.expect(h.t.containsText("GitHub is unavailable"));
    try testing.expect(h.a.panels.github_repository.list == null);
    try h.t.clickText("Refresh");
    h.t.settle(0.1);
    try testing.expect(h.t.hasText(pull.detail.?.title));
    try testing.expectEqual(flow.Kind.pull, h.a.panels.github_repository.kind);
    try testing.expect(h.a.panels.github_repository.list == null);
    try testing.expectEqual(@as(usize, 2), try githubCalls(&h));
    try h.t.clickText("Back to PRs");
    h.t.settle(0.1);
    try request(&h, "pulls", null);
    try testing.expect(h.t.hasText("No matching items"));
    try testing.expectEqual(@as(usize, 3), try githubCalls(&h));
    try nativeOnly(&h);
}

test "github links code deep link loads detail before files and native sections remain read only" {
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{ pull, files, activity });
    defer h.deinit();
    browser.openInternalLink(&h.a, "a", pull_url ++ "/files");
    browser.settleFrame(&h.a);
    try testing.expectEqual(flow.Kind.pull, h.a.panels.github_repository.kind);
    try testing.expectEqual(@as(usize, 1), try githubCalls(&h));
    // Detail and files are two asynchronous replies on consecutive frames.
    h.t.advance(0.2);
    try nativeOnly(&h);
    try testing.expectEqual(flow.Kind.files, h.a.panels.github_repository.kind);
    try testing.expect(h.a.panels.github_repository.pending == null);
    try testing.expect(h.a.panels.github_repository.content != null);
    try testing.expect(h.t.hasText("src/synthetic.zig"));
    try request(&h, "files", 42);
    try h.t.clickText("Activity");
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Synthetic linked review activity."));
    try request(&h, "activity", 42);
    try nativeOnly(&h);
}

test "github links pending navigation is discarded after a source chat pane or visibility change" {
    for (0..3) |change| {
        var h: Harness = undefined;
        try setup(&h, &.{pull});
        defer h.deinit();
        browser.openInternalLink(&h.a, "a", pull_url);
        try testing.expect(h.a.panels.pending_browser != null);
        switch (change) {
            0 => h.a.openChat("b", null),
            1 => {
                h.a.splitPane(.horizontal);
                h.a.tabs.layout().?.zoomed = true; // The source pane is no longer visible.
            },
            2 => h.a.view.settings_open = true,
            else => unreachable,
        }
        browser.settleFrame(&h.a);
        try testing.expect(h.a.panels.pending_browser == null);
        try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
        try testing.expectEqual(@as(usize, 0), try githubCalls(&h));
    }
}

test "github links hidden transcript cannot enqueue navigation and explicit browser action remains external" {
    const saved = browser.open_external_url;
    browser.open_external_url = Opener.open;
    defer browser.open_external_url = saved;
    Opener.count = 0;
    var h: Harness = undefined;
    try setup(&h, &.{pull});
    defer h.deinit();
    try clickPull(&h, true);
    try h.t.clickText("Open in browser");
    h.t.settle(0.1);
    try testing.expectEqual(@as(usize, 1), Opener.count);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), try githubCalls(&h));
    h.a.view.settings_open = true;
    browser.openLink(&h.a, "a", pull_url);
    browser.openInternalLink(&h.a, "a", pull_url);
    browser.openExternalLink(&h.a, "a", pull_url);
    browser.settleFrame(&h.a);
    try testing.expect(h.a.panels.pending_browser == null);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), Opener.count);
    try testing.expectEqual(@as(usize, 0), try githubCalls(&h));
}
