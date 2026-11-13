//! An edit's inline diff (`ToolDiff`'s old and new text) as the changes
//! pane draws it (transcript.rs `diff_to_file`): hunks with 3 lines of
//! context, both 1-based line numbers, and unified-diff hunk headers. A
//! write with no old text is all additions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("diff.zig");

pub const context = 3;
/// What an opened step draws at most (`DIFF_DETAIL_MAX_LINES`).
pub const max_lines = 600;
/// Past this many cells the middle of a change isn't matched line by
/// line: it counts as all removed, then all added.
const max_cells = 250_000;

/// `old` → `new` as hunks, the strings pointing into them and the slices
/// into `a`; `path` names the file.
pub fn file(a: Allocator, path: []const u8, old: ?[]const u8, new: []const u8) !diff.File {
    const xs = try lines(a, old orelse "");
    const ys = try lines(a, new);
    const ops = try script(a, xs, ys);
    var hunks: std.ArrayList(diff.Hunk) = .empty;
    var adds: u32 = 0;
    var dels: u32 = 0;
    var drawn: usize = 0;
    var i: usize = 0;
    while (i < ops.len) {
        // The next change, then the run of changes no more than twice the
        // context apart, with the context around them.
        while (i < ops.len and ops[i].kind == .context) i += 1;
        if (i == ops.len) break;
        const start = i -| context;
        var end = i;
        var gap: usize = 0;
        while (end < ops.len) : (end += 1) {
            if (ops[end].kind == .context) {
                if (gap == 2 * context) break;
                gap += 1;
            } else gap = 0;
        }
        end -= gap -| context;
        const hl = ops[start..end];
        var ol: u32 = 0;
        var nl: u32 = 0;
        for (hl) |l| switch (l.kind) {
            .add => {
                nl += 1;
                adds += 1;
            },
            .del => {
                ol += 1;
                dels += 1;
            },
            else => {
                ol += 1;
                nl += 1;
            },
        };
        const os = firstNumber(hl, .old, ops, start);
        const ns = firstNumber(hl, .new, ops, start);
        if (drawn < max_lines) {
            const room = @min(hl.len, max_lines - drawn);
            drawn += room;
            try hunks.append(a, .{ .header = try std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@", .{ os, ol, ns, nl }), .lines = hl[0..room] });
        }
        i = end;
    }
    return .{ .path = path, .added = old == null, .additions = adds, .deletions = dels, .hunks = hunks.items };
}

/// A hunk's first old or new number, as `git diff` writes it: the line
/// before it when the hunk has none on that side (0 at the top).
fn firstNumber(hl: []const diff.Line, comptime side: enum { old, new }, ops: []const diff.Line, start: usize) u32 {
    for (hl) |l| if (@field(l, @tagName(side))) |n| return n;
    var j = start;
    while (j > 0) {
        j -= 1;
        if (@field(ops[j], @tagName(side))) |n| return n;
    }
    return 0;
}

/// Every line of both, in order: kept, removed or added.
fn script(a: Allocator, xs: []const []const u8, ys: []const []const u8) ![]diff.Line {
    var out: std.ArrayList(diff.Line) = .empty;
    var lo: usize = 0;
    while (lo < xs.len and lo < ys.len and std.mem.eql(u8, xs[lo], ys[lo])) lo += 1;
    var hx = xs.len;
    var hy = ys.len;
    while (hx > lo and hy > lo and std.mem.eql(u8, xs[hx - 1], ys[hy - 1])) {
        hx -= 1;
        hy -= 1;
    }
    for (0..lo) |k| try out.append(a, keep(xs, k, k));
    const mx = xs[lo..hx];
    const my = ys[lo..hy];
    if (mx.len > 0 and my.len > 0 and (mx.len + 1) * (my.len + 1) <= max_cells) {
        // The longest common subsequence's table, walked from the front.
        const w = my.len + 1;
        const t = try a.alloc(u32, (mx.len + 1) * w);
        @memset(t, 0);
        var x = mx.len;
        while (x > 0) {
            x -= 1;
            var y = my.len;
            while (y > 0) {
                y -= 1;
                t[x * w + y] = if (std.mem.eql(u8, mx[x], my[y])) t[(x + 1) * w + y + 1] + 1 else @max(t[(x + 1) * w + y], t[x * w + y + 1]);
            }
        }
        var i: usize = 0;
        var j: usize = 0;
        while (i < mx.len or j < my.len) {
            if (i < mx.len and j < my.len and std.mem.eql(u8, mx[i], my[j])) {
                try out.append(a, keep(xs, lo + i, lo + j));
                i += 1;
                j += 1;
            } else if (i < mx.len and (j == my.len or t[(i + 1) * w + j] >= t[i * w + j + 1])) {
                // Removed lines before added ones, as `git diff` has them.
                try out.append(a, .{ .kind = .del, .text = mx[i], .old = @intCast(lo + i + 1) });
                i += 1;
            } else {
                try out.append(a, .{ .kind = .add, .text = my[j], .new = @intCast(lo + j + 1) });
                j += 1;
            }
        }
    } else {
        for (mx, 0..) |l, k| try out.append(a, .{ .kind = .del, .text = l, .old = @intCast(lo + k + 1) });
        for (my, 0..) |l, k| try out.append(a, .{ .kind = .add, .text = l, .new = @intCast(lo + k + 1) });
    }
    for (0..xs.len - hx) |k| try out.append(a, keep(xs, hx + k, hy + k));
    return out.items;
}

fn keep(xs: []const []const u8, x: usize, y: usize) diff.Line {
    return .{ .kind = .context, .text = xs[x], .old = @intCast(x + 1), .new = @intCast(y + 1) };
}

fn lines(a: Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    // A final newline doesn't start another line (`str::lines`).
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

const testing = std.testing;

test "an edit: one hunk, three lines of context each side, both numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const old = "a\nb\nc\nd\ne\nf\ng\nh\ni\n";
    const new = "a\nb\nc\nd\nE\nf\ng\nh\ni\n";
    const f = try file(arena.allocator(), "x.txt", old, new);
    try testing.expectEqual(@as(usize, 1), f.hunks.len);
    try testing.expectEqualStrings("@@ -2,7 +2,7 @@", f.hunks[0].header);
    const ls = f.hunks[0].lines;
    try testing.expectEqual(@as(usize, 8), ls.len);
    try testing.expectEqualStrings("b", ls[0].text);
    try testing.expectEqual(diff.LineKind.del, ls[3].kind);
    try testing.expectEqual(@as(?u32, 5), ls[3].old);
    try testing.expectEqual(diff.LineKind.add, ls[4].kind);
    try testing.expectEqual(@as(?u32, 5), ls[4].new);
    try testing.expectEqualStrings("E", ls[4].text);
    try testing.expectEqual(@as(u32, 1), f.additions);
    try testing.expectEqual(@as(u32, 1), f.deletions);
}

test "far-apart changes are separate hunks; near ones share one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var old: std.ArrayList(u8) = .empty;
    var new: std.ArrayList(u8) = .empty;
    for (1..31) |n| {
        try old.print(arena.allocator(), "line {d}\n", .{n});
        try new.print(arena.allocator(), "line {d}{s}\n", .{ n, if (n == 2 or n == 5 or n == 25) "!" else "" });
    }
    const f = try file(arena.allocator(), "x.txt", old.items, new.items);
    try testing.expectEqual(@as(usize, 2), f.hunks.len);
    try testing.expectEqualStrings("@@ -1,8 +1,8 @@", f.hunks[0].header);
    try testing.expectEqualStrings("@@ -22,7 +22,7 @@", f.hunks[1].header);
    try testing.expectEqual(@as(u32, 3), f.additions);
}

test "a new file is all additions, from line 1" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try file(arena.allocator(), "notes.md", null, "one\ntwo\n");
    try testing.expect(f.added);
    try testing.expectEqualStrings("@@ -0,0 +1,2 @@", f.hunks[0].header);
    try testing.expectEqual(@as(?u32, 1), f.hunks[0].lines[0].new);
    try testing.expectEqual(@as(?u32, null), f.hunks[0].lines[0].old);
}
