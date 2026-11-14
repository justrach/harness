//! Chat-owned inspection of bytes already loaded through the jailed host cache.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const images = @import("app_attachment_images.zig");

pub fn open(a: *App, chat_id: ?[]const u8, image: *images.Image) void {
    const chat = chat_id orelse return;
    if (image.status != .ready or image.bytes.items.len == 0) return;
    const owner = a.gpa.dupe(u8, chat) catch return;
    close(a);
    const cache = &a.attachments.images;
    cache.preview = image;
    cache.preview_chat = owner;
    cache.zoom = 1;
    cache.center = .{ .x = 0.5, .y = 0.5 };
    a.redraw();
}

pub fn close(a: *App) void {
    const cache = &a.attachments.images;
    cache.preview = null;
    if (cache.preview_chat) |chat| a.gpa.free(chat);
    cache.preview_chat = null;
    cache.drag = null;
    a.redraw();
}

pub fn visible(a: *const App) bool {
    const cache = &a.attachments.images;
    const chat = cache.preview_chat orelse return false;
    if (cache.preview == null or !@import("app_question.zig").ownsActivePane(a)) return false;
    return std.mem.eql(u8, chat, a.selected.?);
}

/// A hidden/background inspector never eats another pane's Escape or typing.
pub fn keys(c: *ui.Context, a: *App) bool {
    if (!visible(a)) return false;
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) close(a);
    return true;
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, bounds: ?ui.Rect) void {
    if (!visible(a)) return;
    const r = bounds orelse return;
    const cache = &a.attachments.images;
    const image = cache.preview orelse return;
    ui.key(c, "chat-image-preview");
    const card = ui.div(c).fixed().offset(r.x + 8, r.y + 8).size(@max(1, r.w - 16), @max(1, r.h - 16)).column().p(12).gap(10).rounded(8).bg(k.background).border(k.accent.alpha(0.4)).borderW(1).clip().control().layer(6);
    defer card.end();
    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        ui.text(c, "Image preview", .{ .size = 12, .weight = .semibold, .color = k.text });
        ui.spacer(c);
        if (button(c, k, "Close preview")) {
            close(a);
            return;
        }
    }
    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        if (button(c, k, "Zoom out")) cache.zoom = @max(1, cache.zoom / 1.5);
        if (button(c, k, "Zoom in")) cache.zoom = @min(4, cache.zoom * 1.5);
        if (button(c, k, "Fit")) {
            cache.zoom = 1;
            cache.center = .{ .x = 0.5, .y = 0.5 };
        }
        ui.text(c, c.print("{d:.0}%", .{cache.zoom * 100}), .{ .size = 10.5, .color = k.muted });
    }
    ui.text(c, "Drag to inspect · Esc to close", .{ .size = 10.5, .color = k.muted });
    const area = ui.div(c).column().wFull().grow().h(0).center().clip().control();
    defer area.end();
    const key = c.print("inspect:{s}:{s}:{x}", .{ image.device, image.path, image.content_hash });
    const natural = ui.imageSize(c, key, image.bytes.items) orelse return;
    const fit = @min(@max(1, r.w - 42) / natural.w, @max(1, r.h - 148) / natural.h);
    const w = @max(1, natural.w * fit);
    const h = @max(1, natural.h * fit);
    if (c.input.pressed and area.hovered()) cache.drag = c.input.mouse;
    if (!c.input.down) cache.drag = null;
    if (cache.drag) |last| {
        cache.center.x -= (c.input.mouse.x - last.x) / (w * cache.zoom);
        cache.center.y -= (c.input.mouse.y - last.y) / (h * cache.zoom);
        cache.drag = c.input.mouse;
    }
    const half = 0.5 / cache.zoom;
    cache.center.x = std.math.clamp(cache.center.x, half, 1 - half);
    cache.center.y = std.math.clamp(cache.center.y, half, 1 - half);
    _ = ui.image(c, .{
        .key = key,
        .source = .{ .encoded = image.bytes.items },
        .box = .{ .w = w, .h = h },
        .part = .{ cache.center.x - half, cache.center.y - half, cache.center.x + half, cache.center.y + half },
    });
}

fn button(c: *ui.Context, k: theme.Colors, label: []const u8) bool {
    ui.key(c, label);
    const b = ui.div(c).row().h(26).px(6).itemsCenter().rounded(5).bg(k.hover).control();
    defer b.end();
    ui.text(c, label, .{ .size = 10.5, .color = k.text });
    return b.clicked();
}
