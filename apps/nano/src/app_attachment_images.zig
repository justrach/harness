//! Host-jailed attachment read-back. Never open a transported local path.
const std = @import("std");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const attachments = @import("app_attachments.zig");
const refs = @import("attachment_refs.zig");

pub const Cache = struct {
    items: std.ArrayList(*Image) = .empty,
    generation: u64 = 0,

    pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
        for (cache.items.items) |image| image.destroy();
        cache.items.deinit(gpa);
    }
};

pub const Image = struct {
    app: *App,
    device: []u8,
    path: []u8,
    bytes: std.ArrayList(u8) = .empty,
    encoded: std.ArrayList(u8) = .empty,
    status: enum { loading, ready, failed } = .loading,
    request: ?u64 = null,
    offset: u64 = 0,
    chunks: usize = 0,
    used: u64 = 0,

    fn destroy(image: *Image) void {
        const gpa = image.app.gpa;
        gpa.free(image.device);
        gpa.free(image.path);
        image.bytes.deinit(gpa);
        image.encoded.deinit(gpa);
        gpa.destroy(image);
    }

    fn fail(image: *Image) void {
        image.request = null;
        image.status = .failed;
        image.encoded.clearAndFree(image.app.gpa);
        image.app.redraw();
    }

    fn next(image: *Image) void {
        const a = image.app;
        const local = if (a.device_id) |mine| std.mem.eql(u8, mine, image.device) else image.device.len == 0;
        image.request = a.send_(.{ .method = "ReadAttachmentChunk", .params = .{
            .path = image.path,
            .offset = image.offset,
            .targetDeviceId = if (local) @as(?[]const u8, null) else image.device,
        } }, .of(Image, image, onChunk));
        if (image.request == null) image.fail();
    }

    fn onChunk(image: *Image, _: u64, reply: rpc.Reply) void {
        image.request = null;
        const value = switch (reply) {
            .ok => |v| v,
            else => return image.fail(),
        };
        if (value != .object) return image.fail();
        const o = value.object;
        const data = o.get("data") orelse return image.fail();
        const done = o.get("done") orelse return image.fail();
        const mime = o.get("mimeType") orelse return image.fail();
        if (data != .string or done != .bool or mime != .string or !std.mem.startsWith(u8, mime.string, "image/")) return image.fail();
        if (!withinReadBudget(image.encoded.items.len, data.string.len, image.chunks)) return image.fail();
        image.chunks += 1;
        image.encoded.appendSlice(image.app.gpa, data.string) catch return image.fail();
        if (done.bool) {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(image.encoded.items) catch return image.fail();
            if (size == 0 or size > attachments.max_bytes) return image.fail();
            image.bytes.resize(image.app.gpa, size) catch return image.fail();
            decoder.decode(image.bytes.items, image.encoded.items) catch {
                image.bytes.clearAndFree(image.app.gpa);
                return image.fail();
            };
            image.encoded.clearAndFree(image.app.gpa);
            image.status = .ready;
            image.app.redraw();
            return;
        }
        const offset = o.get("nextOffset") orelse return image.fail();
        if (offset != .integer or offset.integer <= 0) return image.fail();
        const next_offset: u64 = @intCast(offset.integer);
        if (next_offset <= image.offset) return image.fail();
        image.offset = next_offset;
        image.next();
    }
};

/// Resolve the containing chat, not the focused pane or the message author.
pub fn get(a: *App, chat_id: ?[]const u8, path: []const u8) ?*Image {
    const chat = a.findChat(chat_id orelse return null) orelse return null;
    const device = chat.device_id orelse return null;
    return getDevice(a, device, path);
}

pub fn getDevice(a: *App, device: []const u8, path: []const u8) ?*Image {
    if (!refs.validPath(path) or !attachments.isImageName(path)) return null;
    const cache = &a.attachments.images;
    for (cache.items.items) |image| if (std.mem.eql(u8, image.device, device) and std.mem.eql(u8, image.path, path)) {
        image.used = cache.generation;
        return image;
    };
    if (!a.engine.up()) return null;
    const image = a.gpa.create(Image) catch return null;
    const dev = a.gpa.dupe(u8, device) catch {
        a.gpa.destroy(image);
        return null;
    };
    const ref = a.gpa.dupe(u8, path) catch {
        a.gpa.free(dev);
        a.gpa.destroy(image);
        return null;
    };
    image.* = .{ .app = a, .device = dev, .path = ref, .used = cache.generation };
    cache.items.append(a.gpa, image) catch {
        image.destroy();
        return null;
    };
    image.next();
    return image;
}

/// A frame's image nodes borrow encoded bytes. Evict only at the following
/// frame boundary, never from a render callback. Bound retained history to
/// two attachment budgets / 64 refs, while keeping currently drawn tiles.
pub fn reap(a: *App) void {
    const cache = &a.attachments.images;
    cache.generation += 1;
    var bytes: usize = 0;
    for (cache.items.items) |image| bytes += image.bytes.items.len + image.encoded.items.len;
    var i: usize = 0;
    while (i < cache.items.items.len) {
        const image = cache.items.items[i];
        if ((bytes > 2 * attachments.max_bytes or cache.items.items.len > 64) and image.used + 1 < cache.generation) {
            if (image.request) |id| a.engine.cancel(id);
            bytes -= image.bytes.items.len + image.encoded.items.len;
            _ = cache.items.orderedRemove(i);
            image.destroy();
        } else i += 1;
    }
}

pub fn withinReadBudget(encoded: usize, incoming: usize, chunks: usize) bool {
    const max_encoded = std.base64.standard.Encoder.calcSize(attachments.max_bytes);
    return chunks < 1000 and encoded <= max_encoded and incoming <= max_encoded -| encoded;
}

test "nano image parity read budget uses existing byte and chunk caps" {
    const t = std.testing;
    const max_encoded = std.base64.standard.Encoder.calcSize(attachments.max_bytes);
    try t.expect(withinReadBudget(0, max_encoded, 999));
    try t.expect(!withinReadBudget(0, max_encoded + 1, 0));
    try t.expect(!withinReadBudget(max_encoded, 1, 0));
    try t.expect(!withinReadBudget(0, 1, 1000));
    try t.expect(!withinReadBudget(std.math.maxInt(usize), 1, 0));
}
