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
                const image = attachments.isImageName(item.name) and ui.image(c, .{ .key = &item.id, .bytes = item.bytes, .max_width = 56, .max_height = 56, .radius = 6, .scale = 1 });
                if (!image) icons.icon(c, .document, 24, k.muted, 0);
                if (item.status != .ready) {
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
