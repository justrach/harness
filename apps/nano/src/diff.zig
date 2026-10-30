//! A checkout's unified git patch (`CheckoutDiff.patch`), split into what
//! the changes pane draws (crates/ui/src/changes.rs): per file a header,
//! notices ("New file", "Renamed from …", "Binary file — contents not
//! shown"), hunk headers, and lines with their old and new numbers.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LineKind = enum { add, del, context, meta };

pub const Line = struct {
    kind: LineKind,
    text: []const u8,
    old: ?u32 = null,
    new: ?u32 = null,
};

pub const Hunk = struct {
    header: []const u8,
    lines: []const Line,
};

pub const File = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    added: bool = false,
    deleted: bool = false,
    binary: bool = false,
    mode: ?[]const u8 = null,
    additions: u32 = 0,
    deletions: u32 = 0,
    hunks: []const Hunk,
};

/// Parses `patch` into files; strings point into `patch`, the slices into
/// `arena`.
pub fn parse(arena: Allocator, patch: []const u8) ![]File {
    var files: std.ArrayList(File) = .empty;
    var hunks: std.ArrayList(Hunk) = .empty;
    var lines: std.ArrayList(Line) = .empty;
    var cur: ?File = null;
    var hunk_header: ?[]const u8 = null;
    var old_no: u32 = 0;
    var new_no: u32 = 0;
    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "diff --git ")) {
            try closeHunk(arena, &hunks, &lines, &hunk_header);
            if (cur) |*f| {
                f.hunks = try hunks.toOwnedSlice(arena);
                try files.append(arena, f.*);
            }
            cur = .{ .path = pathFromGitLine(l), .hunks = &.{} };
            continue;
        }
        const f = if (cur) |*f| f else continue;
        if (hunk_header == null) {
            if (std.mem.startsWith(u8, l, "new file mode")) f.added = true;
            if (std.mem.startsWith(u8, l, "deleted file mode")) f.deleted = true;
            if (std.mem.startsWith(u8, l, "new mode ")) f.mode = l["new mode ".len..];
            if (std.mem.startsWith(u8, l, "rename from ")) f.old_path = l["rename from ".len..];
            if (std.mem.startsWith(u8, l, "rename to ")) f.path = l["rename to ".len..];
            if (std.mem.startsWith(u8, l, "Binary files ") or std.mem.eql(u8, l, "GIT binary patch")) f.binary = true;
            if (std.mem.startsWith(u8, l, "+++ b/")) f.path = l["+++ b/".len..];
        }
        if (std.mem.startsWith(u8, l, "@@")) {
            try closeHunk(arena, &hunks, &lines, &hunk_header);
            hunk_header = l;
            const r = hunkStarts(l);
            old_no = r[0];
            new_no = r[1];
            continue;
        }
        if (hunk_header == null or l.len == 0 and it.peek() == null) continue;
        if (l.len == 0) {
            try lines.append(arena, .{ .kind = .context, .text = "", .old = old_no, .new = new_no });
            old_no += 1;
            new_no += 1;
            continue;
        }
        switch (l[0]) {
            '+' => {
                try lines.append(arena, .{ .kind = .add, .text = l[1..], .new = new_no });
                new_no += 1;
                f.additions += 1;
            },
            '-' => {
                try lines.append(arena, .{ .kind = .del, .text = l[1..], .old = old_no });
                old_no += 1;
                f.deletions += 1;
            },
            ' ' => {
                try lines.append(arena, .{ .kind = .context, .text = l[1..], .old = old_no, .new = new_no });
                old_no += 1;
                new_no += 1;
            },
            '\\' => try lines.append(arena, .{ .kind = .meta, .text = l }),
            else => {},
        }
    }
    try closeHunk(arena, &hunks, &lines, &hunk_header);
    if (cur) |*f| {
        f.hunks = try hunks.toOwnedSlice(arena);
        try files.append(arena, f.*);
    }
    return files.toOwnedSlice(arena);
}

fn closeHunk(arena: Allocator, hunks: *std.ArrayList(Hunk), lines: *std.ArrayList(Line), header: *?[]const u8) !void {
    const h = header.* orelse return;
    try hunks.append(arena, .{ .header = h, .lines = try lines.toOwnedSlice(arena) });
    header.* = null;
}

/// "diff --git a/x b/y" → "y" (the new side).
fn pathFromGitLine(l: []const u8) []const u8 {
    const rest = l["diff --git ".len..];
    if (std.mem.lastIndexOf(u8, rest, " b/")) |i| return rest[i + 3 ..];
    return rest;
}

/// "@@ -12,7 +12,9 @@ fn x" → .{ 12, 12 }.
fn hunkStarts(l: []const u8) [2]u32 {
    var out = [2]u32{ 1, 1 };
    var it = std.mem.tokenizeScalar(u8, l, ' ');
    while (it.next()) |tok| {
        const side: usize = if (tok[0] == '-') 0 else if (tok[0] == '+') 1 else continue;
        const end = std.mem.indexOfScalar(u8, tok, ',') orelse tok.len;
        out[side] = std.fmt.parseInt(u32, tok[1..end], 10) catch out[side];
        if (side == 1) break;
    }
    return out;
}

const testing = std.testing;

test "a patch splits into files, hunks and numbered lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const patch =
        \\diff --git a/src/app.ts b/src/app.ts
        \\index 1111..2222 100644
        \\--- a/src/app.ts
        \\+++ b/src/app.ts
        \\@@ -10,3 +10,4 @@ export function main() {
        \\ const a = 1;
        \\-const b = 2;
        \\+const b = 3;
        \\+const c = 4;
        \\ return a;
        \\diff --git a/new.md b/new.md
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.md
        \\@@ -0,0 +1 @@
        \\+# Hello
        \\\ No newline at end of file
        \\diff --git a/old.png b/old.png
        \\Binary files a/old.png and b/old.png differ
        \\
    ;
    const files = try parse(arena.allocator(), patch);
    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqualStrings("src/app.ts", files[0].path);
    try testing.expectEqual(@as(u32, 2), files[0].additions);
    try testing.expectEqual(@as(u32, 1), files[0].deletions);
    const lines = files[0].hunks[0].lines;
    try testing.expectEqual(@as(?u32, 10), lines[0].old);
    try testing.expectEqual(LineKind.del, lines[1].kind);
    try testing.expectEqual(@as(?u32, 11), lines[1].old);
    try testing.expectEqual(@as(?u32, 12), lines[3].new);
    try testing.expect(files[1].added);
    try testing.expectEqual(LineKind.meta, files[1].hunks[0].lines[1].kind);
    try testing.expect(files[2].binary);
}

test "a rename keeps both paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const files = try parse(arena.allocator(),
        \\diff --git a/a.txt b/b.txt
        \\similarity index 100%
        \\rename from a.txt
        \\rename to b.txt
    );
    try testing.expectEqualStrings("b.txt", files[0].path);
    try testing.expectEqualStrings("a.txt", files[0].old_path.?);
}
