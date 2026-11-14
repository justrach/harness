//! Only canonical github.com PR/issue navigation, never arbitrary API URLs.
const std = @import("std");
pub const Kind = enum { pull, issue };
pub const Section = enum { summary, code, activity };
pub const Target = struct { owner: []const u8, name: []const u8, number: u64, kind: Kind, section: Section = .summary };

pub fn validPart(part: []const u8) bool {
    if (part.len == 0 or part.len > 100 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}

/// Borrowed slices. Query/fragment contents are never forwarded to the host.
pub fn parse(url: []const u8) ?Target {
    const prefix = "https://github.com/";
    if (url.len > 8192 or !std.ascii.startsWithIgnoreCase(url, prefix)) return null;
    const raw = url[prefix.len..];
    const path = raw[0 .. std.mem.indexOfAny(u8, raw, "?#") orelse raw.len];
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, path, "/"), '/');
    const owner = parts.next() orelse return null;
    const name = parts.next() orelse return null;
    if (!validPart(owner) or !validPart(name)) return null;
    const segment = parts.next() orelse return null;
    const kind: Kind = if (std.mem.eql(u8, segment, "pull")) .pull else if (std.mem.eql(u8, segment, "issues")) .issue else return null;
    const digits = parts.next() orelse return null;
    if (digits.len == 0) return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const number = std.fmt.parseInt(u64, digits, 10) catch return null;
    if (number == 0 or number > std.math.maxInt(i64)) return null;
    var section: Section = .summary;
    if (parts.next()) |tail| {
        if (kind != .pull) return null;
        section = if (std.mem.eql(u8, tail, "files")) .code else if (std.mem.eql(u8, tail, "commits")) .activity else return null;
        if (parts.next() != null) return null;
    }
    return .{ .owner = owner, .name = name, .number = number, .kind = kind, .section = section };
}

test "github link parser accepts only bounded explicit native destinations" {
    const t = parse("https://github.com/demo/other/pull/42?tab=files#discussion").?;
    try std.testing.expectEqualStrings("demo", t.owner);
    try std.testing.expectEqualStrings("other", t.name);
    try std.testing.expectEqual(@as(u64, 42), t.number);
    try std.testing.expectEqual(Kind.pull, t.kind);
    try std.testing.expectEqual(Section.code, parse("https://github.com/demo/other/pull/42/files").?.section);
    try std.testing.expectEqual(Kind.issue, parse("https://github.com/demo/other/issues/51/").?.kind);
    for ([_][]const u8{
        "https://github.com.evil.invalid/demo/other/pull/42",     "https://user@github.com/demo/other/pull/42",
        "http://github.com/demo/other/pull/42",                   "https://github.com:443/demo/other/pull/42",
        "https://github.com/demo/%2e%2e/pull/42",                 "https://github.com/demo/../pull/42",
        "https://github.com/demo/other/pull/0",                   "https://github.com/demo/other/pull/-1",
        "https://github.com/demo/other/pull/9223372036854775808", "https://github.com/demo/other/pull/42/evil",
        "https://github.com/demo/other/issues/51/files",          "https://github.com/demo/other/pull/4%32",
        "https://github.com/demo/other/pull/42//files",           "javascript:github.com/demo/other/pull/42",
    }) |bad| try std.testing.expect(parse(bad) == null);
}
