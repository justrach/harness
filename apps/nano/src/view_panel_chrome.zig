//! The panel writing plane, kept separate from shell/strip colors. Desktop
//! panel_surface.rs owns one selected-tab/body contour; these retained boxes
//! use the same radii, fills, hairline opacity and two-layer shadow.
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const chrome = @import("panel_chrome.zig");

const dark_shadow = [_]ui.Shadow{
    .{ .color = .{ .a = 0.40 }, .y = 3, .blur = 7.68 },
    .{ .color = .{ .a = 0.36 }, .y = 1, .blur = 2.24 },
};
const light_shadow = [_]ui.Shadow{
    .{ .color = .{ .a = 0.11 }, .y = 3, .blur = 7.68 },
    .{ .color = .{ .a = 0.12 }, .y = 1, .blur = 2.24 },
};

pub fn edge(k: theme.Colors) ui.Color {
    return k.border.alpha(k.border.a * (if (k.dark) @as(f32, 0.72) else 0.55));
}

pub fn body(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().bg(k.background).border(edge(k)).borderW(1).p(1).rounded(chrome.body_radius)
        .shadows(if (k.dark) &dark_shadow else &light_shadow);
}

/// Join before panel content, outside its rounded clip: the selected cap and
/// inverse-circle shoulders erase only the body's top rule. No overlay paints
/// over a toolbar, transcript, native browser or the title's hit target.
pub fn join(c: *ui.Context, k: theme.Colors, panel_width: f32, selected_left: f32, selected_right: f32) void {
    const flush_left = selected_left < chrome.body_radius + chrome.shoulder;
    const flush_right = selected_right > panel_width - chrome.body_radius - chrome.shoulder;
    // The body's p(1) content origin is a point inside its outer bounds.
    const left = (if (flush_left) @as(f32, 0) else selected_left) - 1;
    const right = (if (flush_right) panel_width else selected_right) - 1;
    const top = chrome.tab_top - chrome.header_height - 1;
    const foot: f32 = -1;
    const r = chrome.shoulder;
    if (right - left < 20) return;
    // GPUI shadows the selected cap as well as the body. Keep this outside
    // the cap's clip and before every opaque fill; title layout is untouched.
    ui.key(c, "panel-selected-cap-shadow");
    ui.div(c).absolute().offset(left, top).size(right - left, foot - top).rounded(10)
        .shadows(if (k.dark) &dark_shadow else &light_shadow).end();
    {
        // Only the top half of the rounded box: the shoulder, not a second
        // convex bottom corner, supplies its foot.
        const cap = ui.div(c).absolute().offset(left, top).size(right - left, foot - r - top).clip();
        defer cap.end();
        ui.div(c).absolute().offset(0, 0).size(right - left, foot - top + 20).rounded(10).border(edge(k)).borderW(1).bg(k.background).end();
    }
    ui.div(c).absolute().offset(left + 1, foot - r).size(right - left - 2, r + 2).bg(k.background).end();
    if (flush_left) {
        // First tab and body have the same straight leading edge.
        ui.div(c).absolute().offset(left + 1, foot).size(@min(chrome.body_radius, right - left - 2), chrome.body_radius + 1).bg(k.background).end();
        ui.div(c).absolute().offset(left, foot - r).size(1, r + chrome.body_radius + 1).bg(edge(k)).end();
    } else shoulder(c, k, left - r, foot - r, true);
    if (flush_right) {
        ui.div(c).absolute().offset(right - chrome.body_radius, foot).size(chrome.body_radius - 1, chrome.body_radius + 1).bg(k.background).end();
        ui.div(c).absolute().offset(right - 1, foot - r).size(1, r + chrome.body_radius + 1).bg(edge(k)).end();
    } else shoulder(c, k, right - 1, foot - r, false);
}

test "selected panel cap carries both surface shadows before its opaque fill" {
    const testing = @import("std").testing;
    const Fixture = struct {
        fn draw(dark: *bool, c: *ui.Context) void {
            const k = theme.colors(dark.*);
            const plane = body(c, k).absolute().offset(20, 60).size(400, 200);
            defer plane.end();
            join(c, k, 400, 24, 220);
        }
    };
    for ([_]bool{ false, true }) |appearance| {
        var dark = appearance;
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&dark, Fixture.draw), .{ .width = 480, .height = 300, .dark = dark });
        defer t.deinit();
        t.settle(0.1);
        const shadows = if (dark) &dark_shadow else &light_shadow;
        var count: usize = 0;
        for (t.ctx.nodes.items, 0..) |node, i| {
            if (node.style.shadows.len != shadows.len) continue;
            try testing.expectEqualSlices(ui.Shadow, shadows, node.style.shadows);
            count += 1;
            if (count == 2) {
                try testing.expect(node.style.background == null);
                try testing.expect(node.rect.y < 60);
                // The clipped cap and its fill follow the shadow sibling.
                try testing.expectEqual(node.rect.y, t.ctx.nodes.items[i + 1].rect.y);
                try testing.expectEqual(theme.colors(dark).background, t.ctx.nodes.items[i + 2].style.background.?);
            }
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
}

fn shoulder(c: *ui.Context, k: theme.Colors, x: f32, y: f32, leading: bool) void {
    const r = chrome.shoulder;
    const quadrant = ui.div(c).absolute().offset(x, y).size(r + 1, r + 1).bg(k.background).clip();
    defer quadrant.end();
    ui.div(c).absolute().offset(if (leading) -r else 0, -r).size(2 * r, 2 * r).rounded(r).border(edge(k)).borderW(1).bg(k.shell).end();
}
