//! Visible artifact links must be actionable, not merely underlined. Real
//! Markdown hit boxes; synthetic host denial prevents any filesystem/OS open.
const std = @import("std");
const t = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;

fn calls(h: *Harness) !usize {
    var count: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, frame, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.object.get("method").?.string, "ReadAttachmentChunk")) {
            const params = parsed.value.object.get("params").?.object;
            try t.expectEqualStrings("/synthetic/fieldnotes/artifacts/promo.mp4", params.get("path").?.string);
            try t.expectEqualStrings("local", params.get("targetDeviceId").?.string);
            count += 1;
        }
    }
    return count;
}

test "artifact markdown bold and list links activate the owning host reader" {
    for ([_][]const u8{ "artifacts/promo.mp4", "/synthetic/fieldnotes/artifacts/promo.mp4", "file:///synthetic/fieldnotes/artifacts/promo.mp4" }) |destination| {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        const chats = try std.json.parseFromSlice(std.json.Value, t.allocator,
            \\[{"id":"a","deviceId":"local","cwd":"/synthetic/fieldnotes","spaceId":"local-project","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, t.allocator,
            \\{"ReadAttachmentChunk":{"$err":"Synthetic host denied the artifact"}}
        , .{});
        h.a.engine.state = .connected;
        const text = try std.fmt.allocPrint(t.allocator, "## Watch\n\n- **[Watch video]({s})**\n", .{destination});
        defer t.allocator.free(text);
        const json = try std.json.Stringify.valueAlloc(t.allocator, .{ .reset = .{.{ .id = "reply", .role = "assistant", .status = "complete", .parts = .{.{ .id = "p", .kind = "text", .text = text }} }} }, .{});
        defer t.allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(0.3);
        const rect = h.t.findText("Watch video") orelse return error.MissingArtifactLabel;
        h.t.click(rect.x + 10, rect.y + rect.h / 2);
        h.t.settle(0.3);
        try t.expectEqual(@as(usize, 1), try calls(&h));
        try t.expect(h.a.notice_len > 0);
        const link = h.t.findText("Watch video") orelse return error.MissingArtifactLabel;
        h.t.rightClick(link.x + 10, link.y + link.h / 2);
        h.t.settle(0.1);
        try t.expect(h.t.hasText("Open file"));
        try t.expect(!h.t.hasText("Open in browser"));
        try h.t.clickText("Copy link");
        try t.expectEqualStrings(destination, h.t.clipboard.items);
        try t.expectEqual(@as(usize, 1), try calls(&h));
        h.t.ctx.focus = for (h.t.ctx.a11y_items.items) |item| {
            if (item.role == .link and std.mem.eql(u8, item.label, "Watch video")) break item.id;
        } else return error.MissingArtifactAccessibility;
        h.t.key(.enter);
        h.t.settle(0.3);
        try t.expectEqual(@as(usize, 2), try calls(&h));
    }
}

fn providerView(a: *@import("app.zig").App, c: *@import("nanoui").ui.Context) void {
    @import("view_markdown.zig").providerMarkdown(c, @import("theme.zig").colors(false), "[Video](/synthetic/video.mp4) [Unsafe](javascript:alert)", a);
}

test "artifact markdown provider documents do not gain local file authority" {
    const App = @import("app.zig").App;
    const ui = @import("nanoui").ui;
    var a: App = .init(t.allocator, t.io, 1);
    defer a.deinit();
    a.offscreen = true;
    @import("theme.zig").registerFonts();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&a, providerView), .{ .width = 500, .height = 200 });
    defer tester.deinit();
    tester.settle(0.1);
    for (tester.ctx.a11y_items.items) |item| try t.expect(item.role != .link);
    try t.expectEqual(@as(usize, 0), a.engine.sent.items.len);
}
