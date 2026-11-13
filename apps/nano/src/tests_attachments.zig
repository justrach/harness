//! Attachment transport exercised against synthetic engine replies only.
const std = @import("std");
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");
const testing = std.testing;

test {
    _ = @import("tests_native_drop.zig");
}

fn connected(a: *App, replies: []const u8) !void {
    a.* = .init(testing.allocator, testing.io, 1);
    a.offscreen = true;
    a.device_id = try a.gpa.dupe(u8, "local-synthetic");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa, replies, .{});
    a.engine.state = .connected;
    const chats = try std.json.parseFromSlice(std.json.Value, a.gpa,
        \\[ {"id":"image-chat","deviceId":"remote-synthetic","config":{"harness":"mock"}} ]
    , .{});
    defer chats.deinit();
    try a.chats.replace(chats.value);
    a.select("image-chat", null);
}

fn pump(a: *App) !void {
    for (0..20) |_| if (!a.engine.pump()) return;
    return error.UploadDidNotSettle;
}

test "image uploads chunk, commit on the chat host, and send the same attachment trailer as GPUI" {
    var a: App = undefined;
    try connected(&a,
        \\{"UploadChunk":{},"UploadCommit":{"path":"/synthetic/uploads/image.png"},"QueueCommand":{}}
    );
    defer a.deinit();
    const bytes = try a.gpa.alloc(u8, 510_003);
    defer a.gpa.free(bytes);
    @memset(bytes, 0xab);
    try attachments.stage(&a, "image.png", bytes);
    try testing.expect(!attachments.ready(&a));
    a.composer.set("Synthetic image prompt");
    a.send();
    try testing.expectEqualStrings("Synthetic image prompt", a.composer.text());
    try testing.expectEqual(@as(usize, 0), a.pending_sends.items.len);
    try pump(&a);
    try testing.expect(attachments.ready(&a));
    var chunks: usize = 0;
    var commits: usize = 0;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        const method = o.get("method").?.string;
        if (!std.mem.eql(u8, method, "UploadChunk") and !std.mem.eql(u8, method, "UploadCommit")) continue;
        const p = o.get("params").?.object;
        try testing.expectEqualStrings("remote-synthetic", p.get("targetDeviceId").?.string);
        try testing.expectEqual(@as(usize, 36), p.get("uploadId").?.string.len);
        try testing.expect(frame.len < 1024 * 1024);
        if (std.mem.eql(u8, method, "UploadCommit")) {
            commits += 1;
            try testing.expectEqualStrings("image.png", p.get("fileName").?.string);
        } else {
            try testing.expectEqual(@as(i64, @intCast(chunks)), p.get("seq").?.integer);
            const data = p.get("data").?.string;
            const decoder = std.base64.standard.Decoder;
            const decoded = try a.gpa.alloc(u8, try decoder.calcSizeForSlice(data));
            defer a.gpa.free(decoded);
            try decoder.decode(decoded, data);
            const from = chunks * 510_000;
            try testing.expectEqualSlices(u8, bytes[from..@min(from + 510_000, bytes.len)], decoded);
            chunks += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), chunks);
    try testing.expectEqual(@as(usize, 1), commits);
    a.send();
    try testing.expectEqualStrings("", a.composer.text());
    try testing.expectEqual(@as(usize, 0), attachments.count(&a));
    try testing.expectEqualStrings("Synthetic image prompt\n\nAttached images (local files — open them to view):\n- /synthetic/uploads/image.png", a.pending_sends.items[0].part.text.items);
    try pump(&a);
}

test "image-only sends work and failed uploads leave the draft intact" {
    var a: App = undefined;
    try connected(&a,
        \\{"UploadChunk":{},"UploadCommit":{"$err":"Synthetic upload failed"},"QueueCommand":{}}
    );
    defer a.deinit();
    try attachments.stage(&a, "image.png", @embedFile("icons/project-default.png"));
    try pump(&a);
    a.composer.set("Keep this draft");
    a.send();
    try testing.expectEqualStrings("Keep this draft", a.composer.text());
    try testing.expectEqual(@as(usize, 1), attachments.count(&a));
    try testing.expectEqual(@as(usize, 0), a.pending_sends.items.len);
    // A failed file can be retried without choosing or pasting it again.
    a.engine.scene.?.deinit();
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa,
        \\{"UploadChunk":{},"UploadCommit":{"path":"/synthetic/uploads/image.png"},"QueueCommand":{}}
    , .{});
    a.attachments.items.items[0].start();
    try pump(&a);
    a.composer.clear();
    a.send();
    try testing.expectEqualStrings("See the attached image(s).\n\nAttached images (local files — open them to view):\n- /synthetic/uploads/image.png", a.pending_sends.items[0].part.text.items);
    try pump(&a);
}

test "staged images stay with their chat and removing an upload is safe before its reply" {
    var a: App = undefined;
    try connected(&a,
        \\{"UploadChunk":{},"UploadCommit":{"path":"/synthetic/uploads/image.png"}}
    );
    defer a.deinit();
    try attachments.stage(&a, "image.png", @embedFile("icons/project-default.png"));
    a.select("other-synthetic", null);
    try testing.expectEqual(@as(usize, 0), attachments.count(&a));
    a.select("image-chat", null);
    try testing.expectEqual(@as(usize, 1), attachments.count(&a));
    a.attachments.items.items[0].remove();
    a.reap();
    try testing.expectEqual(@as(usize, 0), a.attachments.items.items.len);
    try pump(&a);
}

const images = @import("app_attachment_images.zig");
const queue_edit = @import("app_queue.zig");
const refs = @import("attachment_refs.zig");
const ui = @import("nanoui").ui;
const picture_bytes = @embedFile("icons/project-default.png");
const image_prompt = "Inspect these\n\n" ++ refs.marker ++ "\n- /synthetic/uploads/first shot.png\n- /synthetic/uploads/second.png";

fn encodePicture() ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try testing.allocator.alloc(u8, encoder.calcSize(picture_bytes.len));
    _ = encoder.encode(out, picture_bytes);
    return out;
}

fn editConnected(a: *App, text: []const u8, load: anytype) !void {
    const replies = try std.json.Stringify.valueAlloc(testing.allocator, .{
        .BeginQueuedMessageEdit = .{ .outcome = "acquired", .leaseId = "synthetic-lease", .baseTextHash = "synthetic-hash", .text = text },
        .FinishQueuedMessageEdit = .{ .outcome = "committed" },
        .ReadAttachmentChunk = load,
        .UploadChunk = .{},
        .UploadCommit = .{ .path = "/synthetic/uploads/draft.png" },
    }, .{});
    defer testing.allocator.free(replies);
    try connected(a, replies);
    a.caps.edit_lease = true;
}

fn expectFinish(a: *App, action: []const u8, text: ?[]const u8) !void {
    var found = false;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        if (!std.mem.eql(u8, o.get("method").?.string, "FinishQueuedMessageEdit")) continue;
        const params = o.get("params").?.object;
        try testing.expectEqualStrings(action, params.get("action").?.string);
        try testing.expectEqualStrings("remote-synthetic", params.get("targetDeviceId").?.string);
        if (text) |body| try testing.expectEqualStrings(body, params.get("text").?.string) else try testing.expect(params.get("text") == null);
        found = true;
    }
    try testing.expect(found);
}

fn countCalls(a: *App, method: []const u8) !usize {
    var count: usize = 0;
    for (a.engine.sent.items) |frame| {
        const p = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer p.deinit();
        if (std.mem.eql(u8, p.value.object.get("method").?.string, method)) count += 1;
    }
    return count;
}

test "nano image parity queue edit restores removable committed tiles and saves without reupload" {
    const encoded = try encodePicture();
    defer testing.allocator.free(encoded);
    var a: App = undefined;
    try editConnected(&a, image_prompt, .{ .name = "shot.png", .mimeType = "image/png", .data = encoded, .done = true });
    defer a.deinit();
    a.composer.set("Synthetic draft");
    try attachments.stage(&a, "draft.png", picture_bytes);
    try pump(&a);
    queue_edit.beginEdit(&a, "synthetic-row");
    try pump(&a);
    try testing.expectEqualStrings("Inspect these", a.composer.text());
    try testing.expectEqual(@as(usize, 2), attachments.count(&a));
    try testing.expect(attachments.ready(&a));
    const first = a.attachments.items.items[1];
    const second = a.attachments.items.items[2];
    try testing.expectEqualStrings("first shot.png", first.name);
    _ = first.preview();
    _ = second.preview();
    try pump(&a);
    try testing.expectEqualSlices(u8, picture_bytes, first.preview());
    try testing.expectEqualSlices(u8, picture_bytes, second.preview());
    second.remove();
    a.composer.set("Edited prompt");
    queue_edit.finishEdit(&a, .commit);
    try pump(&a);
    try expectFinish(&a, "commit", "Edited prompt\n\n" ++ refs.marker ++ "\n- /synthetic/uploads/first shot.png");
    try testing.expectEqualStrings("Synthetic draft", a.composer.text());
    try testing.expectEqual(@as(usize, 1), attachments.count(&a));
    try testing.expectEqual(@as(usize, 1), try countCalls(&a, "UploadCommit"));
}

test "nano image parity cancel discards edited images and restores draft attachments" {
    var a: App = undefined;
    try editConnected(&a, image_prompt, .{ .@"$err" = "Synthetic unavailable attachment" });
    defer a.deinit();
    a.composer.set("Unsent draft");
    try attachments.stage(&a, "draft.png", picture_bytes);
    try pump(&a);
    queue_edit.beginEdit(&a, "synthetic-row");
    try pump(&a);
    try testing.expectEqual(@as(usize, 2), attachments.count(&a));
    a.attachments.items.items[1].remove();
    try attachments.stage(&a, "new.png", picture_bytes);
    try pump(&a);
    queue_edit.finishEdit(&a, .cancel);
    try pump(&a);
    try expectFinish(&a, "cancel", null);
    try testing.expectEqualStrings("Unsent draft", a.composer.text());
    try testing.expectEqual(@as(usize, 1), attachments.count(&a));
    try testing.expect(!a.attachments.items.items[0].removed);
}

test "nano image parity unavailable preview keeps committed refs saveable and removable" {
    var a: App = undefined;
    try editConnected(&a, image_prompt, .{ .@"$err" = "Synthetic unavailable attachment" });
    defer a.deinit();
    queue_edit.beginEdit(&a, "synthetic-row");
    try pump(&a);
    try testing.expectEqual(@as(usize, 2), attachments.count(&a));
    for (a.attachments.items.items) |item| _ = item.preview();
    try pump(&a);
    try testing.expect(attachments.ready(&a));
    for (a.attachments.items.items) |item| try testing.expectEqual(@as(usize, 0), item.preview().len);
    queue_edit.finishEdit(&a, .commit);
    try pump(&a);
    try expectFinish(&a, "commit", image_prompt);
    try testing.expectEqual(@as(usize, 0), try countCalls(&a, "UploadChunk"));
}

test "nano image parity metadata-only queue refs restore" {
    var a: App = undefined;
    try editConnected(&a, "Metadata only", .{ .@"$err" = "Synthetic unavailable attachment" });
    defer a.deinit();
    const rows = try std.json.parseFromSlice(std.json.Value, a.gpa,
        \\[{"id":"synthetic-row","text":"Metadata only","attachments":["/synthetic/uploads/metadata.png"]}]
    , .{});
    defer rows.deinit();
    try a.queue.replace(rows.value);
    queue_edit.beginEdit(&a, "synthetic-row");
    try pump(&a);
    try testing.expectEqual(@as(usize, 1), attachments.count(&a));
    try testing.expectEqualStrings("Metadata only", a.composer.text());
    queue_edit.finishEdit(&a, .commit);
    try pump(&a);
    try expectFinish(&a, "commit", "Metadata only\n\n" ++ refs.marker ++ "\n- /synthetic/uploads/metadata.png");
}

fn attachmentView(a: *App, c: *ui.Context) void {
    const k = @import("theme.zig").colors(true);
    const root = ui.div(c).column().wFull().hFull();
    defer root.end();
    _ = @import("view_transcript.zig").entries(c, a, k, &a.transcript, 700, false, 0);
    @import("view_composer_attachments.zig").strip(c, a, k, 700);
}

test "nano image parity sent user and queue edit show the staged attachment picture renderer" {
    const encoded = try encodePicture();
    defer testing.allocator.free(encoded);
    var a: App = undefined;
    try editConnected(&a, image_prompt, .{ .name = "shot.png", .mimeType = "image/png", .data = encoded, .done = true });
    defer a.deinit();
    const frame = try std.json.Stringify.valueAlloc(a.gpa, .{ .reset = .{.{ .id = "synthetic-user", .role = "user", .parts = .{.{ .id = "p", .kind = "text", .text = image_prompt ++ "\nLater prose" }} }} }, .{});
    defer a.gpa.free(frame);
    const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
    @import("theme.zig").registerFonts();
    var tester: ui.Tester = undefined;
    try tester.init(a.gpa, .init(&a, attachmentView), .{ .width = 800, .height = 700, .dark = true });
    defer tester.deinit();
    tester.settle(2);
    try pump(&a);
    tester.settle(2);
    try testing.expect(!tester.hasText(refs.marker));
    try testing.expect(tester.hasText("Inspect these\n\nLater prose"));
    try testing.expect(!tester.hasText("/synthetic/uploads/first shot.png"));
    try testing.expectEqual(@as(usize, 2), a.attachments.images.items.items.len);
    try testing.expect(tester.text.images.decoded.count() > 0);
    for (tester.text.images.decoded.values()) |decoded| try testing.expect(decoded != null);
    const loaded = try countCalls(&a, "ReadAttachmentChunk");
    queue_edit.beginEdit(&a, "synthetic-row");
    try pump(&a);
    tester.settle(2);
    try testing.expectEqualStrings("Inspect these", a.composer.text());
    try testing.expectEqual(@as(usize, 2), attachments.count(&a));
    try testing.expectEqual(loaded, try countCalls(&a, "ReadAttachmentChunk"));
    try testing.expectEqualStrings(image_prompt ++ "\nLater prose", a.transcript.entries.items[0].parts.items[0].text.items);
}

test "nano image parity readback chunks route to the owner and cache by device and path" {
    const encoded = try encodePicture();
    defer testing.allocator.free(encoded);
    const half = (encoded.len / 8) * 4;
    const Chunk = struct { name: []const u8 = "shot.png", mimeType: []const u8 = "image/png", data: []const u8, done: bool, nextOffset: usize };
    var a: App = undefined;
    try editConnected(&a, image_prompt, .{ .@"$seq" = [_]Chunk{
        .{ .data = encoded[0..half], .done = false, .nextOffset = half },
        .{ .data = encoded[half..], .done = true, .nextOffset = encoded.len },
    } });
    defer a.deinit();
    const path = "/synthetic/uploads/first shot.png";
    const image = images.get(&a, "image-chat", path).?;
    try testing.expect(images.get(&a, "image-chat", path).? == image);
    try pump(&a);
    try testing.expect(image.status == .ready);
    try testing.expectEqualSlices(u8, picture_bytes, image.bytes.items);
    try testing.expectEqual(@as(usize, 2), try countCalls(&a, "ReadAttachmentChunk"));
    var read: usize = 0;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        if (!std.mem.eql(u8, o.get("method").?.string, "ReadAttachmentChunk")) continue;
        const params = o.get("params").?.object;
        try testing.expectEqualStrings("remote-synthetic", params.get("targetDeviceId").?.string);
        try testing.expectEqualStrings(path, params.get("path").?.string);
        try testing.expectEqual(@as(i64, @intCast(if (read == 0) 0 else half)), params.get("offset").?.integer);
        read += 1;
    }
    try testing.expect(images.getDevice(&a, "other-synthetic", path).? != image);
    try testing.expect(images.get(&a, "unknown-chat", path) == null);
    try testing.expect(images.get(&a, "image-chat", "relative.png") == null);
    try testing.expectEqual(@as(usize, 0), try countCalls(&a, "ReadWorkspaceFile"));
}

fn expectReadFailure(reply: anytype) !void {
    var a: App = undefined;
    try editConnected(&a, image_prompt, reply);
    defer a.deinit();
    const image = images.get(&a, "image-chat", "/synthetic/uploads/invalid.png").?;
    try pump(&a);
    try testing.expect(image.status == .failed);
    try testing.expectEqual(@as(usize, 1), try countCalls(&a, "ReadAttachmentChunk"));
    try testing.expectEqual(@as(usize, 0), image.encoded.items.len);
    try testing.expectEqual(@as(usize, 0), image.bytes.items.len);
}

test "nano image parity readback rejects stalled offsets malformed base64 and non-images" {
    try expectReadFailure(.{ .mimeType = "image/png", .data = "AAAA", .done = false, .nextOffset = 0 });
    try expectReadFailure(.{ .mimeType = "image/png", .data = "@@@@", .done = true });
    try expectReadFailure(.{ .mimeType = "text/plain", .data = "AAAA", .done = true });
}

test "nano image parity queue preview strips only the attachment block" {
    var buf: [400]u8 = undefined;
    try testing.expectEqualStrings("Inspect these Later prose", @import("queue.zig").oneLine(&buf, image_prompt ++ "\nLater prose"));
    const malformed = "Keep this\n\n" ++ refs.marker ++ "\n- not-a-path";
    const projected = @import("queue.zig").oneLine(&buf, malformed);
    try testing.expect(std.mem.indexOf(u8, projected, refs.marker) != null);
}

test "only picture names get a thumbnail, as GPUI's is_image_path" {
    for ([_][]const u8{ "image.png", "0a1b2c3d-shot.PNG", "a.jpg", "a.jpeg", "a.gif", "a.webp", "a.svg", "a.bmp", "a.tif", "a.TIFF" }) |name| {
        try testing.expect(attachments.isImageName(name));
    }
    for ([_][]const u8{ "pasted-text.txt", "0a1b2c3d-report.pdf", "png", "archive.png.zip", "noext", "trailing." }) |name| {
        try testing.expect(!attachments.isImageName(name));
    }
}
