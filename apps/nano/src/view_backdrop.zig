//! Bounded procedural animated ambient backdrop canvas for focused workspace panes
//! and static miniature scene thumbnails in Theme Studio / Settings › Appearance.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const custom_themes = @import("custom_themes.zig");

pub const max_draw_leaves: usize = 36;

pub fn isDisabledMotion(motion_key: []const u8) bool {
    return std.mem.eql(u8, motion_key, "off") or std.mem.eql(u8, motion_key, "none");
}

pub fn isStaticMotion(motion_key: []const u8) bool {
    return std.mem.eql(u8, motion_key, "static");
}

pub fn speedFactor(motion_key: []const u8) f32 {
    if (std.mem.eql(u8, motion_key, "subtle")) return 0.48;
    if (std.mem.eql(u8, motion_key, "lively")) return 1.45;
    if (isStaticMotion(motion_key) or isDisabledMotion(motion_key)) return 0;
    return 1.0;
}

/// Draw the configured ambient scene behind `focused()` pane content.
/// Emits 0 nodes when disabled or on default themes, and never schedules
/// background ticks when static, reduced-motion, unfocused, or sliding sidebar.
pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    const motion_key = a.settings.backdropMotionKey();
    if (isDisabledMotion(motion_key)) return;
    const opacity = a.settings.backdropOpacity();
    if (opacity <= 0.01) return;

    const theme_id = a.settings.themeId(k.dark);
    const spec = custom_themes.findBackdrop(theme_id, a.settings.backdropScene(), k) orelse return;

    var w: f32 = @max(200, c.size.w - a.view.sidebar_width);
    var h: f32 = @max(180, c.size.h - 44);
    if (c.stack.items.len > 0) {
        const parent = c.stack.items[c.stack.items.len - 1];
        if (c.rects.get(c.node(parent).id)) |r| {
            if (r.w > 1 and r.h > 1) {
                w = r.w;
                h = r.h;
            }
        }
    }

    const frozen = isStaticMotion(motion_key) or c.reduced_motion;
    const t: f32 = if (frozen) 0 else @floatCast(c.time * @as(f64, spec.speed * speedFactor(motion_key)));
    if (!frozen and c.input.window_active and a.view.sidebar_tween == null) {
        c.frameIn(1.0 / 24.0);
    }

    const gain = std.math.clamp(spec.intensity * opacity * (if (k.dark) @as(f32, 1.0) else 0.72), 0.05, 0.95);
    renderMotif(c, spec.motif, spec.primary, spec.secondary, w, h, t, gain, k.dark);
}

/// Compact static thumbnail preview of a scene motif (<= 10 leaves, zero frame wakeups).
pub fn miniature(c: *ui.Context, spec: custom_themes.BackdropSpec, w: f32, h: f32, dark: bool) void {
    const gain: f32 = if (dark) 0.85 else 0.72;
    switch (spec.motif) {
        .rain => {
            orb(c, w * 0.75, h * 0.28, h * 0.55, spec.primary.alpha(0.18 * gain));
            for (0..6) |i| {
                const f: f32 = @floatFromInt(i);
                const x = w * (0.12 + f * 0.14);
                const y = h * @mod(0.15 + f * 0.27, 0.65);
                capsule(c, x, y, 1.6, 10 + @mod(f, 3) * 4, 1, spec.secondary.alpha((0.28 + @mod(f, 2) * 0.14) * gain));
            }
        },
        .constellations => {
            orb(c, w * 0.5, h * 0.45, h * 0.6, spec.primary.alpha(0.16 * gain));
            const pts = [_][2]f32{ .{ 0.18, 0.34 }, .{ 0.36, 0.22 }, .{ 0.54, 0.46 }, .{ 0.72, 0.28 }, .{ 0.84, 0.62 }, .{ 0.28, 0.68 } };
            for (pts, 0..) |p, idx| {
                const sz: f32 = if (idx % 2 == 0) 3.0 else 2.2;
                orb(c, w * p[0], h * p[1], sz, (if (idx % 2 == 0) spec.primary else spec.secondary).alpha(0.75 * gain));
            }
            // Faint guide dots linking stars 0->1 and 2->3.
            orb(c, w * 0.27, h * 0.28, 1.3, spec.secondary.alpha(0.35 * gain));
            orb(c, w * 0.63, h * 0.37, 1.3, spec.primary.alpha(0.35 * gain));
        },
        .waves => {
            orb(c, w * 0.78, h * 0.25, h * 0.45, spec.secondary.alpha(0.20 * gain));
            for (0..6) |i| {
                const f: f32 = @floatFromInt(i);
                const col = if (i % 2 == 0) spec.primary else spec.secondary;
                const y = h * (0.48 + f * 0.085);
                const x = w * (0.04 + 0.06 * @sin(f * 1.4));
                capsule(c, x, y, w * 0.84, 4.5 - f * 0.3, 3, col.alpha((0.26 + f * 0.04) * gain));
            }
        },
        .fireflies => {
            orb(c, w * 0.3, h * 0.65, h * 0.5, spec.secondary.alpha(0.16 * gain));
            const orbs = [_][3]f32{ .{ 0.22, 0.35, 3.4 }, .{ 0.44, 0.62, 4.2 }, .{ 0.66, 0.28, 3.0 }, .{ 0.78, 0.56, 3.8 }, .{ 0.34, 0.48, 2.4 }, .{ 0.56, 0.72, 2.8 } };
            for (orbs, 0..) |o, i| {
                const col = if (i % 2 == 0) spec.primary else spec.secondary;
                orb(c, w * o[0], h * o[1], o[2], col.alpha(0.70 * gain));
            }
        },
        .petals => {
            orb(c, w * 0.28, h * 0.32, h * 0.5, spec.primary.alpha(0.18 * gain));
            for (0..7) |i| {
                const f: f32 = @floatFromInt(i);
                const x = w * (0.14 + f * 0.11);
                const y = h * @mod(0.18 + f * 0.23, 0.72);
                const col = if (i % 3 == 0) spec.secondary else spec.primary;
                capsule(c, x, y, 5.5 - @mod(f, 2), 3.0, 2, col.alpha(0.62 * gain));
            }
        },
        .aurora => {
            for (0..7) |i| {
                const f: f32 = @floatFromInt(i);
                const bw = w / 5.5;
                const x = (f - 0.5) * (w / 7.0);
                const col = spec.primary.mix(spec.secondary, f / 6.0);
                capsule(c, x, h * (0.06 + 0.06 * @sin(f)), bw, h * (0.55 + 0.15 * @cos(f)), bw * 0.4, col.alpha(0.24 * gain));
            }
        },
        .matrix => {
            orb(c, w * 0.5, h * 0.5, h * 0.7, spec.primary.alpha(0.12 * gain));
            for (0..6) |i| {
                const f: f32 = @floatFromInt(i);
                const x = w * (0.12 + f * 0.145);
                const y = h * (0.10 + @mod(f * 0.19, 0.45));
                capsule(c, x, y, 2.5, h * 0.36, 1.5, spec.primary.alpha(0.32 * gain));
            }
        },
        .ripples => {
            ring(c, w * 0.48, h * 0.52, h * 0.18, spec.primary.alpha(0.55 * gain));
            ring(c, w * 0.48, h * 0.52, h * 0.34, spec.primary.alpha(0.35 * gain));
            ring(c, w * 0.48, h * 0.52, h * 0.50, spec.secondary.alpha(0.22 * gain));
            orb(c, w * 0.74, h * 0.30, 5, spec.secondary.alpha(0.35 * gain));
        },
    }
}

fn renderMotif(c: *ui.Context, motif: custom_themes.Motif, primary: ui.Color, secondary: ui.Color, w: f32, h: f32, t: f32, gain: f32, dark: bool) void {
    switch (motif) {
        .rain => {
            orb(c, w * 0.82, h * 0.16, @min(w, h) * 0.42, primary.alpha(0.11 * gain));
            orb(c, w * 0.18, h * 0.78, @min(w, h) * 0.36, secondary.alpha(0.08 * gain));
            for (0..18) |i| {
                const f: f32 = @floatFromInt(i);
                const speed = 135.0 + @mod(f * 29.0, 90.0);
                const y = @mod(f * 53.0 + t * speed, h + 64.0) - 48.0;
                const x = @mod(w * (0.04 + f * 0.053) + t * 14.0, w);
                const len: f32 = 18.0 + @mod(f * 7.0, 20.0);
                const col = if (i % 3 == 0) secondary else primary;
                capsule(c, x, y, 1.5, len, 1, col.alpha((0.12 + @mod(f * 0.07, 0.14)) * gain));
            }
        },
        .constellations => {
            orb(c, w * 0.55, h * 0.32, @min(w, h) * 0.48, primary.alpha(0.09 * gain));
            orb(c, w * 0.22, h * 0.68, @min(w, h) * 0.36, secondary.alpha(0.08 * gain));
            const seeds = [_][2]f32{
                .{ 0.14, 0.22 }, .{ 0.26, 0.16 }, .{ 0.38, 0.29 }, .{ 0.51, 0.18 },
                .{ 0.64, 0.31 }, .{ 0.77, 0.19 }, .{ 0.88, 0.35 }, .{ 0.19, 0.54 },
                .{ 0.33, 0.48 }, .{ 0.46, 0.62 }, .{ 0.60, 0.51 }, .{ 0.74, 0.64 },
                .{ 0.85, 0.77 }, .{ 0.28, 0.81 },
            };
            for (seeds, 0..) |pt, i| {
                const f: f32 = @floatFromInt(i);
                const twinkle = 0.55 + 0.45 * @sin(t * (1.1 + @mod(f * 0.31, 0.9)) + f * 1.7);
                const sx = w * pt[0] + @sin(t * 0.2 + f) * 5.0;
                const sy = h * pt[1] + @cos(t * 0.17 + f * 0.8) * 4.0;
                const col = if (i % 3 == 0) secondary else primary;
                orb(c, sx, sy, 2.2 + @mod(f, 2.5), col.alpha(0.42 * twinkle * gain));
            }
            // Delicate dotted links across neighboring stars (4 segments x 3 midpoints = 12 leaves).
            const pairs = [_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 4, 5 }, .{ 8, 9 } };
            for (pairs) |pair| {
                const a_pt = seeds[pair[0]];
                const b_pt = seeds[pair[1]];
                for (1..4) |step| {
                    const u: f32 = @as(f32, @floatFromInt(step)) / 4.0;
                    const mx = w * (a_pt[0] + (b_pt[0] - a_pt[0]) * u);
                    const my = h * (a_pt[1] + (b_pt[1] - a_pt[1]) * u);
                    orb(c, mx, my, 1.3, secondary.alpha(0.18 * gain));
                }
            }
        },
        .waves => {
            orb(c, w * 0.76, h * 0.22, @min(w, h) * 0.30, secondary.alpha(0.10 * gain));
            for (0..22) |i| {
                const f: f32 = @floatFromInt(i);
                const band = @divFloor(i, 7);
                const col = if (band == 1) secondary else primary;
                const seg_w = w * 0.22;
                const x = @mod(f * (w * 0.17) + t * (16.0 + @as(f32, @floatFromInt(band)) * 7.0), w + seg_w) - seg_w * 0.5;
                const base_y = h * (0.52 + @as(f32, @floatFromInt(band)) * 0.14);
                const y = base_y + @sin(t * 0.9 + f * 0.85) * 10.0;
                capsule(c, x, y, seg_w, 5.0 - @as(f32, @floatFromInt(band)) * 0.8, 3, col.alpha((0.12 + 0.03 * @as(f32, @floatFromInt(band))) * gain));
            }
        },
        .fireflies => {
            orb(c, w * 0.24, h * 0.70, @min(w, h) * 0.42, secondary.alpha(0.09 * gain));
            orb(c, w * 0.78, h * 0.30, @min(w, h) * 0.34, primary.alpha(0.08 * gain));
            for (0..20) |i| {
                const f: f32 = @floatFromInt(i);
                const cx = w * @mod(0.11 + f * 0.137, 0.88);
                const cy = h * @mod(0.17 + f * 0.193, 0.82);
                const dx = @sin(t * (0.45 + @mod(f * 0.13, 0.4)) + f * 1.3) * 26.0;
                const dy = @cos(t * (0.38 + @mod(f * 0.11, 0.35)) + f * 0.9) * 22.0;
                const pulse = 0.40 + 0.60 * (0.5 + 0.5 * @sin(t * (1.2 + @mod(f * 0.21, 0.8)) + f));
                const col = if (i % 3 == 0) secondary else primary;
                orb(c, cx + dx, cy + dy, 3.0 + @mod(f, 3.0), col.alpha(0.46 * pulse * gain));
            }
        },
        .petals => {
            orb(c, w * 0.22, h * 0.20, @min(w, h) * 0.38, primary.alpha(0.10 * gain));
            for (0..20) |i| {
                const f: f32 = @floatFromInt(i);
                const fall = 32.0 + @mod(f * 9.0, 26.0);
                const y = @mod(f * 47.0 + t * fall, h + 40.0) - 24.0;
                const sway = @sin(t * 1.1 + f * 0.9) * 18.0;
                const x = @mod(w * (0.05 + f * 0.048) + t * 9.0 + sway, w);
                const col = if (i % 4 == 0) secondary else primary;
                capsule(c, x, y, 7.0 + @mod(f, 4.0), 3.6 + @mod(f, 2.0), 3, col.alpha((0.28 + @mod(f * 0.05, 0.18)) * gain));
            }
        },
        .aurora => {
            for (0..20) |i| {
                const f: f32 = @floatFromInt(i);
                const u = f / 19.0;
                const strip_w = w / 12.0;
                const drift = @sin(t * 0.45 + f * 0.4) * 14.0;
                const x = u * (w - strip_w * 0.4) + drift;
                const ribbon_h = h * (0.36 + 0.14 * @sin(t * 0.62 + f * 0.55));
                const y = h * (0.02 + 0.06 * @cos(t * 0.48 + f * 0.42));
                const col = primary.mix(secondary, u);
                const alpha = (if (dark) @as(f32, 0.13) else 0.10) * gain * (0.7 + 0.3 * @sin(t * 0.7 + f));
                capsule(c, x, y, strip_w, ribbon_h, strip_w * 0.45, col.alpha(alpha));
            }
        },
        .matrix => {
            orb(c, w * 0.5, h * 0.45, @min(w, h) * 0.50, primary.alpha(0.08 * gain));
            for (0..12) |col_idx| {
                const f: f32 = @floatFromInt(col_idx);
                const x = w * (0.06 + f * 0.08);
                const speed = 78.0 + @mod(f * 23.0, 56.0);
                const head_y = @mod(f * 61.0 + t * speed, h + 110.0) - 40.0;
                capsule(c, x, head_y - 36.0, 2.4, 34.0, 1.5, primary.alpha(0.14 * gain));
                capsule(c, x, head_y, 2.6, 5.0, 1.5, secondary.alpha(0.38 * gain));
            }
        },
        .ripples => {
            const centers = [_][3]f32{ .{ 0.32, 0.38, 0.0 }, .{ 0.68, 0.56, 1.3 }, .{ 0.48, 0.74, 2.5 } };
            for (centers, 0..) |ctr, ci| {
                for (0..4) |ring_i| {
                    const phase = @mod(t * 0.22 + ctr[2] + @as(f32, @floatFromInt(ring_i)) * 0.25, 1.0);
                    const r = 18.0 + phase * @min(w, h) * 0.34;
                    const fade = (1.0 - phase) * (0.28 * gain);
                    const col = if (ci == 1) secondary else primary;
                    ring(c, w * ctr[0], h * ctr[1], r, col.alpha(fade));
                }
            }
        },
    }
}

fn orb(c: *ui.Context, cx: f32, cy: f32, r: f32, col: ui.Color) void {
    if (col.a <= 0.002 or r <= 0) return;
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = cx - r, .y = cy - r },
        .width = .{ .px = r * 2 },
        .height = .{ .px = r * 2 },
        .background = col,
        .radius = r,
    }, .none, null);
}

fn capsule(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, radius: f32, col: ui.Color) void {
    if (col.a <= 0.002 or w <= 0 or h <= 0) return;
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = w },
        .height = .{ .px = h },
        .background = col,
        .radius = radius,
    }, .none, null);
}

fn ring(c: *ui.Context, cx: f32, cy: f32, r: f32, col: ui.Color) void {
    if (col.a <= 0.002 or r <= 1) return;
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = cx - r, .y = cy - r },
        .width = .{ .px = r * 2 },
        .height = .{ .px = r * 2 },
        .border = col,
        .border_width = 1.25,
        .radius = r,
    }, .none, null);
}
