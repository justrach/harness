//! Tooltips where the GPUI app has them (`.tooltip(..)` with its
//! `tooltip_show_delay`), in each one's own box, with a nanoui that has
//! tooltips (`ui.Div.tooltip`, justrach/nanoui); none before.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");

/// Whether this nanoui shows tooltips.
pub const has = @hasDecl(ui.Div, "tooltip");

/// GPUI's `DEFAULT_TOOLTIP_SHOW_DELAY`, and the 350 ms most of the app's
/// tooltips ask for (`tooltip_show_delay(Duration::from_millis(350))`).
pub const default_delay: f32 = 0.5;
pub const quick: f32 = 0.35;

/// Which tooltip box.
pub const Look = enum {
    /// `widgets::text_tooltip` (and its copies: the sidebar's view
    /// options, a code block's actions): max_w 280, px 8, py 6, rounded
    /// 6, a `border_strong` line, `surface_raised`, `shadow_md`, 11-point
    /// text.
    text,
    /// `QueueActionTooltip`: frosted (the popover's surface), a `border`
    /// line, px 8, py 5, 10.5-point muted text.
    queue,
    /// `FileEditorTooltip`: as `queue`, max_w 360, px 9, py 6.
    file,
    /// `SurfaceTabTooltip`: as `file`, max_w 380.
    tab,
};

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
    return switch (look) {
        .text => .{
            .delay = delay,
            .background = k.raised,
            .border = k.border_strong,
            .text = style(11, k.text, false),
        },
        .queue, .file, .tab => .{
            .delay = delay,
            .background = k.composer,
            .border = k.border,
            .padding = if (look == .queue) .xy(8, 5) else .xy(9, 6),
            .max_width = switch (look) {
                .file => 360,
                .tab => 380,
                else => 1e4,
            },
            .shadows = &.{},
            .text = style(10.5, k.muted, look == .file),
        },
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
    o.background = k.composer;
    o.padding = .xy(9, 7);
    o.max_width = 320;
    return d.tooltipWith(p, Project.draw, o);
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
