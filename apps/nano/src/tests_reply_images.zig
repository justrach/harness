//! Synthetic assistant reply pictures, through the real host-routed loader/render path.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const images = @import("app_attachment_images.zig");
const bytes = @embedFile("reply-image-fixture.png");
const path = "/synthetic/workspace/picture.png";

fn setup(a: *App, partial: bool) !void {
    a.* = .init(t.allocator, t.io, 1);
    a.offscreen = true;
    a.device_id = try a.gpa.dupe(u8, "local-synthetic");
    const encoded = try a.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer a.gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    const Chunk = struct { mimeType: []const u8 = "image/png", data: []const u8, done: bool, nextOffset: usize };
    const half = (encoded.len / 8) * 4;
    const replies = try std.json.Stringify.valueAlloc(a.gpa, .{ .ReadAttachmentChunk = .{ .@"$seq" = [_]Chunk{
        .{ .data = if (partial) encoded[0..half] else encoded, .done = !partial, .nextOffset = half },
        .{ .data = encoded[half..], .done = true, .nextOffset = encoded.len },
    } } }, .{});
    defer a.gpa.free(replies);
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa, replies, .{});
    a.engine.state = .connected;
    const chats = try std.json.parseFromSlice(std.json.Value, a.gpa,
        \\[ {"id":"reply-owner","deviceId":"remote-synthetic","cwd":"/synthetic/workspace","config":{"harness":"mock"}} ]
    , .{});
    defer chats.deinit();
    try a.chats.replace(chats.value);
    a.select("reply-owner", null);
}

fn reset(a: *App, markdown: bool) !void {
    const frame = if (markdown)
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Before **bold** [link](https://example.invalid). ![Four color picture](picture.png) After $x^2$."}]}]}
    else
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"p","kind":"image","name":"Four color picture","path":"/synthetic/workspace/picture.png","mimeType":"image/png"}]}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
}

fn view(a: *App, c: *ui.Context) void {
    const root = ui.div(c).column().wFull().hFull();
    defer root.end();
    _ = @import("view_transcript.zig").entries(c, a, @import("theme.zig").colors(true), &a.transcript, 620, false, 0);
}

fn initTester(a: *App, tester: *ui.Tester) !void {
    @import("theme.zig").registerFonts();
    try tester.init(a.gpa, .init(a, view), .{ .width = 700, .height = 500, .dark = true });
    tester.settle(3);
}

fn expectPicture(tester: *ui.Tester) !void {
    try t.expect(tester.text.images.decoded.count() > 0);
    for (tester.text.images.decoded.values()) |decoded| try t.expect(decoded != null);
    // Check actual offscreen pixels, not just image nodes: all four corners
    // of the synthetic picture must survive transfer, decoding and rendering.
    const pixels = try tester.render(t.allocator);
    defer pixels.deinit(t.allocator);
    var counts: [4]usize = @splat(0);
    var i: usize = 0;
    while (i + 3 < pixels.bytes.len) : (i += 4) {
        const b = pixels.bytes[i];
        const g = pixels.bytes[i + 1];
        const r = pixels.bytes[i + 2];
        if (r > 210 and g < 90 and b < 90) counts[0] += 1;
        if (g > 140 and r < 70 and b < 130) counts[1] += 1;
        if (b > 200 and r < 90 and g < 140) counts[2] += 1;
        if (r > 220 and g > 160 and b < 80) counts[3] += 1;
    }
    for (counts) |count| try t.expect(count > 1000);
    try t.expect(!tester.hasText("Loading image…"));
}

fn expectOwner(a: *App) !void {
    var found = false;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        if (!std.mem.eql(u8, o.get("method").?.string, "ReadAttachmentChunk")) continue;
        found = true;
        const p = o.get("params").?.object;
        try t.expectEqualStrings(path, p.get("path").?.string);
        try t.expectEqualStrings("remote-synthetic", p.get("targetDeviceId").?.string);
    }
    try t.expect(found);
}

test "reply images completed native and Markdown pictures render all four quadrants" {
    for ([_]bool{ false, true }) |markdown| {
        var a: App = undefined;
        try setup(&a, false);
        defer a.deinit();
        try reset(&a, markdown);
        var tester: ui.Tester = undefined;
        try initTester(&a, &tester);
        defer tester.deinit();
        _ = a.engine.pump();
        tester.settle(3);
        try expectPicture(&tester);
        try expectOwner(&a);
        try tester.screenshot(if (markdown) "../../.graff/retention-audit/deep/reply-images-markdown.png" else "../../.graff/retention-audit/deep/reply-images-native.png");
        // More than the shared cache's 64 refs: evict inactive/pending refs,
        // never the image still borrowed by the visible reply's next frame.
        const retained = a.attachments.images.items.items[0];
        for (0..66) |i| {
            const other = try std.fmt.allocPrint(a.gpa, "/synthetic/workspace/unused-{d}.png", .{i});
            defer a.gpa.free(other);
            _ = images.getDevice(&a, "remote-synthetic", other);
        }
        images.reap(&a);
        tester.settle(2);
        images.reap(&a);
        tester.settle(2);
        try t.expectEqual(@as(usize, 64), a.attachments.images.items.items.len);
        const loaded = a.attachments.images.items.items.len;
        try t.expect(a.attachments.images.items.items[0] == retained);
        try expectPicture(&tester);
        tester.resize(420, 500);
        tester.settle(3);
        try expectPicture(&tester);
        try t.expectEqual(loaded, a.attachments.images.items.items.len);
    }
}

test "reply images partial transfer stays loading then completes without cached placeholder" {
    for ([_]bool{ false, true }) |markdown| {
        var a: App = undefined;
        try setup(&a, true);
        defer a.deinit();
        try reset(&a, markdown);
        var tester: ui.Tester = undefined;
        try initTester(&a, &tester);
        defer tester.deinit();
        try t.expect(tester.hasText("Loading image…"));
        const before = tester.text.images.decoded.count();
        _ = a.engine.pump();
        tester.settle(3);
        try t.expect(tester.hasText("Loading image…"));
        try t.expectEqual(before, tester.text.images.decoded.count());
        try t.expectEqual(@as(usize, 0), images.tileBytes(a.attachments.images.items.items[0]).len);
        _ = a.engine.pump();
        tester.settle(3);
        try expectPicture(&tester);
        try expectOwner(&a);
        const pixels = try tester.render(t.allocator);
        defer pixels.deinit(t.allocator);
        for (0..4) |_| {
            images.reap(&a);
            tester.settle(2);
        }
        const again = try tester.render(t.allocator);
        defer again.deinit(t.allocator);
        try t.expectEqualSlices(u8, pixels.bytes, again.bytes);
    }
}

fn ownerView(a: *App, c: *ui.Context) void {
    const root = ui.div(c).column().wFull().hFull();
    defer root.end();
    @import("view_markdown.zig").withLinks(c, @import("theme.zig").colors(true), "![Owned picture](picture.png)", a, "reply-owner");
}

test "reply images Markdown ownership ignores focus and rejects untrusted sources without RPC" {
    const reply = @import("view_reply_images.zig");
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "https://example.invalid/picture.png", "http://127.0.0.1/picture.png",
        "file:///synthetic/picture.png",       "data:image/png;base64,AAAA",
        "../private.png",                      "nested/../../private.png",
        "//remote/picture.png",                "\\\\remote\\picture.png",
        "/synthetic/picture.svg",              "picture.png?query",
        "picture.png#fragment",                "%2e%2e/private.png",
        "bad\nname.png",
    }) |src| try t.expect(reply.resolve(arena.allocator(), "/synthetic/workspace", src) == null);
    try t.expectEqualStrings("C:\\synthetic\\workspace\\picture.png", reply.resolve(arena.allocator(), "C:\\synthetic\\workspace", "picture.png").?);
    try t.expect(reply.resolve(arena.allocator(), null, "picture.png") == null);

    var a: App = undefined;
    try setup(&a, false);
    defer a.deinit();
    // Simulate a neighboring pane being focused. The rendered owner remains
    // reply-owner, so neither the device nor cwd may come from a.selected.
    a.gpa.free(a.selected.?);
    a.selected = try a.gpa.dupe(u8, "unrelated-focused-pane");
    @import("theme.zig").registerFonts();
    var tester: ui.Tester = undefined;
    try tester.init(a.gpa, .init(&a, ownerView), .{ .width = 700, .height = 500, .dark = true });
    defer tester.deinit();
    tester.settle(3);
    _ = a.engine.pump();
    tester.settle(3);
    try expectPicture(&tester);
    try expectOwner(&a);
}

test "reply images unavailable engine resources and remote URLs show explicit fallback" {
    var a: App = undefined;
    try setup(&a, false);
    defer a.deinit();
    // This scene returns a normal engine error, not local file I/O.
    a.engine.scene.?.deinit();
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa,
        \\{"ReadAttachmentChunk":{"$err":"Synthetic resource unavailable"}}
    , .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa,
        \\{"reset":[{"id":"reply","role":"assistant","parts":[{"id":"p","kind":"text","text":"![Remote](https://example.invalid/image.png) ![Missing](picture.png) ![Unsafe](file:///etc/private.png)"}]}]}
    , .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
    var tester: ui.Tester = undefined;
    try initTester(&a, &tester);
    defer tester.deinit();
    _ = a.engine.pump();
    tester.settle(3);
    try t.expect(tester.hasText("Image unavailable: Remote"));
    try t.expect(tester.hasText("Image unavailable: Missing"));
    try t.expect(tester.hasText("Image unavailable: Unsafe"));
    try t.expect(!tester.hasText("Loading image…"));
    try t.expectEqual(@as(usize, 1), a.attachments.images.items.items.len);
    try expectOwner(&a);
}
