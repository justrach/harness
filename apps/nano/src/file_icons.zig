//! The GPUI app's Symbols file/folder theme, from its original manifest and
//! SVGs. Resolve names without allocating; unpack and rasterize only
//! identities shown.
const std = @import("std");
const ui = @import("nanoui").ui;
const data = @import("file_icons_data");

/// GPUI's dark_icon_svg palette: lift dark accents, never tint the artwork.
/// Each pair is the same length, so it's swapped in place.
const dark_palette = [_][2]*const [7]u8{
    .{ "#64748B", "#CBD5E1" }, .{ "#71717A", "#D4D4D8" },
    .{ "#2563EB", "#60A5FA" }, .{ "#EA580C", "#FB923C" },
    .{ "#16A34A", "#4ADE80" }, .{ "#8B5CF6", "#A78BFA" },
    .{ "#A855F7", "#C084FC" },
};

pub fn darken(bytes: []u8) void {
    for (dark_palette) |pair| {
        var from: usize = 0;
        while (std.ascii.findIgnoreCasePos(bytes, from, pair[0])) |at| {
            @memcpy(bytes[at..][0..7], pair[1]);
            from = at + 7;
        }
    }
}

/// Each identity's SVG, light and dark, unpacked the first time it's drawn
/// and kept: only the icons shown take memory. UI thread only.
var unpacked: [data.assets.len][2]?[]const u8 = @splat(@splat(null));

fn unpack(gpa: std.mem.Allocator, a: *const data.Asset) ![]u8 {
    const flate = std.compress.flate;
    var in: std.Io.Reader = .fixed(a.deflated);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var z: flate.Decompress = .init(&in, .raw, window);
    const out = try gpa.alloc(u8, a.len);
    errdefer gpa.free(out);
    try z.reader.readSliceAll(out);
    return out;
}

/// The SVG of `a`, in the dark palette for `dark`; empty if it can't be
/// unpacked (it's checked at build and in a test).
pub fn svg(a: *const data.Asset, dark: bool) []const u8 {
    const id = (@intFromPtr(a) - @intFromPtr(&data.assets)) / @sizeOf(data.Asset);
    const slot = &unpacked[id][@intFromBool(dark)];
    if (slot.*) |s| return s;
    const gpa = std.heap.c_allocator;
    const bytes = unpack(gpa, a) catch return "";
    if (dark) darken(bytes);
    slot.* = bytes;
    return bytes;
}

pub fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash + 1 ..];
}

pub fn asset(path: []const u8, directory: bool) *const data.Asset {
    const name = basename(path);
    if (directory) return &data.assets[data.folders.get(name) orelse data.folder];
    if (data.names.get(name)) |id| return &data.assets[id];
    // Exact names win; the earliest dot gives the longest compound suffix.
    for (name, 0..) |ch, i| if (ch == '.' and i + 1 < name.len) {
        if (data.extensions.get(name[i + 1 ..])) |id| return &data.assets[id];
    };
    return &data.assets[data.file];
}

pub fn icon(c: *ui.Context, path: []const u8, directory: bool, dark: bool, size: f32) void {
    const identity = asset(path, directory);
    _ = ui.svg(c, .{
        .key = c.print("file-icons/{s}{s}", .{ if (dark) "dark/" else "", identity.path }),
        .bytes = svg(identity, dark),
        .size = size,
        // No monochrome tint: keep the authored colors as GPUI's img does.
    });
}

test "file identities use Harness's exact names, compound extensions and fallbacks" {
    const cases = [_][2][]const u8{
        .{ "/work/demo/README.md", "files/markdown.svg" },
        .{ "C:\\demo\\MAIN.RS", "files/rust.svg" },
        .{ "main.zig", "files/zig.svg" },
        .{ "TSCONFIG.JSON", "files/tsconfig.svg" },
        .{ ".prettierrc.json", "files/prettier.svg" },
        .{ "test.ts", "files/ts-test.svg" },
        .{ "widget.test.ts", "files/ts-test.svg" },
        .{ "widget.ts", "files/ts.svg" },
        .{ "style.less", "files/brackets-sky.svg" },
        .{ "config.yml", "files/yaml.svg" },
        .{ "unknown.synthetic-extension", "files/document.svg" },
        .{ "trailing.", "files/document.svg" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], asset(case[0], false).path);
    try std.testing.expectEqualStrings("folders/folder-orange-code.svg", asset("/work/demo/SRC", true).path);
    try std.testing.expectEqualStrings("folders/folder.svg", asset("other", true).path);
}

fn sheet(dark: *bool, c: *ui.Context) void {
    const row = ui.div(c).row().gap(4);
    defer row.end();
    for ([_][]const u8{ "main.rs", "main.zig", "main.ts", "README.md", "unknown" }) |path|
        icon(c, path, false, dark.*, 14);
    icon(c, "src", true, dark.*, 14);
}

test "identity SVGs keep their colors, density, dark palette and cache" {
    for ([_]f32{ 1, 2 }) |scale| {
        var dark = false;
        var t: ui.Tester = undefined;
        try t.init(std.testing.allocator, .init(&dark, sheet), .{ .scale = scale });
        defer t.deinit();
        for ([_]bool{ false, true }) |appearance| {
            dark = appearance;
            t.frame();
            var count: usize = 0;
            for (t.ctx.nodes.items) |node| switch (node.content) {
                .image => |im| {
                    try std.testing.expect(im.tint == null);
                    const decoded = t.text.images.decoded.get(im.key).?.?;
                    try std.testing.expectEqual(@as(u32, @intFromFloat(14 * scale)), decoded.width);
                    try std.testing.expectEqual(decoded.width, decoded.height);
                    try std.testing.expectEqual(@as(f32, 14), node.rect.w);
                    count += 1;
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 6), count);
            const cached = t.text.images.decoded.count();
            t.frame();
            try std.testing.expectEqual(cached, t.text.images.decoded.count());
        }
    }
    const rust = asset("main.rs", false);
    try std.testing.expect(!std.mem.eql(u8, svg(rust, false), svg(rust, true)));
}

test "every identity unpacks to its SVG, and dark lifts only the accent palette" {
    for (&data.assets) |*a| {
        const light = svg(a, false);
        try std.testing.expectEqual(@as(usize, a.len), light.len);
        try std.testing.expect(std.mem.indexOf(u8, light, "<svg") != null);
        const dark = svg(a, true);
        try std.testing.expectEqual(light.len, dark.len);
        for (dark_palette) |pair| try std.testing.expect(std.ascii.findIgnoreCasePos(dark, 0, pair[0]) == null);
        // Outside the swapped colors, the artwork is the same bytes: every
        // byte that differs sits in a `#RRGGBB` the palette lifted.
        for (light, dark, 0..) |l, d, i| if (l != d) {
            const start = std.mem.lastIndexOfScalar(u8, light[0 .. i + 1], '#') orelse return error.UnexpectedChange;
            try std.testing.expect(i - start < 7);
            var lifted = false;
            for (dark_palette) |pair| lifted = lifted or std.mem.eql(u8, dark[start..][0..7], pair[1]);
            try std.testing.expect(lifted);
        };
    }
    var sample = "fill=\"#64748b\" stroke=\"#2563EB\" other=\"#123456\"".*;
    darken(&sample);
    try std.testing.expectEqualStrings("fill=\"#CBD5E1\" stroke=\"#60A5FA\" other=\"#123456\"", &sample);
}
