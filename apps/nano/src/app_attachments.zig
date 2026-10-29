//! Composer intake and the same host-routed upload/text transport as
//! crates/ui/src/attachments.rs. Clipboard reads happen only on Paste.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const rpc = @import("rpc.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const max_bytes = 24 * 1024 * 1024;
const chunk_bytes = 510_000; // 680,000 base64 characters, below the relay ceiling.

pub const Paste = union(enum) {
    image: []u8,
    files: [][]u8,
    text: []u8,

    fn deinit(p: Paste, gpa: Allocator) void {
        switch (p) {
            .image, .text => |bytes| gpa.free(bytes),
            .files => |paths| nanoui.dialog.freePaths(gpa, paths),
        }
    }
};

/// Tests inject made-up clipboard content; never read the system clipboard.
pub const Source = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (?*anyopaque, Allocator) anyerror!?Paste,
};

pub const State = struct {
    items: std.ArrayList(*Item) = .empty,
    source: ?Source = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (s.items.items) |item| item.destroy();
        s.items.deinit(gpa);
        s.* = .{};
    }
};

pub const Item = struct {
    app: *App,
    owner: []u8,
    name: []u8,
    bytes: []u8,
    target: ?[]u8,
    id: [36]u8,
    path: ?[]u8 = null,
    status: enum { staged, uploading, ready, failed } = .staged,
    request: ?u64 = null,
    offset: usize = 0,
    seq: usize = 0,
    removed: bool = false,

    fn destroy(item: *Item) void {
        const gpa = item.app.gpa;
        gpa.free(item.owner);
        gpa.free(item.name);
        gpa.free(item.bytes);
        if (item.target) |t| gpa.free(t);
        if (item.path) |p| gpa.free(p);
        gpa.destroy(item);
    }

    pub fn active(item: *const Item, a: *const App) bool {
        return !item.removed and std.mem.eql(u8, item.owner, owner(a));
    }

    pub fn remove(item: *Item) void {
        item.removed = true;
        if (item.request) |id| item.app.engine.cancel(id);
        item.request = null;
        item.app.view.focus_composer = true;
        item.app.redraw();
    }

    pub fn start(item: *Item) void {
        if (!item.app.engine.up() or item.removed) return;
        item.status = .uploading;
        item.offset = 0;
        item.seq = 0;
        item.next();
    }

    fn next(item: *Item) void {
        const a = item.app;
        if (item.offset >= item.bytes.len) {
            item.request = a.send_(.{ .method = "UploadCommit", .params = .{
                .uploadId = @as([]const u8, &item.id),
                .fileName = item.name,
                .targetDeviceId = item.target,
            } }, .of(Item, item, committed));
            return;
        }
        const bytes = item.bytes[item.offset..@min(item.offset + chunk_bytes, item.bytes.len)];
        const encoder = std.base64.standard.Encoder;
        const data = a.gpa.alloc(u8, encoder.calcSize(bytes.len)) catch return item.failed("Couldn't prepare the attachment.");
        defer a.gpa.free(data);
        _ = encoder.encode(data, bytes);
        item.request = a.send_(.{ .method = "UploadChunk", .params = .{
            .uploadId = @as([]const u8, &item.id),
            .seq = item.seq,
            .data = data,
            .targetDeviceId = item.target,
        } }, .of(Item, item, chunked));
    }

    fn chunked(item: *Item, _: u64, reply: rpc.Reply) void {
        item.request = null;
        switch (reply) {
            .ok => {
                item.offset = @min(item.offset + chunk_bytes, item.bytes.len);
                item.seq += 1;
                item.next();
            },
            .err => |why| item.failed(why),
            else => {},
        }
    }

    fn committed(item: *Item, _: u64, reply: rpc.Reply) void {
        item.request = null;
        const v = switch (reply) {
            .ok => |v| v,
            .err => |why| return item.failed(why),
            else => return,
        };
        if (v == .object) if (v.object.get("path")) |p| if (p == .string and p.string.len > 0) {
            item.path = item.app.gpa.dupe(u8, p.string) catch return item.failed("Couldn't keep the uploaded attachment.");
            item.status = .ready;
            item.app.redraw();
            return;
        };
        item.failed("The upload returned no attachment path.");
    }

    fn failed(item: *Item, why: []const u8) void {
        item.status = .failed;
        item.app.setNotice(why);
        item.app.redraw();
    }
};

fn owner(a: *const App) []const u8 {
    return if (a.queue_edit) |e| e.row else a.selected orelse "";
}

fn host(a: *const App) ?[]const u8 {
    if (a.selected) |id| if (a.findChat(id)) |chat| if (chat.device_id) |device| {
        if (a.device_id) |mine| if (std.mem.eql(u8, mine, device)) return null;
        return device;
    };
    if (a.selected == null) if (a.newChatSpace()) |space| if (space.device_id) |device| {
        if (a.device_id) |mine| if (std.mem.eql(u8, mine, device)) return null;
        return device;
    };
    return null;
}

pub fn count(a: *const App) usize {
    var n: usize = 0;
    for (a.attachments.items.items) |item| if (item.active(a)) {
        n += 1;
    };
    return n;
}

/// Whether an attachment named `name` is a picture the composer previews
/// (`attachments::is_image_path`); anything else shows the file's icon,
/// without trying to decode it.
pub fn isImageName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
    }
    return false;
}

pub fn ready(a: *const App) bool {
    for (a.attachments.items.items) |item| if (item.active(a) and item.status != .ready) return false;
    return true;
}

pub fn stage(a: *App, name: []const u8, bytes: []const u8) !void {
    if (bytes.len == 0) return error.EmptyAttachment;
    if (bytes.len > max_bytes) return error.AttachmentTooLarge;
    const item = try a.gpa.create(Item);
    errdefer a.gpa.destroy(item);
    const key = try a.gpa.dupe(u8, owner(a));
    errdefer a.gpa.free(key);
    const label = try a.gpa.dupe(u8, name);
    errdefer a.gpa.free(label);
    const data = try a.gpa.dupe(u8, bytes);
    errdefer a.gpa.free(data);
    const target = if (host(a)) |h| try a.gpa.dupe(u8, h) else null;
    errdefer if (target) |h| a.gpa.free(h);
    item.* = .{ .app = a, .owner = key, .name = label, .bytes = data, .target = target, .id = undefined };
    _ = @import("ids.zig").uuid(a.io, &item.id);
    try a.attachments.items.append(a.gpa, item);
    item.start();
    a.view.focus_composer = true;
    a.redraw();
}

pub fn stageFile(a: *App, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(a.io, path, a.gpa, .limited(max_bytes));
    defer a.gpa.free(bytes);
    try stage(a, std.fs.path.basename(path), bytes);
}

pub fn pick(a: *App) void {
    if (a.offscreen) return;
    const paths = (nanoui.dialog.open(a.gpa, .{ .title = "Attach files", .button = "Attach", .multiple = true }) catch return) orelse return;
    defer nanoui.dialog.freePaths(a.gpa, paths);
    for (paths) |path| stageFile(a, path) catch {
        a.setNotice("Couldn't attach that file (24 MB maximum).");
    };
    a.redraw();
}

fn systemPaste(_: ?*anyopaque, gpa: Allocator) !?Paste {
    if (try nanoui.clipboard.readFiles(gpa)) |files| return .{ .files = files };
    if (try nanoui.clipboard.readImage(gpa)) |image| return .{ .image = image };
    if (try nanoui.clipboard.readText(gpa)) |text| return .{ .text = text };
    return null;
}

/// Consume Paste only in the composer. Text goes through the field's native
/// edit operation (selection/caret/undo), keeping newlines, unlike nanoui's
/// single-line clipboard fallback. No timer, background clipboard reads or
/// global shortcut that steals Paste from other fields.
pub fn paste(c: *ui.Context, a: *App) void {
    if (c.focus == 0 or c.focus != a.view.composer_id) return;
    const source = a.attachments.source orelse if (!a.offscreen) Source{ .read = systemPaste } else return;
    if (!c.shortcut(.{ .key = 'v', .cmd = true })) return;
    const value = (source.read(source.ctx, a.gpa) catch {
        a.setNotice("Couldn't read the clipboard.");
        return;
    }) orelse return;
    defer value.deinit(a.gpa);
    c.changed = true;
    switch (value) {
        .image => |bytes| stage(a, "image.png", bytes) catch {
            a.setNotice("Couldn't attach that image (24 MB maximum).");
        },
        .files => |paths| for (paths) |path| {
            stageFile(a, path) catch {
                a.setNotice("Couldn't attach that file (24 MB maximum).");
            };
        },
        .text => |text| {
            // Larger pastes become a lossless file instead of silently losing
            // the tail at the text field's 16 KB editing-buffer boundary.
            if (text.len > a.composer.buf.len - a.composer.len) {
                stage(a, "pasted-text.txt", text) catch {
                    a.setNotice("Couldn't attach the pasted text.");
                };
                return;
            }
            const ops = c.alloc().alloc(ui.TextOp, 1) catch return;
            const normalized = c.alloc().alloc(u8, text.len) catch return;
            var n: usize = 0;
            for (text, 0..) |ch, i| {
                if (ch == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
                normalized[n] = if (ch == '\r') '\n' else ch;
                n += 1;
            }
            ops[0] = .{ .insert = normalized[0..n] };
            c.input.ops = ops;
        },
    }
}

/// Same plain-text trailer the desktop persists and the agents understand.
/// Nothing sends until every active file has a committed host-side path.
pub fn prompt(a: *App, text: []const u8) !?[]u8 {
    if (count(a) == 0) return null;
    if (!ready(a)) return error.AttachmentsNotReady;
    var out: std.Io.Writer.Allocating = .init(a.gpa);
    errdefer out.deinit();
    try out.writer.writeAll(if (text.len > 0) text else "See the attached image(s).");
    try out.writer.writeAll("\n\nAttached images (local files — open them to view):");
    for (a.attachments.items.items) |item| if (item.active(a)) {
        try out.writer.print("\n- {s}", .{item.path.?});
    };
    return try out.toOwnedSlice();
}

pub fn clear(a: *App) void {
    for (a.attachments.items.items) |item| if (item.active(a)) item.remove();
}

/// Called at the frame boundary: the previous frame may still borrow a
/// thumbnail's encoded bytes after its remove button was clicked.
pub fn reap(a: *App) void {
    var i: usize = 0;
    while (i < a.attachments.items.items.len) {
        const item = a.attachments.items.items[i];
        if (item.removed) {
            _ = a.attachments.items.orderedRemove(i);
            item.destroy();
        } else {
            if (item.status == .staged) item.start();
            i += 1;
        }
    }
}
