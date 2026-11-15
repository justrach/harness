//! Explicit-click, conversation-owned artifact downloads. Transported paths
//! are read ONLY by the owner's jailed engine RPC, never by this computer.
//! App must call artifacts.deinit(a) BEFORE engine/settings destruction.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const browser = @import("app_browser.zig");
const rpc = @import("rpc.zig");

pub const max_bytes = 32 * 1024 * 1024;
pub const chunk_bytes = 45_000;
pub const max_chunks = 1000;
const max_path = 4096;
const max_cached = 8;

pub const State = struct {
    active: ?*Transfer = null,
    request: ?u64 = null,
    // Only destinations created by this module are recorded/removed.
    cached: [max_cached]?[]u8 = @splat(null),

    /// Cancels the mux handler before freeing callback-owned memory. Queued
    /// replies can subsequently be pumped safely (their ids have no handler).
    pub fn deinit(s: *State, a: *App) void {
        s.cancel(a);
        for (&s.cached) |*entry| if (entry.*) |path| {
            std.Io.Dir.cwd().deleteFile(a.io, path) catch {};
            a.gpa.free(path);
            entry.* = null;
        };
    }

    pub fn cancel(s: *State, a: *App) void {
        if (s.request) |id| a.engine.cancel(id);
        s.request = null;
        if (s.active) |t| t.destroy(a.gpa);
        s.active = null;
    }
};

/// Complete cache-write + OS boundary. Tests replace this with a recorder;
/// it receives a GENERATED basename, not the transported name/path. Borrowed
/// bytes last only for this call. Default refuses all test/offscreen I/O.
pub var handoff: *const fn (*App, []const u8, []const u8) anyerror!void = cacheAndOpen;

const Kind = enum {
    mp4,
    mov,
    m4v,
    webm,
    png,
    jpg,
    gif,
    webp,
    avif,
    bmp,
    tiff,
    ico,
    pdf,

    fn extension(k: Kind) []const u8 {
        return @tagName(k);
    }

    fn acceptsMime(k: Kind, mime: []const u8) bool {
        const expected = switch (k) {
            .mp4, .m4v => "video/mp4",
            .mov => "video/quicktime",
            .webm => "video/webm",
            .png => "image/png",
            .jpg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .avif => "image/avif",
            .bmp => "image/bmp",
            .tiff => "image/tiff",
            .ico => "image/x-icon",
            .pdf => "application/pdf",
        };
        return std.ascii.eqlIgnoreCase(mime, expected) or
            (k == .m4v and std.ascii.eqlIgnoreCase(mime, "video/x-m4v")) or
            (k == .ico and std.ascii.eqlIgnoreCase(mime, "image/vnd.microsoft.icon"));
    }

    fn signature(k: Kind, bytes: []const u8) bool {
        return switch (k) {
            .mp4, .mov, .m4v => bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp"),
            .webm => std.mem.startsWith(u8, bytes, "\x1a\x45\xdf\xa3"),
            .png => std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n"),
            .jpg => std.mem.startsWith(u8, bytes, "\xff\xd8\xff"),
            .gif => std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a"),
            .webp => bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"),
            .avif => bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp") and
                (std.mem.eql(u8, bytes[8..12], "avif") or std.mem.eql(u8, bytes[8..12], "avis")),
            .bmp => std.mem.startsWith(u8, bytes, "BM"),
            .tiff => std.mem.startsWith(u8, bytes, "II\x2a\x00") or std.mem.startsWith(u8, bytes, "MM\x00\x2a"),
            .ico => std.mem.startsWith(u8, bytes, "\x00\x00\x01\x00"),
            .pdf => std.mem.startsWith(u8, bytes, "%PDF-"),
        };
    }
};

fn kind(path: []const u8) ?Kind {
    const ext = std.fs.path.extension(path);
    inline for ([_]Kind{ .mp4, .mov, .m4v, .webm, .png, .jpg, .gif, .webp, .avif, .bmp, .tiff, .ico, .pdf }) |value| {
        if (std.ascii.eqlIgnoreCase(ext, "." ++ @tagName(value))) return value;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".jpeg")) return .jpg;
    if (std.ascii.eqlIgnoreCase(ext, ".tif")) return .tiff;
    return null;
}

fn hex(c: u8) ?u8 {
    return if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else null;
}

/// Decode once into a fixed buffer, then validate the decoded path as well.
/// Encoded schemes, UNC paths, controls, query/fragment and malformed escapes
/// cannot bypass this gate. file:// accepts ONLY an empty authority.
fn localPath(raw: []const u8, buf: *[max_path]u8) ![]const u8 {
    if (raw.len == 0 or raw.len > max_path * 3) return error.InvalidLocalPath;
    var input = raw;
    var file_url = false;
    if (raw.len >= 7 and std.ascii.eqlIgnoreCase(raw[0..7], "file://")) {
        input = raw[7..];
        file_url = true;
        if (input.len == 0 or input[0] != '/') return error.RemoteFileAuthority;
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (n == buf.len) return error.InvalidLocalPath;
        var c = input[i];
        if (c == '%') {
            if (i + 2 >= input.len) return error.InvalidLocalPath;
            c = ((hex(input[i + 1]) orelse return error.InvalidLocalPath) << 4) | (hex(input[i + 2]) orelse return error.InvalidLocalPath);
            i += 2;
        }
        if (c < 0x20 or c == 0x7f or c == '\\' or c == '?' or c == '#' or c == '%') return error.InvalidLocalPath;
        buf[n] = c;
        n += 1;
    }
    const path = buf[0..n];
    if (n == 0 or !std.unicode.utf8ValidateSlice(path) or std.mem.startsWith(u8, path, "//")) return error.InvalidLocalPath;
    // Colon rejects URL/executable schemes, Windows device names and ADS.
    // POSIX absolute/relative paths are supported; Windows paths fail closed.
    if (std.mem.indexOfScalar(u8, path, ':') != null or path[0] == '~') return error.InvalidLocalPath;
    if (file_url and path[0] != '/') return error.InvalidLocalPath;
    if (path[n - 1] == '/') return error.InvalidLocalPath;
    return path;
}

/// Plausible local path, not a claim that its type is supported or it exists.
/// Unsupported local links are routed here too so the click shows a notice.
pub fn isLocal(raw: []const u8) bool {
    var buf: [max_path]u8 = undefined;
    _ = localPath(raw, &buf) catch return false;
    return true;
}

pub fn resolve(gpa: std.mem.Allocator, cwd: []const u8, raw: []const u8) ![]u8 {
    var buf: [max_path]u8 = undefined;
    const path = try localPath(raw, &buf);
    if (cwd.len == 0 or cwd.len > max_path or cwd[0] != '/' or std.mem.startsWith(u8, cwd, "//") or std.mem.indexOfScalar(u8, cwd, '\\') != null) return error.InvalidWorkingDirectory;
    const resolved = if (path[0] == '/') try gpa.dupe(u8, path) else try std.fs.path.resolvePosix(gpa, &.{ cwd, path });
    errdefer gpa.free(resolved);
    if (resolved.len > max_path) return error.InvalidLocalPath;
    // No client-side jail approximation: engine canonicalizes symlinks and
    // checks this resolved path against its uploads/chat-cwd allowlist.
    return resolved;
}

const Transfer = struct {
    parent: []u8,
    device: []u8,
    cwd: []u8,
    path: []u8,
    owner: browser.LinkOwner,
    file_kind: Kind,
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    chunks: usize = 0,

    fn destroy(t: *Transfer, gpa: std.mem.Allocator) void {
        gpa.free(t.parent);
        gpa.free(t.device);
        gpa.free(t.cwd);
        gpa.free(t.path);
        t.bytes.deinit(gpa);
        gpa.destroy(t);
    }

    fn owned(t: *const Transfer, a: *App) bool {
        const owner = browser.sourceOwner(a, t.parent) orelse return false;
        if (owner.tab != t.owner.tab or owner.pane != t.owner.pane or owner.project != t.owner.project) return false;
        const chat = a.findChat(t.parent) orelse return false;
        return std.mem.eql(u8, chat.device_id orelse return false, t.device) and
            std.mem.eql(u8, chat.cwd orelse return false, t.cwd);
    }
};

fn fail(a: *App, message: []const u8) void {
    a.artifacts.cancel(a);
    a.setNotice(message);
    a.redraw();
}

/// No render-time/prefetch entrypoint exists: only the explicit click calls
/// this function. A second click is rejected rather than creating more tasks.
pub fn open(a: *App, parent: []const u8, raw: []const u8) void {
    const owner = browser.sourceOwner(a, parent) orelse return a.setNotice("This artifact's conversation is no longer visible.");
    if (a.artifacts.active != null) return a.setNotice("An artifact is already downloading. Please wait.");
    const chat = a.findChat(parent) orelse return a.setNotice("The artifact's conversation is not available.");
    const device = chat.device_id orelse return a.setNotice("The artifact's host is not known yet.");
    const cwd = chat.cwd orelse return a.setNotice("The artifact's working folder is not known yet.");
    const path = resolve(a.gpa, cwd, raw) catch return a.setNotice("This artifact link is not a supported local path.");
    const file_kind = kind(path) orelse {
        a.gpa.free(path);
        return a.setNotice("This artifact type cannot be opened. Use a video, image, GIF or PDF link.");
    };
    if (!a.engine.up()) {
        a.gpa.free(path);
        return a.setNotice("Connect to the artifact's host before opening it.");
    }
    const t = createTransfer(a.gpa, parent, device, cwd, path, owner, file_kind) catch {
        a.gpa.free(path);
        return a.setNotice("Not enough memory to open this artifact.");
    };
    a.artifacts.active = t;
    a.setNotice("Downloading artifact from its host…");
    a.redraw();
    next(a);
}

// Takes ownership of path on success only.
fn createTransfer(gpa: std.mem.Allocator, parent: []const u8, device: []const u8, cwd: []const u8, path: []u8, owner: browser.LinkOwner, file_kind: Kind) !*Transfer {
    const t = try gpa.create(Transfer);
    errdefer gpa.destroy(t);
    const p = try gpa.dupe(u8, parent);
    errdefer gpa.free(p);
    const d = try gpa.dupe(u8, device);
    errdefer gpa.free(d);
    const c = try gpa.dupe(u8, cwd);
    t.* = .{ .parent = p, .device = d, .cwd = c, .path = path, .owner = owner, .file_kind = file_kind };
    return t;
}

fn next(a: *App) void {
    const t = a.artifacts.active orelse return;
    if (!t.owned(a)) return fail(a, "The artifact's conversation or host changed. Click its link again.");
    // Always address the OWNER, including local owners. Never retarget using
    // the selected chat or fall back to local filesystem reads.
    const id = a.send_(.{ .method = "ReadAttachmentChunk", .params = .{
        .path = t.path,
        .offset = t.offset,
        .targetDeviceId = t.device,
    } }, .of(App, a, onChunk));
    // Engine.call may synchronously call onChunk on a send error. Do not
    // dereference the freed transfer or resurrect its request in that case.
    if (a.artifacts.active != t) return;
    a.artifacts.request = id;
    if (id == null) fail(a, "The artifact download could not start.");
}

pub fn withinBudget(current: usize, incoming: usize, chunks: usize) bool {
    return chunks < max_chunks and incoming > 0 and incoming <= chunk_bytes and current <= max_bytes and incoming <= max_bytes -| current;
}

fn onChunk(a: *App, id: u64, reply: rpc.Reply) void {
    // A malformed streaming response to this unary RPC must not leave a
    // handler alive that could later act on a replacement transfer.
    if (reply == .item) a.engine.cancel(id);
    a.artifacts.request = null;
    const t = a.artifacts.active orelse return;
    if (!t.owned(a)) return fail(a, "The artifact's conversation or host changed. Click its link again.");
    const value = switch (reply) {
        .ok => |v| v,
        else => return fail(a, "The host could not read this artifact. It may be unavailable, outside its allowed folders, or unsupported by this engine."),
    };
    if (value != .object) return fail(a, "The host returned an invalid artifact chunk.");
    const o = value.object;
    const data = o.get("data") orelse return fail(a, "The host returned an invalid artifact chunk.");
    const done = o.get("done") orelse return fail(a, "The host returned an invalid artifact chunk.");
    const mime = o.get("mimeType") orelse return fail(a, "The host returned an invalid artifact type.");
    const offset = o.get("nextOffset") orelse return fail(a, "The host returned an invalid artifact offset.");
    if (data != .string or done != .bool or mime != .string or offset != .integer or offset.integer < 0) return fail(a, "The host returned an invalid artifact chunk.");
    if (!t.file_kind.acceptsMime(mime.string)) return fail(a, "The artifact's type does not match its link.");
    const decoder = std.base64.standard.Decoder;
    if (data.string.len > std.base64.standard.Encoder.calcSize(chunk_bytes)) return fail(a, "This artifact exceeds the download limit.");
    const size = decoder.calcSizeForSlice(data.string) catch return fail(a, "The host returned invalid artifact data.");
    if (!withinBudget(t.offset, size, t.chunks)) return fail(a, "This artifact exceeds the download limit.");
    if (@as(u64, @intCast(offset.integer)) != t.offset + size) return fail(a, "The host returned an invalid artifact offset.");
    var decoded: [chunk_bytes]u8 = undefined;
    decoder.decode(decoded[0..size], data.string) catch return fail(a, "The host returned invalid artifact data.");
    // Appending only decoded, bounded chunks avoids retaining base64 history
    // and handles padding on EACH chunk, not just the last one.
    t.bytes.appendSlice(a.gpa, decoded[0..size]) catch return fail(a, "Not enough memory to download this artifact.");
    t.offset += size;
    t.chunks += 1;
    if (!done.bool) return next(a);
    if (!t.file_kind.signature(t.bytes.items)) return fail(a, "The artifact's contents do not match its type.");
    if (!t.owned(a)) return fail(a, "The artifact's conversation changed before it could open.");
    var uuid: [36]u8 = undefined;
    var name: [64]u8 = undefined;
    const filename = std.fmt.bufPrint(&name, "artifact-{s}.{s}", .{ @import("ids.zig").uuid(a.io, &uuid), t.file_kind.extension() }) catch return fail(a, "The artifact cache is not available.");
    handoff(a, filename, t.bytes.items) catch return fail(a, "The artifact could not be saved or opened. Its safe cache may be unavailable or full.");
    a.artifacts.cancel(a);
    a.setNotice("Artifact opened in its default viewer.");
    a.redraw();
}

fn cacheAndOpen(a: *App, filename: []const u8, bytes: []const u8) !void {
    if (builtin.is_test or a.offscreen) return error.OffscreenHandoffRequiresRecorder;
    const dir = a.settings.dataDir() orelse return error.NoCacheDirectory;
    if (!std.fs.path.isAbsolute(dir)) return error.NoCacheDirectory;
    var slot: ?*?[]u8 = null;
    for (&a.artifacts.cached) |*entry| if (entry.* == null) {
        slot = entry;
        break;
    };
    const dest = slot orelse return error.CacheFull;
    const cache = try std.fs.path.join(a.gpa, &.{ dir, "artifact-cache" });
    defer a.gpa.free(cache);
    try std.Io.Dir.cwd().createDirPath(a.io, cache);
    const path = try std.fs.path.join(a.gpa, &.{ cache, filename });
    errdefer a.gpa.free(path);
    // Exclusive creation: never follow an existing file or overwrite one.
    // Generated basename and allowlisted extension cannot be executable.
    var created = false;
    // Outer error cleanup runs AFTER the inner handle has closed, including
    // on platforms that cannot unlink an open file.
    errdefer if (created) std.Io.Dir.cwd().deleteFile(a.io, path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(a.io, path, .{ .exclusive = true });
        created = true;
        defer file.close(a.io);
        try file.writeStreamingAll(a.io, bytes);
    }
    const url = try fileUrl(a.gpa, path);
    defer a.gpa.free(url);
    // Revalidate immediately before the OS boundary, after cache creation.
    const t = a.artifacts.active orelse return error.OwnerChanged;
    if (!t.owned(a)) return error.OwnerChanged;
    if (!@import("nanoui").shell.openUrl(url)) return error.OpenFailed;
    dest.* = path;
}

pub fn fileUrl(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidLocalPath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    const digits = "0123456789ABCDEF";
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else try out.appendSlice(gpa, &.{ '%', digits[c >> 4], digits[c & 15] });
    }
    return out.toOwnedSlice(gpa);
}
