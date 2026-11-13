//! Rust staticlibs bundle compiler intrinsics. On COFF their weak fallback
//! definitions collide with Zig's compiler-rt. Keep Zig as the sole provider,
//! without dropping the Rust allocator, std or the panic/unwind boundary.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) return error.Usage;
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], gpa, .limited(512 << 20));
    var output: std.Io.Writer.Allocating = .init(gpa);
    try filter(gpa, input, &output.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = output.written() });
}

fn filter(gpa: std.mem.Allocator, input: []const u8, output: *std.Io.Writer) !void {
    if (!std.mem.startsWith(u8, input, "!<arch>\n")) return error.BadArchive;
    try output.writeAll("!<arch>\n");
    var names: []const u8 = &.{};
    var offsets: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    var removed: usize = 0;
    var at: usize = 8;
    while (at < input.len) {
        if (input.len - at < 60) return error.BadArchive;
        var header = input[at..][0..60].*;
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.BadArchive;
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, header[48..58], " "), 10);
        const start = at + 60;
        if (size > input.len - start) return error.BadArchive;
        const end = start + size;
        const next = end + size % 2;
        if (next > input.len) return error.BadArchive;
        const field = std.mem.trimEnd(u8, header[0..16], " ");
        var name = field;
        if (std.mem.eql(u8, field, "//")) {
            names = input[start..end];
            // COFF uses NUL-separated long names; GNU ar uses / + newline.
            // Emit GNU names and remap every offset before zig ar reindexes.
            var table: std.Io.Writer.Allocating = .init(gpa);
            var offset: usize = 0;
            while (offset < names.len) {
                const length = std.mem.indexOfAny(u8, names[offset..], "\x00\n") orelse return error.BadArchive;
                const entry = std.mem.trimEnd(u8, names[offset..][0..length], "/");
                try offsets.put(gpa, offset, table.written().len);
                try table.writer.writeAll(entry);
                try table.writer.writeAll("/\n");
                offset += length + 1;
            }
            @memset(header[48..58], ' ');
            var digits: [20]u8 = undefined;
            const text = try std.fmt.bufPrint(&digits, "{d}", .{table.written().len});
            if (text.len > 10) return error.BadArchive;
            @memcpy(header[48..][0..text.len], text);
            try output.writeAll(&header);
            try output.writeAll(table.written());
            if (table.written().len % 2 != 0) try output.writeByte('\n');
            at = next;
            continue;
        } else if (field.len > 1 and field[0] == '/' and std.ascii.isDigit(field[1])) {
            const offset = try std.fmt.parseInt(usize, field[1..], 10);
            if (offset >= names.len) return error.BadArchive;
            const rest = names[offset..];
            const length = std.mem.indexOfAny(u8, rest, "\x00\n") orelse return error.BadArchive;
            name = std.mem.trimEnd(u8, rest[0..length], "/");
            var digits: [20]u8 = undefined;
            const text = try std.fmt.bufPrint(&digits, "/{d}", .{offsets.get(offset) orelse return error.BadArchive});
            if (text.len > 16) return error.BadArchive;
            @memset(header[0..16], ' ');
            @memcpy(header[0..text.len], text);
        } else {
            name = std.mem.trimEnd(u8, name, "/");
        }
        // Cargo's crate identity, not compiler-specific hashes or a list of
        // today's duplicate symbols. Reindex the remaining members afterward.
        if (std.mem.startsWith(u8, name, "compiler_builtins-")) {
            removed += 1;
        } else if (!std.mem.eql(u8, field, "/") and !std.mem.eql(u8, field, "/SYM64/")) {
            try output.writeAll(&header);
            try output.writeAll(input[start..next]);
        }
        at = next;
    }
    if (removed == 0) return error.NoCompilerBuiltins;
}
