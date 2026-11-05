//! Attachment transport exercised against synthetic engine replies only.
const std = @import("std");
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");
const testing = std.testing;

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

test "only picture names get a thumbnail, as GPUI's is_image_path" {
    for ([_][]const u8{ "image.png", "0a1b2c3d-shot.PNG", "a.jpg", "a.jpeg", "a.gif", "a.webp", "a.svg", "a.bmp", "a.tif", "a.TIFF" }) |name| {
        try testing.expect(attachments.isImageName(name));
    }
    for ([_][]const u8{ "pasted-text.txt", "0a1b2c3d-report.pdf", "png", "archive.png.zip", "noext", "trailing." }) |name| {
        try testing.expect(!attachments.isImageName(name));
    }
}
