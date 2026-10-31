//! Ids the client mints: version 4 UUIDs, as the GPUI app mints chat,
//! message and space ids.
const std = @import("std");

/// A version 4 UUID, as the GPUI app mints chat and message ids.
pub fn uuid(io: std.Io, out: *[36]u8) []const u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (b, 0..) |x, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[x >> 4];
        out[o + 1] = hex[x & 15];
        o += 2;
    }
    return out;
}

test "uuids are version 4" {
    var buf: [36]u8 = undefined;
    const u = uuid(std.testing.io, &buf);
    try std.testing.expectEqual(@as(u8, '4'), u[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", u[19]) != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, u, "-"));
}
