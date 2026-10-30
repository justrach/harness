//! The themes, as the GPUI app offers them: the built-in catalog the phones
//! bundle (apps/ios/Harness/Theme/themes.json, which crates/theme's
//! `builtin_catalog_matches_ios_bundle` keeps in lockstep with the Rust
//! registry), then the custom ones the theme library holds
//! (`theme-library.json` in Harness's data folder, which either app's Add
//! theme writes). Each variant is made nano's `theme.Colors` as
//! crates/ui/src/theme.rs derives its roles, a custom one's words made
//! readable as `harden_model_foreground` makes them.
const std = @import("std");
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;
const theme = @import("theme.zig");
const json = std.json;
const theme_library = @import("theme_library.zig");

pub const Variant = struct {
    id: []const u8,
    family: []const u8,
    name: []const u8,
    dark: bool,
    colors: theme.Colors,
};

var builtins: ?[]const Variant = null;
/// The built-ins, then the library's custom families, as last read.
var everything: []const Variant = &.{};
var custom_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var builtin_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// Every variant, built-ins first, each family's in its order.
pub fn all() []const Variant {
    if (builtins == null) {
        // In an arena: straight from the page allocator, each of the
        // catalog's thousands of strings and objects took a page of its own
        // (87 MB for a 103 KB file).
        builtins = parse(builtin_arena.allocator(), @import("themes_json").json, true) catch &.{};
        everything = builtins.?;
    }
    return everything;
}

/// Reads the theme library in `data_dir` again (`CustomThemeLibrary`):
/// its entries' families join the built-ins. A missing or unreadable file
/// leaves only the built-ins.
pub fn loadLibrary(io: std.Io, data_dir: []const u8) void {
    // The built-ins' own list: the combined one is the arena's, reset now.
    _ = all();
    const b = builtins.?;
    _ = custom_arena.reset(.retain_capacity);
    const a = custom_arena.allocator();
    everything = b;
    library = .{};
    load_warning = null;
    library = theme_library.load(a, io, data_dir) catch {
        load_warning = a.dupe(u8, theme_library.last_error) catch null;
        return;
    };
    var out: std.ArrayList(Variant) = .empty;
    out.appendSlice(a, b) catch return;
    for (library.entries.items) |e| {
        if (e != .object) continue;
        const family = e.object.get("family") orelse continue;
        if (family != .object) continue;
        appendFamily(a, &out, family.object, false) catch continue;
    }
    everything = out.items;
}

/// The library as last read: its entries, in the arena `loadLibrary` resets.
pub var library: theme_library.Library = .{};
/// Why it couldn't be read (`load_warning`), until the next read.
pub var load_warning: ?[]const u8 = null;

/// A library or import variant's colours, made readable as an imported
/// theme's are.
pub fn colorsOf(o: json.ObjectMap) ?theme.Colors {
    return derive(o, std.mem.eql(u8, str(o, "appearance"), "dark"), false);
}

pub fn find(id: []const u8) ?*const Variant {
    for (all()) |*v| if (std.mem.eql(u8, v.id, id)) return v;
    return null;
}

fn parse(gpa: std.mem.Allocator, text: []const u8, curated: bool) ![]const Variant {
    const doc = try json.parseFromSliceLeaky(json.Value, gpa, text, .{});
    var out: std.ArrayList(Variant) = .empty;
    const families = (doc.object.get("families") orelse return error.Catalog).array.items;
    for (families) |f| if (f == .object) try appendFamily(gpa, &out, f.object, curated);
    return out.items;
}

fn appendFamily(gpa: std.mem.Allocator, out: *std.ArrayList(Variant), f: json.ObjectMap, curated: bool) !void {
    const variants = f.get("variants") orelse return;
    if (variants != .array) return;
    for (variants.array.items) |v| {
        if (v != .object) continue;
        const o = v.object;
        const dark = std.mem.eql(u8, str(o, "appearance"), "dark");
        try out.append(gpa, .{
            .id = str(o, "id"),
            .family = str(o, "familyId"),
            .name = str(o, "name"),
            .dark = dark,
            .colors = derive(o, dark, curated) orelse continue,
        });
    }
}

fn str(o: json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// "#rrggbb" or "#rrggbbaa".
pub fn hex(s: []const u8) ?Color {
    if (s.len != 7 and s.len != 9 or s[0] != '#') return null;
    const n = std.fmt.parseInt(u32, s[1..], 16) catch return null;
    const rgba: u32 = if (s.len == 7) (n << 8) | 0xff else n;
    return .{
        .r = @as(f32, @floatFromInt((rgba >> 24) & 0xff)) / 255,
        .g = @as(f32, @floatFromInt((rgba >> 16) & 0xff)) / 255,
        .b = @as(f32, @floatFromInt((rgba >> 8) & 0xff)) / 255,
        .a = @as(f32, @floatFromInt(rgba & 0xff)) / 255,
    };
}

/// `top` laid over the opaque `base` as the GPU blends it: its alpha in
/// 8 bits, the result to the byte.
pub fn over(base: Color, top: Color) Color {
    const a = @round(top.a * 255) / 255;
    const ch = struct {
        fn f(b: f32, t: f32, al: f32) f32 {
            return @round((b + (t - b) * al) * 255) / 255;
        }
    };
    return .{ .r = ch.f(base.r, top.r, a), .g = ch.f(base.g, top.g, a), .b = ch.f(base.b, top.b, a), .a = 1 };
}

/// A variant's roles, as theme.rs's `apply_model` and the paint helpers
/// derive them (`wash`, `user_bubble_bg`, the composer's flattened input).
fn derive(o: json.ObjectMap, dark: bool, curated: bool) ?theme.Colors {
    const cs = (o.get("colors") orelse return null).object;
    const acc = (o.get("accent") orelse return null).object;
    const term = (o.get("terminal") orelse return null).object;
    const syn = (o.get("syntax") orelse return null).object;
    const col = struct {
        fn get(m: json.ObjectMap, key: []const u8) Color {
            const v = m.get(key) orelse return .{};
            return if (v == .string) hex(v.string) orelse .{} else .{};
        }
    };
    const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: Color = .{};
    // `wash`: near-white (hsl 0.92) in dark, near-black (0.10) in light.
    const wash: Color = if (dark) Color.hex(0xebebeb) else Color.hex(0x1a1a1a);
    const shell = col.get(cs, "shell");
    const background = col.get(cs, "background");
    var text = col.get(cs, "text");
    var muted = col.get(cs, "textMuted");
    var on_solid = col.get(cs, "onSolid");
    if (!curated) {
        // An imported theme's words are made readable on every surface they
        // sit on (`harden_model_foreground`, 4.5:1).
        const mc = @import("model_color.zig");
        const m8 = struct {
            fn get(m: json.ObjectMap, key: []const u8) mc.Rgba {
                const v = m.get(key) orelse return .{};
                return if (v == .string) mc.Rgba.parse(v.string) orelse .{} else .{};
            }
        };
        const grounds = [_]mc.Rgba{ m8.get(cs, "background"), m8.get(cs, "shell"), m8.get(cs, "raised"), m8.get(cs, "card"), m8.get(cs, "dialog"), m8.get(cs, "overlay"), m8.get(cs, "input") };
        const safe_text = mc.harden(m8.get(cs, "text"), &grounds, 4.5, null);
        const safe_muted = mc.harden(m8.get(cs, "textMuted"), &grounds, 4.5, safe_text);
        const safe_on = mc.harden(m8.get(cs, "onSolid"), &.{m8.get(cs, "solid")}, 4.5, safe_text);
        text = safe_text.color();
        muted = safe_muted.color();
        on_solid = safe_on.color();
    }
    var glyph: [3]Color = .{ .{}, .{}, .{} };
    if (acc.get("glyph")) |g| if (g == .array) for (g.array.items[0..@min(3, g.array.items.len)], 0..) |c, i| {
        glyph[i] = if (c == .string) hex(c.string) orelse .{} else .{};
    };
    var ansi: [16]Color = @splat(.{});
    if (term.get("ansi")) |list| if (list == .array) for (list.array.items[0..@min(16, list.array.items.len)], 0..) |c, i| {
        ansi[i] = if (c == .string) hex(c.string) orelse .{} else .{};
    };
    // The Markdown hues come from the appearance's own palette
    // (`SyntaxPalette::dark`/`light`), which a variant's roles leave be.
    const base = theme.builtin(dark).syntax;
    return .{
        .dark = dark,
        .recommended_frosted = std.mem.eql(u8, str(o, "recommendedSurfaceTreatment"), "frosted"),
        .input_tint = col.get(cs, "input"),
        .overlay = col.get(cs, "overlay"),
        .card = col.get(cs, "card"),
        .panel = shell,
        .background = background,
        .shell = shell,
        .sidebar = over(shell, wash.alpha(0.05)),
        .raised = col.get(cs, "raised"),
        .text = text,
        .muted = muted,
        .faint = col.get(cs, "textFaint"),
        .subline = over(shell, muted.alpha(0.5)),
        .accent = col.get(acc, "primary"),
        .accent_wash = col.get(acc, "wash"),
        .glyph = glyph,
        .danger = col.get(cs, "danger"),
        .danger_muted = col.get(cs, "dangerMuted"),
        .warning = col.get(cs, "warning"),
        .success = col.get(cs, "success"),
        .success_muted = col.get(cs, "successMuted"),
        .border = col.get(cs, "border"),
        .border_strong = col.get(cs, "borderStrong"),
        .hover = col.get(cs, "hover"),
        .selected = wash.alpha(if (dark) 0.11 else 0.06),
        .user_bubble = over(shell, wash.alpha(if (dark) 0.08 else 0.04)),
        .composer = over(background, col.get(cs, "input")),
        .code_bg = (if (dark) white else black).alpha(0.035),
        .code_header = (if (dark) white else black).alpha(0.02),
        .tone = if (dark) white else black,
        .ansi = ansi,
        .solid = col.get(cs, "solid"),
        .on_solid = on_solid,
        .diff_add = col.get(cs, "diffAdd"),
        .diff_del = col.get(cs, "diffDelete"),
        .syntax = .{
            .comment = col.get(syn, "comment"),
            .keyword = col.get(syn, "keyword"),
            .string = col.get(syn, "string"),
            .number = col.get(syn, "number"),
            .type = col.get(syn, "type"),
            .function = col.get(syn, "function"),
            .property = col.get(syn, "property"),
            .variable = col.get(syn, "variable"),
            .punctuation = col.get(syn, "punctuation"),
            .tag = col.get(syn, "tag"),
            .attribute = col.get(syn, "attribute"),
            .invalid = col.get(syn, "invalid"),
            .markup_heading = base.markup_heading,
            .markup_raw = base.markup_raw,
            .markup_link = base.markup_link,
            .markup_reference = base.markup_reference,
            .markup_emphasis = base.markup_emphasis,
            .markup_strong = base.markup_strong,
        },
    };
}

const testing = std.testing;

fn same(a: Color, b: Color) bool {
    const near = struct {
        fn f(x: f32, y: f32) bool {
            return @abs(x - y) <= 1.5 / 255.0;
        }
    };
    return near.f(a.r, b.r) and near.f(a.g, b.g) and near.f(a.b, b.b) and near.f(a.a, b.a);
}

test "the catalog's Codegraff derives the palette nano draws Codegraff in" {
    inline for (.{ .{ "codegraff-dark", true }, .{ "codegraff-light", false } }) |t| {
        const v = find(t[0]) orelse return error.Missing;
        const want = theme.builtin(t[1]);
        const info = @typeInfo(theme.Colors).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            const got = @field(v.colors, name);
            const exp = @field(want, name);
            switch (T) {
                Color => if (!same(got, exp)) {
                    std.debug.print("{s}.{s}: {any} != {any}\n", .{ t[0], name, got, exp });
                    return error.Differs;
                },
                [3]Color, [16]Color => for (got, exp) |g, e| if (!same(g, e)) {
                    std.debug.print("{s}.{s}\n", .{ t[0], name });
                    return error.Differs;
                },
                else => {},
            }
        }
    }
}

test "every built-in variant is offered, Codegraff among them" {
    try testing.expect(all().len >= 30);
    var light: usize = 0;
    for (all()) |v| if (!v.dark) {
        light += 1;
    };
    try testing.expect(light >= 10);
    try testing.expectEqualStrings("Codegraff Dark", find("codegraff-dark").?.name);
}

test "a custom theme from the library joins the built-ins, its words made readable" {
    // A made-up family: Codegraff Dark's roles, renamed, with grey text on
    // its near-black grounds that wouldn't read.
    const doc = try json.parseFromSlice(json.Value, testing.allocator, @import("themes_json").json, .{});
    defer doc.deinit();
    var v: json.Value = .null;
    for (doc.value.object.get("families").?.array.items) |f| for (f.object.get("variants").?.array.items) |x|
        if (std.mem.eql(u8, x.object.get("id").?.string, "codegraff-dark")) {
            v = x;
        };
    const variant = try std.json.Stringify.valueAlloc(testing.allocator, v, .{});
    defer testing.allocator.free(variant);
    var edited: std.ArrayList(u8) = .empty;
    defer edited.deinit(testing.allocator);
    try edited.appendSlice(testing.allocator, variant);
    for ([_][2][]const u8{
        .{ "\"id\":\"codegraff-dark\"", "\"id\":\"custom-dim-dark\"" },
        .{ "\"name\":\"Codegraff Dark\"", "\"name\":\"Dim Dark\"" },
        .{ "\"text\":\"#edeae2\"", "\"text\":\"#3a3a3a\"" },
    }) |r| {
        const at = std.mem.indexOf(u8, edited.items, r[0]) orelse return error.NoField;
        try edited.replaceRange(testing.allocator, at, r[0].len, r[1]);
    }
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{{\"entries\":[{{\"id\":\"custom-dim\",\"family\":{{\"id\":\"custom-dim\",\"name\":\"Dim\",\"variants\":[{s}]}}}}]}}", .{edited.items});
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "theme-library.json", .data = aw.written() });
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    defer loadLibrary(testing.io, "/nonexistent");

    loadLibrary(testing.io, dir);
    const dim = find("custom-dim-dark") orelse return error.Missing;
    try testing.expectEqualStrings("Dim Dark", dim.name);
    try testing.expect(dim.dark);
    // After every built-in.
    try testing.expectEqualStrings("custom-dim-dark", all()[all().len - 1].id);
    // Its #3a3a3a text was lifted to read at 4.5:1 on its grounds.
    const mc = @import("model_color.zig");
    const text8: mc.Rgba = .{ .r = @intFromFloat(@round(dim.colors.text.r * 255)), .g = @intFromFloat(@round(dim.colors.text.g * 255)), .b = @intFromFloat(@round(dim.colors.text.b * 255)) };
    try testing.expect(text8.contrast(mc.Rgba.parse("#16140f").?) >= 4.5);
    // A library gone, only the built-ins.
    loadLibrary(testing.io, "/nonexistent");
    try testing.expect(find("custom-dim-dark") == null);
}
