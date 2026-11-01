//! What the agent's latest turn did, reduced for the chat's work cue
//! (crates/ui/src/turn_work.rs): the "N files changed" card over the
//! composer that opens the Changes pane.
const std = @import("std");
const Allocator = std.mem.Allocator;
const transcript = @import("transcript.zig");

/// Files the latest agent turn edited, with summed line counts.
pub const TurnChanges = struct {
    /// Edited paths in first-touch order, each once.
    files: []const []const u8,
    additions: u64,
    deletions: u64,

    /// "1 file changed" / "3 files changed".
    pub fn title(t: TurnChanges, buf: []u8) []const u8 {
        if (t.files.len == 1) return "1 file changed";
        return std.fmt.bufPrint(buf, "{d} files changed", .{t.files.len}) catch "";
    }

    /// Up to three file names (not full paths), then "+N more".
    pub fn names(t: TurnChanges, a: Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (t.files[0..@min(3, t.files.len)], 0..) |path, i| {
            if (i > 0) out.appendSlice(a, ", ") catch {};
            out.appendSlice(a, std.fs.path.basenamePosix(path)) catch {};
        }
        if (t.files.len > 3) out.print(a, ", +{d} more", .{t.files.len - 3}) catch {};
        return out.items;
    }
};

/// The entries of the latest turn: everything after the last user prompt.
fn latestTurn(entries: []const transcript.Entry) []const transcript.Entry {
    var i = entries.len;
    while (i > 0) : (i -= 1) if (entries[i - 1].role == .user) return entries[i..];
    return entries;
}

/// Successful file edits in the latest turn, or null when it changed none
/// (`latest_turn_changes`).
pub fn latestTurnChanges(a: Allocator, entries: []const transcript.Entry) ?TurnChanges {
    var files: std.ArrayList([]const u8) = .empty;
    var t: TurnChanges = .{ .files = &.{}, .additions = 0, .deletions = 0 };
    for (latestTurn(entries)) |e| for (e.parts.items) |p| {
        if (p.kind != .tool or p.is_error) continue;
        switch (p.tool) {
            .writeFile, .editFile, .applyPatch => {},
            else => continue,
        }
        t.additions += p.additions;
        t.deletions += p.deletions;
        // The stats' paths (a patch's files), else the call's own.
        var paths = std.mem.tokenizeScalar(u8, p.stat_paths, '\n');
        var any = false;
        while (paths.next()) |path| {
            any = true;
            add(a, &files, path);
        }
        if (!any and p.path.len > 0) add(a, &files, p.path);
    };
    if (files.items.len == 0) return null;
    t.files = files.items;
    return t;
}

fn add(a: Allocator, files: *std.ArrayList([]const u8), path: []const u8) void {
    for (files.items) |f| if (std.mem.eql(u8, f, path)) return;
    files.append(a, path) catch {};
}

/// A `diff`'s lines added and removed (`harness_doc::diff_stat`): every
/// line of a new file, else the shortest edit between the two texts.
pub fn diffStat(gpa: Allocator, old: ?[]const u8, new: []const u8) struct { additions: u64, deletions: u64 } {
    const before = old orelse return .{ .additions = lineCount(new), .deletions = 0 };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const xs = lines(a, before) catch return .{ .additions = 0, .deletions = 0 };
    const ys = lines(a, new) catch return .{ .additions = 0, .deletions = 0 };
    // Common head and tail first: an edit's lines are usually few.
    var lo: usize = 0;
    while (lo < xs.len and lo < ys.len and std.mem.eql(u8, xs[lo], ys[lo])) lo += 1;
    var hx = xs.len;
    var hy = ys.len;
    while (hx > lo and hy > lo and std.mem.eql(u8, xs[hx - 1], ys[hy - 1])) {
        hx -= 1;
        hy -= 1;
    }
    const mx = xs[lo..hx];
    const my = ys[lo..hy];
    // The longest common subsequence of what's left, one row at a time; a
    // huge middle counts as all removed and all added.
    var common: usize = 0;
    if (mx.len > 0 and my.len > 0 and mx.len * my.len <= 4_000_000) {
        const prev = a.alloc(u32, my.len + 1) catch return .{ .additions = my.len, .deletions = mx.len };
        const row = a.alloc(u32, my.len + 1) catch return .{ .additions = my.len, .deletions = mx.len };
        @memset(prev, 0);
        for (mx) |x| {
            row[0] = 0;
            for (my, 1..) |y, j| row[j] = if (std.mem.eql(u8, x, y)) prev[j - 1] + 1 else @max(prev[j], row[j - 1]);
            @memcpy(prev, row);
        }
        common = prev[my.len];
    }
    return .{ .additions = my.len - common, .deletions = mx.len - common };
}

fn lineCount(s: []const u8) u64 {
    if (s.len == 0) return 0;
    var n: u64 = std.mem.count(u8, s, "\n");
    if (s[s.len - 1] != '\n') n += 1;
    return n;
}

fn lines(a: Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(a, l);
    // A final newline doesn't start another line (`str::lines`).
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

const testing = std.testing;

fn part(gpa: Allocator, tool: transcript.ToolKind, path: []const u8, is_error: bool) !transcript.Part {
    return .{ .id = try gpa.dupe(u8, "p"), .kind = .tool, .tool = tool, .path = try gpa.dupe(u8, path), .resolved = true, .is_error = is_error };
}

fn entry(gpa: Allocator, role: transcript.Role, parts: []const transcript.Part) !transcript.Entry {
    var e: transcript.Entry = .{ .id = try gpa.dupe(u8, "e"), .role = role, .status = .complete };
    try e.parts.appendSlice(gpa, parts);
    return e;
}

test "counts only the latest turn and skips failed edits (counts_only_the_latest_turn_and_skips_failed_edits)" {
    const gpa = testing.allocator;
    var entries = [_]transcript.Entry{
        try entry(gpa, .user, &.{}),
        try entry(gpa, .assistant, &.{try part(gpa, .editFile, "old.rs", false)}),
        try entry(gpa, .user, &.{}),
        try entry(gpa, .assistant, &.{
            try part(gpa, .editFile, "src/a.rs", false),
            try part(gpa, .editFile, "src/a.rs", false),
            try part(gpa, .editFile, "src/b.rs", true),
            try part(gpa, .exec, "", false),
        }),
    };
    defer for (&entries) |*e| e.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = latestTurnChanges(arena.allocator(), &entries) orelse return error.NoChanges;
    try testing.expectEqual(@as(usize, 1), t.files.len);
    try testing.expectEqualStrings("src/a.rs", t.files[0]);
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("1 file changed", t.title(&b));
    try testing.expectEqualStrings("a.rs", t.names(arena.allocator()));
}

test "no edits means no card (no_edits_means_no_card)" {
    const gpa = testing.allocator;
    var entries = [_]transcript.Entry{
        try entry(gpa, .user, &.{}),
        try entry(gpa, .assistant, &.{try part(gpa, .exec, "", false)}),
    };
    defer for (&entries) |*e| e.deinit(gpa);
    try testing.expect(latestTurnChanges(testing.allocator, &entries) == null);
}

test "names cap at three (names_cap_at_three)" {
    const files = [_][]const u8{ "a/x.rs", "y.rs", "z.rs", "w.rs" };
    const t: TurnChanges = .{ .files = &files, .additions = 0, .deletions = 0 };
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("4 files changed", t.title(&b));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("x.rs, y.rs, z.rs, +1 more", t.names(arena.allocator()));
}

test "a diff's lines added and removed are the shortest edit's" {
    const new_file = diffStat(testing.allocator, null, "a\nb\nc\n");
    try testing.expectEqual(@as(u64, 3), new_file.additions);
    try testing.expectEqual(@as(u64, 0), new_file.deletions);
    const edit = diffStat(testing.allocator, "a\nb\nc\nd\n", "a\nB\nc\nd\ne\n");
    try testing.expectEqual(@as(u64, 2), edit.additions);
    try testing.expectEqual(@as(u64, 1), edit.deletions);
    const same = diffStat(testing.allocator, "x\n", "x\n");
    try testing.expectEqual(@as(u64, 0), same.additions + same.deletions);
}
