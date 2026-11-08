//! Display/edit projection of the durable attachment trailer. No file I/O.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const marker = "Attached images (local files — open them to view):";
const legacy_marker = "Attached images (local files):";

pub const Parsed = struct {
    text: []const u8,
    paths: []const []const u8 = &.{},
};

/// Only consume an exact standalone transport header followed by absolute
/// path bullets. Spaces inside names are significant; later prose is not a
/// path. A malformed bullet makes the whole block literal (lossless fallback).
/// Returned allocations use `gpa`; path slices borrow the input.
pub fn parse(gpa: Allocator, text: []const u8) !Parsed {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var cursor: usize = 0;
    var copied: usize = 0;
    var fence: ?u8 = null;
    while (cursor < text.len) {
        const at = cursor;
        const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[at..end], "\r");
        cursor = @min(end + 1, text.len);
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            if (fence == null) {
                fence = trimmed[0];
            } else if (fence.? == trimmed[0]) {
                fence = null;
            }
            continue;
        }
        if (fence != null) continue;
        if (!std.mem.eql(u8, line, marker) and !std.mem.eql(u8, line, legacy_marker)) continue;
        // Validate a whole block before consuming any of it. Other blocks
        // remain independent, and interstitial/trailing prose is copied.
        var block: std.ArrayList([]const u8) = .empty;
        defer block.deinit(gpa);
        var block_end = cursor;
        var malformed = false;
        while (block_end < text.len) {
            const entry_end = std.mem.indexOfScalarPos(u8, text, block_end, '\n') orelse text.len;
            const entry = std.mem.trimEnd(u8, text[block_end..entry_end], "\r");
            if (!std.mem.startsWith(u8, entry, "- ")) break;
            if (!validPath(entry[2..])) {
                malformed = true;
                break;
            }
            try block.append(gpa, entry[2..]);
            block_end = @min(entry_end + 1, text.len);
        }
        if (malformed or block.items.len == 0) continue;
        try body.appendSlice(gpa, text[copied..at]);
        try paths.appendSlice(gpa, block.items);
        copied = block_end;
        cursor = block_end;
    }
    if (paths.items.len == 0) return .{ .text = text };
    try body.appendSlice(gpa, text[copied..]);
    body.items.len = std.mem.trimEnd(u8, body.items, "\r\n").len;
    const out = try body.toOwnedSlice(gpa);
    errdefer gpa.free(out);
    return .{ .text = out, .paths = try paths.toOwnedSlice(gpa) };
}

pub fn deinit(gpa: Allocator, parsed: Parsed) void {
    if (parsed.paths.len == 0) return;
    gpa.free(parsed.text);
    gpa.free(parsed.paths);
}

pub fn validPath(path: []const u8) bool {
    if (path.len < 2 or path.len > 4096) return false;
    const absolute = path[0] == '/' or std.mem.startsWith(u8, path, "\\\\") or (path.len > 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\'));
    if (!absolute or path[path.len - 1] == '/' or path[path.len - 1] == '\\') return false;
    var codepoints = (std.unicode.Utf8View.init(path) catch return false).iterator();
    while (codepoints.nextCodepoint()) |ch| if (ch < 32 or (ch >= 127 and ch <= 159)) return false;
    const basename = path[(if (std.mem.lastIndexOfAny(u8, path, "/\\")) |at| at + 1 else 0)..];
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        const extension = basename[dot + 1 ..];
        // Do not guess an image path from a prefix such as `shot.png and
        // I want Enter…`; preserve the complete ambiguous bullet literally.
        if (extension.len == 0) return false;
        for (extension) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    }
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

test "nano image parity parser keeps spaces and trailing prose" {
    const t = std.testing;
    const text = "Inspect this\n\n" ++ marker ++ "\n- /synthetic/uploads/a shot.png\n- C:\\synthetic\\other shot.JPG\nLater prose must stay.";
    const p = try parse(t.allocator, text);
    defer deinit(t.allocator, p);
    try t.expectEqualStrings("Inspect this\n\nLater prose must stay.", p.text);
    try t.expectEqual(@as(usize, 2), p.paths.len);
    try t.expectEqualStrings("/synthetic/uploads/a shot.png", p.paths[0]);
    try t.expectEqualStrings("C:\\synthetic\\other shot.JPG", p.paths[1]);
}

test "nano image parity parser is lossless for malformed or ordinary content" {
    const t = std.testing;
    for ([_][]const u8{
        "A normal prompt",
        marker,
        "Prompt\n\n" ++ marker ++ "\n- relative.png",
        "Prompt\n\n" ++ marker ++ "\n- /synthetic/a.png\n- malformed",
        "Prompt\n\n" ++ marker ++ "\n- /synthetic/../private.png",
        "Prompt\n\n" ++ marker ++ "\n- /synthetic/a\tshot.png",
        "Example " ++ marker ++ "\n- /synthetic/a.png",
        marker ++ "\n- /synthetic/shot.png and I want Enter…",
        marker ++ "\n- /synthetic/shot.png trailing prose",
        "```text\n\n" ++ marker ++ "\n- /synthetic/example.png\n```",
        "~~~\n\n" ++ marker ++ "\n- /synthetic/example.png\n~~~",
    }) |text| {
        const p = try parse(t.allocator, text);
        defer deinit(t.allocator, p);
        try t.expectEqualStrings(text, p.text);
        try t.expectEqual(@as(usize, 0), p.paths.len);
    }
    const p = try parse(t.allocator, legacy_marker ++ "\n- /synthetic/report.txt");
    defer deinit(t.allocator, p);
    try t.expectEqualStrings("", p.text);
    try t.expectEqual(@as(usize, 1), p.paths.len);
}

test "nano image parity parser accepts image-only and CRLF transports" {
    const t = std.testing;
    for ([_][]const u8{ marker ++ "\n- /synthetic/image.png", "Prompt\r\n\r\n" ++ marker ++ "\r\n- /synthetic/image.png" }, 0..) |text, index| {
        const p = try parse(t.allocator, text);
        defer deinit(t.allocator, p);
        try t.expectEqualStrings(if (index == 0) "" else "Prompt", p.text);
        try t.expectEqualStrings("/synthetic/image.png", p.paths[0]);
    }
}

test "nano image parity parser keeps prose across multiple blocks and exact Unicode UNC paths" {
    const t = std.testing;
    const unc = "\\\\synthetic\\share\\café shot.png";
    const text = "First\n" ++ marker ++ "\n- /synthetic/a shot.png\nBetween\n\n" ++ legacy_marker ++ "\n- " ++ unc ++ "\nAfter";
    const p = try parse(t.allocator, text);
    defer deinit(t.allocator, p);
    try t.expectEqualStrings("First\nBetween\n\nAfter", p.text);
    try t.expectEqual(@as(usize, 2), p.paths.len);
    try t.expectEqualStrings("/synthetic/a shot.png", p.paths[0]);
    try t.expectEqualStrings(unc, p.paths[1]);
}
