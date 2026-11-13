//! Owned, bounded parse/highlight results. Width does not affect these results;
//! palette, source bytes and language do. Never evict during a frame: UI text
//! nodes borrow these slices until layout/paint has finished.
const std = @import("std");
const ui = @import("nanoui").ui;
const md = @import("markdown.zig");
const hl = @import("highlight.zig");

pub const Line = struct { text: []const u8, spans: []const ui.Span };
const Parsed = struct { hash: u64, source: []const u8, palette: md.Palette, blocks: []const md.Block };
const Code = struct { hash: u64, source: []const u8, language: []const u8, palette: hl.Palette, lines: []const Line };

pub const Cache = struct {
    arena: ?std.heap.ArenaAllocator = null,
    parsed: std.ArrayList(Parsed) = .empty,
    code: std.ArrayList(Code) = .empty,
    const limit = 128;
    const max_bytes = 16 * 1024 * 1024;
    const max_source = 256 * 1024;

    pub fn deinit(self: *Cache) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    /// Called once before the app builds its tree. A full cache retires here,
    /// never while an earlier node in the current frame still borrows it.
    pub fn beginFrame(self: *Cache) void {
        if (self.arena) |*arena| {
            if (self.parsed.items.len == limit or self.code.items.len == limit or arena.queryCapacity() >= max_bytes) self.deinit();
        }
    }

    fn allocator(self: *Cache, gpa: std.mem.Allocator) std.mem.Allocator {
        if (self.arena == null) self.arena = .init(gpa);
        return self.arena.?.allocator();
    }

    fn full(self: *const Cache, len: usize, source_len: usize) bool {
        return len == limit or source_len > max_source or (if (self.arena) |arena| arena.queryCapacity() >= max_bytes else false);
    }

    pub fn parse(self: *Cache, gpa: std.mem.Allocator, frame: std.mem.Allocator, source: []const u8, palette: md.Palette) []const md.Block {
        const hash = std.hash.Wyhash.hash(0, source);
        for (self.parsed.items) |entry| {
            if (entry.hash == hash and std.meta.eql(entry.palette, palette) and std.mem.eql(u8, entry.source, source)) return entry.blocks;
        }
        if (self.full(self.parsed.items.len, source.len)) return md.parse(frame, source, palette);
        const a = self.allocator(gpa);
        const owned = a.dupe(u8, source) catch return md.parse(frame, source, palette);
        const blocks = md.parse(a, owned, palette);
        self.parsed.append(a, .{ .hash = hash, .source = owned, .palette = palette, .blocks = blocks }) catch {};
        return blocks;
    }

    pub fn highlight(self: *Cache, gpa: std.mem.Allocator, frame: std.mem.Allocator, source: []const u8, language: []const u8, palette: hl.Palette) []const Line {
        const hash = std.hash.Wyhash.hash(0, source);
        for (self.code.items) |entry| {
            if (entry.hash == hash and std.meta.eql(entry.palette, palette) and std.mem.eql(u8, entry.language, language) and std.mem.eql(u8, entry.source, source)) return entry.lines;
        }
        if (self.full(self.code.items.len, source.len)) return highlightLines(frame, source, language, palette);
        const a = self.allocator(gpa);
        const owned = a.dupe(u8, source) catch return highlightLines(frame, source, language, palette);
        const lang = a.dupe(u8, language) catch return highlightLines(frame, source, language, palette);
        const lines = highlightLines(a, owned, lang, palette);
        self.code.append(a, .{ .hash = hash, .source = owned, .language = lang, .palette = palette, .lines = lines }) catch {};
        return lines;
    }
};

pub fn highlightLines(a: std.mem.Allocator, source: []const u8, language: []const u8, palette: hl.Palette) []const Line {
    var lines: std.ArrayList(Line) = .empty;
    var state: hl.State = .{};
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |text| lines.append(a, .{ .text = text, .spans = hl.line(a, text, language, palette, &state) }) catch break;
    return lines.items;
}

test "#814 cache keys include text, language and theme, and retire only between frames" {
    const testing = std.testing;
    var cache: Cache = .{};
    defer cache.deinit();
    var frame: std.heap.ArenaAllocator = .init(testing.allocator);
    defer frame.deinit();
    const a = frame.allocator();
    const colors = @import("theme.zig").colors(true);
    var palette: md.Palette = .{ .code = colors.accent, .code_bg = colors.accent_wash, .link = colors.text, .muted = colors.muted };
    const first = cache.parse(testing.allocator, a, "hello", palette);
    const again = cache.parse(testing.allocator, a, "hello", palette);
    try testing.expect(first.ptr == again.ptr);
    const changed = cache.parse(testing.allocator, a, "world", palette);
    try testing.expectEqualStrings("world", changed[0].paragraph.text);
    palette.code = colors.text;
    _ = cache.parse(testing.allocator, a, "hello", palette);
    try testing.expectEqual(@as(usize, 3), cache.parsed.items.len);
    _ = cache.highlight(testing.allocator, a, "/* comment\nstill comment */", "zig", colors.syntax);
    _ = cache.highlight(testing.allocator, a, "/* comment\nstill comment */", "json", colors.syntax);
    var syntax = colors.syntax;
    syntax.comment = colors.text;
    _ = cache.highlight(testing.allocator, a, "/* comment\nstill comment */", "zig", syntax);
    try testing.expectEqual(@as(usize, 3), cache.code.items.len);
    for (0..Cache.limit) |i| {
        const source = try std.fmt.allocPrint(a, "synthetic {d}", .{i});
        _ = cache.parse(testing.allocator, a, source, palette);
    }
    try testing.expectEqual(Cache.limit, cache.parsed.items.len);
    // The first node's text must still be alive after overflowing the cache.
    try testing.expectEqualStrings("hello", first[0].paragraph.text);
    cache.beginFrame();
    try testing.expect(cache.arena == null);
}
