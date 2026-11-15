//! Synthetic parser/transport/ownership regressions. No native UI, filesystem
//! fixture, user data, network, or real OS viewer is used by these tests.
const std = @import("std");
const testing = std.testing;
const App = @import("app.zig").App;
const artifacts = @import("artifact_links.zig");

const Recorder = struct {
    var calls: usize = 0;
    var filename: [64]u8 = undefined;
    var filename_len: usize = 0;
    var bytes: [128]u8 = undefined;
    var bytes_len: usize = 0;
    var reject: bool = false;

    fn save(_: *App, name: []const u8, data: []const u8) !void {
        if (reject) return error.SyntheticHandoffFailure;
        if (name.len > filename.len or data.len > bytes.len) return error.TestRecorderOverflow;
        calls += 1;
        @memcpy(filename[0..name.len], name);
        filename_len = name.len;
        @memcpy(bytes[0..data.len], data);
        bytes_len = data.len;
    }

    fn reset() void {
        calls = 0;
        filename_len = 0;
        bytes_len = 0;
        reject = false;
    }
};

const original_chats =
    \\[ {"id":"artifact-chat","deviceId":"artifact-host","spaceId":"artifact-project","cwd":"/synthetic/project","archived":false},
    \\  {"id":"peer-chat","deviceId":"peer-host","cwd":"/synthetic/peer","archived":false} ]
;

fn replaceChats(a: *App, text: []const u8) !void {
    const p = try std.json.parseFromSlice(std.json.Value, a.gpa, text, .{});
    defer p.deinit();
    try a.chats.replace(p.value);
}

fn setup(a: *App, scene: []const u8) !void {
    a.* = .init(testing.allocator, testing.io, 1);
    a.offscreen = true;
    a.device_id = try a.gpa.dupe(u8, "viewer-device");
    try replaceChats(a, original_chats);
    a.openChat("artifact-chat", null);
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa, scene, .{});
    a.engine.state = .connected;
    Recorder.reset();
}

fn pump(a: *App) !void {
    for (0..20) |_| if (!a.engine.pump()) return;
    return error.ArtifactDidNotSettle;
}

const gif_scene =
    \\{"ReadAttachmentChunk":{"name":"unsafe-original-name.gif","mimeType":"image/gif","data":"R0lGODlh","nextOffset":6,"done":true}}
;

fn requestCount(a: *App) !usize {
    var n: usize = 0;
    for (a.engine.sent.items) |frame| {
        const p = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer p.deinit();
        if (std.mem.eql(u8, p.value.object.get("method").?.string, "ReadAttachmentChunk")) n += 1;
    }
    return n;
}

fn expectRead(a: *App, path: []const u8, offset: i64) !void {
    var found = false;
    for (a.engine.sent.items) |frame| {
        const p = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
        defer p.deinit();
        if (!std.mem.eql(u8, p.value.object.get("method").?.string, "ReadAttachmentChunk")) continue;
        const params = p.value.object.get("params").?.object;
        if (params.get("offset").?.integer != offset) continue;
        try testing.expectEqualStrings(path, params.get("path").?.string);
        try testing.expectEqualStrings("artifact-host", params.get("targetDeviceId").?.string);
        found = true;
    }
    try testing.expect(found);
}

fn containsNotice(a: *App, text: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, (a.noticeText() orelse ""), text) != null);
}

test "artifact links accept local paths and reject executable schemes network shares and escape tricks" {
    for ([_][]const u8{
        "/synthetic/storyboard.gif",           "output/movie.mp4",       "./clip.MOV",                  "../renders/clip.webm",
        "file:///synthetic/story%20board.gif", "output/frame%20one.png", "FILE:///synthetic/image.gif",
    }) |raw| try testing.expect(artifacts.isLocal(raw));
    for ([_][]const u8{
        "",                                 "https://example.invalid/movie.mp4", "javascript:alert(1)",          "data:image/gif;base64,AAAA",
        "mailto:demo@example.invalid",      "shell:open",                        "file://example.invalid/a.gif", "file://localhost/a.gif",
        "//example.invalid/a.gif",          "\\\\server\\a.gif",                 "file:////server/a.gif",        "file:///\\server/a.gif",
        "%6aavascript%3Aalert(1)",          "%2f%2fserver/a.gif",                "movie.mp4%00",                 "movie.mp4%0A",
        "bad%2.gif",                        "bad%.gif",                          "movie.gif?download=1",         "movie.gif#fragment",
        "file:///synthetic/%252fetc/x.gif", "C:/synthetic/movie.mp4",            "~/movie.mp4",                  "/synthetic/",
        "file:///synthetic/%FF.gif",
    }) |raw| try testing.expect(!artifacts.isLocal(raw));
}

test "artifact links resolve decoded relative paths only against owner cwd and encode cache file URLs" {
    const relative = try artifacts.resolve(testing.allocator, "/synthetic/project", "output/story%20board.gif");
    defer testing.allocator.free(relative);
    try testing.expectEqualStrings("/synthetic/project/output/story board.gif", relative);
    const absolute = try artifacts.resolve(testing.allocator, "/synthetic/project", "file:///synthetic/uploads/clip.mp4");
    defer testing.allocator.free(absolute);
    try testing.expectEqualStrings("/synthetic/uploads/clip.mp4", absolute);
    try testing.expectError(error.InvalidWorkingDirectory, artifacts.resolve(testing.allocator, "relative/cwd", "clip.mp4"));
    const url = try artifacts.fileUrl(testing.allocator, "/synthetic/cache space/artifact-123.gif");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("file:///synthetic/cache%20space/artifact-123.gif", url);
}

test "artifact links click downloads from owner host and hands only generated cache name and validated bytes to viewer" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    var a: App = undefined;
    try setup(&a, gif_scene);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), try requestCount(&a));
    artifacts.open(&a, "artifact-chat", "output/story%20board.gif");
    try testing.expectEqual(@as(usize, 0), Recorder.calls);
    try testing.expect(a.artifacts.active != null);
    try pump(&a);
    try expectRead(&a, "/synthetic/project/output/story board.gif", 0);
    try testing.expectEqual(@as(usize, 1), Recorder.calls);
    try testing.expectEqualStrings("GIF89a", Recorder.bytes[0..Recorder.bytes_len]);
    const name = Recorder.filename[0..Recorder.filename_len];
    try testing.expect(std.mem.startsWith(u8, name, "artifact-"));
    try testing.expect(std.mem.endsWith(u8, name, ".gif"));
    try testing.expect(std.mem.indexOf(u8, name, "unsafe-original") == null);
    try testing.expect(std.mem.indexOfScalar(u8, name, '/') == null);
    try testing.expect(a.artifacts.active == null);
    try testing.expect(a.artifacts.request == null);
    try containsNotice(&a, "opened");
}

test "artifact links decode independently padded chunks and verify exact progress" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    var a: App = undefined;
    try setup(&a,
        \\{"ReadAttachmentChunk":{"$seq":[
        \\{"mimeType":"image/gif","data":"R0lGODlheA==","nextOffset":7,"done":false},
        \\{"mimeType":"image/gif","data":"eQ==","nextOffset":8,"done":true}]}}
    );
    defer a.deinit();
    artifacts.open(&a, "artifact-chat", "movie.gif");
    try pump(&a);
    try testing.expectEqual(@as(usize, 2), try requestCount(&a));
    try expectRead(&a, "/synthetic/project/movie.gif", 7);
    try testing.expectEqual(@as(usize, 1), Recorder.calls);
    try testing.expectEqualStrings("GIF89axy", Recorder.bytes[0..Recorder.bytes_len]);
}

test "artifact links supported video image and PDF types keep non-executable generated extensions" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    const Vector = struct { path: []const u8, mime: []const u8, bytes: []const u8, extension: []const u8 };
    const vectors = [_]Vector{
        .{ .path = "clip.mp4", .mime = "video/mp4", .bytes = "\x00\x00\x00\x18ftypisom", .extension = ".mp4" },
        .{ .path = "clip.MOV", .mime = "video/quicktime", .bytes = "\x00\x00\x00\x18ftypqt  ", .extension = ".mov" },
        .{ .path = "clip.m4v", .mime = "video/x-m4v", .bytes = "\x00\x00\x00\x18ftypM4V ", .extension = ".m4v" },
        .{ .path = "clip.webm", .mime = "video/webm", .bytes = "\x1a\x45\xdf\xa3synthetic", .extension = ".webm" },
        .{ .path = "storyboard.pdf", .mime = "application/pdf", .bytes = "%PDF-1.7 synthetic", .extension = ".pdf" },
        .{ .path = "frame.png", .mime = "image/png", .bytes = "\x89PNG\r\n\x1a\nsynthetic", .extension = ".png" },
        .{ .path = "frame.jpeg", .mime = "image/jpeg", .bytes = "\xff\xd8\xffsynthetic", .extension = ".jpg" },
    };
    for (vectors) |v| {
        var encoded: [128]u8 = undefined;
        const data = std.base64.standard.Encoder.encode(&encoded, v.bytes);
        const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{ .ReadAttachmentChunk = .{
            .name = "untrusted-original.sh",
            .mimeType = v.mime,
            .data = data,
            .nextOffset = v.bytes.len,
            .done = true,
        } }, .{});
        defer testing.allocator.free(scene);
        var a: App = undefined;
        try setup(&a, scene);
        defer a.deinit();
        artifacts.open(&a, "artifact-chat", v.path);
        try pump(&a);
        try testing.expectEqual(@as(usize, 1), Recorder.calls);
        try testing.expectEqualSlices(u8, v.bytes, Recorder.bytes[0..Recorder.bytes_len]);
        try testing.expect(std.mem.endsWith(u8, Recorder.filename[0..Recorder.filename_len], v.extension));
    }
}

test "artifact links reject malformed type signature offsets and backend errors visibly" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    const scenes = [_][]const u8{
        "{\"ReadAttachmentChunk\":{\"mimeType\":\"text/html\",\"data\":\"R0lGODlh\",\"nextOffset\":6,\"done\":true}}",
        "{\"ReadAttachmentChunk\":{\"mimeType\":\"image/gif\",\"data\":\"PGh0bWw+\",\"nextOffset\":6,\"done\":true}}",
        "{\"ReadAttachmentChunk\":{\"mimeType\":\"image/gif\",\"data\":\"R0lGODlh\",\"nextOffset\":7,\"done\":true}}",
        "{\"ReadAttachmentChunk\":{\"mimeType\":\"image/gif\",\"data\":\"R0lGODlh\",\"nextOffset\":0,\"done\":false}}",
        "{\"ReadAttachmentChunk\":{\"mimeType\":\"image/gif\",\"data\":\"!!!\",\"nextOffset\":2,\"done\":true}}",
        "{\"ReadAttachmentChunk\":{\"mimeType\":\"image/gif\",\"data\":\"\",\"nextOffset\":0,\"done\":true}}",
        "{\"ReadAttachmentChunk\":{\"mimeType\":\"image/gif\",\"data\":\"R0lGODlh\",\"done\":true}}",
        "{\"ReadAttachmentChunk\":{\"$err\":\"Synthetic path jail denied\"}}",
        "{\"ReadAttachmentChunk\":{\"$items\":[{\"mimeType\":\"image/gif\",\"data\":\"R0lGODlh\",\"nextOffset\":6,\"done\":true}]}}",
    };
    for (scenes) |scene| {
        var a: App = undefined;
        try setup(&a, scene);
        defer a.deinit();
        artifacts.open(&a, "artifact-chat", "movie.gif");
        try pump(&a);
        try testing.expectEqual(@as(usize, 0), Recorder.calls);
        try testing.expect(a.artifacts.active == null);
        try testing.expect(a.notice_len > 0);
        try testing.expectEqual(@as(usize, 1), try requestCount(&a));
    }
}

test "artifact links bound bytes chunks and simultaneous transfers" {
    try testing.expect(artifacts.withinBudget(artifacts.max_bytes - 1, 1, artifacts.max_chunks - 1));
    try testing.expect(!artifacts.withinBudget(artifacts.max_bytes, 1, 0));
    try testing.expect(!artifacts.withinBudget(0, artifacts.chunk_bytes + 1, 0));
    try testing.expect(!artifacts.withinBudget(0, 1, artifacts.max_chunks));
    try testing.expect(!artifacts.withinBudget(std.math.maxInt(usize), 1, 0));
    try testing.expect(!artifacts.withinBudget(0, 0, 0));
    var a: App = undefined;
    try setup(&a, gif_scene);
    defer a.deinit();
    artifacts.open(&a, "artifact-chat", "movie.gif");
    artifacts.open(&a, "artifact-chat", "second.gif");
    try testing.expectEqual(@as(usize, 1), try requestCount(&a));
    try containsNotice(&a, "already downloading");
    a.artifacts.cancel(&a);
    try pump(&a);
}

test "artifact links ownership invalidated by chat reuse project device cwd archival deletion and hidden routes" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    for (0..7) |change| {
        var a: App = undefined;
        try setup(&a, gif_scene);
        defer a.deinit();
        artifacts.open(&a, "artifact-chat", "movie.gif");
        try testing.expect(a.artifacts.active != null);
        switch (change) {
            0 => a.openChat("peer-chat", null),
            1 => try replaceChats(&a, "[{\"id\":\"artifact-chat\",\"deviceId\":\"new-host\",\"spaceId\":\"artifact-project\",\"cwd\":\"/synthetic/project\"}]"),
            2 => try replaceChats(&a, "[{\"id\":\"artifact-chat\",\"deviceId\":\"artifact-host\",\"spaceId\":\"artifact-project\",\"cwd\":\"/synthetic/changed\"}]"),
            3 => try replaceChats(&a, "[{\"id\":\"artifact-chat\",\"deviceId\":\"artifact-host\",\"spaceId\":\"changed-project\",\"cwd\":\"/synthetic/project\"}]"),
            4 => try replaceChats(&a, "[{\"id\":\"artifact-chat\",\"archived\":true}]"),
            5 => {
                try replaceChats(&a, "[]");
                a.chats_synced = true;
            },
            else => a.view.settings_open = true,
        }
        try pump(&a);
        try testing.expectEqual(@as(usize, 0), Recorder.calls);
        try testing.expect(a.artifacts.active == null);
        try testing.expect(a.notice_len > 0);
    }
}

test "artifact links retain opening peer ownership across split focus changes" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    var a: App = undefined;
    try setup(&a, gif_scene);
    defer a.deinit();
    a.splitPane(.horizontal);
    // New focused pane is a canvas; artifact-chat is the visible peer.
    artifacts.open(&a, "artifact-chat", "movie.gif");
    try testing.expect(a.artifacts.active != null);
    a.focusPane(0);
    try pump(&a);
    try testing.expectEqual(@as(usize, 1), Recorder.calls);
    try expectRead(&a, "/synthetic/project/movie.gif", 0);
}

test "artifact links destruction cancels queued handlers and late replies cannot reach a replacement transfer" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    var a: App = undefined;
    try setup(&a, gif_scene);
    defer a.deinit();
    artifacts.open(&a, "artifact-chat", "first.gif");
    const first_id = a.artifacts.request.?;
    a.artifacts.deinit(&a);
    try testing.expect(!a.engine.mux.pending.contains(first_id));
    artifacts.open(&a, "artifact-chat", "second.gif");
    try pump(&a);
    try testing.expectEqual(@as(usize, 1), Recorder.calls);
    try testing.expect(a.artifacts.active == null);
}

test "artifact links failed reads release active transfer for explicit retries" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    var a: App = undefined;
    try setup(&a, "{\"ReadAttachmentChunk\":{\"$err\":\"Synthetic jailed-host denial\"}}");
    defer a.deinit();
    for (1..4) |count| {
        artifacts.open(&a, "artifact-chat", "artifacts/promo.mp4");
        try pump(&a);
        try testing.expectEqual(count, try requestCount(&a));
        try testing.expect(a.artifacts.active == null);
        try testing.expect(a.artifacts.request == null);
        try containsNotice(&a, "host could not read");
    }
    try testing.expectEqual(@as(usize, 0), Recorder.calls);
}

test "artifact links unsupported files and safe viewer failures always report a notice" {
    const old = artifacts.handoff;
    artifacts.handoff = Recorder.save;
    defer artifacts.handoff = old;
    var a: App = undefined;
    try setup(&a, gif_scene);
    defer a.deinit();
    for ([_][]const u8{ "run.sh", "page.html", "drawing.svg", "executable.app", "file://remote/a.gif" }) |raw| {
        artifacts.open(&a, "artifact-chat", raw);
        try testing.expect(a.notice_len > 0);
    }
    try testing.expectEqual(@as(usize, 0), try requestCount(&a));
    Recorder.reject = true;
    artifacts.open(&a, "artifact-chat", "movie.gif");
    try pump(&a);
    try testing.expectEqual(@as(usize, 0), Recorder.calls);
    try containsNotice(&a, "could not be saved or opened");
    try testing.expect(a.artifacts.active == null);
}
