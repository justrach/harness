//! The desktop's 56-point removable attachment tiles, wrapping at the pill.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const theme = @import("theme.zig");

pub fn strip(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const n = attachments.count(a);
    if (n == 0) return;
    const items = c.alloc().alloc(*attachments.Item, n) catch return;
    var at: usize = 0;
    for (a.attachments.items.items) |item| if (item.active(a)) {
        items[at] = item;
        at += 1;
    };
    const per_row: usize = @intFromFloat(@max(1, @floor((w - 32 + 8) / 64)));
    const area = ui.div(c).column().wFull().px(16).pt(12).gap(8);
    defer area.end();
    var row: usize = 0;
    while (row < items.len) : (row += per_row) {
        const line = ui.div(c).row().gap(8);
        defer line.end();
        for (items[row..@min(row + per_row, items.len)]) |item| {
            ui.key(c, &item.id);
            const tile = ui.div(c).column().w(56).gap(2);
            defer tile.end();
            {
                const thumb = ui.div(c).row().size(56, 56).center().rounded(8).border(if (item.status == .failed) k.danger else k.border).bg(k.hover).clip();
                defer thumb.end();
                picture(c, k, &item.id, item.name, item.preview());
                if (item.status != .ready or (attachments.isImageName(item.name) and item.preview().len == 0)) {
                    const state = ui.div(c).row().absolute().offset(38, 38).size(18, 18).center().roundedFull().bg(k.composer);
                    defer state.end();
                    icons.icon(c, if (item.status == .failed) .refresh else .@"clock-circle", 12, if (item.status == .failed) k.danger else k.muted, 0);
                }
                if (item.status == .failed and thumb.clicked()) item.start();
            }
            kit.ellipsisText(c, item.name, .{ .size = 10, .line_height = 12, .color = k.muted }, 56);
            const remove = ui.div(c).row().absolute().offset(40, 0).size(16, 16).center().roundedFull().bg(k.composer).hover(k.hover);
            defer remove.end();
            icons.icon(c, .close, 10, k.muted, 0);
            if (remove.clicked()) {
                item.remove();
                c.changed = true;
            }
        }
    }
}

/// Identical 56-point picture content for staged, restored and sent refs.
/// Empty/unavailable read-back stays a file tile, not a raw transport path.
pub fn picture(c: *ui.Context, k: theme.Colors, key: []const u8, name: []const u8, bytes: []const u8) void {
    // A full screenshot decoded on the main thread blocks the window
    // (ImageIO thumbnail) for every key. A 56-point tile does not need
    // that. Draw the file glyph until a small preview already exists.
    if (bytes.len > 0 and bytes.len <= 256 * 1024 and (attachments.isImageName(name) or std.mem.endsWith(u8, key, ".jpg"))) {
        if (ui.image(c, .{ .key = key, .bytes = bytes, .max_width = 56, .max_height = 56, .radius = 6, .scale = 1 })) return;
    }
    icons.icon(c, .document, 24, k.muted, 0);
}
