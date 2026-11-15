//! Curated & model-synthesized custom themes paired with procedural animated
//! ambient backdrops. Keeps contrast WCAG AA (>= 4.5:1) via `model_color.zig`.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;
const mc = @import("model_color.zig");
const theme = @import("theme.zig");
const themes = @import("themes.zig");

pub const Motif = enum {
    rain,
    constellations,
    waves,
    fireflies,
    petals,
    aurora,
    matrix,
    ripples,

    pub const all = [_]Motif{ .rain, .constellations, .waves, .fireflies, .petals, .aurora, .matrix, .ripples };

    pub fn fromString(raw: []const u8) ?Motif {
        inline for (all) |m| if (std.ascii.eqlIgnoreCase(@tagName(m), std.mem.trim(u8, raw, " \t\r\n"))) return m;
        return null;
    }

    pub fn label(m: Motif) []const u8 {
        return switch (m) {
            .rain => "Rain",
            .constellations => "Constellations",
            .waves => "Waves",
            .fireflies => "Fireflies",
            .petals => "Petals",
            .aurora => "Aurora",
            .matrix => "Matrix",
            .ripples => "Ripples",
        };
    }
};

pub const BackdropSpec = struct {
    motif: Motif,
    primary: Color,
    secondary: Color,
    speed: f32 = 0.85,
    intensity: f32 = 0.62,
};

pub const Preset = struct {
    id: []const u8,
    name: []const u8,
    subtitle: []const u8,
    variant: themes.Variant,
    backdrop: BackdropSpec,
    is_custom: bool = false,
};

pub const PaletteInput = struct {
    id: []const u8,
    name: []const u8,
    subtitle: []const u8,
    dark: bool,
    motif: Motif,
    speed: f32 = 0.85,
    intensity: f32 = 0.62,
    shell: []const u8,
    sidebar: []const u8,
    background: []const u8,
    card: []const u8,
    border: []const u8,
    text: []const u8,
    muted: []const u8,
    accent: []const u8,
    glow_primary: []const u8,
    glow_secondary: []const u8,
    is_custom: bool = false,
};

const Seed = struct {
    id: []const u8,
    name: []const u8,
    subtitle: []const u8,
    dark: bool,
    motif: Motif,
    speed: f32,
    intensity: f32,
    shell: u24,
    sidebar: u24,
    background: u24,
    card: u24,
    border: u24,
    text: u24,
    muted: u24,
    accent: u24,
    glow1: u24,
    glow2: u24,
};

const curated_seeds = [_]Seed{
    // Dark curated scenes (12)
    .{ .id = "custom-kyoto-rain", .name = "Kyoto Rain", .subtitle = "Slate night · indigo drizzle", .dark = true, .motif = .rain, .speed = 1.05, .intensity = 0.68, .shell = 0x0b0f17, .sidebar = 0x0e1420, .background = 0x111827, .card = 0x172033, .border = 0x26344f, .text = 0xe8eef9, .muted = 0x94a3b8, .accent = 0x60a5fa, .glow1 = 0x60a5fa, .glow2 = 0x38bdf8 },
    .{ .id = "custom-astral-observatory", .name = "Astral Observatory", .subtitle = "Deep zenith · drifting starfield", .dark = true, .motif = .constellations, .speed = 0.65, .intensity = 0.65, .shell = 0x090b16, .sidebar = 0x0d1020, .background = 0x101428, .card = 0x171d38, .border = 0x29325c, .text = 0xf1f5ff, .muted = 0x9aa5ce, .accent = 0xa78bfa, .glow1 = 0xa78bfa, .glow2 = 0x7dd3fc },
    .{ .id = "custom-midnight-sakura", .name = "Midnight Sakura", .subtitle = "Sumi plum · falling petals", .dark = true, .motif = .petals, .speed = 0.78, .intensity = 0.64, .shell = 0x130d15, .sidebar = 0x18111b, .background = 0x1d1421, .card = 0x271b2d, .border = 0x3e2a47, .text = 0xf9ecf4, .muted = 0xc4a2b8, .accent = 0xf472b6, .glow1 = 0xf472b6, .glow2 = 0xfba4c8 },
    .{ .id = "custom-nordic-aurora", .name = "Nordic Aurora", .subtitle = "Polar spruce · shimmering veil", .dark = true, .motif = .aurora, .speed = 0.72, .intensity = 0.68, .shell = 0x071316, .sidebar = 0x0a1a1f, .background = 0x0d2128, .card = 0x122c36, .border = 0x1f4854, .text = 0xe7fbf7, .muted = 0x8bc0b8, .accent = 0x34d399, .glow1 = 0x34d399, .glow2 = 0x22d3ee },
    .{ .id = "custom-hotaru-river", .name = "Hotaru River", .subtitle = "Moss bank · lantern fireflies", .dark = true, .motif = .fireflies, .speed = 0.70, .intensity = 0.66, .shell = 0x0c130f, .sidebar = 0x101a14, .background = 0x142019, .card = 0x1b2b21, .border = 0x2d4435, .text = 0xedf6ee, .muted = 0x9ab8a0, .accent = 0xfbbf24, .glow1 = 0xfbbf24, .glow2 = 0x86efac },
    .{ .id = "custom-kanagawa-surf", .name = "Kanagawa Surf", .subtitle = "Prussian sea · rolling swells", .dark = true, .motif = .waves, .speed = 0.80, .intensity = 0.65, .shell = 0x09111a, .sidebar = 0x0d1724, .background = 0x101e2e, .card = 0x16293f, .border = 0x264364, .text = 0xeaf2f8, .muted = 0x92aec6, .accent = 0x38bdf8, .glow1 = 0x38bdf8, .glow2 = 0x93c5fd },
    .{ .id = "custom-phosphor-grid", .name = "Phosphor Grid", .subtitle = "CRT obsidian · emerald streams", .dark = true, .motif = .matrix, .speed = 1.08, .intensity = 0.60, .shell = 0x070d09, .sidebar = 0x0a130d, .background = 0x0d1811, .card = 0x132219, .border = 0x1f3b2a, .text = 0xe4fce9, .muted = 0x82b890, .accent = 0x4ade80, .glow1 = 0x4ade80, .glow2 = 0x2dd4bf },
    .{ .id = "custom-karesansui-night", .name = "Karesansui Night", .subtitle = "Basalt court · calm water rings", .dark = true, .motif = .ripples, .speed = 0.62, .intensity = 0.62, .shell = 0x111214, .sidebar = 0x16171a, .background = 0x1a1b1f, .card = 0x23252b, .border = 0x353942, .text = 0xf0efe9, .muted = 0xa2a4aa, .accent = 0xd6d3d1, .glow1 = 0xe7e5e4, .glow2 = 0x9ca3af },
    .{ .id = "custom-kumiko-lantern", .name = "Kumiko Lantern", .subtitle = "Cedar screen · warm embers", .dark = true, .motif = .fireflies, .speed = 0.68, .intensity = 0.64, .shell = 0x16100b, .sidebar = 0x1c140e, .background = 0x221912, .card = 0x2d2118, .border = 0x473426, .text = 0xfbf1e6, .muted = 0xc9ac93, .accent = 0xfb923c, .glow1 = 0xfb923c, .glow2 = 0xfbbf24 },
    .{ .id = "custom-obsidian-nebula", .name = "Obsidian Nebula", .subtitle = "Void violet · stellar prism", .dark = true, .motif = .constellations, .speed = 0.72, .intensity = 0.66, .shell = 0x0c0914, .sidebar = 0x100c1b, .background = 0x141022, .card = 0x1d1731, .border = 0x332954, .text = 0xf3ecff, .muted = 0xb09fd1, .accent = 0xc084fc, .glow1 = 0xc084fc, .glow2 = 0xf472b6 },
    .{ .id = "custom-arashiyama-dusk", .name = "Arashiyama Dusk", .subtitle = "Bamboo mist · soft evening rain", .dark = true, .motif = .rain, .speed = 0.92, .intensity = 0.62, .shell = 0x0d1413, .sidebar = 0x111b19, .background = 0x162220, .card = 0x1d2d2a, .border = 0x2e4641, .text = 0xeaf5f2, .muted = 0x94b5ae, .accent = 0x2dd4bf, .glow1 = 0x2dd4bf, .glow2 = 0x6ee7b7 },
    .{ .id = "custom-ember-tide", .name = "Ember Tide", .subtitle = "Volcanic shore · copper waves", .dark = true, .motif = .waves, .speed = 0.76, .intensity = 0.64, .shell = 0x150d0e, .sidebar = 0x1c1112, .background = 0x221617, .card = 0x2e1e20, .border = 0x4a3033, .text = 0xfbeced, .muted = 0xc79ea2, .accent = 0xf87171, .glow1 = 0xf87171, .glow2 = 0xfb923c },
    // Light curated scenes (8)
    .{ .id = "custom-washi-sakura", .name = "Washi Sakura", .subtitle = "Warm rice paper · drifting cherry", .dark = false, .motif = .petals, .speed = 0.75, .intensity = 0.56, .shell = 0xf7f1ee, .sidebar = 0xfaf5f3, .background = 0xfffaf8, .card = 0xfbf2ef, .border = 0xe6d6d2, .text = 0x261a1c, .muted = 0x735c60, .accent = 0xc83e6b, .glow1 = 0xf472b6, .glow2 = 0xfb7185 },
    .{ .id = "custom-morning-koi", .name = "Morning Koi", .subtitle = "Sunlit stone · pond ripples", .dark = false, .motif = .ripples, .speed = 0.64, .intensity = 0.54, .shell = 0xf3f1eb, .sidebar = 0xf7f5f0, .background = 0xfcfbf7, .card = 0xf5f2ea, .border = 0xded9cd, .text = 0x1f1e1a, .muted = 0x676359, .accent = 0xc2410c, .glow1 = 0xfb923c, .glow2 = 0x60a5fa },
    .{ .id = "custom-coastal-linen", .name = "Coastal Linen", .subtitle = "Sea glass · gentle ocean swell", .dark = false, .motif = .waves, .speed = 0.78, .intensity = 0.55, .shell = 0xedf3f6, .sidebar = 0xf2f7f9, .background = 0xf8fbfc, .card = 0xf0f6f8, .border = 0xd2e1e7, .text = 0x16242b, .muted = 0x526b78, .accent = 0x0284c7, .glow1 = 0x0284c7, .glow2 = 0x0d9488 },
    .{ .id = "custom-matcha-garden", .name = "Matcha Garden", .subtitle = "Kyoto tea leaf · quiet fireflies", .dark = false, .motif = .fireflies, .speed = 0.68, .intensity = 0.54, .shell = 0xf0f3ec, .sidebar = 0xf4f7f1, .background = 0xfafcf8, .card = 0xf2f6ed, .border = 0xd6dfd0, .text = 0x1a2618, .muted = 0x586b54, .accent = 0x15803d, .glow1 = 0x22c55e, .glow2 = 0xd97706 },
    .{ .id = "custom-alpine-glaze", .name = "Alpine Glaze", .subtitle = "Morning frost · translucent aurora", .dark = false, .motif = .aurora, .speed = 0.72, .intensity = 0.56, .shell = 0xeef3f8, .sidebar = 0xf3f7fb, .background = 0xf9fcff, .card = 0xf1f6fb, .border = 0xd3e0ec, .text = 0x152230, .muted = 0x556a7f, .accent = 0x2563eb, .glow1 = 0x2563eb, .glow2 = 0x0d9488 },
    .{ .id = "custom-sunlit-mist", .name = "Sunlit Mist", .subtitle = "Silver shower · warm courtyard", .dark = false, .motif = .rain, .speed = 0.95, .intensity = 0.52, .shell = 0xf1f2f4, .sidebar = 0xf6f7f9, .background = 0xfbfcfd, .card = 0xf3f5f8, .border = 0xd8dde5, .text = 0x1a1e26, .muted = 0x5b6474, .accent = 0x4f46e5, .glow1 = 0x4f46e5, .glow2 = 0x0ea5e9 },
    .{ .id = "custom-celadon-pond", .name = "Celadon Pond", .subtitle = "Jade ceramic · slow concentric rings", .dark = false, .motif = .ripples, .speed = 0.60, .intensity = 0.55, .shell = 0xebf3f0, .sidebar = 0xf0f7f4, .background = 0xf7fbf9, .card = 0xedf6f2, .border = 0xcee0d8, .text = 0x162620, .muted = 0x516e63, .accent = 0x0f766e, .glow1 = 0x0f766e, .glow2 = 0x38bdf8 },
    .{ .id = "custom-celestial-paper", .name = "Celestial Paper", .subtitle = "Ink observatory · fine constellations", .dark = false, .motif = .constellations, .speed = 0.65, .intensity = 0.54, .shell = 0xf2f0f7, .sidebar = 0xf6f5fa, .background = 0xfbfafd, .card = 0xf3f1f9, .border = 0xdcd7ea, .text = 0x1e192b, .muted = 0x625a78, .accent = 0x6d28d9, .glow1 = 0x7c3aed, .glow2 = 0x2563eb },
};

var curated_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var curated_cache: ?[]const Preset = null;

var user_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var user_cache: std.ArrayListUnmanaged(Preset) = .empty;

const custom_themes_file = "custom-themes.json";

pub fn curated() []const Preset {
    if (curated_cache) |list| return list;
    const alloc = curated_arena.allocator();
    var out = alloc.alloc(Preset, curated_seeds.len) catch return &.{};
    for (curated_seeds, 0..) |s, i| {
        const colors = buildColors(
            s.dark,
            rgbaHex(s.shell),
            rgbaHex(s.sidebar),
            rgbaHex(s.background),
            rgbaHex(s.card),
            rgbaHex(s.border),
            rgbaHex(s.text),
            rgbaHex(s.muted),
            rgbaHex(s.accent),
        );
        out[i] = .{
            .id = s.id,
            .name = s.name,
            .subtitle = s.subtitle,
            .variant = .{
                .id = s.id,
                .family = "Custom Backdrop",
                .name = s.name,
                .dark = s.dark,
                .colors = colors,
            },
            .backdrop = .{
                .motif = s.motif,
                .primary = Color.hex(s.glow1),
                .secondary = Color.hex(s.glow2),
                .speed = s.speed,
                .intensity = s.intensity,
            },
            .is_custom = false,
        };
    }
    curated_cache = out;
    return out;
}

pub fn userPresets() []const Preset {
    return user_cache.items;
}

pub fn findPreset(id: []const u8) ?*const Preset {
    for (curated()) |*p| if (std.mem.eql(u8, p.id, id)) return p;
    for (userPresets()) |*p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

pub fn findVariant(id: []const u8) ?*const themes.Variant {
    if (findPreset(id)) |p| return &p.variant;
    return null;
}

pub fn findBackdrop(theme_id: []const u8, scene_override: []const u8, k: theme.Colors) ?BackdropSpec {
    if (std.mem.eql(u8, scene_override, "off") or std.mem.eql(u8, scene_override, "none")) return null;
    if (findPreset(theme_id)) |p| {
        if (std.mem.eql(u8, scene_override, "auto") or scene_override.len == 0) return p.backdrop;
        if (Motif.fromString(scene_override)) |m| {
            var spec = p.backdrop;
            spec.motif = m;
            return spec;
        }
        return p.backdrop;
    }
    if (std.mem.eql(u8, scene_override, "auto") or scene_override.len == 0) return null;
    const m = Motif.fromString(scene_override) orelse return null;
    return .{
        .motif = m,
        .primary = k.accent,
        .secondary = k.accent.mix(k.text, 0.35),
        .speed = 0.85,
        .intensity = if (k.dark) 0.62 else 0.54,
    };
}

pub fn loadUserThemes(io: std.Io, data_dir: []const u8) void {
    _ = user_arena.reset(.retain_capacity);
    user_cache = .empty;
    const alloc = user_arena.allocator();
    const path = std.fs.path.join(alloc, &.{ data_dir, custom_themes_file }) catch return;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(2 * 1024 * 1024)) catch return;
    const doc = json.parseFromSliceLeaky(json.Value, alloc, bytes, .{}) catch return;
    const arr = if (doc == .object) (doc.object.get("themes") orelse return) else return;
    if (arr != .array) return;
    for (arr.array.items) |item| {
        if (parseGeneratedJson(alloc, item)) |p| {
            var owned = p;
            owned.is_custom = true;
            user_cache.append(alloc, owned) catch continue;
        }
    }
}

pub fn saveUserTheme(io: std.Io, data_dir: ?[]const u8, p: Preset) !Preset {
    const alloc = user_arena.allocator();
    var copy = p;
    copy.id = try alloc.dupe(u8, p.id);
    copy.name = try alloc.dupe(u8, p.name);
    copy.subtitle = try alloc.dupe(u8, p.subtitle);
    copy.variant.id = copy.id;
    copy.variant.family = "Generated";
    copy.variant.name = copy.name;
    copy.is_custom = true;

    // Replace existing custom preset with same id or prepend so newest appears first.
    var replaced = false;
    for (user_cache.items) |*slot| {
        if (std.mem.eql(u8, slot.id, copy.id)) {
            slot.* = copy;
            replaced = true;
            break;
        }
    }
    if (!replaced) try user_cache.insert(alloc, 0, copy);
    if (user_cache.items.len > 48) user_cache.shrinkRetainingCapacity(48);

    const dir = data_dir orelse return copy;
    var scratch_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const sa = scratch_arena.allocator();
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    var arr = json.Array.init(sa);
    for (user_cache.items) |item| {
        var obj: json.ObjectMap = .empty;
        try obj.put(sa, "id", .{ .string = item.id });
        try obj.put(sa, "name", .{ .string = item.name });
        try obj.put(sa, "subtitle", .{ .string = item.subtitle });
        try obj.put(sa, "dark", .{ .bool = item.variant.dark });
        try obj.put(sa, "scene", .{ .string = @tagName(item.backdrop.motif) });
        try obj.put(sa, "speed", .{ .float = item.backdrop.speed });
        try obj.put(sa, "intensity", .{ .float = item.backdrop.intensity });
        try obj.put(sa, "shell", .{ .string = try hexOfColor(sa, item.variant.colors.shell) });
        try obj.put(sa, "sidebar", .{ .string = try hexOfColor(sa, item.variant.colors.sidebar) });
        try obj.put(sa, "background", .{ .string = try hexOfColor(sa, item.variant.colors.background) });
        try obj.put(sa, "card", .{ .string = try hexOfColor(sa, item.variant.colors.card) });
        try obj.put(sa, "border", .{ .string = try hexOfColor(sa, item.variant.colors.border) });
        try obj.put(sa, "text", .{ .string = try hexOfColor(sa, item.variant.colors.text) });
        try obj.put(sa, "muted", .{ .string = try hexOfColor(sa, item.variant.colors.muted) });
        try obj.put(sa, "accent", .{ .string = try hexOfColor(sa, item.variant.colors.accent) });
        try obj.put(sa, "glowPrimary", .{ .string = try hexOfColor(sa, item.backdrop.primary) });
        try obj.put(sa, "glowSecondary", .{ .string = try hexOfColor(sa, item.backdrop.secondary) });
        try arr.append(.{ .object = obj });
    }
    var root: json.ObjectMap = .empty;
    try root.put(sa, "themes", .{ .array = arr });
    var aw: std.Io.Writer.Allocating = .init(sa);
    try json.Stringify.value(json.Value{ .object = root }, .{ .whitespace = .indent_2 }, &aw.writer);
    const p_path = try std.fs.path.join(sa, &.{ dir, custom_themes_file });
    const tmp = try std.fmt.allocPrint(sa, "{s}.tmp", .{p_path});
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = aw.written() });
    try cwd.rename(tmp, cwd, p_path, io);
    return copy;
}

pub fn clearUserThemes() void {
    _ = user_arena.reset(.retain_capacity);
    user_cache = .empty;
}

pub fn parseGeneratedJson(arena: std.mem.Allocator, v: json.Value) ?Preset {
    if (v != .object) return null;
    const o = v.object;
    const raw_id = strField(o, "id") orelse return null;
    const raw_name = strField(o, "name") orelse return null;
    const dark = if (o.get("dark")) |b| (if (b == .bool) b.bool else true) else true;
    const motif = if (strField(o, "scene")) |sc| (Motif.fromString(sc) orelse .rain) else .rain;
    const speed = floatField(o, "speed") orelse 0.85;
    const intensity = floatField(o, "intensity") orelse 0.62;
    const shell = rgbaParse(strField(o, "shell") orelse "") orelse rgbaHex(if (dark) 0x0b0f17 else 0xf4f4f6);
    const sidebar = rgbaParse(strField(o, "sidebar") orelse "") orelse shell;
    const bg = rgbaParse(strField(o, "background") orelse "") orelse rgbaHex(if (dark) 0x111827 else 0xfafafa);
    const card = rgbaParse(strField(o, "card") orelse "") orelse rgbaHex(if (dark) 0x172033 else 0xf2f3f5);
    const border = rgbaParse(strField(o, "border") orelse "") orelse rgbaHex(if (dark) 0x26344f else 0xd8dce3);
    const text = rgbaParse(strField(o, "text") orelse "") orelse rgbaHex(if (dark) 0xf1f5f9 else 0x181a1f);
    const muted = rgbaParse(strField(o, "muted") orelse "") orelse rgbaHex(if (dark) 0x94a3b8 else 0x5c6472);
    const accent = rgbaParse(strField(o, "accent") orelse "") orelse rgbaHex(if (dark) 0x60a5fa else 0x4f46e5);
    const glow1 = rgbaParse(strField(o, "glowPrimary") orelse "") orelse accent;
    const glow2 = rgbaParse(strField(o, "glowSecondary") orelse "") orelse accent.mix(text, 0.35);

    const id = arena.dupe(u8, raw_id) catch return null;
    const name = arena.dupe(u8, raw_name) catch return null;
    const sub = if (strField(o, "subtitle")) |s| (arena.dupe(u8, s) catch motif.label()) else (std.fmt.allocPrint(arena, "{s} · generated", .{motif.label()}) catch motif.label());

    return .{
        .id = id,
        .name = name,
        .subtitle = sub,
        .variant = .{
            .id = id,
            .family = "Generated",
            .name = name,
            .dark = dark,
            .colors = buildColors(dark, shell, sidebar, bg, card, border, text, muted, accent),
        },
        .backdrop = .{
            .motif = motif,
            .primary = glow1.color(),
            .secondary = glow2.color(),
            .speed = std.math.clamp(speed, 0.25, 2.5),
            .intensity = std.math.clamp(intensity, 0.15, 0.95),
        },
        .is_custom = true,
    };
}

/// Deterministic offline theme + animated backdrop synthesis matching the Rust engine synthesizer.
pub fn synthesizeFromPrompt(arena: std.mem.Allocator, prompt_in: []const u8, dark_hint: ?bool) Preset {
    const trimmed = std.mem.trim(u8, prompt_in, " \t\r\n");
    const prompt = if (trimmed.len > 0) trimmed else "Calm Zen Pond";
    var lower_buf: [256]u8 = undefined;
    const n = @min(prompt.len, lower_buf.len);
    for (prompt[0..n], 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const lower = lower_buf[0..n];

    const dark = dark_hint orelse blk: {
        const light_hits = countMatches(lower, &.{ "light", "paper", "morning", "day", "snow", "cream", "washi", "sakura", "spring", "matcha" });
        const dark_hits = countMatches(lower, &.{ "dark", "night", "midnight", "neon", "obsidian", "space", "cosmos", "stars", "noir", "aurora", "matrix", "cyber", "rain", "lantern" });
        break :blk light_hits <= dark_hits;
    };

    const motif: Motif = if (hasAny(lower, &.{ "sakura", "cherry", "petal", "blossom", "spring" }))
        .petals
    else if (hasAny(lower, &.{ "rain", "cyberpunk", "storm", "tokyo", "drizzle" }))
        .rain
    else if (hasAny(lower, &.{ "star", "space", "cosmos", "galaxy", "nebula", "constellation" }))
        .constellations
    else if (hasAny(lower, &.{ "wave", "ocean", "sea", "surf", "tide", "ukiyo" }))
        .waves
    else if (hasAny(lower, &.{ "firefl", "forest", "meadow", "moss", "cedar", "bamboo", "river", "lantern" }))
        .fireflies
    else if (hasAny(lower, &.{ "aurora", "northern", "arctic", "polar", "nordic" }))
        .aurora
    else if (hasAny(lower, &.{ "matrix", "hacker", "terminal", "code", "glyph" }))
        .matrix
    else
        .ripples;

    const hue: f32 = if (hasAny(lower, &.{ "sakura", "cherry", "rose", "blossom", "pink" }))
        340
    else if (hasAny(lower, &.{ "amber", "gold", "lantern", "warm", "autumn", "sunset" }))
        32
    else if (hasAny(lower, &.{ "matcha", "bamboo", "forest", "moss", "emerald", "jade", "matrix" }))
        142
    else if (hasAny(lower, &.{ "ocean", "kyoto", "indigo", "cobalt", "midnight", "rain" }))
        215
    else if (hasAny(lower, &.{ "violet", "purple", "nebula", "lavender" }))
        268
    else if (hasAny(lower, &.{ "crimson", "vermilion", "red", "ruby", "torii" }))
        6
    else blk: {
        var h: u32 = 5381;
        for (lower) |b| h = h *% 33 +% b;
        break :blk @floatFromInt(h % 360);
    };

    const bg = if (dark) hsl(hue, 0.24, 0.085) else hsl(hue, 0.18, 0.965);
    const shell = if (dark) hsl(hue, 0.22, 0.065) else hsl(hue, 0.16, 0.935);
    const sidebar = if (dark) hsl(hue, 0.23, 0.075) else hsl(hue, 0.15, 0.945);
    const card = if (dark) hsl(hue, 0.20, 0.115) else hsl(hue, 0.14, 0.985);
    const border = if (dark) hsl(hue, 0.18, 0.20) else hsl(hue, 0.15, 0.84);
    const text = if (dark) hsl(hue, 0.10, 0.93) else hsl(hue, 0.16, 0.13);
    const muted = if (dark) hsl(hue, 0.12, 0.65) else hsl(hue, 0.12, 0.40);
    const accent = if (dark) hsl(@mod(hue + 18, 360), 0.78, 0.62) else hsl(@mod(hue + 14, 360), 0.72, 0.44);
    const glow1 = hsl(hue, 0.75, 0.58);
    const glow2 = hsl(@mod(hue + 42, 360), 0.70, 0.54);

    // Build clean short display title & slug.
    var title_buf: [64]u8 = undefined;
    var tw: usize = 0;
    var words = std.mem.tokenizeAny(u8, prompt, " \t\r\n");
    var wc: usize = 0;
    while (words.next()) |w| : (wc += 1) {
        if (wc >= 3) break;
        if (wc > 0 and tw < title_buf.len) {
            title_buf[tw] = ' ';
            tw += 1;
        }
        for (w, 0..) |ch, idx| {
            if (tw >= title_buf.len) break;
            title_buf[tw] = if (idx == 0) std.ascii.toUpper(ch) else ch;
            tw += 1;
        }
    }
    const name = arena.dupe(u8, if (tw > 0) title_buf[0..tw] else "Custom Zen") catch "Custom Zen";
    var id_list: std.ArrayList(u8) = .empty;
    id_list.appendSlice(arena, "ai-") catch {};
    var prev_dash = false;
    for (name) |ch| {
        if (id_list.items.len >= 38) break;
        if (std.ascii.isAlphanumeric(ch)) {
            id_list.append(arena, std.ascii.toLower(ch)) catch {};
            prev_dash = false;
        } else if (!prev_dash and id_list.items.len > 3) {
            id_list.append(arena, '-') catch {};
            prev_dash = true;
        }
    }
    const id = if (id_list.items.len > 3) id_list.items else "ai-custom-zen";
    const sub = std.fmt.allocPrint(arena, "{s} · synthesized", .{motif.label()}) catch motif.label();

    return .{
        .id = id,
        .name = name,
        .subtitle = sub,
        .variant = .{
            .id = id,
            .family = "Generated",
            .name = name,
            .dark = dark,
            .colors = buildColors(dark, shell, sidebar, bg, card, border, text, muted, accent),
        },
        .backdrop = .{
            .motif = motif,
            .primary = glow1.color(),
            .secondary = glow2.color(),
            .speed = if (motif == .matrix or motif == .rain) 1.0 else 0.80,
            .intensity = if (dark) 0.64 else 0.54,
        },
        .is_custom = true,
    };
}

fn buildColors(dark: bool, shell_in: mc.Rgba, sidebar_in: mc.Rgba, bg_in: mc.Rgba, card_in: mc.Rgba, border_in: mc.Rgba, text_in: mc.Rgba, muted_in: mc.Rgba, accent_in: mc.Rgba) theme.Colors {
    const safe_text = mc.harden(text_in, &.{ bg_in, shell_in, sidebar_in, card_in }, 4.5, null);
    const safe_muted = mc.harden(muted_in, &.{ bg_in, shell_in, card_in }, 4.5, safe_text);
    const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: Color = .{};
    const wash: Color = if (dark) Color.hex(0xebebeb) else Color.hex(0x1a1a1a);

    var c = theme.fallback(dark);
    c.dark = dark;
    c.is_harp = false;
    c.is_warm_harp = false;
    c.recommended_frosted = false;
    c.shell = shell_in.color();
    c.panel = c.shell;
    c.sidebar = sidebar_in.color();
    c.background = bg_in.color();
    c.card = card_in.color();
    c.raised = card_in.mix(safe_text, if (dark) 0.06 else 0.02).color();
    c.overlay = card_in.color();
    c.input_tint = if (dark) Color.hex(0xffffff).alpha(0.03) else Color.hex(0x000000).alpha(0.025);
    c.composer = if (dark) card_in.mix(bg_in, 0.35).color() else Color.white.mix(card_in.color(), 0.25);
    c.border = border_in.color();
    c.border_strong = border_in.mix(safe_text, 0.28).color();
    c.text = safe_text.color();
    c.muted = safe_muted.color();
    c.faint = c.muted.alpha(0.68);
    c.subline = c.shell.mix(c.muted, 0.45);
    c.accent = accent_in.color();
    c.accent_strong = c.accent;
    c.on_accent = accent_in.bestOn().color();
    c.accent_wash = c.accent.alpha(if (dark) 0.22 else 0.13);
    c.glyph = .{ c.accent, c.accent.mix(c.text, 0.35), c.accent.mix(c.muted, 0.5) };
    c.hover = wash.alpha(if (dark) 0.065 else 0.055);
    c.selected = wash.alpha(if (dark) 0.11 else 0.065);
    c.active = wash.alpha(if (dark) 0.15 else 0.09);
    c.user_bubble = wash.alpha(if (dark) 0.08 else 0.045);
    c.code_bg = (if (dark) white else black).alpha(0.04);
    c.code_header = (if (dark) white else black).alpha(0.025);
    c.tone = if (dark) white else black;
    c.solid = if (dark) safe_text.color() else mc.Rgba.black.mix(accent_in, 0.2).color();
    c.on_solid = if (dark) shell_in.color() else Color.white;
    return c;
}

fn rgbaHex(v: u24) mc.Rgba {
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

fn rgbaParse(s: []const u8) ?mc.Rgba {
    return mc.Rgba.parse(std.mem.trim(u8, s, " \t\r\n"));
}

fn hexOfColor(a: std.mem.Allocator, col: Color) ![]const u8 {
    const r: u8 = @intFromFloat(@round(std.math.clamp(col.r, 0, 1) * 255));
    const g: u8 = @intFromFloat(@round(std.math.clamp(col.g, 0, 1) * 255));
    const b: u8 = @intFromFloat(@round(std.math.clamp(col.b, 0, 1) * 255));
    return std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b });
}

fn strField(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn floatField(o: json.ObjectMap, key: []const u8) ?f32 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn hasAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

fn countMatches(haystack: []const u8, needles: []const []const u8) usize {
    var count: usize = 0;
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) {
        count += 1;
    };
    return count;
}

fn hsl(h_deg: f32, s_in: f32, l_in: f32) mc.Rgba {
    const h = @mod(h_deg, 360) / 360.0;
    const s = std.math.clamp(s_in, 0, 1);
    const l = std.math.clamp(l_in, 0, 1);
    if (s == 0) {
        const v: u8 = @intFromFloat(@round(l * 255));
        return .{ .r = v, .g = v, .b = v };
    }
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;
    const hue_ch = struct {
        fn f(p0: f32, q0: f32, t_in: f32) u8 {
            var t = t_in;
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            const c = if (t < 1.0 / 6.0) p0 + (q0 - p0) * 6 * t else if (t < 0.5) q0 else if (t < 2.0 / 3.0) p0 + (q0 - p0) * (2.0 / 3.0 - t) * 6 else p0;
            return @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255));
        }
    };
    return .{
        .r = hue_ch.f(p, q, h + 1.0 / 3.0),
        .g = hue_ch.f(p, q, h),
        .b = hue_ch.f(p, q, h - 1.0 / 3.0),
    };
}
