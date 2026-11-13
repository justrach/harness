//! Tooltips where the GPUI app has them (`.tooltip(..)` with its
//! `tooltip_show_delay`), in each one's own box, with a nanoui that has
//! tooltips (`ui.Div.tooltip`, justrach/nanoui); none before.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");

/// Whether this nanoui shows tooltips.
pub const has = @hasDecl(ui.Div, "tooltip");

/// GPUI's `DEFAULT_TOOLTIP_SHOW_DELAY`, and the 350 ms most of the app's
/// tooltips ask for (`tooltip_show_delay(Duration::from_millis(350))`).
pub const default_delay: f32 = 0.5;
pub const quick: f32 = 0.35;

/// Action labels now share `popover::tooltip_surface`, including queue,
/// file and surface-tab labels. Keep the call-site names for rich-card callers.
pub const Look = enum { text, queue, file, tab };

const label_shadow = [_]ui.Shadow{.{ .color = .{ .a = 0.18 }, .y = 2, .blur = 6 }};

pub const Tip = struct {
    text: []const u8,
    delay: f32 = default_delay,
    look: Look = .text,
};

/// GPUI's line for `size`-point text (`phi` times it, on the device pixel).
fn line(size: f32) f32 {
    return @round(size * 1.618 * 2) / 2;
}

/// `size`-point text in `color` on GPUI's line. A tooltip is laid out as a
/// root of its own, so it is in the window's font, the system's, unless it
/// sets the app's (`FileEditorTooltip` does: `app_font`).
fn style(size: f32, color: ui.Color, app_font: bool) ui.TextStyle {
    var s: ui.TextStyle = .{ .size = size, .line_height = line(size), .color = color };
    if (comptime @hasField(ui.TextStyle, "system_font")) s.system_font = !app_font;
    return s;
}

/// `d` with the tooltip `t` (nothing for an empty text).
pub fn on(d: ui.Div, k: theme.Colors, t: Tip) ui.Div {
    if (comptime !has) return d;
    if (t.text.len == 0) return d;
    return d.tooltip(t.text, options(k, t.look, t.delay));
}

/// The box and text of `look`.
pub fn options(k: theme.Colors, look: Look, delay: f32) if (has) ui.TooltipOptions else void {
    if (comptime !has) return;
    _ = k;
    _ = look;
    // Theme::tooltip_colors is deliberately the same opaque charcoal in
    // light and dark appearances, independent of popup/glass surface roles.
    return .{
        .delay = delay,
        .background = ui.Color.hex(0x282828),
        .border = ui.Color.hex(0x383838),
        .padding = .xy(12, 5),
        .radius = 13,
        .max_width = 380,
        .shadows = &label_shadow,
        .text = .{ .size = 13, .line_height = 18, .color = ui.Color.hex(0xf8f8f8) },
    };
}

/// `ProjectIconTooltip` (shell/project_icon.rs): the project's name over
/// its device, in a frosted card (max_w 320, px 9, py 7, gap 3, a
/// `border_strong` line, `shadow_md`), after 350 ms.
pub fn project(c: *ui.Context, d: ui.Div, k: theme.Colors, name: []const u8, device: []const u8) ui.Div {
    if (comptime !has) return d;
    // Drawn after the view: kept in the frame's memory till then.
    const p = c.alloc().create(Project) catch return d;
    p.* = .{ .name = name, .device = device, .k = k };
    var o = options(k, .text, quick);
    // Project previews remain rich cards, not compact action labels.
    o.background = k.composer;
    o.border = k.border_strong;
    o.padding = .xy(9, 7);
    o.radius = 6;
    o.shadows = &ui.Shadow.md;
    o.max_width = 320;
    return d.tooltipWith(p, Project.draw, o);
}

test "compact action tooltips use the shared opaque app-font bubble in both appearances" {
    if (comptime !has) return error.SkipZigTest;
    for ([_]bool{ false, true }) |dark| {
        for ([_]Look{ .text, .queue, .file, .tab }) |look| {
            const o = options(theme.colors(dark), look, quick);
            try std.testing.expectEqual(ui.Color.hex(0x282828), o.background.?);
            try std.testing.expectEqual(ui.Color.hex(0x383838), o.border.?);
            try std.testing.expectEqual(ui.Color.hex(0xf8f8f8), o.text.color.?);
            try std.testing.expectEqual(@as(f32, 13), o.text.size);
            try std.testing.expectEqual(@as(f32, 18), o.text.line_height);
            try std.testing.expect(!o.text.system_font);
            try std.testing.expectEqual(@as(f32, 12), o.padding.left);
            try std.testing.expectEqual(@as(f32, 5), o.padding.top);
            try std.testing.expectEqual(@as(f32, 13), o.radius);
            try std.testing.expectEqual(@as(f32, 380), o.max_width);
            try std.testing.expectEqual(quick, o.delay);
            try std.testing.expectEqual(@as(usize, 1), o.shadows.len);
            try std.testing.expectEqual(label_shadow[0], o.shadows[0]);
        }
    }
}

const Project = struct {
    name: []const u8,
    device: []const u8,
    k: theme.Colors,

    fn draw(p: *Project, c: *ui.Context) void {
        const col = ui.div(c).column().gap(3);
        defer col.end();
        var name = style(11, p.k.text, false);
        name.weight = .medium;
        name.truncate = .ellipsis;
        var device = style(11, p.k.muted, false);
        device.truncate = .ellipsis;
        ui.text(c, p.name, name);
        ui.text(c, p.device, device);
    }
};
