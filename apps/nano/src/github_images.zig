//! Bounded native GitHub previews. Workers own only ref-counted image entries,
//! never an App/panel pointer; a closed or changed panel cannot receive a reply.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const urls = @import("github_image_url.zig");
const transport = @import("github_image_transport.zig");
const theme = @import("theme.zig");
const alloc = std.heap.page_allocator;
pub const max_images = 16;
const max_parallel = 4;
var active: std.atomic.Value(usize) = .init(0);

pub const Entry = struct {
    refs: std.atomic.Value(usize) = .init(1),
    status: std.atomic.Value(Status) = .init(.queued),
    url: []u8,
    bytes: []u8 = &.{},
    hash: u64 = 0,
    retired: bool = false, // UI-thread only
    pub const Status = enum(u8) { queued, loading, ready, failed };

    fn release(e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) != 1) return;
        alloc.free(e.url);
        alloc.free(e.bytes);
        alloc.destroy(e);
    }

    fn start(e: *Entry, io: std.Io) void {
        if (e.status.load(.acquire) != .queued) return;
        const running = active.fetchAdd(1, .acq_rel);
        if (running >= max_parallel) {
            _ = active.fetchSub(1, .acq_rel);
            return;
        }
        e.status.store(.loading, .release);
        _ = e.refs.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, work, .{ e, io }) catch {
            _ = active.fetchSub(1, .acq_rel);
            e.status.store(.failed, .release);
            e.release();
            return;
        };
        thread.detach();
    }

    fn work(e: *Entry, io: std.Io) void {
        defer e.release();
        defer _ = active.fetchSub(1, .acq_rel);
        const bytes = transport.fetch(alloc, io, e.url) catch {
            e.status.store(.failed, .release);
            return;
        };
        e.complete(bytes);
    }

    /// Takes owned bytes; the release store publishes immutable data to the UI.
    fn complete(e: *Entry, bytes: []u8) void {
        if (bytes.len == 0 or bytes.len > transport.max_bytes or !urls.raster(bytes)) {
            alloc.free(bytes);
            e.status.store(.failed, .release);
            return;
        }
        e.bytes = bytes;
        e.hash = std.hash.Wyhash.hash(0, bytes);
        e.status.store(.ready, .release);
    }
};

pub const Cache = struct {
    entries: [max_images]?*Entry = @splat(null),

    pub fn deinit(cache: *Cache) void {
        for (&cache.entries) |*slot| {
            if (slot.*) |e| e.release();
            slot.* = null;
        }
    }

    /// Keep frame-borrowed bytes until the central pre-tree reap boundary.
    pub fn reset(cache: *Cache) void {
        for (cache.entries) |slot| if (slot) |e| {
            e.retired = true;
        };
    }

    pub fn reap(cache: *Cache) void {
        for (&cache.entries) |*slot| if (slot.*) |e| {
            if (e.retired) {
                slot.* = null;
                e.release();
            }
        };
    }

    pub fn get(cache: *Cache, io: std.Io, url: []const u8, network: bool) ?*Entry {
        if (!urls.allowed(url)) return null;
        for (cache.entries) |slot| if (slot) |e| {
            if (!e.retired and std.mem.eql(u8, e.url, url)) {
                if (network) e.start(io);
                return e;
            }
        };
        for (&cache.entries) |*slot| if (slot.* == null) {
            const e = alloc.create(Entry) catch return null;
            const owned = alloc.dupe(u8, url) catch {
                alloc.destroy(e);
                return null;
            };
            e.* = .{ .url = owned };
            slot.* = e;
            if (network) e.start(io);
            return e;
        };
        return null;
    }

    pub fn seed(cache: *Cache, url: []const u8, bytes: []const u8) !void {
        if (!builtin.is_test) return error.TestOnly;
        const e = cache.get(std.testing.io, url, false) orelse return error.InvalidImage;
        if (e.status.load(.acquire) != .queued) return error.AlreadyLoaded;
        e.complete(try alloc.dupe(u8, bytes));
    }
};

pub fn draw(c: *ui.Context, a: *@import("app.zig").App, k: theme.Colors, src: []const u8, alt: []const u8, width: ?f32) void {
    const box = ui.div(c).column().wFull().gap(4).clip();
    defer box.end();
    const e = a.panels.github_repository.images.get(a.io, src, !a.offscreen and !builtin.is_test);
    if (e) |image| switch (image.status.load(.acquire)) {
        .ready => {
            const available = if (c.rects.get(c.node(box.index).id)) |r| r.w else @min(c.size.w, 480);
            if (ui.image(c, .{
                .key = c.print("github-image:{x}:{x}", .{ std.hash.Wyhash.hash(0, src), image.hash }),
                .source = .{ .encoded = image.bytes },
                .max_width = @max(1, @min(available, width orelse 800)),
                .max_height = 560,
                .scale = 1,
            })) return;
        },
        .queued, .loading => {
            ui.text(c, "Loading image…", .{ .size = 12, .color = k.muted });
            if (!a.offscreen and !builtin.is_test) c.frameIn(0.1);
            return;
        },
        .failed => {},
    };
    ui.text(c, c.print("Image unavailable{s}{s}", .{ if (alt.len > 0) ": " else "", alt }), .{ .size = 12, .color = k.muted, .wrap = true });
}

test "github images cache is bounded and retires late completions without app callbacks" {
    var cache: Cache = .{};
    defer cache.deinit();
    const url = "https://raw.githubusercontent.com/demo/repo/media/image.png";
    const e = cache.get(std.testing.io, url, false).?;
    try std.testing.expect(e == cache.get(std.testing.io, url, false).?);
    try std.testing.expect(cache.get(std.testing.io, "file:///private.png", false) == null);
    // A worker's independent ref survives reset/reap/panel teardown.
    _ = e.refs.fetchAdd(1, .monotonic);
    cache.reset();
    cache.reap();
    try std.testing.expect(cache.entries[0] == null);
    e.complete(try alloc.dupe(u8, "<svg>not a raster</svg>"));
    try std.testing.expectEqual(Entry.Status.failed, e.status.load(.acquire));
    e.release();
    for (0..max_images) |i| {
        var buf: [160]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "https://raw.githubusercontent.com/demo/repo/media/{d}.png", .{i});
        try std.testing.expect(cache.get(std.testing.io, src, false) != null);
    }
    try std.testing.expect(cache.get(std.testing.io, url, false) == null);
}
