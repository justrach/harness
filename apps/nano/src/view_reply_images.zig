//! Reply pictures borrow the shared host-jailed attachment cache. Model text
//! never becomes a local filesystem read or an unauthenticated network fetch.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const refs = @import("attachment_refs.zig");
const images = @import("app_attachment_images.zig");

/// Only raster resources supported by the attachment transport. In particular
/// no SVG external resources, file: URLs, data: URLs or web fetches.
pub fn supported(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff" }) |suffix| {
        if (std.ascii.eqlIgnoreCase(ext, suffix)) return true;
    }
    return false;
}

/// Relative Markdown destinations belong to this chat's host cwd, never the
/// focused pane's cwd. The engine canonicalizes and jails the resulting path.
pub fn resolve(gpa: std.mem.Allocator, cwd: ?[]const u8, src: []const u8) ?[]const u8 {
    if (!supported(src) or std.mem.startsWith(u8, src, "//") or std.mem.startsWith(u8, src, "\\\\")) return null;
    if (refs.validPath(src)) return src;
    if (src.len == 0 or src[0] == '/' or src[0] == '\\' or std.mem.indexOfAny(u8, src, ":?#%") != null) return null;
    var parts = std.mem.tokenizeAny(u8, src, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return null;
    const root = cwd orelse return null;
    // Join using the owning host's separator, not this machine's platform.
    const path = std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ std.mem.trimEnd(u8, root, "/\\"), if (std.mem.indexOfScalar(u8, root, '\\') != null) "\\" else "/", src }) catch return null;
    return if (refs.validPath(path)) path else null;
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, src: []const u8, alt: []const u8, width: ?f32) void {
    const box = ui.div(c).column().wFull().gap(4).clip().control();
    defer box.end();
    const chat = if (chat_id) |id| a.findChat(id) else null;
    const path = resolve(c.alloc(), if (chat) |ch| ch.cwd else null, src);
    const loaded = if (path) |p| images.get(a, chat_id, p) else null;
    if (loaded) |image| {
        if (image.status == .ready) {
            const available = if (c.rects.get(c.node(box.index).id)) |r| r.w else @min(c.size.w, 480);
            // Never feed empty/partial bytes to nanoui: a failed decode under
            // that key would otherwise poison the later completed picture.
            if (ui.image(c, .{
                .key = c.print("reply:{s}:{s}:{x}", .{ image.device, image.path, image.content_hash }),
                .source = .{ .encoded = image.bytes.items },
                .max_width = @max(1, @min(available, width orelse 480)),
                .max_height = 360,
                .scale = 1,
            })) {
                const picture = c.interact(@intCast(c.nodes.items.len - 1), .{ .focusable = true });
                if (picture.clicked or box.clicked()) @import("view_image_preview.zig").open(a, chat_id, image);
                return;
            }
        } else if (image.status == .loading) {
            ui.text(c, "Loading image…", .{ .size = 12, .color = k.muted });
            return;
        }
    }
    ui.text(c, c.print("Image unavailable{s}{s}", .{ if (alt.len > 0) ": " else "", alt }), .{ .size = 12, .color = k.muted, .wrap = true });
}
