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
    preview_entry: ?*Entry = null, // borrows a ready, non-retired cache entry
    zoom: f32 = 1,
    center: ui.Point = .{ .x = 0.5, .y = 0.5 },
    drag: ?ui.Point = null,
    inspection: @import("image_inspection.zig").State = .{},
    focus_scope: @import("preview_focus.zig").State = .{},

    pub fn deinit(cache: *Cache) void {
        for (&cache.entries) |*slot| {
            if (slot.*) |e| e.release();
            slot.* = null;
        }
    }

    /// Keep frame-borrowed bytes until the central pre-tree reap boundary.
    pub fn reset(cache: *Cache) void {
        cache.preview_entry = null;
        cache.focus_scope = .{};
        cache.drag = null;
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
    const box = ui.div(c).column().wFull().gap(4).clip().control();
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
            })) {
                // The picture itself can be the top hit (not its prose
                // wrapper). Register that leaf as the same preview action.
                const picture_index: u32 = @intCast(c.nodes.items.len - 1);
                const picture = @import("preview_focus.zig").action(c, picture_index, k, c.print("Open image preview: {s}", .{alt}));
                ui.text(c, "Preview image", .{ .size = 10.5, .color = k.accent });
                if (picture or box.clicked()) {
                    c.focus = c.node(picture_index).id;
                    const cache = &a.panels.github_repository.images;
                    cache.preview_entry = image;
                    cache.zoom = 1;
                    cache.center = .{ .x = 0.5, .y = 0.5 };
                    cache.drag = null;
                    cache.inspection = .{};
                    cache.focus_scope = .{};
                    a.view.strip.focused = .host;
                    c.changed = true;
                }
                return;
            }
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

/// Run before workspace shortcuts: Escape belongs to the visible preview,
/// not the chat/composer underneath it. Hidden previews own no keyboard.
pub fn keys(c: *ui.Context, a: *@import("app.zig").App) bool {
    const cache = &a.panels.github_repository.images;
    if (cache.preview_entry == null or a.view.settings_open or a.view.strip.focused != .host or !@import("app_github_repository.zig").surface(a) or !@import("view_tab_strip.zig").hasHost(a)) return false;
    if (a.view.strip.expanded) |expanded| if (expanded != .host) return false;
    cache.focus_scope.keys(c);
    if (c.shortcut(.{ .key = ui.Shortcut.escape }) or c.input.key == .escape) {
        c.input.key = null;
        dismiss(c, cache);
    }
    return true;
}

/// A pane-local lightbox over the existing trusted cache. No URL fetch, file
/// read, new window or navigation is performed by preview/zoom/drag/close.
pub fn preview(c: *ui.Context, a: *@import("app.zig").App, k: theme.Colors, bounds: ?ui.Rect) void {
    const cache = &a.panels.github_repository.images;
    const image = cache.preview_entry orelse return;
    if (image.retired or image.status.load(.acquire) != .ready) {
        dismiss(c, cache);
        return;
    }
    if (a.view.strip.focused == .host and c.shortcut(.{ .key = ui.Shortcut.escape })) {
        dismiss(c, cache);
        return;
    }
    const r = bounds orelse return;
    cache.focus_scope.begin(c);
    ui.key(c, "github-image-lightbox");
    const card = ui.div(c).fixed().offset(r.x + 8, r.y + 8).size(@max(1, r.w - 16), @max(1, r.h - 16)).column().p(12).gap(10).rounded(8).bg(k.background).border(k.accent.alpha(0.4)).borderW(1).clip().control().layer(6);
    defer card.end();
    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        ui.text(c, "GitHub image preview", .{ .size = 12, .weight = .semibold, .color = k.text });
        ui.spacer(c);
        if (cache.focus_scope.button(c, k, "Close preview")) {
            dismiss(c, cache);
            return;
        }
    }
    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        if (cache.focus_scope.button(c, k, "Zoom out")) cache.zoom = @max(1, cache.zoom / 1.5);
        if (cache.focus_scope.button(c, k, "Zoom in")) cache.zoom = @min(4, cache.zoom * 1.5);
        if (cache.focus_scope.button(c, k, "Fit")) {
            cache.zoom = 1;
            cache.center = .{ .x = 0.5, .y = 0.5 };
        }
        ui.text(c, c.print("{d:.0}%", .{cache.zoom * 100}), .{ .size = 10.5, .color = k.muted });
    }
    ui.text(c, "Scroll or pinch to zoom · Drag to inspect · Esc to close", .{ .size = 10.5, .color = k.muted });
    const area = ui.div(c).column().wFull().grow().h(0).center().clip().control().wheel();
    defer area.end();
    const key = c.print("github-image:{x}:{x}", .{ std.hash.Wyhash.hash(0, image.url), image.hash });
    const natural = ui.imageSize(c, key, image.bytes) orelse return;
    const available_w = @max(1, r.w - 42);
    const available_h = @max(1, r.h - 148);
    const fit = @min(1, @min(available_w / natural.w, available_h / natural.h));
    const w = @max(1, natural.w * fit);
    const h = @max(1, natural.h * fit);
    const viewport = c.rects.get(c.node(area.index).id) orelse r;
    const part = @import("image_inspection.zig").update(c, cache, area.hovered(), .{
        .x = viewport.x + (viewport.w - w) / 2,
        .y = viewport.y + (viewport.h - h) / 2,
        .w = w,
        .h = h,
    });
    _ = ui.image(c, .{
        .key = key,
        .source = .{ .encoded = image.bytes },
        .box = .{ .w = w, .h = h },
        .part = part,
    });
}

fn dismiss(c: *ui.Context, cache: *Cache) void {
    cache.focus_scope.restore(c);
    cache.preview_entry = null;
    cache.drag = null;
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
