//! Synthetic provider prose: native formatting without navigation or attachment authority.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const markdown = @import("view_markdown.zig");
const md = @import("markdown.zig");

const Fixture = struct {
    a: *App,
    source: []const u8,
    github: bool = false,
    following: ?[]const u8 = null,
    veil: @import("veil.zig").RowVeil = .{ .seeding = true },

    fn view(f: *Fixture, c: *ui.Context) void {
        const page = ui.div(c).column().wFull().p(20);
        defer page.end();
        {
            ui.key(c, "provider");
            const provider = ui.div(c).column().wFull();
            defer provider.end();
            if (f.github) markdown.githubMarkdown(c, theme.colors(true), f.source, f.a) else markdown.providerMarkdown(c, theme.colors(true), f.source, f.a);
        }
        if (f.following) |source| {
            ui.key(c, "following-transcript");
            const transcript = ui.div(c).column().wFull();
            defer transcript.end();
            markdown.withLinksVeil(c, theme.colors(true), source, f.a, "synthetic-owner", &f.veil, true);
        }
    }
};

fn setup(a: *App) !void {
    a.* = .init(t.allocator, t.io, 1);
    a.offscreen = true;
    a.device_id = try a.gpa.dupe(u8, "synthetic-local");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa, "{}", .{});
    a.engine.state = .connected;
    const chats = try std.json.parseFromSlice(std.json.Value, a.gpa,
        \\[{"id":"synthetic-owner","deviceId":"synthetic-remote","cwd":"/synthetic/workspace","config":{"harness":"mock"}}]
    , .{});
    defer chats.deinit();
    try a.chats.replace(chats.value);
    a.select("synthetic-owner", null);
}

const RenderedText = struct { style: ui.TextStyle, spans: []const ui.Span };

fn textNode(tester: *ui.Tester, text: []const u8) !RenderedText {
    for (tester.ctx.nodes.items) |node| {
        if (node.content == .text and std.mem.eql(u8, node.content.text.str, text)) return .{ .style = node.content.text.style, .spans = node.content.text.spans };
    }
    return error.MissingProviderText;
}

test "remote markdown formats provider blocks natively and reuses the app cache" {
    theme.registerFonts();
    var a: App = undefined;
    try setup(&a);
    defer a.deinit();
    var f: Fixture = .{ .a = &a, .source =
        \\# Synthetic release
        \\
        \\Keep **bold** and *italic* with `inline`.
        \\
        \\- Plain bullet
        \\- [x] Completed task
        \\- [ ] Pending task
        \\1. Ordered item
        \\
        \\> Quoted rationale
        \\
        \\```rust
        \\let ready = true;
        \\```
        \\
        \\| Feature | Status |
        \\| --- | --- |
        \\| Native prose | Ready |
    };
    var tester: ui.Tester = undefined;
    try tester.init(a.gpa, .init(&f, Fixture.view), .{ .width = 620, .height = 1000, .dark = true });
    defer tester.deinit();
    tester.settle(3);
    const heading = try textNode(&tester, "Synthetic release");
    try t.expectEqual(@as(f32, 19), heading.style.size);
    try t.expectEqual(ui.Weight.semibold, heading.style.weight);
    const prose = try textNode(&tester, "Keep bold and italic with inline.");
    var bold = false;
    var italic = false;
    var inline_code = false;
    for (prose.spans) |span| {
        bold = bold or span.weight == .semibold;
        italic = italic or span.italic;
        inline_code = inline_code or span.mono;
    }
    try t.expect(bold and italic and inline_code);
    for ([_][]const u8{ "Plain bullet", "Completed task", "Pending task", "Ordered item", "1.", "Quoted rationale", "Feature", "Status", "Native prose", "Ready" }) |label| {
        try t.expect(tester.hasText(label));
    }
    const code = try textNode(&tester, "let ready = true;");
    try t.expect(code.style.mono);
    try t.expect(code.spans.len > 0);
    const calls = md.test_parse_calls;
    tester.settle(3);
    try t.expectEqual(calls, md.test_parse_calls);
}

test "github images render inline in descriptions and HTML with bounded native previews" {
    theme.registerFonts();
    var a: App = undefined;
    try setup(&a);
    defer a.deinit();
    const url = "https://raw.githubusercontent.com/demo/repo/media/before.png";
    try a.panels.github_repository.images.seed(url, @embedFile("testdata/github-preview.png"));
    const sent = a.engine.sent.items.len;
    var f: Fixture = .{ .a = &a, .github = true, .source =
        \\## Before
        \\
        \\![Before preview](https://raw.githubusercontent.com/demo/repo/media/before.png)
        \\
        \\## After
        \\
        \\<img src="https://raw.githubusercontent.com/demo/repo/media/before.png" alt="After preview" width="320">
        \\
        \\![Unavailable preview](file:///synthetic/private.png)
    };
    var tester: ui.Tester = undefined;
    try tester.init(a.gpa, .init(&f, Fixture.view), .{ .width = 620, .height = 900, .dark = true });
    defer tester.deinit();
    tester.settle(3);
    var image_count: usize = 0;
    for (tester.ctx.nodes.items) |node| if (node.content == .image) {
        image_count += 1;
        try t.expect(node.rect.w > 0 and node.rect.w <= 580);
        try t.expect(node.rect.h > 0 and node.rect.h <= 560);
    };
    try t.expectEqual(@as(usize, 2), image_count);
    try t.expect(tester.containsText("Image unavailable: Unavailable preview"));
    try t.expectEqual(@as(usize, 0), a.attachments.images.items.items.len);
    try t.expectEqual(sent, a.engine.sent.items.len);
    if (std.c.getenv("NANO_GITHUB_IMAGES_SNAP")) |path| try tester.screenshot(std.mem.span(path));
    // Repository/chat changes invalidate previews at the next safe frame boundary.
    @import("app_github_repository.zig").reset(&a);
    try t.expect(a.panels.github_repository.images.entries[0].?.retired);
    a.reap();
    try t.expect(a.panels.github_repository.images.entries[0] == null);
}

test "remote markdown provider links images and HTML have no interactive or loading capability" {
    theme.registerFonts();
    var a: App = undefined;
    try setup(&a);
    defer a.deinit();
    const sent = a.engine.sent.items.len;
    var f: Fixture = .{ .a = &a, .source =
        \\[Readable link](https://example.invalid/synthetic) [Unsafe link](javascript:synthetic())
        \\
        \\![Remote alt](https://example.invalid/picture.png) ![Local alt](picture.png) ![File alt](file:///synthetic/private.png) ![Data alt](data:image/png;base64,AAAA)
        \\
        \\<p><a href="https://example.invalid/html">HTML label</a><img src="picture.png" alt="HTML alt" onerror="synthetic()"></p>
        \\
        \\# [Heading label](https://example.invalid/heading)
        \\
        \\- [List label](https://example.invalid/list)
        \\
        \\> [Quote label](https://example.invalid/quote)
        \\
        \\| [Column label](https://example.invalid/column) | Image |
        \\| --- | --- |
        \\| [Cell label](https://example.invalid/cell) | ![Cell alt](picture.png) |
        \\
        \\<script>synthetic()</script><iframe src="https://example.invalid/frame"></iframe>
    };
    var tester: ui.Tester = undefined;
    try tester.init(a.gpa, .init(&f, Fixture.view), .{ .width = 620, .height = 700, .dark = true });
    defer tester.deinit();
    tester.settle(3);
    for ([_][]const u8{ "Readable link", "Unsafe link", "Remote alt", "Local alt", "File alt", "Data alt", "HTML label", "HTML alt", "Heading label", "List label", "Quote label", "Column label", "Cell label", "Cell alt" }) |label| try t.expect(tester.containsText(label));
    // Fail before sending input: a regression must not open an external browser
    // even while testing hostile destinations.
    try t.expectEqual(@as(usize, 0), tester.ctx.hits.items.len);
    for (tester.ctx.nodes.items) |node| {
        try t.expect(!node.interactive);
        try t.expect(node.content != .image and node.content != .hole and node.content != .texture);
    }
    try t.expectEqual(@as(usize, 0), tester.text.images.decoded.count());
    try t.expectEqual(@as(usize, 0), a.attachments.images.items.items.len);
    try t.expectEqual(sent, a.engine.sent.items.len);
    try t.expectEqual(@as(usize, 0), a.panels.tabs.items.len);
    // The rendered prose is still selectable; stripping capabilities must not
    // replace the readable label with a destination or a raw Markdown block.
    var selectable = false;
    for (tester.ctx.nodes.items) |node| selectable = selectable or node.style.selectable;
    try t.expect(selectable);
}

test "remote markdown does not poison following transcript links attachments or streaming veil" {
    theme.registerFonts();
    var a: App = undefined;
    try setup(&a);
    defer a.deinit();
    const source = "[Shared label](https://example.invalid/shared) ![Shared alt](picture.png)";
    var f: Fixture = .{ .a = &a, .source = source, .following = source };
    defer f.veil.deinit(a.gpa);
    var tester: ui.Tester = undefined;
    try tester.init(a.gpa, .init(&f, Fixture.view), .{ .width = 620, .height = 700, .dark = true });
    defer tester.deinit();
    tester.settle(3);
    try t.expect(tester.ctx.hits.items.len > 0);
    try t.expectEqual(@as(usize, 1), a.attachments.images.items.items.len);
    try t.expect(f.veil.elems.count() > 0);
    var found_request = false;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        const method = o.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "ReadAttachmentChunk")) continue;
        found_request = true;
        const params = o.get("params").?.object;
        try t.expectEqualStrings("synthetic-remote", params.get("targetDeviceId").?.string);
        try t.expectEqualStrings("/synthetic/workspace/picture.png", params.get("path").?.string);
    }
    try t.expect(found_request);
    // Shared cached parse entries must not have their image/link arrays cleared.
    const palette: md.Palette = .{ .code = theme.colors(true).accent, .code_bg = theme.colors(true).accent_wash, .link = theme.colors(true).text, .muted = theme.colors(true).muted };
    const blocks = a.markdown_cache.parse(a.gpa, tester.ctx.alloc(), source, palette);
    try t.expectEqual(@as(usize, 1), blocks[0].paragraph.images.len);
    try t.expect(blocks[0].paragraph.links.len > 0);
}
