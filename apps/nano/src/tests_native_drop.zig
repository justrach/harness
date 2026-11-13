//! Native surface payloads through the real Nano view; synthetic files/replies only.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, split: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        h.a.account.scope = .local;
        h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-local");
        const chats = try std.json.parseFromSlice(std.json.Value, h.a.gpa,
            \\[ {"id":"drop-a","deviceId":"synthetic-local"},
            \\  {"id":"drop-b","deviceId":"synthetic-remote"},
            \\  {"id":"drop-c","deviceId":"synthetic-local"} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("drop-a", null);
        if (split) {
            h.a.splitPane(.horizontal);
            h.a.openChatInTab("drop-b");
            h.a.focusPane(0);
        }
        try h.t.init(h.a.gpa, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn hover(h: *Harness) void {
        h.t.ctx.input.drag_over = .{ .x = 1000, .y = 600 };
        h.t.frame();
    }

    fn release(h: *Harness, urls: []const []const u8) void {
        h.t.ctx.input.drag_over = null;
        h.t.ctx.input.drop = .{ .point = .{ .x = 1000, .y = 600 }, .urls = urls };
        h.t.frame();
    }
};

fn dropTargets(a: *App, c: *ui.Context) void {
    const root = ui.div(c).row().sizeFull();
    defer root.end();
    for (0..2) |ix| {
        ui.key(c, c.print("drop-pane-{d}", .{ix}));
        const pane = ui.div(c).grow().hFull();
        defer pane.end();
        @import("view_attachment_drop.zig").target(c, a, pane.index, ix);
    }
}

fn fileUrl(tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "synthetic.png", .data = @embedFile("icons/close.png") });
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/synthetic.png", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const path = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(path);
    // Windows native drops supply absolute paths, not file://C:\\... URLs
    // (which would incorrectly name C: as a remote authority).
    if (@import("builtin").os.tag == .windows) return testing.allocator.dupe(u8, path);
    return std.fmt.allocPrint(testing.allocator, "file://{s}", .{path});
}

// Genuine regressions against v0.2.187: a hover's destination may not silently
// change, and rejected payloads may not switch the active composer.
test "native drop rejects a chat replaced during hover instead of retargeting" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp);
    defer testing.allocator.free(url);
    h.hover();
    h.a.focusPane(1);
    h.a.openChatInTab("drop-c");
    h.a.focusPane(0);
    h.hover();
    h.release(&.{url});
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
    try testing.expectEqualStrings("drop-a", h.a.selected.?);
}

test "native drop empty invalid and oversize payloads never activate another pane" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp);
    defer testing.allocator.free(url);
    const file = try tmp.dir.createFile(testing.io, "synthetic.png", .{});
    try file.setLength(testing.io, attachments.max_bytes + 1);
    file.close(testing.io);
    for ([_][]const []const u8{ &.{""}, &.{"https://example.invalid/image.png"}, &.{"file:///missing-synthetic-drop"}, &.{url} }) |urls| {
        h.t.drop(1000, 600, urls, "");
        h.t.frame();
        try testing.expectEqualStrings("drop-a", h.a.selected.?);
        try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
    }
}

test "native drop text remains available without attachment error or activation" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.t.drop(1000, 600, &.{}, "Synthetic dragged text");
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), h.a.notice_len);
    try testing.expectEqualStrings("drop-a", h.a.selected.?);
    try testing.expect(h.a.file_drop.pending == null);
}

test "native drop pending release cancels after chat replacement or closed pane" {
    for ([_]bool{ false, true }) |close| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try fileUrl(&tmp);
        defer testing.allocator.free(url);
        // Isolate the release/pre-tree boundary: native intake runs now,
        // but the next view build (and prepare) is deliberately delayed.
        h.t.deinit();
        try h.t.init(h.a.gpa, .init(&h.a, dropTargets), .{ .width = 1200, .height = 780 });
        h.t.frame();
        h.t.drop(1000, 600, &.{url}, "");
        try testing.expect(h.a.file_drop.pending != null);
        h.a.focusPane(1);
        if (close) h.a.closePanel() else h.a.openChatInTab("drop-c");
        @import("view_attachment_drop.zig").prepare(&h.a);
        try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
        try testing.expect(h.a.file_drop.pending == null);
    }
}

test "native drop activates stable inactive chat and uploads files and images exactly once" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp);
    defer testing.allocator.free(url);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, h.a.gpa,
        \\{"UploadChunk":{},"UploadCommit":{"path":"/synthetic/uploads/dropped.png"}}
    , .{});
    h.a.engine.state = .connected;
    h.a.composer.set("Keep the outgoing draft");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "synthetic.txt", .data = "Synthetic dropped file" });
    const text_url = try std.fmt.allocPrint(testing.allocator, "{s}/synthetic.txt", .{std.fs.path.dirname(url) orelse return error.MissingDropParent});
    defer testing.allocator.free(text_url);
    h.t.drop(1000, 600, &.{ url, text_url }, "");
    h.t.frame();
    for (0..20) |_| if (!h.a.engine.pump()) break;
    try testing.expectEqualStrings("drop-b", h.a.selected.?);
    try testing.expectEqual(@as(usize, 2), attachments.count(&h.a));
    try testing.expect(attachments.isImageName(h.a.attachments.items.items[0].name));
    try testing.expect(!attachments.isImageName(h.a.attachments.items.items[1].name));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("drop-b", item.owner);
    try testing.expectEqualStrings("synthetic-remote", item.target.?);
    try testing.expect(item.status == .ready);
    try testing.expectEqualStrings("/synthetic/uploads/dropped.png", item.path.?);
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    h.t.frame();
    try testing.expectEqual(@as(usize, 2), h.a.attachments.items.items.len);
    var chunks: usize = 0;
    var commits: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, h.a.gpa, frame, .{});
        defer parsed.deinit();
        const method = parsed.value.object.get("method").?.string;
        if (std.mem.eql(u8, method, "UploadChunk")) chunks += 1;
        if (std.mem.eql(u8, method, "UploadCommit")) commits += 1;
    }
    try testing.expectEqual(@as(usize, 2), chunks);
    try testing.expectEqual(@as(usize, 2), commits);
    h.a.focusPane(0);
    try testing.expectEqualStrings("Keep the outgoing draft", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
}

test "native drop cancelled hover cannot attach after pane close or resize" {
    for ([_]bool{ false, true }) |close| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try fileUrl(&tmp);
        defer testing.allocator.free(url);
        h.hover();
        if (close) {
            h.a.focusPane(1);
            h.a.closePanel();
        } else {
            h.a.tabs.layout().?.shares.items[0] = 0.6;
            h.a.tabs.layout().?.shares.items[1] = 0.4;
        }
        h.hover();
        h.release(&.{url});
        h.t.frame();
        try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
        // A genuine exit ends cancellation. A fresh drag may attach.
        h.t.ctx.input.drag_over = null;
        h.t.frame();
        h.t.drop(1000, 600, &.{url}, "");
        h.t.frame();
        try testing.expectEqual(@as(usize, 1), h.a.attachments.items.items.len);
    }
}
