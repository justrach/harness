//! Compatibility with Nano's pinned fixed TextBuffer and newer dynamic APIs.
//! Keep ownership and lossless paste behavior without upgrading nanoui.
const std = @import("std");

pub fn deinit(buffer: anytype) void {
    if (comptime @hasDecl(@TypeOf(buffer.*), "deinit")) buffer.deinit();
}

/// Reserve dynamic storage, or refuse an insertion that would be truncated
/// by the pinned fixed buffer. The caller still applies its 16 KiB policy.
pub fn reserveInline(buffer: anytype, bytes: usize) bool {
    if (comptime @typeInfo(@TypeOf(buffer.buf)) == .array) {
        return bytes <= buffer.buf.len -| buffer.text().len;
    } else {
        buffer.buf.ensureUnusedCapacity(std.heap.c_allocator, bytes) catch return false;
        return true;
    }
}

test "text buffer compatibility preserves fixed capacity and dynamic ownership" {
    const Fixed = struct {
        buf: [8]u8 = undefined,
        len: usize = 5,
        pub fn text(b: *const @This()) []const u8 {
            return b.buf[0..b.len];
        }
    };
    var fixed: Fixed = .{};
    deinit(&fixed); // The fixed API owns no allocation and has no deinit.
    try std.testing.expect(reserveInline(&fixed, 3));
    try std.testing.expect(!reserveInline(&fixed, 4));
    const Dynamic = struct {
        buf: std.ArrayList(u8) = .empty,
        cleaned: bool = false,
        // Toolkit methods are public: reflection from an importing module
        // must see the same API when all app specializations are compiled.
        pub fn deinit(b: *@This()) void {
            b.buf.deinit(std.heap.c_allocator);
            b.cleaned = true;
        }
    };
    var dynamic: Dynamic = .{};
    try std.testing.expect(reserveInline(&dynamic, 20000));
    try std.testing.expect(dynamic.buf.capacity >= 20000);
    deinit(&dynamic);
    try std.testing.expect(dynamic.cleaned);
}
