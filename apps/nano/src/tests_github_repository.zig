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
fn textRect(h: *Harness, text: []const u8) ?@import("nanoui").ui.Rect {
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, text)) return node.rect,
        else => {},
    };
    return null;
}

fn topTextRect(h: *Harness, text: []const u8) ?@import("nanoui").ui.Rect {
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, text) and node.rect.y < 42 and node.rect.x >= h.a.view.sidebar_width) return node.rect,
        else => {},
    };
    return null;
}

test "github child stays beside its originating split and retains repository on other chat focus" {
    var h: Harness = undefined;
    try setup(&h, true, &.{pulls});
    defer h.deinit();
    // Alpha is the first pane, Beta the second; GitHub belongs to Alpha.
    h.a.splitPane(.horizontal);
    h.a.openChat("b", null);
    h.a.focusPane(0);
    git.open(&h.a, .github);
    h.t.settle(1);
    try h.t.clickText("Repository");
    h.t.settle(1);
    try screenshot(&h, "child-placement");
    const github = textRect(&h, "demo/fieldnotes") orelse return error.NoRepositoryTitle;
    const beta = topTextRect(&h, "Remote work") orelse return error.NoNeighborTitle;
    try testing.expect(github.x < beta.x);
    try testing.expect(h.t.hasText("Split from Navigation polish"));
    const calls = try githubCalls(&h);
    h.a.focusPane(1);
    h.t.settle(0.2);
    try testing.expect(h.t.hasText("demo/fieldnotes"));
    try testing.expectEqual(calls, try githubCalls(&h));
    h.a.panels.host_open = false;
    h.a.panels.host_open = true;
    panels.showTab(&h.a, h.a.panels.active);
    h.t.settle(0.2);
    try testing.expect(h.t.hasText("Split from Navigation polish"));
    try testing.expect(h.t.hasText("demo/fieldnotes"));
}

test "github child vertical layout bounds the child to its parent row and hides it in another workspace" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try setup(&h, dark, &.{pulls});
        defer h.deinit();
        h.a.splitPane(.vertical);
        h.a.openChat("b", null);
        h.a.focusPane(0);
        git.open(&h.a, .github);
        h.t.settle(1);
        try h.t.clickText("Repository");
        h.t.settle(0.2);
        const parent = topTextRect(&h, "Navigation polish") orelse return error.MissingParentTab;
        const child = topTextRect(&h, "GitHub") orelse return error.MissingChildTab;
        const sibling = topTextRect(&h, "Remote work") orelse return error.MissingSiblingTab;
        try testing.expect(parent.x < child.x and child.x < sibling.x);
        const title = textRect(&h, "demo/fieldnotes") orelse return error.NoRepositoryTitle;
        try testing.expect(title.x > h.a.view.chrome.x + h.a.view.chrome.chat_width);
        var bounded = false;
        for (h.t.ctx.nodes.items) |node| {
            if (node.style.radius == 10 and node.rect.x > h.a.view.chrome.x + h.a.view.chrome.chat_width and node.rect.y < 50) {
                bounded = node.rect.h < h.a.view.chrome.height * 0.6;
                if (bounded) break;
            }
        }
        try testing.expect(bounded);
        try screenshot(&h, if (dark) "child-vertical-dark" else "child-vertical-light");
        const calls = try githubCalls(&h);
        h.a.newTab();
        h.t.settle(0.2);
        try testing.expect(!@import("view_tab_strip.zig").hasHost(&h.a));
        try testing.expect(!h.t.hasText("Split from Navigation polish"));
        h.a.showTab(0);
        h.t.settle(0.2);
        try testing.expect(h.t.hasText("demo/fieldnotes"));
        try testing.expectEqual(calls, try githubCalls(&h));
        h.a.focusPane(0);
        h.a.closePanel();
        h.t.settle(0.2);
        try testing.expect(!@import("view_tab_strip.zig").hasHost(&h.a));
        h.a.openChatInTab("a");
        h.t.settle(0.2);
        try testing.expect(h.t.hasText("demo/fieldnotes"));
        try testing.expectEqualStrings("a", h.a.panels.github_repository.owner.?);
        try testing.expectEqual(calls, try githubCalls(&h));
    }
}

test "github child description and activity images open a bounded preview without navigating away" {
    var picture_detail = detail;
    picture_detail.detail.?.body = "![Synthetic image](https://raw.githubusercontent.com/demo/repo/media/image.png)";
    var picture_activity = activity;
    picture_activity.events = &.{.{ .id = "image-event", .event = "commented", .author = "demo-reviewer", .createdAt = "2026-11-13", .body = picture_detail.detail.?.body }};
    var h: Harness = undefined;
    try setup(&h, true, &.{ pulls, picture_detail, picture_activity });
    defer h.deinit();
    try h.t.clickText("Repository");
    try h.t.clickText("Polish repository navigation");
    try h.a.panels.github_repository.images.seed("https://raw.githubusercontent.com/demo/repo/media/image.png", @embedFile("testdata/github-preview.png"));
    for (0..2) |i| {
        if (i == 1) try h.t.clickText("Activity");
        h.t.settle(0.2);
        try screenshot(&h, if (i == 0) "image-inline" else "image-activity");
        const calls = h.a.engine.sent.items.len;
        if (i == 0) {
            const image = for (h.t.ctx.nodes.items) |node| {
                if (node.content == .image and node.rect.w > 100 and node.rect.h > 100 and node.rect.x > h.a.view.chrome.x + h.a.view.chrome.chat_width) break node.rect;
            } else return error.NoInlineImage;
            h.t.click(image.x + image.w / 2, image.y + image.h / 2);
        } else try h.t.clickText("Preview image");
        h.t.settle(0.2);
        try testing.expect(h.t.hasText("GitHub image preview"));
        try h.t.clickText("Zoom in");
        try testing.expect(h.a.panels.github_repository.images.zoom > 1);
        h.a.view.strip.focused = .{ .chat = 0 };
        try testing.expect(!@import("github_images.zig").keys(&h.t.ctx, &h.a));
        h.a.view.strip.focused = .host;
        const preview_title = textRect(&h, "GitHub image preview").?;
        try testing.expect(preview_title.x > h.a.view.chrome.x + h.a.view.chrome.chat_width);
        try screenshot(&h, "image-preview");
        if (i == 0) try h.t.clickText("Close preview") else _ = h.t.shortcut(.{ .key = @import("nanoui").ui.Shortcut.escape });
        h.t.settle(0.2);
        try testing.expect(!h.t.hasText("GitHub image preview"));
        try testing.expectEqual(calls, h.a.engine.sent.items.len);
        try testing.expectEqual(if (i == 0) flow.Kind.pull else flow.Kind.activity, h.a.panels.github_repository.kind);
    }
}

fn githubCalls(h: *Harness) !usize {
    var count: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.object.get("method").?.string, "BrowseCheckoutGitHub")) count += 1;
    }
    return count;
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
    // Focus alone no longer reparents GitHub. An explicit open does.
    try testing.expectEqual(old, h.a.panels.github_repository.pending.?);
    git.open(&h.a, .github);
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

test "repository github presentation renders descriptions as native Markdown" {
    for ([_]bool{ false, true }) |dark| {
        var rich = detail;
        var description = detail.detail.?;
        description.body = "## Readable description\n\nReview **native formatting** without raw Markdown markers.\n\n- Preserve keyboard focus\n- Keep checkout files unchanged\n\n> A synthetic review note.\n\n```zig\nconst ready = true;\n```\n\n| Check | Result |\n| --- | --- |\n| Native UI | Passed |";
        rich.detail = description;
        var h: Harness = undefined;
        try setup(&h, dark, &.{ pulls, rich });
        defer h.deinit();
        try h.t.clickText("Repository");
        try h.t.clickText("Polish repository navigation");
        h.t.settle(0.1);
        try screenshot(&h, if (dark) "formatted-summary-dark" else "formatted-summary-light");
        try testing.expect(h.t.hasText("Readable description"));
        try testing.expect(!h.t.hasText(description.body));
        try testing.expect(h.t.hasText("Description"));
        h.t.resize(760, 780);
        h.t.settle(0.2);
        for ([_][]const u8{ description.title, "Readable description", "Description" }) |label| {
            const rect = h.t.findText(label) orelse return error.MissingNarrowDescription;
            try testing.expect(rect.x >= 0 and rect.x + rect.w <= h.t.size.w);
        }
        try screenshot(&h, if (dark) "formatted-summary-narrow-dark" else "formatted-summary-narrow-light");
    }
}

test "repository github list rows keep long titles and metadata inside the card" {
    var long = pulls;
    var entries = [_]flow.Item{pulls.items[0]};
    entries[0].title = "A long synthetic pull request title that wraps across several lines in a narrow repository panel without losing its author or update metadata";
    long.items = &entries;
    var h: Harness = undefined;
    try setup(&h, false, &.{long});
    defer h.deinit();
    try h.t.clickText("Repository");
    h.t.resize(760, 780);
    h.t.settle(0.2);
    const title = h.t.findText(entries[0].title) orelse return error.MissingLongTitle;
    const author = h.t.findText("demo-author · updated 2026-11-13") orelse return error.MissingAuthor;
    try testing.expect(author.y >= title.y + title.h);
    const card = for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (node.interactive and node.style.radius == 8 and r.x <= title.x and r.y <= title.y and r.x + r.w >= title.x + title.w) break r;
    } else return error.MissingRepositoryCard;
    try testing.expect(author.y + author.h < card.y + card.h);
    try screenshot(&h, "repository-long-title-narrow");
}

test "repository github surface plus opens the surface picker instead of a chat tab" {
    var h: Harness = undefined;
    try setup(&h, false, &.{pulls});
    defer h.deinit();
    const tabs_before = h.a.tabs.items.items.len;
    const title = topTextRect(&h, "GitHub") orelse return error.MissingGitHubTab;
    h.t.moveTo(title.x + title.w / 2, title.y + title.h / 2);
    h.t.settle(0.1);
    var plus: ?@import("nanoui").ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (node.interactive and r.y < 38 and r.x > title.x + title.w and r.w == 18 and r.h == 18) {
            if (plus == null or r.x < plus.?.x) plus = r;
        }
    }
    const target = plus orelse return error.MissingSurfacePlus;
    h.t.click(target.x + target.w / 2, target.y + target.h / 2);
    h.t.settle(0.1);
    try testing.expectEqual(tabs_before, h.a.tabs.items.items.len);
    try testing.expect(h.t.hasText("Git history"));
    try testing.expect(h.t.hasText("Browser"));
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "repository github session empty state does not invent an authentication failure" {
    var h: Harness = undefined;
    try setup(&h, false, &.{pulls});
    defer h.deinit();
    try testing.expect(h.t.hasText("No session-linked pull requests"));
    try testing.expect(!h.t.hasText("No session pull request is available. The host needs gh installed and signed in to GitHub."));
    try h.t.clickText("Repository");
    try testing.expect(h.t.hasText("Polish repository navigation"));
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
