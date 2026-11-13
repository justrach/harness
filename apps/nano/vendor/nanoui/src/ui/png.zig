//! PNG files from rendered frames, in Zig alone: rows unfiltered, stored
//! in uncompressed deflate blocks (larger files, no dependencies), for
//! screenshots where there is no ImageIO.
const std = @import("std");
const gpu = @import("gpu.zig");

fn crc(parts: []const []const u8) u32 {
    var c = std.hash.Crc32.init();
    for (parts) |p| c.update(p);
    return c.final();
}

fn chunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc(&.{ kind, data }), .big);
    try out.appendSlice(gpa, &sum);
}

/// The PNG of premultiplied BGRA `pixels`, as straight RGBA.
pub fn encode(gpa: std.mem.Allocator, pixels: gpu.Pixels) ![]u8 {
    // The image's rows, each led by filter type 0.
    const row_len = pixels.width * 4 + 1;
    const raw = try gpa.alloc(u8, row_len * pixels.height);
    defer gpa.free(raw);
    for (0..pixels.height) |y| {
        raw[y * row_len] = 0;
        for (0..pixels.width) |x| {
            const s = pixels.bytes[(y * pixels.width + x) * 4 ..][0..4];
            const d = raw[y * row_len + 1 + x * 4 ..][0..4];
            const a = s[3];
            const un = struct {
                fn f(v: u8, al: u8) u8 {
                    if (al == 0) return 0;
                    return @intCast(@min(255, (@as(u32, v) * 255 + al / 2) / al));
                }
            }.f;
            d.* = .{ un(s[2], a), un(s[1], a), un(s[0], a), a };
        }
    }
    // zlib: stored blocks of at most 65535 bytes, then the Adler-32.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var at: usize = 0;
    while (true) {
        const n = @min(raw.len - at, 65535);
        const last = at + n == raw.len;
        try z.append(gpa, if (last) 1 else 0);
        try z.appendSlice(gpa, &.{ @truncate(n), @truncate(n >> 8), @truncate(~n), @truncate(~n >> 8) });
        try z.appendSlice(gpa, raw[at .. at + n]);
        at += n;
        if (last) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(pixels.width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(pixels.height), .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA
    try chunk(&out, gpa, "IHDR", &ihdr);
    try chunk(&out, gpa, "IDAT", z.items);
    try chunk(&out, gpa, "IEND", "");
    return out.toOwnedSlice(gpa);
}

pub fn writePng(gpa: std.mem.Allocator, io: std.Io, path: []const u8, pixels: gpu.Pixels) !void {
    const bytes = try encode(gpa, pixels);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

test "a PNG's signature, header and size" {
    const gpa = std.testing.allocator;
    var px = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 };
    const bytes = try encode(gpa, .{ .bytes = &px, .width = 2, .height = 1 });
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("\x89PNG", bytes[0..4]);
    try std.testing.expectEqualStrings("IHDR", bytes[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[16..20], .big));
}
