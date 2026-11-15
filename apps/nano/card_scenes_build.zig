//! Embed Harness's 8 shared Ensō strokes and 20 Japanese member-card scenes
//! (`assets/cards/manifest.json`) as a Zig module (`card_scenes_data`) without
//! runtime JSON parsing.
const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    const manifest_bytes = read(b, "assets/cards/manifest.json");
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, manifest_bytes, .{}) catch @panic("invalid card scenes manifest");
    const root_obj = parsed.value.object;
    const enso_items = root_obj.get("ensos").?.array.items;
    const scene_items = root_obj.get("scenes").?.array.items;

    var source: std.ArrayList(u8) = .empty;
    append(b, &source,
        \\pub const Enso = struct {
        \\    slug: []const u8,
        \\    label: []const u8,
        \\    bytes: []const u8,
        \\};
        \\pub const Scene = struct {
        \\    slug: []const u8,
        \\    title: []const u8,
        \\    finish: []const u8,
        \\    sky_rgb: *const [48 * 64 * 3]u8,
        \\    sky_bytes: []const u8,
        \\    near_bytes: []const u8,
        \\};
        \\
    );

    append(b, &source, b.fmt("pub const enso_count: u32 = {d};\npub const ensos = [_]Enso{{\n", .{enso_items.len}));
    for (enso_items) |entry| {
        const obj = entry.object;
        const slug = obj.get("slug").?.string;
        const label = obj.get("label").?.string;
        const file = obj.get("file").?.string;
        _ = files.addCopyFile(b.path(b.fmt("assets/cards/{s}", .{file})), file);
        append(b, &source, b.fmt(
            "    .{{ .slug = {s}, .label = {s}, .bytes = @embedFile({s}) }},\n",
            .{ quote(b, slug), quote(b, label), quote(b, file) },
        ));
    }
    append(b, &source, "};\n\n");

    append(b, &source, b.fmt("pub const count: u32 = {d};\npub const scenes = [_]Scene{{\n", .{scene_items.len}));
    for (scene_items) |entry| {
        const obj = entry.object;
        const slug = obj.get("slug").?.string;
        const title = obj.get("title").?.string;
        const finish = obj.get("finish").?.string;
        const sky_rgb = obj.get("skyRgb").?.string;
        const sky_file = obj.get("skyFile").?.string;
        const near_file = obj.get("nearFile").?.string;
        _ = files.addCopyFile(b.path(b.fmt("assets/cards/{s}", .{sky_rgb})), sky_rgb);
        _ = files.addCopyFile(b.path(b.fmt("assets/cards/{s}", .{sky_file})), sky_file);
        _ = files.addCopyFile(b.path(b.fmt("assets/cards/{s}", .{near_file})), near_file);

        append(b, &source, b.fmt(
            \\    .{{
            \\        .slug = {s},
            \\        .title = {s},
            \\        .finish = {s},
            \\        .sky_rgb = @embedFile({s}),
            \\        .sky_bytes = @embedFile({s}),
            \\        .near_bytes = @embedFile({s}),
            \\    }},
            \\
        ,
            .{
                quote(b, slug),
                quote(b, title),
                quote(b, finish),
                quote(b, sky_rgb),
                quote(b, sky_file),
                quote(b, near_file),
            },
        ));
    }

    append(b, &source, "};\n");
    return b.createModule(.{ .root_source_file = files.add("card_scenes_data.zig", source.items) });
}

fn read(b: *std.Build, path: []const u8) []const u8 {
    const full = b.root.joinString(b.allocator, path) catch @panic("OOM");
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, full, b.allocator, .limited(8 << 20)) catch @panic("cannot read bundled card scenes");
}

fn quote(b: *std.Build, text: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(b.allocator, text, .{}) catch @panic("OOM");
}

fn append(b: *std.Build, source: *std.ArrayList(u8), text: []const u8) void {
    source.appendSlice(b.allocator, text) catch @panic("OOM");
}
