//! Interactive Harness member card: 20 original Codegraff × Ensō layered
//! Japanese artworks paired with 8 composable Ensō brushstrokes, 5 holographic
//! finishes, and 8 Hanko seals (`card_scenes_data` — 128,000 unique combinations;
//! 3,200 1-of-1 three-layer artworks for founders), 5×7 ASCII sky dither under
//! parallax-shifted cutouts, 7-stop `#f4efe6` washi paper fade, member number
//! (`000·XXX`), join date, and pointer glare.
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
    hovered: bool = false,

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

fn cellHash(cx: u32, cy: u32) f32 {
    return hash2(@floatFromInt(cx), @floatFromInt(cy));
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

/// Renders (or reuses cached) premultiplied BGRA8 texture implementing Zeron's
/// `sky` shader (`member_card.luau`) over `depth == 0` artwork and underneath
/// foreground parallax cutouts.
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

    const dot_px: f32 = @max(1.0, 1.5 * zoom * s);
    const cell_w: f32 = 6.0 * dot_px;
    const cell_h: f32 = 8.0 * dot_px;
    const origin_x: f32 = @as(f32, @floatFromInt(sky_seed % 9)) * zoom * s;
    const origin_y: f32 = @as(f32, @floatFromInt((sky_seed / 9) % 12)) * zoom * s;
    const h_f: f32 = @floatFromInt(h_px);

    // Alpha equivalent for Zeron's `ink * k + own * 0.88 * (1 - k)` where k = 0.62:
    // source-over dst multiplier = 1 - alpha => alpha = 1 - 0.88 * 0.38 = 0.6656 (170/255).
    const lit_alpha_u8: u8 = 170;
    // Dim steady sky by 0.88 where glyph is off (`1 - 0.88 = 0.12 => 31/255`).
    const dim_alpha_u8: u8 = 31;

    @memset(cache.buf, 0);

    for (0..h_px) |py| {
        const py_f = @as(f32, @floatFromInt(py)) + 0.5;
        const v = py_f / h_f;
        // Solid cream paper covers `v >= 0.76`.
        if (v >= 0.78) break;

        const gy = py_f + origin_y;
        const cy = @floor(gy / cell_h);
        const fy_f = @floor(@mod(gy, cell_h) / dot_px);
        const row = cache.buf[py * w_px * 4 ..];

        if (fy_f < 0 or fy_f >= 7.0) {
            for (0..w_px) |px| row[px * 4 + 3] = dim_alpha_u8;
            continue;
        }
        const fy: u32 = @intFromFloat(fy_f);
        const sample_y_pt = ((cy + 0.5) * cell_h - origin_y) / s;
        const v_art = (sample_y_pt + bleed_y) / art_h;

        var cached_cx: f32 = -1e9;
        var cached_idx: usize = 0;
        var cached_ink_b: u8 = 0;
        var cached_ink_g: u8 = 0;
        var cached_ink_r: u8 = 0;

        for (0..w_px) |px| {
            const px_f = @as(f32, @floatFromInt(px)) + 0.5;
            const gx = px_f + origin_x;
            const fx_f = @floor(@mod(gx, cell_w) / dot_px);
            const off = px * 4;
            if (fx_f < 0 or fx_f >= 5.0) {
                row[off + 3] = dim_alpha_u8;
                continue;
            }
            const cx = @floor(gx / cell_w);
            if (cx != cached_cx) {
                cached_cx = cx;
                const sample_x_pt = ((cx + 0.5) * cell_w - origin_x) / s;
                const u_art = (sample_x_pt + bleed_x) / art_w;
                const c_rgb = sampleSkyRgb(sc.sky_rgb, u_art, v_art);
                const luma = 0.299 * c_rgb[0] + 0.587 * c_rgb[1] + 0.114 * c_rgb[2];
                const norm = std.math.clamp((luma - 0.3) / 0.65, 0.0, 1.0);
                const lit = std.math.pow(f32, norm, 1.6);
                cached_idx = @min(@as(usize, 10), @as(usize, @intFromFloat(@floor(lit * 10.999))));
                const peak = @max(c_rgb[0], @max(c_rgb[1], @max(c_rgb[2], 0.25)));
                cached_ink_r = @intFromFloat(@round(std.math.clamp(c_rgb[0] / peak, 0.0, 1.0) * 0.62 * 255.0));
                cached_ink_g = @intFromFloat(@round(std.math.clamp(c_rgb[1] / peak, 0.0, 1.0) * 0.62 * 255.0));
                cached_ink_b = @intFromFloat(@round(std.math.clamp(c_rgb[2] / peak, 0.0, 1.0) * 0.62 * 255.0));
            }
            const fx: u32 = @intFromFloat(fx_f);
            if (ascii.glyphBit(cached_idx, fx, fy)) {
                row[off + 0] = cached_ink_b;
                row[off + 1] = cached_ink_g;
                row[off + 2] = cached_ink_r;
                row[off + 3] = lit_alpha_u8;
            } else {
                row[off + 3] = dim_alpha_u8;
            }
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

/// Renders (or reuses cached) premultiplied BGRA8 holographic foil + pointer
/// glare overlay implementing all 5 Zeron finishes (`aurora`, `reverse`,
/// `secret`, `starlight`, `glyph`).
pub fn renderFoilOverlay(
    cache: *FoilCache,
    gpa: Allocator,
    w_pt: f32,
    h_pt: f32,
    holo: ascii.Holo,
    pointer: [2]f32,
    strength: f32,
) ?ui.Texture {
    if (strength <= 0.005) return null;
    const w_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(w_pt))));
    const h_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(h_pt))));
    const hx = std.math.clamp(pointer[0], -0.4, 1.4);
    const hy = std.math.clamp(pointer[1], -0.4, 1.4);
    const k = std.math.clamp(strength, 0.0, 1.0);
    const hx_q: u16 = @intFromFloat(@round((hx + 0.5) * 100.0));
    const hy_q: u16 = @intFromFloat(@round((hy + 0.5) * 100.0));
    const k_q: u16 = @intFromFloat(@round(k * 50.0));
    const needed: usize = @as(usize, w_px) * @as(usize, h_px) * 4;

    if (cache.buf.len == needed and cache.w_px == w_px and cache.h_px == h_px and
        cache.holo == holo and cache.hx_q == hx_q and cache.hy_q == hy_q and cache.strength_q == k_q)
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

    const zoom = w_pt / base_w;
    const tilt_x = hx - 0.5;
    const tilt_y = hy - 0.5;
    const w_f: f32 = @floatFromInt(w_px);
    const h_f: f32 = @floatFromInt(h_px);

    for (0..h_px) |py| {
        const y_pt = (@as(f32, @floatFromInt(py)) + 0.5) / zoom;
        const v = (@as(f32, @floatFromInt(py)) + 0.5) / h_f;
        const paper = smoothstep(0.5, 0.62, v);
        const quiet = mixf(1.0, 0.4, paper);
        const along = smoothstep(0.0, 0.25, v) * (1.0 - smoothstep(0.75, 1.0, v));
        const off_y = v - hy;
        const row = cache.buf[py * w_px * 4 ..];

        for (0..w_px) |px| {
            const x_pt = (@as(f32, @floatFromInt(px)) + 0.5) / zoom;
            const u = (@as(f32, @floatFromInt(px)) + 0.5) / w_f;
            const across = (u - hx) + (v - hy);

            var shine_rgb = [3]f32{ 1.0, 1.0, 1.0 };
            var shine_a: f32 = 0.0;

            switch (holo) {
                .reverse => {
                    const cx = @floor(x_pt / 2.5);
                    const cy = @floor(y_pt / 2.5);
                    const hval = hash2(cx, cy);
                    if (hval >= 0.5) {
                        const s = @max(@sin(hval * 40.0 + tilt_x * 9.0 + tilt_y * 7.0), 0.0);
                        const glint = std.math.pow(f32, s, 14.0);
                        shine_rgb = mix3(spectrum(hval * 2.0 + tilt_x), .{ 1, 1, 1 }, 0.35);
                        shine_a = (glint * 0.7 + 0.05) * mixf(1.0, 0.35, paper);
                    } else {
                        shine_rgb = mix3(spectrum(hval * 2.0 + tilt_x), .{ 1, 1, 1 }, 0.35);
                        shine_a = 0.05 * mixf(1.0, 0.35, paper);
                    }
                },
                .secret => {
                    const d1 = fract((x_pt + y_pt) / 4.0);
                    const d2 = fract((x_pt - y_pt) / 4.0);
                    const lines = @max(1.0 - smoothstep(0.0, 0.2, @abs(d1 - 0.5)), 1.0 - smoothstep(0.0, 0.2, @abs(d2 - 0.5)));
                    shine_rgb = spectrum((u - v) * 1.3 + tilt_x * 1.6 - tilt_y);
                    shine_a = lines * (0.1 + 0.26 * @exp(-across * across * 3.0)) * quiet;
                },
                .starlight => {
                    const cell_sz: f32 = 16.0;
                    const cx = @floor(x_pt / cell_sz);
                    const cy = @floor(y_pt / cell_sz);
                    const hval = hash2(cx, cy);
                    const centre_x = (cx + 0.3 + 0.4 * hash2(cx + 7.0, cy + 7.0)) * cell_sz;
                    const centre_y = (cy + 0.3 + 0.4 * hash2(cx + 13.0, cy + 13.0)) * cell_sz;
                    const dx = @abs(x_pt - centre_x);
                    const dy = @abs(y_pt - centre_y);
                    const star = @exp(-dx * 0.7 - dy * 4.0) + @exp(-dy * 0.7 - dx * 4.0) + @exp(-(dx * dx + dy * dy) * 0.5);
                    const s = if (hval >= 0.62) @max(@sin(hval * 30.0 + tilt_x * 8.0 - tilt_y * 6.0), 0.0) else 0.0;
                    const glint = std.math.pow(f32, s, 6.0);
                    shine_rgb = mix3(.{ 1, 1, 1 }, spectrum(hval + v), 0.3);
                    shine_a = (@min(star * glint, 1.0) * 0.95 + 0.05 * @exp(-across * across * 4.0)) * quiet;
                },
                .glyph => {
                    const g_px: f32 = 1.5;
                    const cw: f32 = 6.0 * g_px;
                    const ch: f32 = 8.0 * g_px;
                    const cx: u32 = @intFromFloat(@max(0.0, @floor(x_pt / cw)));
                    const cy: u32 = @intFromFloat(@max(0.0, @floor(y_pt / ch)));
                    const gidx: usize = 1 + @min(9, @as(usize, @intFromFloat(cellHash(cx, cy) * 9.999)));
                    const fx_f = @floor((x_pt - @as(f32, @floatFromInt(cx)) * cw) / g_px);
                    const fy_f = @floor((y_pt - @as(f32, @floatFromInt(cy)) * ch) / g_px);
                    var lit: f32 = 0.0;
                    if (fx_f >= 0.0 and fx_f < 5.0 and fy_f >= 0.0 and fy_f < 7.0) {
                        if (ascii.glyphBit(gidx, @intFromFloat(fx_f), @intFromFloat(fy_f))) lit = 1.0;
                    }
                    shine_rgb = spectrum(v * 1.5 + u * 0.7 + tilt_x);
                    shine_a = lit * @exp(-across * across * 7.0) * 0.6 * mixf(1.0, 0.3, paper);
                },
                .aurora => {
                    const x = u * 2.2 - tilt_x * 2.0 + v * 0.35;
                    const pillar = smoothstep(0.0, 1.0, 0.5 + 0.5 * @cos(x * 6.2831853));
                    shine_rgb = mix3(spectrum(u * 0.6 - tilt_x * 1.1 + v * 0.25), .{ 1, 1, 1 }, 0.35);
                    shine_a = pillar * 0.24 * along * quiet;
                },
            }

            const sa = std.math.clamp(shine_a * k, 0.0, 1.0);
            const off_x = u - hx;
            const ga = std.math.clamp(@exp(-(off_x * off_x + off_y * off_y) * 5.0) * 0.22 * k, 0.0, 1.0);
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
    const zoom: f32 = if (props.preview) preview_zoom else 1.0;
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

    var num_buf: [24]u8 = undefined;
    const num_str = ascii.formatMemberNumber(&num_buf, props.member_number);
    var date_buf: [32]u8 = undefined;
    const since_str = ascii.formatSinceDate(&date_buf, props.started_at orelse 1794700800);

    const col = ui.div(c).column().itemsCenter().gap(8);
    defer col.end();

    {
        ui.key(c, if (props.preview) "member-card-preview" else "member-card");
        const card = ui.div(c).column().size(w, h).rounded(radius).bg(ui.Color.hex(0x1c1b22))
            .shadow(.{ .color = ui.Color.black.alpha(0.28), .y = 14.0 * zoom, .blur = 32.0 * zoom })
            .clip();
        defer card.end();

        const hot = card.hovered() and !props.preview;
        state.hovered = hot;
        if (hot) {
            if (c.rects.get(c.node(card.index).id)) |rect| {
                state.hover_x = std.math.clamp((c.input.mouse.x - rect.x) / @max(1.0, rect.w), 0.0, 1.0);
                state.hover_y = std.math.clamp((c.input.mouse.y - rect.y) / @max(1.0, rect.h), 0.0, 1.0);
            }
        }
        const target_tx: f32 = if (hot and !c.reduced_motion) state.hover_x else 0.5;
        const target_ty: f32 = if (hot and !c.reduced_motion) state.hover_y else 0.5;
        const target_foil: f32 = if (hot) 1.0 else 0.0;
        if (c.reduced_motion) {
            state.tilt_x = 0.5;
            state.tilt_y = 0.5;
            state.foil_strength = target_foil;
        } else {
            state.tilt_x += (target_tx - state.tilt_x) * 0.25;
            state.tilt_y += (target_ty - state.tilt_y) * 0.25;
            state.foil_strength += (target_foil - state.foil_strength) * 0.25;
            if (@abs(target_tx - state.tilt_x) > 0.005 or @abs(target_ty - state.tilt_y) > 0.005 or @abs(target_foil - state.foil_strength) > 0.01) {
                c.frameIn(1.0 / 60.0);
            }
        }

        const effective_tx = if (props.force_holo) |fh| fh[0] else state.tilt_x;
        const effective_ty = if (props.force_holo) |fh| fh[1] else state.tilt_y;
        const effective_foil = if (props.force_holo != null) 1.0 else state.foil_strength;
        const foil_pt = if (props.force_holo) |fh| fh else [2]f32{ state.hover_x, state.hover_y };

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

        // 2. 5×7 ASCII character sky overlay sampling the selected sky layer.
        if (renderSkyOverlay(&state.sky, gpa, w, h, c.scale, traits.sky % scene_count, traits.sky_seed)) |tex| {
            ui.texture(c, .{
                .absolute = true,
                .width = .{ .px = w },
                .height = .{ .px = h },
                .radius = radius,
            }, tex, .{ 0, 0, 1, 1 }, 1.0);
        }

        // 3a. Shared Ensō halo layer (`depth == 1.0`) shifted against tilt.
        {
            const shift_x = if (props.preview or c.reduced_motion)
                @as(f32, 0.0)
            else
                std.math.clamp((0.5 - effective_tx) * 1.0 * 16.0 * zoom, -bleed_x, bleed_x);
            const shift_y = if (props.preview or c.reduced_motion)
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
            const shift_x = if (props.preview or c.reduced_motion)
                @as(f32, 0.0)
            else
                std.math.clamp((0.5 - effective_tx) * 2.0 * 16.0 * zoom, -bleed_x, bleed_x);
            const shift_y = if (props.preview or c.reduced_motion)
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

        // 4. 7-stop `#f4efe6` cream paper fade rising beneath card words.
        ui.div(c).absolute().offset(0, 0).size(w, h).bg(paper_bg).gradientStops(&paper_stops, null).end();

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

        // 6. Holographic foil finish & pointer glare (on hover or forced preview).
        if (effective_foil > 0.01) {
            if (renderFoilOverlay(&state.foil, gpa, w, h, traits.holo, foil_pt, effective_foil)) |tex| {
                ui.texture(c, .{
                    .absolute = true,
                    .width = .{ .px = w },
                    .height = .{ .px = h },
                    .radius = radius,
                }, tex, .{ 0, 0, 1, 1 }, 1.0);
            }
        }

        // 7. Crisp perimeter card hairline (Founder gold accent for members #1..1000).
        if (is_founder and !props.preview) {
            ui.div(c).absolute().offset(0, 0).size(w, h).rounded(radius).border(ui.Color.hex(0xd4a64a).alpha(0.55)).borderW(1.25).end();
        } else {
            ui.div(c).absolute().offset(0, 0).size(w, h).rounded(radius).border(ui.Color.black.alpha(0.12)).borderW(1).end();
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
                if (sz.w != 432 or sz.h != 576) s.all_sized = false;
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
                    if (sz.w != 432 or sz.h != 576) s.all_sized = false;
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

test "renderSkyOverlay produces premultiplied BGRA8 sky dither, reuses cache, and leaves bottom transparent for paper" {
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

    // Every pixel satisfies premultiplied BGRA invariant (b,g,r <= a).
    var saw_lit = false;
    var saw_dim = false;
    for (0..360 * 400) |p| {
        const off = p * 4;
        const b = tex1.bgra[off + 0];
        const g = tex1.bgra[off + 1];
        const r = tex1.bgra[off + 2];
        const a = tex1.bgra[off + 3];
        try testing.expect(b <= a and g <= a and r <= a);
        if (a == 170) saw_lit = true;
        if (a == 31) saw_dim = true;
    }
    try testing.expect(saw_lit and saw_dim);

    // Lower region covered by solid paper fade is zeroed.
    const bot_off = (500 * 360 + 180) * 4;
    try testing.expectEqual(@as(u8, 0), tex1.bgra[bot_off + 3]);
}

test "renderFoilOverlay produces valid premultiplied BGRA8 for all 5 finishes" {
    var cache: FoilCache = .{};
    defer cache.deinit(testing.allocator);

    var nonzero_counts: [ascii.holos.len]usize = .{ 0, 0, 0, 0, 0 };
    for (ascii.holos, 0..) |holo, idx| {
        const tex = renderFoilOverlay(&cache, testing.allocator, 150, 210, holo, .{ 0.42, 0.36 }, 1.0).?;
        try testing.expectEqual(@as(u32, 150), tex.width);
        try testing.expectEqual(@as(u32, 210), tex.height);
        for (0..150 * 210) |p| {
            const off = p * 4;
            const b = tex.bgra[off + 0];
            const g = tex.bgra[off + 1];
            const r = tex.bgra[off + 2];
            const a = tex.bgra[off + 3];
            try testing.expect(b <= a and g <= a and r <= a);
            if (a > 0) nonzero_counts[idx] += 1;
        }
        try testing.expect(nonzero_counts[idx] > 100);
    }
}
