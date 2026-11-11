//! 1:1 iOS Liquid Glass surface catalog and rendering primitives.
//! Mirrors all 22 `GlassSurfaceId` specs verified in
//! `apps/nano/lean-proofs/Nano/IosLiquidGlassScroll.lean`:
//! - Zero interior `.bg(...)` wash and zero unfocused `.border(...)` when Reduce Transparency is off,
//!   so `nanoui`'s `glass.metal` (`fs_glass`) preserves live backdrop blur, Snell's-law $n=1.5$
//!   refraction, and Gaussian specular rim highlights.
//! - True circular SDF (`.circular()`) on `capsule` and `circle` pills, continuous squircle on panes.
//! - Tactile spring contraction (`0.92` / `0.94` / `0.96` / `0.98`, `1.0` under Reduce Motion)
//!   with light UIKit impact haptics on tap.
const std = @import("std");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const icons = @import("icons.zig");

pub const ShapeKind = enum {
    capsule,
    circle,
    squircle,

    pub fn usesCircularSdf(self: ShapeKind) bool {
        return self != .squircle;
    }
};

pub const PressRole = enum {
    none,
    circle,
    pill,
    chip,
    card,

    pub fn pressedScale(self: PressRole, reduced_motion: bool) f32 {
        if (reduced_motion) return 1.0;
        return switch (self) {
            .none => 1.0,
            .circle => 0.92,
            .pill => 0.94,
            .chip => 0.96,
            .card => 0.98,
        };
    }
};

pub const GlassSurfaceId = enum(u8) {
    home_zen_pill = 0,
    home_filter_pill = 1,
    home_customize_circle = 2,
    home_search_bar = 3,
    home_new_session_circle = 4,
    session_back_circle = 5,
    session_switcher_pill = 6,
    session_menu_circle = 7,
    session_jump_latest_circle = 8,
    composer_chip_model = 9,
    composer_chip_effort = 10,
    composer_chip_mode = 11,
    composer_chip_branch = 12,
    composer_shell_collapsed = 13,
    composer_shell_expanded = 14,
    composer_attach_circle = 15,
    composer_expand_circle = 16,
    composer_dictate_circle = 17,
    question_panel = 18,
    write_dock = 19,
    write_toolbar_pill = 20,
    org_picker_row = 21,
};

pub const GlassSurfaceSpec = struct {
    id: GlassSurfaceId,
    shape: ShapeKind,
    radius_pt: f32,
    min_height_pt: f32,
    role: PressRole,
    underlap_chrome: bool,
    interior_fill_alpha: f32 = 0.0,
    unfocused_border_width: f32 = 0.0,
};

pub const catalog = [22]GlassSurfaceSpec{
    .{ .id = .home_zen_pill, .shape = .capsule, .radius_pt = 18, .min_height_pt = 36, .role = .pill, .underlap_chrome = true },
    .{ .id = .home_filter_pill, .shape = .capsule, .radius_pt = 18, .min_height_pt = 36, .role = .chip, .underlap_chrome = true },
    .{ .id = .home_customize_circle, .shape = .circle, .radius_pt = 18, .min_height_pt = 36, .role = .circle, .underlap_chrome = true },
    .{ .id = .home_search_bar, .shape = .capsule, .radius_pt = 22, .min_height_pt = 44, .role = .none, .underlap_chrome = true },
    .{ .id = .home_new_session_circle, .shape = .circle, .radius_pt = 22, .min_height_pt = 44, .role = .circle, .underlap_chrome = true },
    .{ .id = .session_back_circle, .shape = .circle, .radius_pt = 18, .min_height_pt = 36, .role = .circle, .underlap_chrome = true },
    .{ .id = .session_switcher_pill, .shape = .capsule, .radius_pt = 18, .min_height_pt = 36, .role = .pill, .underlap_chrome = true },
    .{ .id = .session_menu_circle, .shape = .circle, .radius_pt = 18, .min_height_pt = 36, .role = .circle, .underlap_chrome = true },
    .{ .id = .session_jump_latest_circle, .shape = .circle, .radius_pt = 20, .min_height_pt = 40, .role = .circle, .underlap_chrome = true },
    .{ .id = .composer_chip_model, .shape = .capsule, .radius_pt = 20, .min_height_pt = 40, .role = .chip, .underlap_chrome = true },
    .{ .id = .composer_chip_effort, .shape = .capsule, .radius_pt = 20, .min_height_pt = 40, .role = .chip, .underlap_chrome = true },
    .{ .id = .composer_chip_mode, .shape = .capsule, .radius_pt = 20, .min_height_pt = 40, .role = .chip, .underlap_chrome = true },
    .{ .id = .composer_chip_branch, .shape = .capsule, .radius_pt = 20, .min_height_pt = 40, .role = .chip, .underlap_chrome = true },
    .{ .id = .composer_shell_collapsed, .shape = .squircle, .radius_pt = 24, .min_height_pt = 48, .role = .none, .underlap_chrome = true },
    .{ .id = .composer_shell_expanded, .shape = .squircle, .radius_pt = 22, .min_height_pt = 96, .role = .none, .underlap_chrome = true },
    .{ .id = .composer_attach_circle, .shape = .circle, .radius_pt = 18, .min_height_pt = 36, .role = .circle, .underlap_chrome = true },
    .{ .id = .composer_expand_circle, .shape = .circle, .radius_pt = 16, .min_height_pt = 32, .role = .circle, .underlap_chrome = true },
    .{ .id = .composer_dictate_circle, .shape = .circle, .radius_pt = 18, .min_height_pt = 36, .role = .circle, .underlap_chrome = true },
    .{ .id = .question_panel, .shape = .squircle, .radius_pt = 26, .min_height_pt = 88, .role = .card, .underlap_chrome = true },
    .{ .id = .write_dock, .shape = .squircle, .radius_pt = 28, .min_height_pt = 56, .role = .none, .underlap_chrome = false },
    .{ .id = .write_toolbar_pill, .shape = .capsule, .radius_pt = 18, .min_height_pt = 36, .role = .pill, .underlap_chrome = false },
    .{ .id = .org_picker_row, .shape = .squircle, .radius_pt = 14, .min_height_pt = 48, .role = .card, .underlap_chrome = false },
};

pub fn spec(id: GlassSurfaceId) GlassSurfaceSpec {
    return catalog[@intFromEnum(id)];
}

pub const tactile_spring: ui.Spring = .{ .response = 0.16, .damping = 0.85 };

/// Applies pure Liquid Glass material (or opaque surface fallback when Reduce Transparency is on)
/// onto `d`, strictly keeping `background == null` and unfocused `border == null` for native glass.
pub fn styleGlassDiv(
    c: *ui.Context,
    d: ui.Div,
    id: GlassSurfaceId,
    reduce_transparency: bool,
    tint: ui.Color,
    focused_border: ?ui.Color,
) ui.Div {
    const s = spec(id);
    var out = switch (s.shape) {
        .capsule, .circle => d.roundedFull().circular(),
        .squircle => d.rounded(s.radius_pt),
    };
    if (reduce_transparency) {
        out = out.bg(c.theme.surface).border(focused_border orelse c.theme.border).borderW(1);
    } else {
        out = out.glass(.{ .tint = tint });
        if (focused_border) |fb| out = out.border(fb).borderW(1);
    }
    return out;
}

/// Interactive circular Liquid Glass icon button (`36x36`, `40x40`, or `44x44`).
pub fn circleButton(
    c: *ui.Context,
    key_str: []const u8,
    id: GlassSurfaceId,
    icon_name: icons.Name,
    fg: ui.Color,
    reduce_transparency: bool,
    selected_tint: ?ui.Color,
) ui.Interaction {
    ui.key(c, key_str);
    const s = spec(id);
    const side = s.min_height_pt;
    const d = ui.div(c).row().itemsCenter().justifyCenter().w(side).h(side).control();
    const it = d.interaction();
    defer d.end();
    const press_tint = if (selected_tint) |st| st else ui.Color.white.alpha(if (it.pressed) 0.16 else 0.0);
    _ = styleGlassDiv(c, d, id, reduce_transparency, press_tint, null);
    const target_scale = if (it.pressed) s.role.pressedScale(c.reduced_motion) else 1.0;
    c.node(d.index).style.scale = if (c.reduced_motion) 1.0 else ui.spring(c, it.id, 0x6773_636c, target_scale, tactile_spring);
    icons.icon(c, icon_name, @round(side * 0.44), fg, 0);
    if (it.clicked) {
        c.changed = true;
        nanoui.haptics.impact(.light);
    }
    return it;
}

/// Interactive capsule Liquid Glass pill / chip (`Home` filters, `Session` switcher, `Composer` chips).
pub fn pillButton(
    c: *ui.Context,
    key_str: []const u8,
    id: GlassSurfaceId,
    icon_before: ?icons.Name,
    label: []const u8,
    icon_after: ?icons.Name,
    fg: ui.Color,
    selected: bool,
    accent: ui.Color,
    reduce_transparency: bool,
) ui.Interaction {
    ui.key(c, key_str);
    const s = spec(id);
    const d = ui.div(c).row().itemsCenter().gap(6).h(s.min_height_pt).px(13).control();
    const it = d.interaction();
    defer d.end();
    const tint = if (selected)
        accent.alpha(if (c.theme.dark) 0.28 else 0.18)
    else if (it.pressed)
        ui.Color.white.alpha(0.14)
    else
        ui.Color.transparent;
    _ = styleGlassDiv(c, d, id, reduce_transparency, tint, null);
    const target_scale = if (it.pressed) s.role.pressedScale(c.reduced_motion) else 1.0;
    c.node(d.index).style.scale = if (c.reduced_motion) 1.0 else ui.spring(c, it.id, 0x6770_6c6c, target_scale, tactile_spring);
    if (icon_before) |ib| icons.icon(c, ib, 14, if (selected) accent else fg, 0);
    if (label.len > 0) ui.text(c, label, .{ .size = 13.5, .weight = if (selected) .semibold else .medium, .color = fg });
    if (icon_after) |ia| icons.icon(c, ia, 12, fg.alpha(0.65), 0);
    if (it.clicked) {
        c.changed = true;
        nanoui.haptics.selection();
    }
    return it;
}

test "all 22 Liquid Glass surfaces preserve zero interior fill, zero unfocused border, and shape invariants" {
    for (catalog, 0..) |s, idx| {
        try testing.expectEqual(@as(usize, @intFromEnum(s.id)), idx);
        try testing.expectEqual(@as(f32, 0.0), s.interior_fill_alpha);
        try testing.expectEqual(@as(f32, 0.0), s.unfocused_border_width);
        try testing.expect(s.radius_pt > 0 and s.min_height_pt >= 32);
        switch (s.shape) {
            .capsule, .circle => {
                try testing.expect(s.shape.usesCircularSdf());
                try testing.expectApproxEqAbs(s.min_height_pt * 0.5, s.radius_pt, 0.01);
            },
            .squircle => try testing.expect(!s.shape.usesCircularSdf()),
        }
        try testing.expectEqual(@as(f32, 1.0), s.role.pressedScale(true));
        const active_scale = s.role.pressedScale(false);
        try testing.expect(active_scale >= 0.92 and active_scale <= 1.0);
    }
}
