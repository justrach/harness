//! Current desktop task-tree rules (origin/main tool_call_rows.rs). All
//! outcomes derive from actual transcript parts, never invented activity.
const std = @import("std");
const tr = @import("transcript.zig");
const Allocator = std.mem.Allocator;

pub const row_height: f32 = 32;
pub const gutter: f32 = 48;
pub const text_gap: f32 = 8;
pub const row_inset: f32 = 6;
pub const wash_width: f32 = 112;
pub const footer_height: f32 = 24;
pub const footer_gap: f32 = 6;

pub const Result = union(enum) {
    running: ?u64,
    settled,
    summary: []const u8,
    diff: struct { additions: u64, deletions: u64 },
    failed: []const u8,
    passed: []const u8,

    pub fn washed(r: Result) bool {
        return r == .passed;
    }
};

pub fn result(a: Allocator, p: *const tr.Part, elapsed_ms: ?u64) Result {
    if (!p.resolved) return .{ .running = elapsed_ms };
    if (p.stats.len > 1) return .{ .summary = std.fmt.allocPrint(a, "{d} files", .{p.stats.len}) catch "" };
    if (p.stats.len == 1) return .{ .diff = .{ .additions = p.stats[0].additions, .deletions = p.stats[0].deletions } };
    if (p.diff_new != null or p.additions > 0 or p.deletions > 0)
        return .{ .diff = .{ .additions = p.additions, .deletions = p.deletions } };
    if (p.tool == .exec) {
        // Only command output is a test report. A read/search containing
        // "3 failed" isn't a failed test; the exit status must agree.
        if (captureCount(p.output, "failed")) |n| {
            if (n > 0) return if (p.is_error)
                .{ .failed = std.fmt.allocPrint(a, "{d} failed", .{n}) catch "failed" }
            else
                .settled;
        }
        if (!p.is_error) if (captureCount(p.output, "passed")) |n| return .{ .passed = std.fmt.allocPrint(a, "{d} passed", .{n}) catch "passed" };
    }
    if (searchSummary(a, p)) |s| return .{ .summary = s };
    if (p.is_error) return .{ .failed = "failed" };
    return .settled;
}

fn captureCount(text: []const u8, word: []const u8) ?u64 {
    var i: usize = 0;
    while (i + word.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) continue;
        if (i > 0 and text[i - 1] == ' ') {
            var start = i - 1;
            while (start > 0 and std.ascii.isDigit(text[start - 1])) start -= 1;
            if (start < i - 1) return std.fmt.parseInt(u64, text[start .. i - 1], 10) catch null;
        }
        const end = i + word.len;
        if (end < text.len and text[end] == ':') {
            var start = end + 1;
            while (start < text.len and std.ascii.isWhitespace(text[start])) start += 1;
            var stop = start;
            while (stop < text.len and std.ascii.isDigit(text[stop])) stop += 1;
            if (stop > start) return std.fmt.parseInt(u64, text[start..stop], 10) catch null;
        }
    }
    return null;
}

fn searchSummary(a: Allocator, p: *const tr.Part) ?[]const u8 {
    if (p.tool != .search and p.tool != .glob) return null;
    // The decoder retains a sidecar ref for outputs whose total cannot be
    // recovered from the summary. Do not mislabel a truncated result.
    if (p.output_ref.len > 0) return null;
    var n: usize = 0;
    var lines = std.mem.tokenizeAny(u8, p.output, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (std.mem.endsWith(u8, line, "…") or std.mem.endsWith(u8, line, "...")) return null;
        if (p.tool == .search) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
            const tail = line[colon + 1 ..];
            const stop = std.mem.indexOfScalar(u8, tail, ':') orelse tail.len;
            if (stop == 0) return null;
            for (tail[0..stop]) |b| if (!std.ascii.isDigit(b)) return null;
        } else if (std.mem.indexOfScalar(u8, line, ' ') != null) return null;
        n += 1;
    }
    if (n == 0) return null;
    return std.fmt.allocPrint(a, "{d} {s}", .{ n, if (p.tool == .glob) (if (n == 1) "file" else "files") else (if (n == 1) "match" else "matches") }) catch null;
}

/// Per-path totals, in first-touch order. Failed edits still carry the
/// engine's structured diff when one was actually supplied, as desktop does.
pub fn diffs(a: Allocator, parts: []const tr.Part) []const tr.Stat {
    var out: std.ArrayList(tr.Stat) = .empty;
    for (parts) |p| {
        if (p.kind != .tool or p.agent) continue;
        if (p.stats.len > 0) {
            for (p.stats) |s| merge(a, &out, s);
        } else if (p.diff_new != null or p.additions > 0 or p.deletions > 0) {
            if (p.path.len > 0) merge(a, &out, .{ .path = p.path, .additions = p.additions, .deletions = p.deletions });
        }
    }
    return out.items;
}

fn merge(a: Allocator, out: *std.ArrayList(tr.Stat), s: tr.Stat) void {
    for (out.items) |*old| if (std.mem.eql(u8, old.path, s.path)) {
        old.additions +|= s.additions;
        old.deletions +|= s.deletions;
        return;
    };
    out.append(a, s) catch {};
}

pub fn live(parts: []const tr.Part) bool {
    for (parts) |p| if (p.kind == .tool and !p.agent and !p.resolved) return true;
    return false;
}

/// Unicode-safe, same glyph set, head/tail lengths and phase as desktop.
pub fn scramble(a: Allocator, text: []const u8, phase: f32) []const u8 {
    const view = std.unicode.Utf8View.init(text) catch return text;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepointSlice() != null) n += 1;
    if (n < 6) return text;
    const head = std.math.clamp(n / 4, 2, 8);
    const tail = std.math.clamp(n / 4, 2, 10);
    if (head + tail >= n) return text;
    const glyphs = [_][]const u8{ "a", "c", "e", "k", "m", "n", "o", "r", "s", "u", "v", "x", "z", "·", "-", "_", "=", "+" };
    const seed = @as(usize, @intFromFloat(@floor(@max(phase, 0) * 97))) *% 31 +% n;
    var out: std.ArrayList(u8) = .empty;
    it = view.iterator();
    var i: usize = 0;
    while (it.nextCodepointSlice()) |cp| : (i += 1) {
        out.appendSlice(a, if (i < head or i >= n - tail or std.mem.eql(u8, cp, "/") or std.mem.eql(u8, cp, "\\") or std.mem.eql(u8, cp, " ")) cp else glyphs[(seed +% (i *% 17)) % glyphs.len]) catch return text;
    }
    return out.items;
}

pub fn timer(buf: []u8, ms: u64) []const u8 {
    const seconds = @as(f64, @floatFromInt(ms)) / 1000;
    return if (ms < 10_000) std.fmt.bufPrint(buf, "{d:.1}s", .{seconds}) catch "" else std.fmt.bufPrint(buf, "{d:.0}s", .{seconds}) catch "";
}

pub fn easeOutQuint(raw: f32) f32 {
    const t = 1 - std.math.clamp(raw, 0, 1);
    return 1 - t * t * t * t * t;
}

pub fn rowProgress(start: ?f64, now: f64, reduce: bool) f32 {
    const s = start orelse return 1;
    if (reduce) return 1;
    const t: f32 = @floatCast(std.math.clamp((now - s) / 0.360, 0, 1));
    return if (t >= 1) 1 else if (t <= 0) 0 else 1 - std.math.pow(f32, 2, -10 * t);
}

pub fn connectorProgress(start: ?f64, now: f64, reduce: bool) f32 {
    const s = start orelse return 1;
    return if (reduce) 1 else easeOutQuint(@floatCast((now - s) / 0.480));
}

pub fn connectorParts(progress: f32, predecessor: bool) struct { incoming: f32, branch: f32 } {
    const p = std.math.clamp(progress, 0, 1);
    const incoming_start: f32 = if (predecessor) 0.45 else 0;
    const incoming_end: f32 = if (predecessor) 0.72 else 0.62;
    const branch_start: f32 = if (predecessor) 0.68 else 0.58;
    return .{ .incoming = std.math.clamp((p - incoming_start) / (incoming_end - incoming_start), 0, 1), .branch = std.math.clamp((p - branch_start) / (1 - branch_start), 0, 1) };
}

pub fn washCell(col: u32, row: u32, cols: u32, rows: u32) bool {
    const bayer = [4][4]u8{ .{ 0, 8, 2, 10 }, .{ 12, 4, 14, 6 }, .{ 3, 11, 1, 9 }, .{ 15, 7, 13, 5 } };
    const across = (@as(f32, @floatFromInt(col)) + 0.5) / @as(f32, @floatFromInt(@max(cols, 1)));
    const edge = @as(f32, @floatFromInt(@min(row, rows -| (row + 1))));
    const taper = @min(edge / @max(@as(f32, @floatFromInt(rows)) * 0.25, 1), 1);
    const threshold = (@as(f32, @floatFromInt(bayer[row % 4][col % 4])) + 0.5) / 16;
    return threshold < across * across * 0.6 * taper;
}

/// A tool badge is a link only within its chat's checkout. Absolute paths
/// must share a component boundary; relative traversal cannot escape it.
pub fn workspacePath(a: Allocator, root: []const u8, path: []const u8) ?[]const u8 {
    if (root.len == 0 or path.len == 0 or path.len > 4096 or std.mem.indexOfAny(u8, path, "\r\n\x00") != null) return null;
    const windows = (root.len >= 2 and root[1] == ':') or std.mem.startsWith(u8, root, "\\\\");
    const normalized_root = if (windows) a.dupe(u8, root) catch return null else root;
    const normalized_path = if (windows) a.dupe(u8, path) catch return null else path;
    if (windows) {
        for (@constCast(normalized_root)) |*b| if (b.* == '\\') {
            b.* = '/';
        };
        for (@constCast(normalized_path)) |*b| if (b.* == '\\') {
            b.* = '/';
        };
    }
    var relative = normalized_path;
    const absolute = std.mem.startsWith(u8, relative, "/") or (relative.len >= 2 and relative[1] == ':');
    if (absolute) {
        const base = std.mem.trimEnd(u8, normalized_root, "/");
        if (relative.len <= base.len or relative[base.len] != '/') return null;
        const prefix = relative[0..base.len];
        if (if (windows) !std.ascii.eqlIgnoreCase(prefix, base) else !std.mem.eql(u8, prefix, base)) return null;
        relative = relative[base.len + 1 ..];
    }
    var components: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, relative, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (components.items.len == 0) return null;
            _ = components.pop();
        } else components.append(a, part) catch return null;
    }
    if (components.items.len == 0) return null;
    return std.mem.join(a, "/", components.items) catch null;
}

test "tool file links stay within the containing checkout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/a.zig", workspacePath(a, "/synthetic", "/synthetic/src/a.zig").?);
    try std.testing.expectEqualStrings("src/a.zig", workspacePath(a, "/synthetic", "./src/x/../a.zig").?);
    try std.testing.expect(workspacePath(a, "/synthetic", "/synthetic-other/a.zig") == null);
    try std.testing.expect(workspacePath(a, "/synthetic", "../a.zig") == null);
    try std.testing.expectEqualStrings("src/a.zig", workspacePath(a, "C:\\synthetic", "c:\\synthetic\\src\\a.zig").?);
    try std.testing.expect(workspacePath(a, "C:\\synthetic", "C:\\outside\\a.zig") == null);
}

test "tree results require real output and matching command exit status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: tr.Part = .{ .id = @constCast("synthetic"), .kind = .tool, .tool = .exec, .resolved = true, .output = @constCast("48 passed; 0 failed") };
    try std.testing.expectEqualStrings("48 passed", result(a, &p, null).passed);
    p.is_error = true;
    try std.testing.expectEqualStrings("failed", result(a, &p, null).failed);
    p.output = @constCast("2 failed");
    try std.testing.expectEqualStrings("2 failed", result(a, &p, null).failed);
    p.is_error = false;
    try std.testing.expect(result(a, &p, null) == .settled);
    p.tool = .readFile;
    try std.testing.expect(result(a, &p, null) == .settled);
    p.resolved = false;
    try std.testing.expectEqual(@as(?u64, null), result(a, &p, null).running);
}

test "search counts only complete real match lines, not summary prose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p: tr.Part = .{ .id = @constCast("synthetic"), .kind = .tool, .tool = .search, .resolved = true, .output = @constCast("src/a.zig:2:one\nsrc/b.zig:4:two") };
    try std.testing.expectEqualStrings("2 matches", result(arena.allocator(), &p, null).summary);
    p.output = @constCast("No matches found");
    try std.testing.expect(result(arena.allocator(), &p, null) == .settled);
    p.output = @constCast("src/a.zig:2:one\n…");
    try std.testing.expect(result(arena.allocator(), &p, null) == .settled);
}

test "scramble preserves unicode ends and separators and reduced motion snaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = scramble(arena.allocator(), "src/synthetic/路径.zig", 0.3);
    try std.testing.expect(std.mem.startsWith(u8, s, "src/"));
    try std.testing.expect(std.mem.endsWith(u8, s, ".zig"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
    try std.testing.expectEqual(@as(f32, 1), rowProgress(1, 0, true));
    try std.testing.expectEqual(@as(f32, 1), connectorProgress(null, 0, false));
    try std.testing.expectEqual(@as(f32, 0), connectorParts(0.44, true).branch);
}

test "aggregate diffs merge a path once and saturate counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ps = [_]tr.Part{
        .{ .id = @constCast("a"), .kind = .tool, .stats = @constCast(&[_]tr.Stat{.{ .path = "src/a.zig", .additions = 3, .deletions = 1 }}) },
        .{ .id = @constCast("b"), .kind = .tool, .path = @constCast("src/a.zig"), .additions = 2 },
    };
    const stats = diffs(arena.allocator(), &ps);
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectEqual(@as(u64, 5), stats[0].additions);
    try std.testing.expectEqual(@as(u64, 1), stats[0].deletions);
}
