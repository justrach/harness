//! `zig build vectors`: writes protocol/desktop/requests.json from the
//! request builders (parity_requests.zig).
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else return error.NoPath;
    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();
    try @import("parity_requests.zig").write(init.arena.allocator(), &aw.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = aw.written() });
}
