//! Direct, offscreen GitHub fixtures: dimensions here are the actual pane,
//! deliberately unrelated to the workspace's cached host width.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const flow = @import("app_github_repository.zig");
const github = @import("view_github_repository.zig");
const theme = @import("theme.zig");

const repo: flow.Repository = .{
    .key = "responsive-demo",
    .host = "github.com",
    .owner = "synthetic-navigation-team",
    .name = "a-repository-with-a-deliberately-long-name",
    .url = "https://github.com/synthetic-navigation-team/a-repository-with-a-deliberately-long-name",
};
const title = "Keep a deliberately long synthetic pull request title readable beside its conversation without clipping repository navigation, author metadata, or the pagination controls";
const author = "synthetic-review-team-navigation-bot";
const list_page: flow.Page = .{
    .repository = repo,
    .kind = .pulls,
    .page = 2,
    .hasNextPage = true,
    .items = &.{.{ .number = 42, .title = title, .url = "https://github.com/demo/project/pull/42", .state = "open", .author = author, .updatedAt = "2026-11-13" }},
};
const detail_page: flow.Page = .{
    .repository = repo,
    .kind = .pull,
    .detail = .{
        .number = 42,
        .title = title,
        .url = "https://github.com/demo/project/pull/42",
        .state = "open",
        .author = author,
        .createdAt = "2026-11-12",
        .updatedAt = "2026-11-13",
        .body = "A synthetic description that remains reachable by scrolling.",
        .headRef = "feature/synthetic-responsive-repository-controls-and-long-branch-name",
        .baseRef = "main",
        .changedFiles = 123456,
        .additions = 987654321,
        .deletions = 123456789,
    },
};

const Fixture = struct {
    a: App,
    t: ui.Tester,

    fn init(f: *Fixture, width: f32, height: f32, page: flow.Page) !void {
        theme.registerFonts();
        f.a = .init(testing.allocator, testing.io, 1);
        errdefer f.a.deinit();
        f.a.offscreen = true;
        f.a.dark = true;
        // A stale/wider host measurement must not affect this local pane.
        f.a.view.chrome.host_width = 1400;
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"responsive-chat","deviceId":"local","title":"Synthetic navigation","cwd":"/synthetic/responsive","branch":"main","archived":false} ]
        , .{});
        defer chats.deinit();
        try f.a.chats.replace(chats.value);
        f.a.openChat("responsive-chat", null);
        f.a.panels.github_repository.list = try snapshot(list_page);
        if (page.kind != .pulls) {
            f.a.panels.github_repository.details = try snapshot(detail_page);
            f.a.panels.github_repository.number = 42;
            if (page.kind != .pull) f.a.panels.github_repository.content = try snapshot(page);
        }
        f.a.panels.github_repository.kind = page.kind;
        var next = page;
        next.page = 3;
        next.hasNextPage = false;
        const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{ .BrowseCheckoutGitHub = .{ .@"$seq" = .{ next, page } } }, .{});
        defer testing.allocator.free(scene);
        f.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
        f.a.engine.state = .connected;
        try f.t.init(testing.allocator, .init(f, draw), .{ .width = width, .height = height, .dark = true });
        f.t.settle(0.1);
    }
    fn deinit(f: *Fixture) void {
        f.t.deinit();
        f.a.deinit();
    }
    fn draw(f: *Fixture, c: *ui.Context) void {
        _ = f.a.engine.pump();
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        github.view(c, &f.a, theme.colors(f.a.dark orelse true));
    }
    fn text(f: *Fixture, label: []const u8) !ui.Rect {
        return f.t.findText(label) orelse error.MissingResponsiveText;
    }
    fn inViewport(f: *Fixture, rect: ui.Rect) !void {
        try testing.expect(rect.w > 0 and rect.h > 0);
        try testing.expect(rect.x >= -0.5 and rect.x + rect.w <= f.t.size.w + 0.5);
        try testing.expect(rect.y >= -0.5 and rect.y + rect.h <= f.t.size.h + 0.5);
    }
    fn control(f: *Fixture, label: []const u8) !void {
        for (f.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
                const parent = f.t.ctx.node(node.parent);
                try testing.expect(parent.interactive);
                try f.inViewport(parent.rect);
                try f.inViewport(node.rect);
                return;
            },
            else => {},
        };
        return error.MissingResponsiveControl;
    }
    fn horizontalTextBounds(f: *Fixture) !void {
        for (f.t.ctx.nodes.items) |node| switch (node.content) {
            .text => {
                try testing.expect(node.rect.x >= -0.5);
                try testing.expect(node.rect.x + node.rect.w <= f.t.size.w + 0.5);
            },
            else => {},
        };
    }
    fn wraps(f: *Fixture, label: []const u8) !void {
        for (f.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
                try testing.expect(tx.lines.len > 1);
                return;
            },
            else => {},
        };
        return error.MissingWrappedText;
    }
};
fn snapshot(page: flow.Page) !flow.Snapshot {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, page, .{});
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return flow.Snapshot.parse(testing.allocator, parsed.value);
}

fn pagination(f: *Fixture) !void {
    try f.control("Previous");
    try f.control("Next");
    try f.inViewport(try f.text("Page 2"));
    try f.t.clickText("Next");
    f.t.settle(0.1);
    try testing.expectEqual(@as(usize, 3), f.a.panels.github_repository.current().?.page);
    try f.control("Previous");
    try f.inViewport(try f.text("Page 3"));
    try f.t.clickText("Previous");
    f.t.settle(0.1);
    try testing.expectEqual(@as(usize, 2), f.a.panels.github_repository.current().?.page);
}

test "github responsive list keeps headers filters wrapped titles and clickable pagination inside 280 360 520 panes" {
    for ([_]f32{ 280, 360, 520 }) |width| {
        var f: Fixture = undefined;
        try f.init(width, 620, list_page);
        defer f.deinit();
        for ([_][]const u8{ "Sessions", "Refresh", "Pull requests", "Issues", "Open", "Closed", "All" }) |label| try f.control(label);
        try f.horizontalTextBounds();
        try f.wraps(title);
        const title_rect = try f.text(title);
        const metadata = try f.text(author ++ " · updated 2026-11-13");
        try testing.expect(metadata.y >= title_rect.y + title_rect.h);
        try f.inViewport(metadata);
        try pagination(&f);
    }
}

test "github responsive detail wraps title branches metadata and retains narrow section controls" {
    for ([_]f32{ 280, 360, 520 }) |width| {
        var f: Fixture = undefined;
        try f.init(width, 760, detail_page);
        defer f.deinit();
        for ([_][]const u8{ "Sessions", "Refresh", "Back to PRs", "Open on GitHub", "Summary", "Code", "Activity" }) |label| try f.control(label);
        try f.horizontalTextBounds();
        try f.wraps(title);
        const title_rect = try f.text(title);
        const metadata = try f.text(author ++ " · opened 2026-11-12");
        try testing.expect(metadata.y >= title_rect.y + title_rect.h);
        try f.inViewport(metadata);
    }
}

test "github responsive file headers separate filename and counts without losing expansion or pagination" {
    const files_page: flow.Page = .{ .repository = repo, .kind = .files, .page = 2, .hasNextPage = true, .files = &.{.{ .filename = "src/navigation.zig", .status = "modified", .additions = 987654321, .deletions = 123456789 }} };
    for ([_]f32{ 280, 360, 520 }) |width| {
        var f: Fixture = undefined;
        try f.init(width, 760, files_page);
        defer f.deinit();
        try f.horizontalTextBounds();
        const filename = try f.text("src/navigation.zig");
        const additions = try f.text("+987654321");
        const deletions = try f.text("−123456789");
        try f.inViewport(filename);
        try f.inViewport(additions);
        try f.inViewport(deletions);
        try testing.expect(additions.y >= filename.y + filename.h);
        try f.t.clickText("src/navigation.zig");
        f.t.settle(0.1);
        try testing.expectEqual(@as(?usize, 0), f.a.panels.github_repository.expanded_file);
        try testing.expect(f.t.hasText("Patch not supplied by GitHub (binary, large or omitted)."));
        try pagination(&f);
    }
}

test "github responsive short list and activity panes reserve clickable pagination below scrolling headers" {
    const activity_page: flow.Page = .{ .repository = repo, .kind = .activity, .page = 2, .hasNextPage = true, .events = &.{.{ .id = "synthetic-comment", .event = "commented", .author = author, .createdAt = "2026-11-13", .body = "A synthetic review comment." }} };
    for ([_]f32{ 280, 360, 520 }) |width| {
        for ([_]flow.Page{ list_page, activity_page }) |page| {
            var f: Fixture = undefined;
            try f.init(width, 180, page);
            defer f.deinit();
            try f.control("Sessions");
            try f.control("Refresh");
            try pagination(&f);
            // Detail content taller than the viewport scrolls instead of
            // displacing the footer. Section navigation remains reachable.
            if (page.kind == .activity) {
                const section = try f.text("Activity");
                f.t.scroll(width / 2, 95, 90 - section.y);
                f.t.settle(0.2);
                try f.control("Activity");
                try f.control("Previous");
                try f.control("Next");
            }
        }
    }
}
