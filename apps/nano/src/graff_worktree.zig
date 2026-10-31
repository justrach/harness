//! Graff-owned git worktrees (crates/proto/src/graff_worktree.rs):
//! `graff -w <name>` makes `<root>/.graff/worktrees/<name>`, which the
//! session footer names "Graff worktree" and offers to merge back, archive
//! or remove (`graff worktree merge|archive|remove`).
const std = @import("std");

const marker = "/.graff/worktrees/";

/// `GraffWorktree`: slices of the path it was read from.
pub const GraffWorktree = struct {
    /// The main checkout the tree belongs to (where `graff worktree` runs).
    root: []const u8,
    /// The `-w` name.
    name: []const u8,
    /// The tree's own folder: `path` up to and including `name`.
    path: []const u8,

    /// `GraffWorktree::from_path`: the Graff worktree `path` is (or is
    /// inside), if any.
    pub fn fromPath(path: []const u8) ?GraffWorktree {
        const at = std.mem.indexOf(u8, path, marker) orelse return null;
        const root = path[0..at];
        const rest = path[at + marker.len ..];
        const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        if (root.len == 0 or !validName(name)) return null;
        return .{ .root = root, .name = name, .path = path[0 .. at + marker.len + name.len] };
    }
};

/// `valid_name`: Graff's `-w` name rule, 1–64 of `[A-Za-z0-9._-]`.
pub fn validName(name: []const u8) bool {
    if (name.len < 1 or name.len > 64) return false;
    for (name) |b| if (!std.ascii.isAlphanumeric(b) and b != '.' and b != '_' and b != '-') return false;
    return true;
}

/// `graff_status_line` (pickers.rs): Graff's first non-blank line, the
/// tree's path (and macOS's `/private` spelling of it) shortened to its
/// name. In `buf`, cut to fit.
pub fn statusLine(buf: []u8, message: []const u8, tree_path: []const u8) []const u8 {
    var first: []const u8 = "Graff didn't say";
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) {
            first = t;
            break;
        }
    }
    const name = tree_path[if (std.mem.lastIndexOfScalar(u8, tree_path, '/')) |i| i + 1 else 0..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < first.len and n < buf.len) {
        const rest = first[i..];
        const skip: usize = if (tree_path.len == 0) 0 else if (std.mem.startsWith(u8, rest, "/private") and std.mem.startsWith(u8, rest["/private".len..], tree_path))
            "/private".len + tree_path.len
        else if (std.mem.startsWith(u8, rest, tree_path)) tree_path.len else 0;
        if (skip > 0) {
            const m = @min(name.len, buf.len - n);
            @memcpy(buf[n..][0..m], name[0..m]);
            n += m;
            i += skip;
        } else {
            buf[n] = first[i];
            n += 1;
            i += 1;
        }
    }
    return buf[0..n];
}

const testing = std.testing;

test "parses Graff worktree paths (parses_graff_worktree_paths)" {
    const tree = GraffWorktree.fromPath("/repo/.graff/worktrees/harness-ab12").?;
    try testing.expectEqualStrings("/repo", tree.root);
    try testing.expectEqualStrings("harness-ab12", tree.name);
    try testing.expectEqualStrings("/repo/.graff/worktrees/harness-ab12", tree.path);
    const inside = GraffWorktree.fromPath("/repo/.graff/worktrees/x/src/lib.rs").?;
    try testing.expectEqualStrings("/repo/.graff/worktrees/x", inside.path);
    for ([_][]const u8{ "/repo", "/repo/.graff/worktrees/", "/.graff/worktrees/x", "/r/.graff/worktrees/bad name" }) |other|
        try testing.expect(GraffWorktree.fromPath(other) == null);
}

test "Graff's name rule" {
    try testing.expect(validName("harness-0199a1b2c3d4"));
    try testing.expect(validName("a.b_c-d"));
    const long: [65]u8 = @splat('x');
    try testing.expect(!validName(&long));
    try testing.expect(validName(long[0..64]));
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName(""));
}

test "Graff's verdict as one line, the tree named rather than spelled out" {
    var buf: [200]u8 = undefined;
    const tree = "/w/app/.graff/worktrees/harness-ab12";
    try testing.expectEqualStrings("Merged harness-ab12 into main", statusLine(&buf, "\n  Merged /w/app/.graff/worktrees/harness-ab12 into main\nmore", tree));
    try testing.expectEqualStrings("kept harness-ab12: unmerged work", statusLine(&buf, "kept /private/w/app/.graff/worktrees/harness-ab12: unmerged work", tree));
    try testing.expectEqualStrings("Graff didn't say", statusLine(&buf, " \n ", tree));
    try testing.expectEqualStrings("as is", statusLine(&buf, "as is", ""));
}
