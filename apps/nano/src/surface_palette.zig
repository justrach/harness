//! Harness's theme.rs glass recipes, on the original theme-owned roles.
//! No palette is re-authored for glass; opaque mode is an exact identity.
const std = @import("std");
const builtin = @import("builtin");
const theme = @import("theme.zig");
const Color = @import("nanoui").ui.Color;

pub fn requested(preference: ?[]const u8, recommended: bool) bool {
    const p = preference orelse return recommended;
    if (std.mem.eql(u8, p, "frosted")) return true;
    if (std.mem.eql(u8, p, "opaque")) return false;
    return recommended;
}

pub fn apply(k: theme.Colors, frosted: bool) theme.Colors {
    if (!frosted) return k;
    var out = k;
    out.frosted = true;
    const adverse: Color = if (k.dark) .white else .black;
    const native = builtin.os.tag == .macos or builtin.os.tag == .windows;
    out.shell = k.shell.alpha(coverage(k, k.shell, if (native) 0.80 else 1, adverse));
    // The sidebar is the shared window tint plus a wash, not a second
    // opaque flattened copy of that tint.
    out.sidebar = k.wash(0.05);
    const window = flatten(out.shell, adverse);
    out.composer = k.input_tint.alpha(coverage(k, k.input_tint, if (k.dark) k.input_tint.a else 0.30, window));
    out.overlay = k.overlay.alpha(coverage(k, k.overlay, if (k.dark) 0.50 else 0.85, adverse));
    out.card = k.shell.alpha(coverage(k, k.shell, 0.40, window));
    out.panel = k.background.alpha(0.40);
    return out;
}

pub fn popup(k: theme.Colors) theme.Colors {
    var out = k;
    if (k.frosted) {
        out.muted = k.text.alpha(0.64);
        out.faint = k.text.alpha(0.48);
    }
    return out;
}

/// `contrast_checked_tint_alpha`: the same 21 candidate opacities.
fn coverage(k: theme.Colors, tint: Color, base: f32, backdrop: Color) f32 {
    for (0..21) |step| {
        const a = base + (1 - base) * @as(f32, @floatFromInt(step)) / 20;
        const bg = flatten(tint.alpha(a), backdrop);
        if (contrast(k.text, bg) >= 4.5 and contrast(k.muted, bg) >= 3) return a;
    }
    return 1;
}

pub fn flatten(top: Color, background: Color) Color {
    return .{
        .r = top.r * top.a + background.r * (1 - top.a),
        .g = top.g * top.a + background.g * (1 - top.a),
        .b = top.b * top.a + background.b * (1 - top.a),
    };
}

fn luminance(c: Color) f32 {
    const linear = struct {
        fn channel(v: f32) f32 {
            return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        }
    };
    return 0.2126 * linear.channel(c.r) + 0.7152 * linear.channel(c.g) + 0.0722 * linear.channel(c.b);
}

pub fn contrast(foreground: Color, background: Color) f32 {
    const a = luminance(flatten(foreground, background));
    const b = luminance(background);
    return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
}

test "surface preference respects explicit choices and the theme's recommendation" {
    const t = std.testing;
    try t.expect(requested(null, true));
    try t.expect(!requested(null, false));
    try t.expect(requested("themeDefault", true));
    try t.expect(!requested("opaque", true));
    try t.expect(requested("frosted", false));
}

test "opaque palettes are unchanged and glass preserves theme hues with checked coverage" {
    for ([_]bool{ false, true }) |dark| {
        const k = theme.builtin(dark);
        try std.testing.expectEqualDeep(k, apply(k, false));
        const glass = apply(k, true);
        try std.testing.expect(glass.frosted);
        try std.testing.expectEqual(k.shell.r, glass.shell.r);
        try std.testing.expectEqual(k.shell.g, glass.shell.g);
        try std.testing.expectEqual(k.shell.b, glass.shell.b);
        const bg = flatten(glass.shell, if (dark) .white else .black);
        try std.testing.expect(contrast(k.text, bg) >= 4.5);
        try std.testing.expect(contrast(k.muted, bg) >= 3);
        try std.testing.expect(glass.composer.a < 1);
        try std.testing.expectEqual(k.text.alpha(0.64), popup(glass).muted);
        try std.testing.expectEqualDeep(k, popup(k));
    }
}
