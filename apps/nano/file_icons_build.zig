//! Embed Harness's file-theme artwork and compile its manifest into lookup
//! tables. No JSON parsing in the app. Each SVG is embedded once, deflated
//! (a sixth of the binary as plain text, light and dark); the app unpacks an
//! icon the first time it's drawn and derives its dark palette then
//! (src/file_icons.zig).
const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    const manifest = std.json.parseFromSlice(std.json.Value, b.allocator, read(b, "../../crates/ui/src/file-icons.json"), .{}) catch @panic("invalid file-icon manifest");
    const root = manifest.value.object;
    var definitions: std.StringHashMap(u16) = .init(b.allocator);
    var source: std.ArrayList(u8) = .empty;
    append(b, &source,
        \\const std = @import("std");
        \\/// `deflated`: the SVG as raw deflate, `len` bytes once unpacked.
        \\pub const Asset = struct { path: []const u8, deflated: []const u8, len: u32 };
        \\pub const assets = [_]Asset{
        \\
    );
    var it = root.get("iconDefinitions").?.object.iterator();
    while (it.next()) |entry| {
        const icon_path = entry.value_ptr.object.get("iconPath").?.string;
        if (!std.mem.startsWith(u8, icon_path, "./icons/")) @panic("invalid file-icon asset path");
        const path = icon_path["./icons/".len..];
        const svg = read(b, b.fmt("../../crates/ui/assets/file-icons/{s}", .{path}));
        const packed_name = b.fmt("deflated/{s}", .{path});
        _ = files.add(packed_name, deflate(b, svg));
        append(b, &source, b.fmt("    .{{ .path = {s}, .deflated = @embedFile({s}), .len = {d} }},\n", .{ quote(b, path), quote(b, packed_name), svg.len }));
        definitions.put(entry.key_ptr.*, @intCast(definitions.count())) catch @panic("OOM");
    }
    append(b, &source, "};\n");
    for ([_][2][]const u8{ .{ "fileNames", "names" }, .{ "fileExtensions", "extensions" }, .{ "folderNames", "folders" } }) |table| {
        append(b, &source, b.fmt("pub const {s} = blk: {{\n    @setEvalBranchQuota(200000);\n    break :blk std.StaticStringMapWithEql(u16, std.ascii.eqlIgnoreCase).initComptime(.{{\n", .{table[1]}));
        var entries = root.get(table[0]).?.object.iterator();
        while (entries.next()) |entry| {
            if (definition(&definitions, entry.value_ptr.string)) |id|
                append(b, &source, b.fmt("        .{{ {s}, {d} }},\n", .{ quote(b, entry.key_ptr.*), id }));
        }
        append(b, &source, "    });\n};\n");
    }
    append(b, &source, b.fmt("pub const file: u16 = {d};\npub const folder: u16 = {d};\n", .{
        definition(&definitions, root.get("file").?.string).?,
        definition(&definitions, root.get("folder").?.string).?,
    }));
    return b.createModule(.{ .root_source_file = files.add("file_icons_data.zig", source.items) });
}

fn definition(definitions: *const std.StringHashMap(u16), name: []const u8) ?u16 {
    // The same upstream aliases as crates/ui/src/file_icons.rs.
    const alias = if (std.mem.eql(u8, name, "less")) "brackets-sky" else if (std.mem.eql(u8, name, "yml")) "yaml" else name;
    return definitions.get(alias);
}

fn read(b: *std.Build, path: []const u8) []const u8 {
    const full = b.root.joinString(b.allocator, path) catch @panic("OOM");
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, full, b.allocator, .limited(8 << 20)) catch @panic("cannot read bundled file icons");
}

fn quote(b: *std.Build, text: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(b.allocator, text, .{}) catch @panic("OOM");
}

fn append(b: *std.Build, source: *std.ArrayList(u8), text: []const u8) void {
    source.appendSlice(b.allocator, text) catch @panic("OOM");
}

fn deflate(b: *std.Build, bytes: []const u8) []const u8 {
    const flate = std.compress.flate;
    // Compress asserts room for its header up front.
    var out = std.Io.Writer.Allocating.initCapacity(b.allocator, bytes.len + 64) catch @panic("OOM");
    const window = b.allocator.alloc(u8, flate.max_window_len) catch @panic("OOM");
    var z = flate.Compress.init(&out.writer, window, .raw, flate.Compress.Options.best) catch @panic("deflate");
    z.writer.writeAll(bytes) catch @panic("deflate");
    z.finish() catch @panic("deflate");
    return out.written();
}
