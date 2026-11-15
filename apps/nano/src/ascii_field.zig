//! Shared 5×7 ASCII glyph bitmap ramp (` .-+xXS80#@`), deterministic member
//! card seeding (`cardSeed`), formatting helpers, and the premultiplied BGRA8
//! effort-slider texture renderer (`effort_slider.luau`).
const std = @import("std");
const nanoui = @import("nanoui");
const Allocator = std.mem.Allocator;

/// 5×7 monochrome bitmap glyphs ordered by ink density (` .-+xXS80#@`).
pub const glyphs = [11][2]u32{
    .{ 0, 0 },
    .{ 402653184, 12 },
    .{ 1015808, 0 },
    .{ 139432064, 0 },
    .{ 340083712, 17 },
    .{ 581052977, 17 },
    .{ 35078671, 30 },
    .{ 588727854, 14 },
    .{ 597347886, 14 },
    .{ 368409930, 10 },
    .{ 561700398, 15 },
};

pub fn glyphBit(idx: usize, fx: u32, fy: u32) bool {
    if (fx >= 5 or fy >= 7) return false;
    const g = glyphs[@min(idx, glyphs.len - 1)];
    const word: u32 = if (fy < 6) (g[0] >> @intCast(fy * 5)) else g[1];
    return ((word >> @intCast(4 - fx)) & 1) != 0;
}

/// Holographic foil finishes, in the exact order indexed by `cardSeed`.
pub const Holo = enum(u3) {
    aurora = 0,
    reverse = 1,
    secret = 2,
    starlight = 3,
    glyph = 4,

    pub fn label(h: Holo) []const u8 {
        return switch (h) {
            .aurora => "AURORA FOIL",
            .reverse => "REVERSE FOIL",
            .secret => "SECRET RARE",
            .starlight => "STARLIGHT FOIL",
            .glyph => "KUMIKO FOIL",
        };
    }
};

pub const holos = [_]Holo{ .aurora, .reverse, .secret, .starlight, .glyph };
pub const preview_seed = "harness-enso-30";

/// Murmur3 32-bit finalizer matching Zeron's `card_seed.fmix32`.
pub fn fmix32(in_h: u32) u32 {
    var h = in_h;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

/// FNV-1a 32 (`0x811c9dc5`, prime `0x01000193`) followed by `fmix32` over `seed ++ salt`.
pub fn cardHashSalted(seed: []const u8, salt: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (seed) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    for (salt) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return fmix32(h);
}

/// Red-ochre / mineral-pigment Hanko seal styles stamped beside card titles.
pub const Seal = enum(u3) {
    shuin = 0,
    kin_in = 1,
    ai_in = 2,
    seiji = 3,
    sumi_in = 4,
    akane = 5,
    kohaku = 6,
    fuji_in = 7,

    pub fn label(s: Seal) []const u8 {
        return switch (s) {
            .shuin => "SHU-IN",
            .kin_in => "KIN-IN",
            .ai_in => "AI-IN",
            .seiji => "SEIJI",
            .sumi_in => "SUMI-IN",
            .akane => "AKANE",
            .kohaku => "KOHAKU",
            .fuji_in => "FUJI-IN",
        };
    }
};

pub const seals = [_]Seal{ .shuin, .kin_in, .ai_in, .seiji, .sumi_in, .akane, .kohaku, .fuji_in };

pub const CardTraits = struct {
    scene: u32,
    sky: u32,
    enso: u32,
    holo: Holo,
    seal: Seal,
    sky_seed: u32,
};

/// Bijective 128,000-deck card trait assignment matching `harness_member_card_traits`
/// in PostgreSQL and `deriveMemberCardTraits` on edge:
///   - First 3,200 members receive strictly 1-of-1 unique `(scene, sky, enso)` artwork tuples
///     with full mixing across all 20 scenes, 20 skies, 8 Ensōs, 5 holos, and 8 seals
///     already appearing inside the first 1,000 founder numbers.
///   - Members 1..128,000 receive strictly 1-of-1 unique `(scene, sky, enso, holo, seal)`
///     5-trait combinations via epoch folding across holo and seal.
pub fn memberCardTraits(member_number: u64, scenes: u32, ensos: u32) CardTraits {
    const s_cap = @max(1, scenes);
    const e_cap = @max(1, ensos);
    const clamped: u64 = if (member_number > 0) member_number - 1 else 0;
    const m0: u64 = clamped % 128_000;
    const epoch: u64 = m0 / 3_200;
    const art_idx: u64 = (m0 * 1_993 + 733) % 3_200;
    const scene_base: u64 = art_idx % 20;
    const sky_base: u64 = (scene_base + ((art_idx / 20) % 20)) % 20;
    const enso_base: u64 = (art_idx / 400) % 8;
    const holo_idx: usize = @intCast((m0 * 3 + (art_idx / 20) + 2 + epoch) % 5);
    const seal_idx: usize = @intCast((m0 * 5 + (art_idx / 80) + 1 + (epoch / 5)) % 8);
    return .{
        .scene = @intCast(scene_base % s_cap),
        .sky = @intCast(sky_base % s_cap),
        .enso = @intCast(enso_base % e_cap),
        .holo = holos[holo_idx],
        .seal = seals[seal_idx],
        .sky_seed = fmix32(@as(u32, @truncate(m0)) +% 0x9e3779b1),
    };
}

/// Deterministic fallback traits when a signed-out/local preview card has no member number.
pub fn pickCardTraits(seed: []const u8, scenes: u32, ensos: u32) CardTraits {
    const s_cap = @max(1, scenes);
    const e_cap = @max(1, ensos);
    const sky_seed = cardHashSalted(seed, ":sky");
    if (std.mem.eql(u8, seed, preview_seed)) {
        return .{
            .scene = 0,
            .sky = 0,
            .enso = 0,
            .holo = .aurora,
            .seal = .shuin,
            .sky_seed = sky_seed,
        };
    }
    return .{
        .scene = cardHashSalted(seed, ":scene") % s_cap,
        .sky = sky_seed % s_cap,
        .enso = cardHashSalted(seed, ":enso") % e_cap,
        .holo = holos[cardHashSalted(seed, ":holo") % holos.len],
        .seal = seals[cardHashSalted(seed, ":seal") % seals.len],
        .sky_seed = sky_seed,
    };
}

/// Six-digit centered-dot member badge (`"000·042"`).
pub fn formatMemberNumber(buf: []u8, num: ?u64) []const u8 {
    const v = num orelse 0;
    return std.fmt.bufPrint(buf, "{d:0>3}·{d:0>3}", .{ (v / 1000) % 1000, v % 1000 }) catch "000·000";
}

/// Converts Unix epoch seconds (UTC) to `"MMM D, YYYY"` (e.g. `"Nov 14, 2023"`).
pub fn formatSinceDate(buf: []u8, epoch_secs: i64) []const u8 {
    const months = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const days = @divFloor(epoch_secs, 86400);
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y_base: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const day: u64 = doy - (153 * mp + 2) / 5 + 1;
    const month: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = y_base + @as(i64, if (month <= 2) 1 else 0);
    return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ months[@intCast(month - 1)], day, year }) catch "Jan 1, 1970";
}

pub const EffortLook = struct {
    hex: u24,
    to: f32,
    wander: f32,
    drift: f32,
};

const effort_ladder = [7]EffortLook{
    .{ .hex = 0x8b8b93, .to = 0.24, .wander = 0.18, .drift = 0.10 }, // none
    .{ .hex = 0x8a9fa5, .to = 0.34, .wander = 0.22, .drift = 0.14 }, // minimal
    .{ .hex = 0x7d9bb8, .to = 0.44, .wander = 0.26, .drift = 0.18 }, // low
    .{ .hex = 0x8d86d8, .to = 0.56, .wander = 0.30, .drift = 0.24 }, // medium
    .{ .hex = 0xb47ec2, .to = 0.68, .wander = 0.34, .drift = 0.30 }, // high
    .{ .hex = 0xcda34d, .to = 0.82, .wander = 0.38, .drift = 0.38 }, // xhigh
    .{ .hex = 0xd9845a, .to = 0.96, .wander = 0.44, .drift = 0.48 }, // max
};

pub fn effortLook(level_id: []const u8, index: usize, count: usize) EffortLook {
    if (std.ascii.eqlIgnoreCase(level_id, "none")) return effort_ladder[0];
    if (std.ascii.eqlIgnoreCase(level_id, "minimal")) return effort_ladder[1];
    if (std.ascii.eqlIgnoreCase(level_id, "low")) return effort_ladder[2];
    if (std.ascii.eqlIgnoreCase(level_id, "medium")) return effort_ladder[3];
    if (std.ascii.eqlIgnoreCase(level_id, "high")) return effort_ladder[4];
    if (std.ascii.eqlIgnoreCase(level_id, "xhigh") or std.ascii.eqlIgnoreCase(level_id, "extended")) return effort_ladder[5];
    if (std.ascii.eqlIgnoreCase(level_id, "max") or std.ascii.eqlIgnoreCase(level_id, "ultra") or std.ascii.eqlIgnoreCase(level_id, "deep")) return effort_ladder[6];
    const at: f32 = if (count > 1) @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count - 1)) else 0;
    const ladder_idx: usize = @min(effort_ladder.len - 1, @as(usize, @intFromFloat(@round(at * @as(f32, @floatFromInt(effort_ladder.len - 1))))));
    return effort_ladder[ladder_idx];
}

pub fn noiseHash(x: f32, y: f32) f32 {
    const v = @sin(x * 127.1 + y * 311.7) * 43758.5453;
    return v - @floor(v);
}

pub fn valueNoise(x: f32, y: f32) f32 {
    const ix = @floor(x);
    const iy = @floor(y);
    const fx = x - ix;
    const fy = y - iy;
    const ux = fx * fx * (3.0 - 2.0 * fx);
    const uy = fy * fy * (3.0 - 2.0 * fy);
    const a = noiseHash(ix, iy);
    const b = noiseHash(ix + 1.0, iy);
    const c = noiseHash(ix, iy + 1.0);
    const d = noiseHash(ix + 1.0, iy + 1.0);
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy;
}

pub const EffortFieldCache = struct {
    buf: []u8 = &.{},
    w_px: u32 = 0,
    h_px: u32 = 0,
    fill_px: u32 = 0,
    hex: u24 = 0,
    tick: i64 = -1,

    pub fn deinit(c: *EffortFieldCache, gpa: Allocator) void {
        if (c.buf.len > 0) gpa.free(c.buf);
        c.* = .{};
    }
};

/// Renders (or returns cached) premultiplied BGRA8 ASCII effort field texture
/// matching `effort_slider.luau` (`6×8` cells, 12fps drift when not reduced).
pub fn renderEffortField(
    cache: *EffortFieldCache,
    gpa: Allocator,
    w_pt: f32,
    h_pt: f32,
    fill_pt: f32,
    scale: f32,
    look: EffortLook,
    time_s: f64,
    reduced_motion: bool,
) ?nanoui.ui.Texture {
    const s = if (std.math.isFinite(scale) and scale > 0) scale else 1.0;
    const w_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(w_pt * s))));
    const h_px: u32 = @max(1, @as(u32, @intFromFloat(@ceil(h_pt * s))));
    const fill_px: u32 = @min(w_px, @as(u32, @intFromFloat(@round(@max(0, fill_pt) * s))));
    const tick: i64 = if (reduced_motion) 0 else @intFromFloat(@floor(@max(0.0, time_s) * 12.0));
    const needed: usize = @as(usize, w_px) * @as(usize, h_px) * 4;

    if (cache.buf.len == needed and cache.w_px == w_px and cache.h_px == h_px and
        cache.fill_px == fill_px and cache.hex == look.hex and cache.tick == tick)
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
    cache.fill_px = fill_px;
    cache.hex = look.hex;
    cache.tick = tick;

    const r_f = @as(f32, @floatFromInt((look.hex >> 16) & 0xff));
    const g_f = @as(f32, @floatFromInt((look.hex >> 8) & 0xff));
    const b_f = @as(f32, @floatFromInt(look.hex & 0xff));

    const tint_a: f32 = 0.14;
    const tint_b: u8 = @intFromFloat(@round(b_f * tint_a));
    const tint_g: u8 = @intFromFloat(@round(g_f * tint_a));
    const tint_r: u8 = @intFromFloat(@round(r_f * tint_a));
    const tint_au: u8 = @intFromFloat(@round(255.0 * tint_a));

    // Clear whole buffer to transparent (0), fill active strip [0..fill_px) with tint wash.
    @memset(cache.buf, 0);
    for (0..h_px) |y| {
        const row = cache.buf[y * w_px * 4 ..];
        for (0..fill_px) |x| {
            row[x * 4 + 0] = tint_b;
            row[x * 4 + 1] = tint_g;
            row[x * 4 + 2] = tint_r;
            row[x * 4 + 3] = tint_au;
        }
    }

    if (fill_px > 0) {
        const px_unit: u32 = @max(1, @as(u32, @intFromFloat(@round(s))));
        const cell_w: u32 = 6 * px_unit;
        const cell_h: u32 = 8 * px_unit;
        const rows = h_px / cell_h;
        if (rows > 0) {
            const top_pad: u32 = (h_px - rows * cell_h) / 2;
            const cols: u32 = (fill_px + cell_w - 1) / cell_w;
            const time_q: f32 = @as(f32, @floatFromInt(tick)) / 12.0;
            const fill_denom: f32 = @max(1.0, @as(f32, @floatFromInt(fill_px)));

            for (0..rows) |cy| {
                for (0..cols) |cx| {
                    const cell_x0: u32 = @as(u32, @intCast(cx)) * cell_w;
                    const cell_y0: u32 = top_pad + @as(u32, @intCast(cy)) * cell_h;
                    const u = std.math.clamp((@as(f32, @floatFromInt(cx)) + 0.5) * @as(f32, @floatFromInt(cell_w)) / fill_denom, 0.0, 1.0);
                    var d = 0.04 + (look.to - 0.04) * std.math.pow(f32, u, 1.4);
                    d += (valueNoise(@as(f32, @floatFromInt(cx)) * 0.31 - time_q * look.drift, @as(f32, @floatFromInt(cy)) * 0.57 + 3.0) - 0.5) * look.wander;
                    d = std.math.clamp(d, 0.0, 1.0);
                    const glyph_idx: usize = @min(10, @as(usize, @intFromFloat(@floor(d * 10.999))));
                    if (glyph_idx == 0) continue;

                    const glyph_a: f32 = 0.45 + 0.55 * d;
                    const out_a: f32 = glyph_a + tint_a * (1.0 - glyph_a);
                    const pb: u8 = @intFromFloat(std.math.clamp(@round(b_f * out_a), 0.0, 255.0));
                    const pg: u8 = @intFromFloat(std.math.clamp(@round(g_f * out_a), 0.0, 255.0));
                    const pr: u8 = @intFromFloat(std.math.clamp(@round(r_f * out_a), 0.0, 255.0));
                    const pa: u8 = @intFromFloat(std.math.clamp(@round(255.0 * out_a), 0.0, 255.0));

                    for (0..7) |fy| {
                        if (!anyBitInRow(glyph_idx, @intCast(fy))) continue;
                        for (0..5) |fx| {
                            if (!glyphBit(glyph_idx, @intCast(fx), @intCast(fy))) continue;
                            const px_x0 = cell_x0 + @as(u32, @intCast(fx)) * px_unit;
                            const px_y0 = cell_y0 + @as(u32, @intCast(fy)) * px_unit;
                            const x_end = @min(fill_px, px_x0 + px_unit);
                            const y_end = @min(h_px, px_y0 + px_unit);
                            if (px_x0 >= x_end or px_y0 >= y_end) continue;
                            for (px_y0..y_end) |py| {
                                const row = cache.buf[py * w_px * 4 ..];
                                for (px_x0..x_end) |px| {
                                    row[px * 4 + 0] = pb;
                                    row[px * 4 + 1] = pg;
                                    row[px * 4 + 2] = pr;
                                    row[px * 4 + 3] = pa;
                                }
                            }
                        }
                    }
                }
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

fn anyBitInRow(idx: usize, fy: u32) bool {
    const g = glyphs[@min(idx, glyphs.len - 1)];
    const word: u32 = if (fy < 6) (g[0] >> @intCast(fy * 5)) else g[1];
    return (word & 0x1f) != 0;
}

const testing = std.testing;

test "glyphBit matches space, dot and @ glyph rows" {
    for (0..7) |y| {
        for (0..5) |x| {
            try testing.expect(!glyphBit(0, @intCast(x), @intCast(y)));
        }
    }
    try testing.expect(glyphBit(1, 2, 5));
    try testing.expect(glyphBit(10, 1, 0));
    try testing.expect(!glyphBit(10, 5, 0));
    try testing.expect(!glyphBit(10, 0, 7));
}

test "pickCardTraits and memberCardTraits are deterministic, collision-free, and cover all traits" {
    const a = pickCardTraits(preview_seed, 20, 8);
    const b = pickCardTraits(preview_seed, 20, 8);
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(u32, 0), a.scene);
    try testing.expectEqual(@as(u32, 0), a.sky);
    try testing.expectEqual(@as(u32, 0), a.enso);
    try testing.expectEqual(Holo.aurora, a.holo);
    try testing.expectEqual(Seal.shuin, a.seal);

    const c = pickCardTraits("user_ada", 20, 8);
    try testing.expect(c.scene < 20);
    try testing.expect(c.sky < 20);
    try testing.expect(c.enso < 8);

    // Every single member 1..3200 has a unique 3-layer artwork `(scene, sky, enso)`,
    // and members 1..1000 already cover all 20 scenes, 20 skies, 8 Ensōs, 5 holos, 8 seals.
    var seen_art: [3200]bool = @splat(false);
    var scene_mask: u32 = 0;
    var sky_mask: u32 = 0;
    var enso_mask: u16 = 0;
    var holo_mask: u8 = 0;
    var seal_mask: u16 = 0;

    for (1..3201) |m| {
        const t = memberCardTraits(m, 20, 8);
        try testing.expect(t.scene < 20);
        try testing.expect(t.sky < 20);
        try testing.expect(t.enso < 8);
        const art_code: usize = (@as(usize, t.enso) * 20 + @as(usize, t.sky)) * 20 + @as(usize, t.scene);
        try testing.expect(!seen_art[art_code]);
        seen_art[art_code] = true;

        if (m <= 1000) {
            scene_mask |= @as(u32, 1) << @intCast(t.scene);
            sky_mask |= @as(u32, 1) << @intCast(t.sky);
            enso_mask |= @as(u16, 1) << @intCast(t.enso);
            holo_mask |= @as(u8, 1) << @backingInt(t.holo);
            seal_mask |= @as(u16, 1) << @backingInt(t.seal);
        }
    }

    try testing.expectEqual((@as(u32, 1) << 20) - 1, scene_mask);
    try testing.expectEqual((@as(u32, 1) << 20) - 1, sky_mask);
    try testing.expectEqual((@as(u16, 1) << 8) - 1, enso_mask);
    try testing.expectEqual((@as(u8, 1) << 5) - 1, holo_mask);
    try testing.expectEqual((@as(u16, 1) << 8) - 1, seal_mask);

    // Every single member 1..128000 has a unique 5-trait tuple `(scene, sky, enso, holo, seal)`.
    const seen_full = try testing.allocator.alloc(u8, 128_000);
    defer testing.allocator.free(seen_full);
    @memset(seen_full, 0);
    for (1..128_001) |m| {
        const t = memberCardTraits(m, 20, 8);
        const full_code: usize = ((((@as(usize, t.scene) * 20 + @as(usize, t.sky)) * 8 + @as(usize, t.enso)) * 5 + @backingInt(t.holo)) * 8) + @backingInt(t.seal);
        try testing.expectEqual(@as(u8, 0), seen_full[full_code]);
        seen_full[full_code] = 1;
    }
}

test "member number and UTC since date formatting" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("000·000", formatMemberNumber(&buf, null));
    try testing.expectEqualStrings("000·042", formatMemberNumber(&buf, 42));
    try testing.expectEqualStrings("004·182", formatMemberNumber(&buf, 4182));

    var dbuf: [32]u8 = undefined;
    try testing.expectEqualStrings("Jan 1, 1970", formatSinceDate(&dbuf, 0));
    try testing.expectEqualStrings("Nov 14, 2023", formatSinceDate(&dbuf, 1_700_000_000));
}

test "effortLook and EffortFieldCache render premultiplied BGRA8 textures and reuse cache" {
    const look = effortLook("high", 2, 3);
    try testing.expectEqual(@as(u24, 0xb47ec2), look.hex);

    var cache: EffortFieldCache = .{};
    defer cache.deinit(testing.allocator);

    const tex1 = renderEffortField(&cache, testing.allocator, 240, 20, 180, 2, look, 0.0, false).?;
    try testing.expectEqual(@as(u32, 480), tex1.width);
    try testing.expectEqual(@as(u32, 40), tex1.height);
    try testing.expectEqual(nanoui.ui.TextureFormat.bgra8, tex1.format);
    try testing.expectEqual(@as(usize, 480 * 40 * 4), tex1.bgra.len);

    // Cache hit within the same 12fps tick keeps the exact slice pointer.
    const tex2 = renderEffortField(&cache, testing.allocator, 240, 20, 180, 2, look, 0.04, false).?;
    try testing.expectEqual(tex1.bgra.ptr, tex2.bgra.ptr);

    // Alpha is non-zero in the active fill region and zero past fill_px.
    try testing.expect(tex1.bgra[3] > 0);
    const beyond = (20 * 480 + 470) * 4;
    try testing.expectEqual(@as(u8, 0), tex1.bgra[beyond + 3]);
}
