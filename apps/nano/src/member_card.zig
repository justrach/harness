//! Interactive Harness member card: 20 original Codegraff × Ensō layered
//! Japanese artworks paired with 8 composable Ensō brushstrokes, 5 holographic
//! finishes (including Kumiko star-lattice foil), and 8 Hanko seals
//! (`card_scenes_data` — 128,000 unique combinations; 3,200 1-of-1 three-layer
//! artworks for founders), Seigaiha silkscreen wave + sunago gold-dust sky
//! overlay under parallax-shifted cutouts, 7-stop `#f4efe6` washi paper fade,
//! member number (`000·XXX`), join date, 3D perspective turn/lift motion, and
//! deal-in foil sweep.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const ascii = @import("ascii_field.zig");
const WireCardTraits = @import("app_account.zig").WireCardTraits;
const scenes_data = @import("card_scenes_data");

pub const base_w: f32 = 300;
pub const base_h: f32 = 420;
pub const preview_zoom: f32 = 0.6;
pub const scene_count: u32 = scenes_data.count;
pub const enso_count: u32 = scenes_data.enso_count;
pub const Enso = scenes_data.Enso;
pub const Scene = scenes_data.Scene;

pub const sky_grid_w: usize = 48;
pub const sky_grid_h: usize = 64;

const paper_bg = ui.Color.hex(0xf4efe6);
const paper_stops = [_]ui.GradientStop{
    .{ .at = 0.28, .color = paper_bg.alpha(0.0) },
    .{ .at = 0.38, .color = paper_bg.alpha(26.0 / 255.0) },
    .{ .at = 0.46, .color = paper_bg.alpha(77.0 / 255.0) },
    .{ .at = 0.54, .color = paper_bg.alpha(153.0 / 255.0) },
    .{ .at = 0.61, .color = paper_bg.alpha(209.0 / 255.0) },
    .{ .at = 0.68, .color = paper_bg.alpha(240.0 / 255.0) },
    .{ .at = 0.76, .color = paper_bg.alpha(1.0) },
};

pub fn slug(index: u32) []const u8 {
    return scenes_data.scenes[index % scene_count].slug;
}

pub fn title(index: u32) []const u8 {
    return scenes_data.scenes[index % scene_count].title;
}

pub fn finish(index: u32) []const u8 {
    return scenes_data.scenes[index % scene_count].finish;
}

pub fn ensoLabel(index: u32) []const u8 {
    return scenes_data.ensos[index % enso_count].label;
}

pub const SkyCache = struct {
    buf: []u8 = &.{},
    w_px: u32 = 0,
    h_px: u32 = 0,
    scene: u32 = 0,
    sky_seed: u32 = 0,
    scale_q: u32 = 0,

    pub fn deinit(self: *SkyCache, gpa: Allocator) void {
        if (self.buf.len > 0) gpa.free(self.buf);
        self.* = .{};
    }
};

pub const FoilCache = struct {
    buf: []u8 = &.{},
    w_px: u32 = 0,
    h_px: u32 = 0,
    holo: ascii.Holo = .aurora,
    hx_q: u16 = 0,
    hy_q: u16 = 0,
    strength_q: u16 = 0,
    scale_q: u16 = 0,

    pub fn deinit(self: *FoilCache, gpa: Allocator) void {
        if (self.buf.len > 0) gpa.free(self.buf);
        self.* = .{};
    }
};

pub const State = struct {
    sky: SkyCache = .{},
    foil: FoilCache = .{},
    hover_x: f32 = 0.5,
    hover_y: f32 = 0.5,
    tilt_x: f32 = 0.5,
    tilt_y: f32 = 0.5,
    foil_strength: f32 = 0,
    hover_lift: f32 = 0,
    hovered: bool = false,
    seeded: bool = false,
    seed_hash: u32 = 0,
    arrive_at: f64 = 0,
    glint_at: f64 = -10.0,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.sky.deinit(gpa);
        s.foil.deinit(gpa);
        s.* = .{};
    }
};

pub const Props = struct {
    seed: []const u8,
    name: []const u8,
    member_number: ?u64 = null,
    started_at: ?i64 = null,
    card_scenes: ?u32 = null,
    card_traits: ?WireCardTraits = null,
    preview: bool = false,
    zoom_override: ?f32 = null,
    still: bool = false,
    arrive: bool = true,
    caption: ?[]const u8 = null,
    force_holo: ?[2]f32 = null,
};

pub fn resolveTraits(
    seed: []const u8,
    member_number: ?u64,
    card_scenes: ?u32,
    wire: ?WireCardTraits,
) ascii.CardTraits {
    const s_cap = @max(1, @min(card_scenes orelse scene_count, scene_count));
    if (wire) |wt| {
        const sky_seed = if (member_number) |mn|
            ascii.memberCardTraits(mn, scene_count, enso_count).sky_seed
        else
            ascii.cardHashSalted(seed, ":sky");
        return .{
            .scene = wt.scene % scene_count,
            .sky = wt.sky % scene_count,
            .enso = wt.enso % enso_count,
            .holo = ascii.holos[wt.holo % ascii.holos.len],
            .seal = ascii.seals[wt.seal % ascii.seals.len],
            .sky_seed = sky_seed,
        };
    }
    if (member_number) |mn| {
        if (mn > 0) return ascii.memberCardTraits(mn, s_cap, enso_count);
    }
    return ascii.pickCardTraits(seed, s_cap, enso_count);
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn fract(x: f32) f32 {
    return x - @floor(x);
}

fn mixf(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn mix3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const k = std.math.clamp(t, 0.0, 1.0);
    return .{
        a[0] + (b[0] - a[0]) * k,
        a[1] + (b[1] - a[1]) * k,
        a[2] + (b[2] - a[2]) * k,
    };
}

/// Warm Codegraff lacquerware & pearl holographic foil spectrum cycling across
/// Kintsugi gold (#dfbd8f), coral vermilion (#dc8068), celadon jade (#acc496),
/// and twilight raden pearl (#9aaec6).
fn spectrum(t_in: f32) [3]f32 {
    const palette = [_][3]f32{
        .{ 0.875, 0.741, 0.561 }, // #dfbd8f champagne kintsugi gold
        .{ 0.863, 0.502, 0.408 }, // #dc8068 warm vermilion coral
        .{ 0.675, 0.769, 0.588 }, // #acc496 celadon matcha jade
        .{ 0.604, 0.682, 0.776 }, // #9aaec6 raden pearl slate
    };
    const t = fract(t_in) * @as(f32, @floatFromInt(palette.len));
    const idx: usize = @min(palette.len - 1, @as(usize, @intFromFloat(@floor(t))));
    const next_idx: usize = (idx + 1) % palette.len;
    const f = t - @floor(t);
    const s = f * f * (3.0 - 2.0 * f);
    return mix3(palette[idx], palette[next_idx], s);
}

fn hash2(x: f32, y: f32) f32 {
    return fract(@sin(x * 127.1 + y * 311.7) * 43758.5453);
}

fn sampleSkyRgb(rgb: *const [sky_grid_w * sky_grid_h * 3]u8, u: f32, v: f32) [3]f32 {
    const fx = std.math.clamp(u, 0.0, 1.0) * @as(f32, @floatFromInt(sky_grid_w - 1));
    const fy = std.math.clamp(v, 0.0, 1.0) * @as(f32, @floatFromInt(sky_grid_h - 1));
    const x0: usize = @intFromFloat(@floor(fx));
    const y0: usize = @intFromFloat(@floor(fy));
    const x1: usize = @min(sky_grid_w - 1, x0 + 1);
    const y1: usize = @min(sky_grid_h - 1, y0 + 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));

    const idx00 = (y0 * sky_grid_w + x0) * 3;
    const idx10 = (y0 * sky_grid_w + x1) * 3;
    const idx01 = (y1 * sky_grid_w + x0) * 3;
    const idx11 = (y1 * sky_grid_w + x1) * 3;

    var out: [3]f32 = undefined;
    for (0..3) |ch| {
        const c00 = @as(f32, @floatFromInt(rgb[idx00 + ch])) / 255.0;
        const c10 = @as(f32, @floatFromInt(rgb[idx10 + ch])) / 255.0;
        const c01 = @as(f32, @floatFromInt(rgb[idx01 + ch])) / 255.0;
        const c11 = @as(f32, @floatFromInt(rgb[idx11 + ch])) / 255.0;
        const c0 = c00 + (c10 - c00) * tx;
        const c1 = c01 + (c11 - c01) * tx;
        out[ch] = c0 + (c1 - c0) * ty;
    }
    return out;
}

/// Renders (or reuses cached) premultiplied BGRA8 Seigaiha (青海波) wave-crest
/// silkscreen engraving + sunago gold-dust sky overlay over `depth == 0` artwork
/// and underneath foreground parallax cutouts.
pub fn renderSkyOverlay(
    cache: *SkyCache,
    gpa: Allocator,
    w_pt: f32,
    h_pt: f32,
    scale: f32,
    scene_idx: u32,
    sky_seed: u32,
) ?ui.Texture {
    const s = if (std.math.isFinite(scale) and scale > 0) scale else 1.0;
    const w_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(w_pt * s))));
    const h_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(h_pt * s))));
    const sc_idx = scene_idx % scene_count;
    const scale_q: u32 = @max(1, @as(u32, @intFromFloat(@round(s * 100.0))));
    const needed: usize = @as(usize, w_px) * @as(usize, h_px) * 4;

    if (cache.buf.len == needed and cache.w_px == w_px and cache.h_px == h_px and
        cache.scene == sc_idx and cache.sky_seed == sky_seed and cache.scale_q == scale_q)
    {
        return .{
            .width = w_px,
            .height = h_px,
            .bgra = cache.buf,
            .stride = @as(usize, w_px) * 4,
            .format = .bgra8,
        };
    }

    if (cache.buf.len != needed) {
        if (cache.buf.len > 0) gpa.free(cache.buf);
        cache.buf = gpa.alloc(u8, needed) catch {
            cache.buf = &.{};
            return null;
        };
    }
    cache.w_px = w_px;
    cache.h_px = h_px;
    cache.scene = sc_idx;
    cache.sky_seed = sky_seed;
    cache.scale_q = scale_q;

    const sc = scenes_data.scenes[sc_idx];
    const zoom = w_pt / base_w;
    const bleed_x: f32 = 24.0 * zoom;
    const bleed_y: f32 = 16.0 * zoom;
    const art_w: f32 = w_pt + 2.0 * bleed_x;
    const art_h: f32 = h_pt + 2.0 * bleed_y;

    const cell_w: f32 = 22.0 * zoom;
    const row_h: f32 = 9.6 * zoom;
    const fan_r: f32 = cell_w * 0.56;
    const ring_step: f32 = fan_r * 0.24;
    const seed_ox: f32 = @as(f32, @floatFromInt(sky_seed % 23)) * zoom;
    const seed_oy: f32 = @as(f32, @floatFromInt((sky_seed / 23) % 13)) * zoom;
    const fleck_cell: f32 = 3.2 * zoom;
    const h_f: f32 = @floatFromInt(h_px);
    const drs = [_]i32{ 2, 1, 0, -1 };

    @memset(cache.buf, 0);

    for (0..h_px) |py| {
        const py_f = @as(f32, @floatFromInt(py)) + 0.5;
        const v = py_f / h_f;
        // Solid cream paper covers `v >= 0.76`.
        if (v >= 0.78) break;

        const fade = 1.0 - smoothstep(0.64, 0.77, v);
        const y_pt = py_f / s;
        const v_art = (y_pt + bleed_y) / art_h;
        const wy = y_pt + seed_oy;
        const base_row_f = @floor(wy / row_h);
        const fy_f = wy / fleck_cell;
        const fleck_cy = @floor(fy_f);
        const fleck_fy = fract(fy_f);
        const row = cache.buf[py * w_px * 4 ..];

        for (0..w_px) |px| {
            const x_pt = (@as(f32, @floatFromInt(px)) + 0.5) / s;
            const u_art = (x_pt + bleed_x) / art_w;
            const c_rgb = sampleSkyRgb(sc.sky_rgb, u_art, v_art);
            const luma = 0.299 * c_rgb[0] + 0.587 * c_rgb[1] + 0.114 * c_rgb[2];
            const norm = std.math.clamp((luma - 0.16) / 0.72, 0.0, 1.0);
            const lit = std.math.pow(f32, norm, 1.15);

            const wx = x_pt + seed_ox;
            var hit_r: f32 = 0.0;
            var hit_fan = false;
            for (drs) |dr| {
                const row_r = base_row_f + @as(f32, @floatFromInt(dr));
                const stagger: f32 = if (@mod(@floor(row_r), 2.0) != 0.0) 0.5 * cell_w else 0.0;
                const col_c = @floor((wx - stagger) / cell_w + 0.5);
                const cx = col_c * cell_w + stagger;
                const cy = row_r * row_h + row_h * 0.85;
                const dx = wx - cx;
                const dy = wy - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist <= fan_r and dy <= row_h * 0.28) {
                    hit_r = dist;
                    hit_fan = true;
                    break;
                }
            }

            var arc: f32 = 0.0;
            if (hit_fan) {
                const ring_d = @abs(fract(hit_r / ring_step) - 0.5);
                const stroke_w = mixf(0.08, 0.22, lit);
                arc = (1.0 - smoothstep(stroke_w * 0.35, stroke_w, ring_d)) * smoothstep(0.03, 0.42, lit);
            }

            const fx_f = wx / fleck_cell;
            const fleck_cx = @floor(fx_f);
            var fleck: f32 = 0.0;
            if (lit > 0.35) {
                const fh = hash2(fleck_cx, fleck_cy);
                if (fh > 0.958) {
                    const ox = 0.25 + 0.5 * hash2(fleck_cx + 3.0, fleck_cy + 11.0);
                    const oy = 0.25 + 0.5 * hash2(fleck_cx + 19.0, fleck_cy + 5.0);
                    const fdx = fract(fx_f) - ox;
                    const fdy = fleck_fy - oy;
                    fleck = (1.0 - smoothstep(0.03, 0.14, fdx * fdx + fdy * fdy)) * std.math.clamp((lit - 0.35) * 1.45, 0.0, 1.0);
                }
            }
            const pattern = std.math.clamp(@max(arc * 0.90, fleck), 0.0, 1.0);
            if (pattern <= 0.004 or fade <= 0.004) continue;

            const peak = @max(c_rgb[0], @max(c_rgb[1], @max(c_rgb[2], 0.25)));
            const ink_base = [3]f32{
                std.math.clamp(c_rgb[0] / peak, 0.0, 1.0),
                std.math.clamp(c_rgb[1] / peak, 0.0, 1.0),
                std.math.clamp(c_rgb[2] / peak, 0.0, 1.0),
            };
            const ink = mix3(ink_base, .{ 0.99, 0.94, 0.83 }, 0.44 + 0.46 * std.math.clamp(fleck, 0.0, 1.0));
            const out_a_f = std.math.clamp(pattern * mixf(0.20, 0.62, lit) * fade, 0.0, 1.0);
            const a_u8: u8 = @intFromFloat(@round(out_a_f * 255.0));
            if (a_u8 == 0) continue;
            const ink_scale = out_a_f * 255.0;

            const off = px * 4;
            row[off + 0] = @min(a_u8, @as(u8, @intFromFloat(@round(ink[2] * ink_scale))));
            row[off + 1] = @min(a_u8, @as(u8, @intFromFloat(@round(ink[1] * ink_scale))));
            row[off + 2] = @min(a_u8, @as(u8, @intFromFloat(@round(ink[0] * ink_scale))));
            row[off + 3] = a_u8;
        }
    }

    return .{
        .width = w_px,
        .height = h_px,
        .bgra = cache.buf,
        .stride = @as(usize, w_px) * 4,
        .format = .bgra8,
    };
}

/// Renders (or reuses cached) Retina-sharp premultiplied BGRA8 holographic foil
/// + pointer glare overlay across all 5 finishes (`aurora`, `reverse`,
/// `secret`, `starlight`, `glyph` / Kumiko).
pub fn renderFoilOverlay(
    cache: *FoilCache,
    gpa: Allocator,
    w_pt: f32,
    h_pt: f32,
    scale: f32,
    holo: ascii.Holo,
    pointer: [2]f32,
    strength: f32,
) ?ui.Texture {
    if (strength <= 0.005) return null;
    const s = if (std.math.isFinite(scale) and scale > 0) std.math.clamp(scale, 1.0, 2.0) else 1.0;
    const w_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(w_pt * s))));
    const h_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(h_pt * s))));
    const hx = std.math.clamp(pointer[0], -0.4, 1.4);
    const hy = std.math.clamp(pointer[1], -0.4, 1.4);
    const k = std.math.clamp(strength, 0.0, 1.0);
    const hx_q: u16 = @intFromFloat(@round((hx + 0.5) * 100.0));
    const hy_q: u16 = @intFromFloat(@round((hy + 0.5) * 100.0));
    const k_q: u16 = @intFromFloat(@round(k * 50.0));
    const scale_q: u16 = @max(1, @as(u16, @intFromFloat(@round(s * 100.0))));
    const needed: usize = @as(usize, w_px) * @as(usize, h_px) * 4;

    if (cache.buf.len == needed and cache.w_px == w_px and cache.h_px == h_px and
        cache.holo == holo and cache.hx_q == hx_q and cache.hy_q == hy_q and
        cache.strength_q == k_q and cache.scale_q == scale_q)
    {
        return .{
            .width = w_px,
            .height = h_px,
            .bgra = cache.buf,
            .stride = @as(usize, w_px) * 4,
            .format = .bgra8,
        };
    }

    if (cache.buf.len != needed) {
        if (cache.buf.len > 0) gpa.free(cache.buf);
        cache.buf = gpa.alloc(u8, needed) catch {
            cache.buf = &.{};
            return null;
        };
    }
    cache.w_px = w_px;
    cache.h_px = h_px;
    cache.holo = holo;
    cache.hx_q = hx_q;
    cache.hy_q = hy_q;
    cache.strength_q = k_q;
    cache.scale_q = scale_q;

    const zoom = @max(0.1, w_pt / base_w);
    const inv_pt = 1.0 / (s * zoom);
    const tilt_x = hx - 0.5;
    const tilt_y = hy - 0.5;
    const w_f: f32 = @floatFromInt(w_px);
    const h_f: f32 = @floatFromInt(h_px);

    for (0..h_px) |py| {
        const y_pt = (@as(f32, @floatFromInt(py)) + 0.5) * inv_pt;
        const v = (@as(f32, @floatFromInt(py)) + 0.5) / h_f;
        const paper = smoothstep(0.48, 0.64, v);
        const quiet = mixf(1.0, 0.25, paper);
        const along = smoothstep(0.0, 0.22, v) * (1.0 - smoothstep(0.76, 1.0, v));
        const off_y = v - hy;
        const row = cache.buf[py * w_px * 4 ..];

        for (0..w_px) |px| {
            const x_pt = (@as(f32, @floatFromInt(px)) + 0.5) * inv_pt;
            const u = (@as(f32, @floatFromInt(px)) + 0.5) / w_f;
            const off_x = u - hx;
            const across = off_x * 0.82 + off_y * 0.57;
            const ribbon = 1.0 / (1.0 + across * across * 16.0);

            var shine_rgb = [3]f32{ 1.0, 1.0, 1.0 };
            var shine_a: f32 = 0.0;

            switch (holo) {
                .reverse => {
                    const cell_sz: f32 = 9.5;
                    const cx = @floor(x_pt / cell_sz);
                    const cy = @floor(y_pt / cell_sz);
                    const hval = hash2(cx, cy);
                    const px_c = (cx + 0.25 + 0.5 * hash2(cx + 5.0, cy + 9.0)) * cell_sz;
                    const py_c = (cy + 0.25 + 0.5 * hash2(cx + 17.0, cy + 3.0)) * cell_sz;
                    const pdx = x_pt - px_c;
                    const pdy = y_pt - py_c;
                    const r2 = (pdx * pdx + pdy * pdy) / (cell_sz * cell_sz * 0.14);
                    const disc = if (hval >= 0.45) 1.0 / (1.0 + r2 * r2 * 2.5) else 0.0;
                    const s_gl = @max(@sin(hval * 24.0 + tilt_x * 6.5 + tilt_y * 5.0), 0.0);
                    const pearl = 0.5 + 0.5 * @cos((u * 3.0 + v * 2.2 - tilt_x * 2.4) * 6.2831853);
                    shine_rgb = mix3(spectrum(hval * 0.85 + u * 0.65 + tilt_x * 1.3), .{ 1.0, 0.99, 0.96 }, 0.38);
                    shine_a = (disc * s_gl * s_gl * 0.36 + pearl * ribbon * 0.16) * quiet;
                },
                .secret => {
                    const d1 = @sin((x_pt + y_pt) * (6.2831853 / 7.5) + tilt_x * 1.8);
                    const d2 = @sin((x_pt - y_pt) * (6.2831853 / 7.5) - tilt_y * 1.8);
                    const weave = smoothstep(0.35, 0.98, @max(d1 * d1, d2 * d2));
                    shine_rgb = mix3(spectrum((u - v) * 0.9 + tilt_x * 1.4 - tilt_y * 0.8), .{ 1.0, 0.95, 0.82 }, 0.42);
                    shine_a = (weave * 0.18 + 0.14) * ribbon * quiet;
                },
                .starlight => {
                    const cell_sz: f32 = 18.0;
                    const cx = @floor(x_pt / cell_sz);
                    const cy = @floor(y_pt / cell_sz);
                    const hval = hash2(cx, cy);
                    const centre_x = (cx + 0.28 + 0.44 * hash2(cx + 7.0, cy + 7.0)) * cell_sz;
                    const centre_y = (cy + 0.28 + 0.44 * hash2(cx + 13.0, cy + 13.0)) * cell_sz;
                    const sdx = @abs(x_pt - centre_x);
                    const sdy = @abs(y_pt - centre_y);
                    const ray_h = 1.0 / (1.0 + sdx * sdx * 0.16 + sdy * sdy * 4.5);
                    const ray_v = 1.0 / (1.0 + sdy * sdy * 0.16 + sdx * sdx * 4.5);
                    const core = 1.0 / (1.0 + (sdx * sdx + sdy * sdy) * 0.55);
                    const star = @min(1.0, ray_h + ray_v + core * 0.75);
                    const s_gl = if (hval >= 0.56) @max(@sin(hval * 26.0 + tilt_x * 7.5 - tilt_y * 5.5), 0.0) else 0.0;
                    const glint = s_gl * s_gl * s_gl * s_gl;
                    shine_rgb = mix3(.{ 1, 1, 1 }, spectrum(hval + v * 0.8 + tilt_x), 0.34);
                    shine_a = (star * glint * 0.72 + ribbon * 0.16) * quiet;
                },
                .glyph => {
                    // Kumiko / Asanoha geometric star-lattice finish (non-ASCII).
                    const pitch: f32 = 14.0;
                    const half_sqrt3: f32 = 0.8660254;
                    const d0 = @abs(fract(y_pt / pitch) - 0.5);
                    const d1 = @abs(fract((half_sqrt3 * x_pt + 0.5 * y_pt) / pitch) - 0.5);
                    const d2 = @abs(fract((-half_sqrt3 * x_pt + 0.5 * y_pt) / pitch) - 0.5);
                    const tri = @min(d0, @min(d1, d2));
                    const lattice = 1.0 - smoothstep(0.022, 0.088, tri);
                    shine_rgb = mix3(spectrum(v * 1.1 + u * 0.65 + tilt_x * 1.3), .{ 1.0, 0.96, 0.86 }, 0.32);
                    shine_a = (lattice * ribbon * 0.44 + ribbon * 0.08) * quiet;
                },
                .aurora => {
                    const wave1 = 0.5 + 0.5 * @cos((u * 2.1 - tilt_x * 2.0 + v * 0.40) * 6.2831853);
                    const wave2 = 0.5 + 0.5 * @sin((u * 1.3 + v * 1.5 - tilt_y * 1.6) * 6.2831853);
                    const pillar = smoothstep(0.08, 0.95, wave1 * 0.7 + wave2 * 0.3);
                    shine_rgb = mix3(spectrum(u * 0.65 - tilt_x * 1.15 + v * 0.25), .{ 1, 1, 1 }, 0.35);
                    shine_a = (pillar * 0.22 + ribbon * 0.12) * along * quiet;
                },
            }

            const sa = std.math.clamp(shine_a * k, 0.0, 1.0);
            const glare_falloff = 1.0 / (1.0 + (off_x * off_x + off_y * off_y) * 7.0);
            const ga = std.math.clamp(glare_falloff * 0.22 * k, 0.0, 1.0);
            // Porter-Duff source-over of white pointer glare over colored shine.
            const out_a = std.math.clamp(ga + sa * (1.0 - ga), 0.0, 1.0);
            const a_u8: u8 = @intFromFloat(@round(out_a * 255.0));
            const out_r: u8 = @min(a_u8, @as(u8, @intFromFloat(@round(std.math.clamp(ga + shine_rgb[0] * sa * (1.0 - ga), 0.0, 1.0) * 255.0))));
            const out_g: u8 = @min(a_u8, @as(u8, @intFromFloat(@round(std.math.clamp(ga + shine_rgb[1] * sa * (1.0 - ga), 0.0, 1.0) * 255.0))));
            const out_b: u8 = @min(a_u8, @as(u8, @intFromFloat(@round(std.math.clamp(ga + shine_rgb[2] * sa * (1.0 - ga), 0.0, 1.0) * 255.0))));

            const off = px * 4;
            row[off + 0] = out_b;
            row[off + 1] = out_g;
            row[off + 2] = out_r;
            row[off + 3] = a_u8;
        }
    }

    return .{
        .width = w_px,
        .height = h_px,
        .bgra = cache.buf,
        .stride = @as(usize, w_px) * 4,
        .format = .bgra8,
    };
}

pub fn draw(c: *ui.Context, gpa: Allocator, state: *State, k: theme.Colors, props: Props) void {
    const zoom: f32 = props.zoom_override orelse if (props.preview) preview_zoom else 1.0;
    const w: f32 = base_w * zoom;
    const h: f32 = base_h * zoom;
    const radius: f32 = 16.0 * zoom;
    const pad: f32 = 16.0 * zoom;
    const bleed_x: f32 = 24.0 * zoom;
    const bleed_y: f32 = 16.0 * zoom;
    const art_w: f32 = w + 2.0 * bleed_x;
    const art_h: f32 = h + 2.0 * bleed_y;

    const ink = ui.Color.hex(0x29251f);
    const pill_bg = ui.Color.hex(0x24211d).alpha(0.62);
    const traits = resolveTraits(props.seed, props.member_number, props.card_scenes, props.card_traits);
    const sc = scenes_data.scenes[traits.scene % scene_count];
    const sky_sc = scenes_data.scenes[traits.sky % scene_count];
    const enso_layer = scenes_data.ensos[traits.enso % enso_count];
    const is_founder = if (props.member_number) |mn| (mn >= 1 and mn <= 1000) else false;

    const motion_ok = !c.reduced_motion and !props.still;
    const seed_hash = ascii.cardHashSalted(props.seed, if (props.preview) ":prev" else ":full") ^
        @as(u32, @truncate(props.member_number orelse 0));
    if (!state.seeded or state.seed_hash != seed_hash) {
        state.seeded = true;
        state.seed_hash = seed_hash;
        state.arrive_at = c.time;
        state.glint_at = if (props.arrive and motion_ok) c.time else -10.0;
    }

    const arrive_dur: f64 = 0.50;
    const glint_dur: f64 = 0.62;
    const arr_elapsed = c.time - state.arrive_at;
    var arrive_y: f32 = 0.0;
    var arrive_opacity: f32 = 1.0;
    var active_anim_k: f32 = 0.0;
    if (props.arrive and motion_ok and arr_elapsed >= 0.0 and arr_elapsed < arrive_dur) {
        const t_arr: f32 = std.math.clamp(@as(f32, @floatCast(arr_elapsed / arrive_dur)), 0.0, 1.0);
        const inv = 1.0 - t_arr;
        const ease = 1.0 - inv * inv * inv;
        arrive_y = (1.0 - ease) * 28.0 * zoom;
        arrive_opacity = 0.12 + 0.88 * ease;
        active_anim_k = @max(active_anim_k, 1.0 - t_arr);
        c.frameIn(1.0 / 60.0);
        c.animationFrame();
    }

    const gl_elapsed = c.time - state.glint_at;
    var glint_strength: f32 = 0.0;
    var glint_pt = [2]f32{ 0.5, 0.45 };
    if (motion_ok and gl_elapsed >= 0.0 and gl_elapsed < glint_dur) {
        const t_gl: f32 = std.math.clamp(@as(f32, @floatCast(gl_elapsed / glint_dur)), 0.0, 1.0);
        const s_gl = t_gl * t_gl * (3.0 - 2.0 * t_gl);
        glint_pt = .{ mixf(-0.35, 1.35, s_gl), 0.45 };
        glint_strength = @sin(t_gl * std.math.pi) * 0.92;
        active_anim_k = @max(active_anim_k, glint_strength);
        c.frameIn(1.0 / 60.0);
        c.animationFrame();
    }

    var num_buf: [24]u8 = undefined;
    const num_str = ascii.formatMemberNumber(&num_buf, props.member_number);
    var date_buf: [32]u8 = undefined;
    const since_str = ascii.formatSinceDate(&date_buf, props.started_at orelse 1794700800);

    const col = ui.div(c).column().itemsCenter().gap(10);
    defer col.end();

    {
        // Stationary unturned hit-box: 3D turning & hovering lift happen on `mover`
        // inside so tilted corners never walk out from under a resting cursor.
        ui.key(c, if (props.preview) "member-card-preview" else "member-card");
        const stage = ui.div(c).size(w, h).control();
        defer stage.end();

        const hot = stage.hovered() and !props.still;
        if (stage.clicked() and motion_ok) {
            state.glint_at = c.time;
            c.changed = true;
            c.frameIn(1.0 / 60.0);
            c.animationFrame();
        }
        state.hovered = hot;
        if (hot) {
            if (c.rects.get(stage.id())) |rect| {
                state.hover_x = std.math.clamp((c.input.mouse.x - rect.x) / @max(1.0, rect.w), 0.0, 1.0);
                state.hover_y = std.math.clamp((c.input.mouse.y - rect.y) / @max(1.0, rect.h), 0.0, 1.0);
            }
        }
        const target_tx: f32 = if (hot and motion_ok) state.hover_x else 0.5;
        const target_ty: f32 = if (hot and motion_ok) state.hover_y else 0.5;
        const target_foil: f32 = if (hot and !props.still) 1.0 else 0.0;
        const target_lift: f32 = if (hot and motion_ok) 1.0 else 0.0;
        if (!motion_ok) {
            state.tilt_x = 0.5;
            state.tilt_y = 0.5;
            state.foil_strength = target_foil;
            state.hover_lift = 0.0;
        } else {
            state.tilt_x += (target_tx - state.tilt_x) * 0.25;
            state.tilt_y += (target_ty - state.tilt_y) * 0.25;
            state.foil_strength += (target_foil - state.foil_strength) * 0.25;
            state.hover_lift += (target_lift - state.hover_lift) * 0.22;
            const settling = @abs(target_tx - state.tilt_x) > 0.002 or
                @abs(target_ty - state.tilt_y) > 0.002 or
                @abs(target_foil - state.foil_strength) > 0.004 or
                @abs(target_lift - state.hover_lift) > 0.004;
            if (settling) {
                c.frameIn(1.0 / 60.0);
                c.animationFrame();
            } else {
                state.tilt_x = target_tx;
                state.tilt_y = target_ty;
                state.foil_strength = target_foil;
                state.hover_lift = target_lift;
            }
        }

        const effective_tx = if (props.force_holo) |fh| fh[0] else state.tilt_x;
        const effective_ty = if (props.force_holo) |fh| fh[1] else state.tilt_y;
        const hover_k = if (props.force_holo != null and motion_ok) @as(f32, 1.0) else state.hover_lift;
        const dx = effective_tx - 0.5;
        const dy = effective_ty - 0.5;
        const effective_foil = if (props.force_holo != null)
            @as(f32, 1.0)
        else if (glint_strength > state.foil_strength)
            glint_strength
        else
            state.foil_strength;
        const foil_pt = if (props.force_holo) |fh|
            fh
        else if (glint_strength > state.foil_strength and !hot)
            glint_pt
        else
            [2]f32{ state.hover_x, state.hover_y };

        // Soft sky-tinted ambient halo floating outside behind the card.
        {
            const glow_rgb = sampleSkyRgb(sky_sc.sky_rgb, 0.5, 0.28);
            const halo_a: f32 = (if (k.dark) @as(f32, 0.24) else 0.14) + hover_k * 0.14;
            const glow_col: ui.Color = .{
                .r = std.math.clamp(glow_rgb[0] * 1.12, 0.0, 1.0),
                .g = std.math.clamp(glow_rgb[1] * 1.12, 0.0, 1.0),
                .b = std.math.clamp(glow_rgb[2] * 1.12, 0.0, 1.0),
                .a = halo_a,
            };
            ui.div(c).absolute()
                .offset(12.0 * zoom - dx * 6.0 * zoom, 14.0 * zoom + arrive_y * 0.5 - dy * 4.0 * zoom)
                .size(w - 24.0 * zoom, h - 24.0 * zoom)
                .rounded(radius)
                .opacity(arrive_opacity)
                .shadow(.{
                    .color = glow_col,
                    .y = 4.0 * zoom,
                    .blur = (36.0 + hover_k * 16.0) * zoom,
                    .spread = (8.0 + hover_k * 6.0) * zoom,
                })
                .end();
        }

        const turn_rad: f32 = if (!motion_ok or (@abs(dx) < 0.002 and hover_k == 0.0))
            0.0
        else
            dx * 0.34;
        const card_scale: f32 = if (!motion_ok) 1.0 else (1.0 + hover_k * 0.045);
        const card_ox: f32 = if (!motion_ok) 0.0 else dx * 12.0 * zoom;
        const card_oy: f32 = (if (!motion_ok) @as(f32, 0.0) else (dy * 8.0 - hover_k * 8.0) * zoom) + arrive_y;
        const sh_x: f32 = -dx * 22.0 * zoom;
        const sh_y: f32 = (16.0 + hover_k * 12.0) * zoom;
        const sh_blur: f32 = (34.0 + hover_k * 16.0) * zoom;

        var mover = ui.div(c).absolute()
            .offset(card_ox, card_oy)
            .size(w, h)
            .rounded(radius)
            .opacity(arrive_opacity)
            .shadow(.{
                .color = ui.Color.black.alpha(0.32 + hover_k * 0.14),
                .x = sh_x,
                .y = sh_y,
                .blur = sh_blur,
            });
        if (turn_rad != 0.0 or card_scale != 1.0) {
            mover = mover.pivot(0.5, 0.5);
            if (turn_rad != 0.0) mover = mover.turn(turn_rad, 820.0 * zoom);
            if (card_scale != 1.0) mover = mover.scale(card_scale);
        }
        defer mover.end();

        const card = ui.div(c).wFull().hFull().rounded(radius).bg(ui.Color.hex(0x1c1b22)).clip();
        defer card.end();

        const layer_drift: f32 = if (!motion_ok) 0.0 else blk: {
            const k_wave = @max(hover_k, active_anim_k);
            break :blk if (k_wave > 0.01) @as(f32, @floatCast(@sin(c.time * 1.4))) * 3.0 * zoom * k_wave else 0.0;
        };

        // 1. Steady background (`depth == 0`: sky / back) across bleed box.
        {
            const box = ui.div(c).absolute().offset(-bleed_x, -bleed_y).size(art_w, art_h);
            defer box.end();
            _ = ui.image(c, .{
                .key = c.print("mc-sky-{s}", .{sky_sc.slug}),
                .source = .{ .encoded = sky_sc.sky_bytes },
                .box = .{ .w = art_w, .h = art_h },
                .radius = 0,
            });
        }

        // 2. Seigaiha wave silkscreen + sunago gold-dust sky overlay sampling the sky layer.
        if (renderSkyOverlay(&state.sky, gpa, w, h, c.scale, traits.sky % scene_count, traits.sky_seed)) |tex| {
            ui.texture(c, .{
                .absolute = true,
                .width = .{ .px = w },
                .height = .{ .px = h },
                .radius = radius,
            }, tex, .{ 0, 0, 1, 1 }, 1.0);
        }

        // 3a. Shared Ensō halo layer (`depth == 1.0`) shifted against tilt & gentle motion.
        {
            const shift_x = if (!motion_ok)
                @as(f32, 0.0)
            else
                std.math.clamp((0.5 - effective_tx) * 1.0 * 16.0 * zoom + layer_drift, -bleed_x, bleed_x);
            const shift_y = if (!motion_ok)
                @as(f32, 0.0)
            else
                std.math.clamp((0.5 - effective_ty) * 1.0 * 10.0 * zoom, -bleed_y, bleed_y);
            const box = ui.div(c).absolute().offset(-bleed_x + shift_x, -bleed_y + shift_y).size(art_w, art_h);
            defer box.end();
            _ = ui.image(c, .{
                .key = c.print("mc-enso-{s}", .{enso_layer.slug}),
                .source = .{ .encoded = enso_layer.bytes },
                .box = .{ .w = art_w, .h = art_h },
                .radius = 0,
            });
        }

        // 3b. Foreground cutout layer (`depth == 2.0`) shifted against tilt.
        {
            const shift_x = if (!motion_ok)
                @as(f32, 0.0)
            else
                std.math.clamp((0.5 - effective_tx) * 2.0 * 16.0 * zoom + layer_drift * 1.6, -bleed_x, bleed_x);
            const shift_y = if (!motion_ok)
                @as(f32, 0.0)
            else
                std.math.clamp((0.5 - effective_ty) * 2.0 * 10.0 * zoom, -bleed_y, bleed_y);
            const box = ui.div(c).absolute().offset(-bleed_x + shift_x, -bleed_y + shift_y).size(art_w, art_h);
            defer box.end();
            _ = ui.image(c, .{
                .key = c.print("mc-near-{s}", .{sc.slug}),
                .source = .{ .encoded = sc.near_bytes },
                .box = .{ .w = art_w, .h = art_h },
                .radius = 0,
            });
        }

        // 4. 7-stop `#f4efe6` cream paper fade rising beneath card words + subtle top edge contrast scrim.
        ui.div(c).absolute().offset(0, 0).size(w, h).bg(paper_bg).gradientStops(&paper_stops, null).end();
        ui.div(c).absolute().offset(0, 0).size(w, h * 0.20).bg(ui.Color.hex(0x0e0d0b).alpha(0.22)).gradient(ui.Color.hex(0x0e0d0b).alpha(0.0)).end();

        // 5. Card words & pills (`harness`, `000·XXX`, member name, join date).
        {
            const inner = ui.div(c).absolute().offset(0, 0).size(w, h).p(pad).column();
            defer inner.end();

            {
                const top_row = ui.div(c).row().wFull().itemsCenter();
                defer top_row.end();

                ui.text(c, "harness", .{
                    .size = 16 * zoom,
                    .line_height = 20 * zoom,
                    .weight = .bold,
                    .color = ui.Color.hex(0xfaf8f3),
                });

                ui.spacer(c);

                {
                    var num_pill = ui.div(c).row().h(22 * zoom).px(8 * zoom).center().roundedFull().bg(pill_bg);
                    if (is_founder and !props.preview) {
                        num_pill = num_pill.border(ui.Color.hex(0xd4a64a).alpha(0.65)).borderW(1.0 * zoom);
                    }
                    defer num_pill.end();
                    ui.text(c, c.print("{s}", .{num_str}), .{
                        .size = 12 * zoom,
                        .line_height = 14 * zoom,
                        .mono = true,
                        .weight = .medium,
                        .tracking = 1.0 * zoom,
                        .color = ui.Color.white,
                    });
                }
            }

            ui.spacer(c);

            kit.ellipsisText(c, props.name, .{
                .size = 32 * zoom,
                .line_height = 36 * zoom,
                .weight = .semibold,
                .tracking = -0.8 * zoom,
                .color = ink,
            }, w - 2.0 * pad);

            ui.div(c).h(12 * zoom).end();

            {
                const bottom_row = ui.div(c).row().wFull().itemsCenter();
                defer bottom_row.end();

                {
                    const date_pill = ui.div(c).row().h(22 * zoom).px(8 * zoom).itemsCenter().justifyCenter().roundedFull().bg(pill_bg);
                    defer date_pill.end();
                    ui.text(c, c.print("{s}", .{since_str}), .{
                        .size = 12 * zoom,
                        .line_height = 14 * zoom,
                        .mono = true,
                        .weight = .medium,
                        .tracking = 1.0 * zoom,
                        .color = ui.Color.hex(0xfaf8f3),
                    });
                }

                ui.spacer(c);

                if (!props.preview) {
                    const right_row = ui.div(c).row().itemsCenter().gap(6 * zoom);
                    defer right_row.end();

                    ui.text(c, sc.title, .{
                        .size = 8.5 * zoom,
                        .line_height = 11 * zoom,
                        .mono = true,
                        .weight = .medium,
                        .tracking = 0.8 * zoom,
                        .color = ui.Color.hex(0x766c5f),
                    });

                    drawHankoSeal(c, traits.seal, zoom);
                }
            }
        }

        // 6. Holographic foil finish & pointer glare (on hover, deal-in glint, or forced preview).
        if (effective_foil > 0.01) {
            if (renderFoilOverlay(&state.foil, gpa, w, h, c.scale, traits.holo, foil_pt, effective_foil)) |tex| {
                ui.texture(c, .{
                    .absolute = true,
                    .width = .{ .px = w },
                    .height = .{ .px = h },
                    .radius = radius,
                }, tex, .{ 0, 0, 1, 1 }, 1.0);
            }
        }

        // 7. Physical perimeter card rim & specular bevel (Founder brushed gold accent for #1..1000).
        if (is_founder and !props.preview) {
            ui.div(c).absolute().offset(0, 0).size(w, h).rounded(radius).border(ui.Color.hex(0xe4b856).alpha(0.72 + hover_k * 0.18)).borderW(1.25).end();
            if (w > 4 and h > 4) {
                ui.div(c).absolute().offset(1, 1).size(w - 2, h - 2).rounded(@max(0, radius - 1)).border(ui.Color.hex(0xfff8e6).alpha(0.18 + hover_k * 0.12)).borderW(1).end();
            }
        } else if (k.dark) {
            ui.div(c).absolute().offset(0, 0).size(w, h).rounded(radius).border(ui.Color.white.alpha(0.16 + hover_k * 0.16)).borderW(1).end();
        } else {
            ui.div(c).absolute().offset(0, 0).size(w, h).rounded(radius).border(ui.Color.black.alpha(0.11)).borderW(1).end();
            if (w > 4 and h > 4) {
                ui.div(c).absolute().offset(1, 1).size(w - 2, h - 2).rounded(@max(0, radius - 1)).border(ui.Color.white.alpha(0.45)).borderW(1).end();
            }
        }
    }

    if (props.caption) |cap| {
        ui.text(c, cap, .{
            .size = 12,
            .line_height = 16,
            .color = k.muted,
        });
    }
}

fn drawHankoSeal(c: *ui.Context, seal_kind: ascii.Seal, zoom: f32) void {
    const seal_color = switch (seal_kind) {
        .shuin => ui.Color.hex(0xb14228),
        .kin_in => ui.Color.hex(0xb8892a),
        .ai_in => ui.Color.hex(0x2d4f7c),
        .seiji => ui.Color.hex(0x3d7a68),
        .sumi_in => ui.Color.hex(0x2b2723),
        .akane => ui.Color.hex(0x9e2b3b),
        .kohaku => ui.Color.hex(0xc46d1f),
        .fuji_in => ui.Color.hex(0x6b4c8c),
    };
    const outer_base = ui.div(c).row().size(20 * zoom, 20 * zoom).center()
        .border(seal_color.alpha(0.85)).borderW(1.25 * zoom).bg(seal_color.alpha(0.10));
    const outer = switch (seal_kind) {
        .shuin, .kin_in, .kohaku => outer_base.rounded(4 * zoom),
        .seiji => outer_base.rounded(6 * zoom),
        .sumi_in => outer_base.rounded(3 * zoom),
        .ai_in, .akane, .fuji_in => outer_base.roundedFull(),
    };
    defer outer.end();

    switch (seal_kind) {
        .shuin, .ai_in => {
            ui.div(c).size(10 * zoom, 10 * zoom).roundedFull().border(seal_color).borderW(1.5 * zoom).end();
        },
        .kin_in, .akane => {
            ui.div(c).size(10 * zoom, 10 * zoom).rounded(2 * zoom).border(seal_color).borderW(1.5 * zoom).end();
        },
        .sumi_in => {
            ui.div(c).size(10 * zoom, 10 * zoom).rounded(1 * zoom).border(seal_color).borderW(1.5 * zoom).end();
        },
        .seiji => {
            const ring = ui.div(c).row().size(12 * zoom, 12 * zoom).center().roundedFull().border(seal_color).borderW(1.4 * zoom);
            defer ring.end();
            ui.div(c).size(4 * zoom, 4 * zoom).roundedFull().bg(seal_color).end();
        },
        .kohaku => {
            ui.div(c).size(8 * zoom, 8 * zoom).rounded(2 * zoom).bg(seal_color).end();
        },
        .fuji_in => {
            ui.div(c).size(9 * zoom, 9 * zoom).roundedFull().bg(seal_color).end();
        },
    }
}

const testing = std.testing;

test "all 20 card scenes and 8 shared Ensō layers decode cleanly through nanoui" {
    const EnsoHarness = struct {
        all_sized: bool = true,
        all_drawn: bool = true,
        fn view(s: *@This(), c: *ui.Context) void {
            for (scenes_data.ensos) |en| {
                const kname = c.print("test-enso-{s}", .{en.slug});
                const sz = ui.imageSize(c, kname, en.bytes) orelse {
                    s.all_sized = false;
                    continue;
                };
                if (sz.w != 696 or sz.h != 904) s.all_sized = false;
                if (!ui.image(c, .{
                    .key = kname,
                    .source = .{ .encoded = en.bytes },
                    .box = .{ .w = 108, .h = 144 },
                    .radius = 0,
                })) s.all_drawn = false;
            }
        }
    };

    const BatchHarness = struct {
        start: usize = 0,
        end: usize = 0,
        all_sized: bool = true,
        all_drawn: bool = true,
        fn view(s: *@This(), c: *ui.Context) void {
            for (scenes_data.scenes[s.start..s.end]) |sc| {
                const pairs = [_]struct { name: []const u8, bytes: []const u8 }{
                    .{ .name = "sky", .bytes = sc.sky_bytes },
                    .{ .name = "near", .bytes = sc.near_bytes },
                };
                for (pairs) |pair| {
                    const kname = c.print("test-{s}-{s}", .{ sc.slug, pair.name });
                    const sz = ui.imageSize(c, kname, pair.bytes) orelse {
                        s.all_sized = false;
                        continue;
                    };
                    if (sz.w != 696 or sz.h != 904) s.all_sized = false;
                    if (!ui.image(c, .{
                        .key = kname,
                        .source = .{ .encoded = pair.bytes },
                        .box = .{ .w = 108, .h = 144 },
                        .radius = 0,
                    })) s.all_drawn = false;
                }
            }
        }
    };

    try testing.expectEqual(@as(u32, 20), scene_count);
    try testing.expectEqual(@as(u32, 8), enso_count);
    for (scenes_data.scenes) |sc| {
        try testing.expectEqual(@as(usize, 48 * 64 * 3), sc.sky_rgb.len);
    }

    var decoded_total: usize = 0;

    // Batch 0: 8 shared Ensō layers.
    {
        var eh: EnsoHarness = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, ui.View.init(&eh, EnsoHarness.view), .{ .width = 320, .height = 320, .scale = 1 });
        defer t.deinit();
        t.frame();
        try testing.expect(eh.all_sized);
        try testing.expect(eh.all_drawn);
        var entries: usize = 0;
        var it = t.ctx.text.images.entries.valueIterator();
        while (it.next()) |v| {
            if (v.entry != null) entries += 1;
        }
        try testing.expectEqual(@as(usize, 8), entries);
        decoded_total += entries;
    }

    // Batches 1..4: 5 scenes (10 images) per Tester so atlas eviction never drops entries.
    var start: usize = 0;
    while (start < scenes_data.scenes.len) : (start += 5) {
        const end = @min(scenes_data.scenes.len, start + 5);
        var bh: BatchHarness = .{ .start = start, .end = end };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, ui.View.init(&bh, BatchHarness.view), .{ .width = 320, .height = 320, .scale = 1 });
        defer t.deinit();
        t.frame();
        try testing.expect(bh.all_sized);
        try testing.expect(bh.all_drawn);
        var entries: usize = 0;
        var it = t.ctx.text.images.entries.valueIterator();
        while (it.next()) |v| {
            if (v.entry != null) entries += 1;
        }
        try testing.expectEqual((end - start) * 2, entries);
        decoded_total += entries;
    }

    try testing.expectEqual(@as(usize, 48), decoded_total);
}

test "renderSkyOverlay produces premultiplied BGRA8 Seigaiha silkscreen wave overlay, reuses cache, and leaves bottom transparent for paper" {
    var cache: SkyCache = .{};
    defer cache.deinit(testing.allocator);

    const traits = ascii.pickCardTraits(ascii.preview_seed, scene_count, enso_count);
    const tex1 = renderSkyOverlay(&cache, testing.allocator, 180, 252, 2, traits.sky, traits.sky_seed).?;
    try testing.expectEqual(@as(u32, 360), tex1.width);
    try testing.expectEqual(@as(u32, 504), tex1.height);
    try testing.expectEqual(ui.TextureFormat.bgra8, tex1.format);
    try testing.expectEqual(@as(usize, 360 * 504 * 4), tex1.bgra.len);

    // Cache hit reuses buffer slice pointer identically.
    const tex2 = renderSkyOverlay(&cache, testing.allocator, 180, 252, 2, traits.sky, traits.sky_seed).?;
    try testing.expectEqual(tex1.bgra.ptr, tex2.bgra.ptr);

    // Every pixel satisfies premultiplied BGRA invariant (b,g,r <= a), with transparent gaps and bright wave strokes.
    var saw_lit = false;
    var saw_clear = false;
    for (0..360 * 320) |p| {
        const off = p * 4;
        const b = tex1.bgra[off + 0];
        const g = tex1.bgra[off + 1];
        const r = tex1.bgra[off + 2];
        const a = tex1.bgra[off + 3];
        try testing.expect(b <= a and g <= a and r <= a);
        if (a >= 75 and (r > a / 2 or g > a / 2 or b > a / 2)) saw_lit = true;
        if (a == 0) saw_clear = true;
    }
    try testing.expect(saw_lit and saw_clear);

    // Lower region covered by solid paper fade is zeroed.
    const bot_off = (500 * 360 + 180) * 4;
    try testing.expectEqual(@as(u8, 0), tex1.bgra[bot_off + 3]);
}

test "renderFoilOverlay produces Retina-scaled valid premultiplied BGRA8 for all 5 finishes" {
    var cache: FoilCache = .{};
    defer cache.deinit(testing.allocator);

    var nonzero_counts: [ascii.holos.len]usize = .{ 0, 0, 0, 0, 0 };
    for (ascii.holos, 0..) |holo, idx| {
        const tex1 = renderFoilOverlay(&cache, testing.allocator, 150, 210, 1.0, holo, .{ 0.42, 0.36 }, 1.0).?;
        try testing.expectEqual(@as(u32, 150), tex1.width);
        try testing.expectEqual(@as(u32, 210), tex1.height);

        const tex2 = renderFoilOverlay(&cache, testing.allocator, 150, 210, 2.0, holo, .{ 0.42, 0.36 }, 1.0).?;
        try testing.expectEqual(@as(u32, 300), tex2.width);
        try testing.expectEqual(@as(u32, 420), tex2.height);
        const tex2_hit = renderFoilOverlay(&cache, testing.allocator, 150, 210, 2.0, holo, .{ 0.42, 0.36 }, 1.0).?;
        try testing.expectEqual(tex2.bgra.ptr, tex2_hit.bgra.ptr);

        for (0..300 * 420) |p| {
            const off = p * 4;
            const b = tex2.bgra[off + 0];
            const g = tex2.bgra[off + 1];
            const r = tex2.bgra[off + 2];
            const a = tex2.bgra[off + 3];
            try testing.expect(b <= a and g <= a and r <= a);
            if (a > 0) nonzero_counts[idx] += 1;
        }
        try testing.expect(nonzero_counts[idx] > 400);
    }
}

test "member card arrives with foil sweep, turns in 3D on preview hover, and settles to zero wakeups at rest" {
    theme.registerFonts();
    const Host = struct {
        card: State = .{},
        preview: bool = true,
        fn view(h: *@This(), c: *ui.Context) void {
            const root = ui.div(c).wFull().hFull().p(32).column().itemsStart();
            defer root.end();
            draw(c, testing.allocator, &h.card, theme.colors(true), .{
                .seed = ascii.preview_seed,
                .name = "You",
                .preview = h.preview,
            });
        }
    };

    var host: Host = .{};
    defer host.card.deinit(testing.allocator);

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, ui.View.init(&host, Host.view), .{ .width = 360, .height = 420, .scale = 1, .dark = true });
    defer t.deinit();

    // Arrival deal-in + sweep starts active and settles cleanly to zero wakeups.
    try testing.expect(t.ctx.animating);
    t.advance(0.8);
    try testing.expect(!t.ctx.animating and t.ctx.frame_in == null);
    for (t.instances.items) |inst| try testing.expectEqual(@as(f32, 0.0), inst.turn[0]);

    // Hovering near the left edge of the signed-out preview card turns and lifts it.
    t.moveTo(56, 120);
    t.advance(0.35);
    try testing.expect(host.card.hovered);
    try testing.expect(host.card.hover_lift > 0.9);
    try testing.expect(host.card.foil_strength > 0.9);

    var saw_turn = false;
    var saw_perspective: f32 = 0;
    for (t.instances.items) |inst| {
        if (inst.turn[0] != 0.0) {
            saw_turn = true;
            saw_perspective = inst.turn[1];
        }
    }
    try testing.expect(saw_turn);
    try testing.expect(saw_perspective > 100.0);

    // Moving the pointer off settles cleanly back to rest with zero idle wakeups.
    t.moveTo(4, 4);
    t.advance(0.8);
    try testing.expect(!host.card.hovered);
    try testing.expectEqual(@as(f32, 0.0), host.card.hover_lift);
    try testing.expectEqual(@as(f32, 0.0), host.card.foil_strength);
    try testing.expect(!t.ctx.animating and t.ctx.frame_in == null);
    for (t.instances.items) |inst| try testing.expectEqual(@as(f32, 0.0), inst.turn[0]);
}
