//! GitHub fragments use the same numbered, syntax-colored rows as local diffs.
const std = @import("std");
const ui = @import("nanoui").ui;
const diff = @import("diff.zig");
const theme = @import("theme.zig");

pub fn draw(c: *ui.Context, k: theme.Colors, file: *const diff.File, available: f32) void {
    var widest: u32 = 1;
    var code_width: f32 = 0;
    var header_width: f32 = 0;
    var height: f32 = 4;
    for (file.hunks) |hunk| {
        height += 28;
        header_width = @max(header_width, c.text.width(hunk.header, .{ .size = 11, .mono = true }) + 24);
        for (hunk.lines) |line| {
            widest = @max(widest, line.old orelse 0, line.new orelse 0);
            code_width = @max(code_width, c.text.width(line.text, .{ .size = 12, .mono = true }));
            height += 21;
        }
    }
    const digits: f32 = @floatFromInt(std.fmt.count("{d}", .{widest}));
    const gutter = @max(36, digits * 6.6 + 14);
    const width = @max(available, @max(header_width, code_width + 2 * gutter + 3 + 28 + 12 + 16));
    // A real horizontal viewport: source lines stay intact in narrow panes,
    // while the file header and outer vertical list remain stationary.
    _ = c.open(.{ .direction = .column, .width = .fill, .height = .{ .px = height }, .scroll_x = true }, null);
    defer c.end();
    const content = ui.div(c).column().w(width).h(height).bg(k.ink(0.015));
    defer content.end();
    @import("view_diffs.zig").body(c, k, file);
}
