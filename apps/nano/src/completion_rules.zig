//! #575's accepted-name replacement range, independent of drawing/RPC.
const std = @import("std");
const unicode = @import("completion_unicode.zig");
// Keep the existing palette's locale-independent fold without pulling UI/App
// into this pure range rule.
const fold = struct {
    fn lowerCodepoint(cp: u21) u21 {
        return switch (cp) {
            'A'...'Z' => cp + 32,
            0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
            0x100...0x12F, 0x132...0x137, 0x14A...0x177 => if (cp % 2 == 0) cp + 1 else cp,
            0x139...0x148, 0x179...0x17E => if (cp % 2 == 1) cp + 1 else cp,
            0x130 => 'i',
            0x178 => 0xFF,
            0x391...0x3A1, 0x3A3...0x3AB => cp + 0x20,
            0x400...0x40F => cp + 0x50,
            0x410...0x42F => cp + 0x20,
            else => cp,
        };
    }
    fn foldBuf(buf: []u8, text: []const u8) []const u8 {
        var n: usize = 0;
        var it = (std.unicode.Utf8View.init(text) catch return "").iterator();
        while (it.nextCodepoint()) |cp| {
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(lowerCodepoint(cp), &enc) catch continue;
            if (n + len > buf.len) break;
            @memcpy(buf[n..][0..len], enc[0..len]);
            n += len;
        }
        return buf[0..n];
    }
};
pub const Range = struct { start: usize, end: usize };
pub const Token = struct { range: Range, caret: usize, prefix: u8, query: []const u8 };

fn codepoint(text: []const u8, at: usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(text[at]) catch return 0;
    return std.unicode.utf8Decode(text[at..@min(text.len, at + n)]) catch 0;
}
fn next(text: []const u8, at: usize) usize {
    return @min(text.len, at + (std.unicode.utf8ByteSequenceLength(text[at]) catch 1));
}
fn previous(text: []const u8, at: usize) usize {
    var p = at - 1;
    while (p > 0 and text[p] & 0xc0 == 0x80) p -= 1;
    return p;
}
fn whitespace(cp: u21) bool {
    return cp == ' ' or (cp >= 9 and cp <= 13) or cp == 0x85 or cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000;
}
fn separator(cp: u21) bool {
    return whitespace(cp) or cp == '(' or cp == '[' or cp == '{' or cp == '>';
}
pub fn nameCodepoint(cp: u21) bool {
    return unicode.alnum(cp) or unicode.mark(cp) or cp == '-' or cp == '_' or cp == ':' or cp == '.' or cp == 0x200D;
}

/// Names contain letter/number graphemes or -_:. Combining marks, Hangul
/// syllable components and virama-linked letters remain indivisible.
pub fn graphemeEnd(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    var end = next(text, at);
    var last = codepoint(text, at);
    while (end < text.len) {
        const cp = codepoint(text, end);
        const l = last >= 0x1100 and last <= 0x115F;
        const v = last >= 0x1160 and last <= 0x11A7;
        const t = last >= 0x11A8 and last <= 0x11FF;
        const syllable = last >= 0xAC00 and last <= 0xD7A3;
        const lv = syllable and (last - 0xAC00) % 28 == 0;
        const hangul = (l and cp >= 0x1100 and cp <= 0x11A7) or ((v or lv) and cp >= 0x1160 and cp <= 0x11FF) or ((t or (syllable and !lv)) and cp >= 0x11A8 and cp <= 0x11FF);
        if (!unicode.mark(cp) and cp != 0x200D and last != 0x200D and !unicode.linker(last) and !hangul) break;
        end = next(text, end);
        last = cp;
    }
    return end;
}

/// Completion is not active inside Markdown examples or existing links.
fn markdownAllows(text: []const u8, at: usize) bool {
    var ticks: usize = 0;
    var link_depth: usize = 0;
    var i: usize = 0;
    while (i < at) {
        if (text[i] == '\\') {
            i = @min(at, i + 2);
            continue;
        }
        if (text[i] == '`') {
            var end = i + 1;
            while (end < text.len and text[end] == '`') end += 1;
            const n = end - i;
            if (ticks == 0) ticks = n else if (ticks == n) ticks = 0;
            i = end;
            continue;
        }
        if (ticks == 0) {
            if (text[i] == '[') link_depth += 1;
            if (text[i] == ']' and link_depth > 0) {
                link_depth -= 1;
                if (i + 1 < at and text[i + 1] == '(') {
                    const close = std.mem.indexOfScalarPos(u8, text, i + 2, ')') orelse text.len;
                    if (at <= close) return false;
                }
            }
        }
        i += 1;
    }
    return ticks == 0 and link_depth == 0;
}

pub fn token(text: []const u8, caret: usize) ?Token {
    if (caret > text.len or !std.unicode.utf8ValidateSlice(text) or (caret < text.len and text[caret] & 0xc0 == 0x80)) return null;
    var start = caret;
    while (start > 0) {
        const p = previous(text, start);
        if (separator(codepoint(text, p))) break;
        start = p;
    }
    if (start >= caret or (text[start] != '/' and text[start] != '$') or !markdownAllows(text, start)) return null;
    const name_start = start + 1;
    var i = name_start;
    while (i < caret) : (i = next(text, i)) if (!nameCodepoint(codepoint(text, i))) return null;
    if (text[start] == '$' and name_start < caret and text[name_start] >= '0' and text[name_start] <= '9') return null;
    var end = caret;
    while (end < text.len and nameCodepoint(codepoint(text, end))) end = next(text, end);
    return .{ .range = .{ .start = start, .end = end }, .caret = caret, .prefix = text[start], .query = text[name_start..caret] };
}

fn compact(out: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return "").iterator();
    while (it.nextCodepoint()) |cp| {
        if (!unicode.alnum(cp) and !unicode.mark(cp)) continue;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(fold.lowerCodepoint(cp), &buf) catch continue;
        if (n + len > out.len) break;
        @memcpy(out[n..][0..len], buf[0..len]);
        n += len;
    }
    return out[0..n];
}

/// Exact (case-folded) names win before prefixes, then the existing substring
/// and punctuation-insensitive ranks. Equal ranks retain catalog order.
pub fn matchRank(query: []const u8, name: []const u8) ?u8 {
    var qbuf: [1024]u8 = undefined;
    var nbuf: [1024]u8 = undefined;
    const q = fold.foldBuf(&qbuf, query);
    const n = fold.foldBuf(&nbuf, name);
    if (std.mem.eql(u8, n, q)) return 0;
    if (std.mem.startsWith(u8, n, q)) return 1;
    if (std.mem.indexOf(u8, n, q) != null) return 2;
    var cqbuf: [1024]u8 = undefined;
    var cnbuf: [1024]u8 = undefined;
    const cq = compact(&cqbuf, query);
    const cn = compact(&cnbuf, name);
    if (cq.len == 0) return null;
    if (std.mem.startsWith(u8, cn, cq)) return 3;
    if (std.mem.indexOf(u8, cn, cq) != null) return 4;
    return null;
}

pub fn replacementRange(text: []const u8, tok: Token, name: []const u8) Range {
    const start = tok.range.start + 1;
    var end = tok.caret;
    var i = start;
    while (i < tok.range.end) {
        const ge = graphemeEnd(text, i);
        defer i = ge;
        if (ge <= tok.caret) continue;
        if (i < tok.caret) {
            end = ge;
            continue;
        }
        if (matchRank(text[start..ge], name) == null) break;
        if (unicode.alnum(codepoint(text, i))) end = ge;
    }
    return .{ .start = tok.range.start, .end = end };
}

const testing = std.testing;
test "completion exact names outrank longer prefixes without changing fuzzy match order" {
    const Case = struct { query: []const u8, exact: []const u8, prefix: []const u8 };
    for ([_]Case{
        .{ .query = "compact", .exact = "compact", .prefix = "compact-at" },
        .{ .query = "COMPACT", .exact = "compact", .prefix = "compact-at" },
        .{ .query = "review", .exact = "review", .prefix = "review-extra" },
        .{ .query = "harness:model", .exact = "harness:model", .prefix = "harness:model-extra" },
        .{ .query = "ÄPFEL", .exact = "äpfel", .prefix = "äpfel-baum" },
    }) |c| try testing.expect(matchRank(c.query, c.exact).? < matchRank(c.query, c.prefix).?);

    // Partial and empty queries keep stable catalog order within a rank.
    try testing.expectEqual(matchRank("comp", "compact-at"), matchRank("comp", "compact"));
    try testing.expectEqual(matchRank("", "compact-at"), matchRank("", "compact"));
    try testing.expect(matchRank("compact", "compact-at").? < matchRank("compact", "auto-compact").?);
    try testing.expect(matchRank("compact", "auto-compact").? < matchRank("compact", "com-pact-at").?);
    try testing.expect(matchRank("compact", "com-pact-at").? < matchRank("compact", "auto-com-pact").?);
    try testing.expectEqual(@as(?u8, null), matchRank("compact", "review"));
}

test "completion range preserves issue575 adjacent suffix and consumes only accepted-name continuation" {
    const Case = struct { text: []const u8, caret: usize, name: []const u8, suffix: []const u8 };
    for ([_]Case{
        .{ .text = "/goalprompt text remains", .caret = 5, .name = "goal", .suffix = "prompt text remains" },
        .{ .text = "/compact rest", .caret = 3, .name = "compact", .suffix = " rest" },
        .{ .text = "/COMPACT rest", .caret = 3, .name = "compact", .suffix = " rest" },
        .{ .text = "/pact rest", .caret = 3, .name = "compact", .suffix = " rest" },
        .{ .text = "/goal-x rest", .caret = 5, .name = "goal", .suffix = "-x rest" },
        .{ .text = "/a-bc rest", .caret = 2, .name = "abc", .suffix = " rest" },
        .{ .text = "/a-xyz rest", .caret = 2, .name = "abc", .suffix = "-xyz rest" },
        .{ .text = "(/goal) rest", .caret = 6, .name = "goal", .suffix = ") rest" },
        .{ .text = "$reviewprompt", .caret = 7, .name = "review", .suffix = "prompt" },
        .{ .text = "/命令suffix", .caret = 4, .name = "命令", .suffix = "suffix" },
        .{ .text = "/e\u{301}suffix", .caret = 2, .name = "é", .suffix = "suffix" },
        .{ .text = "/name:qualifiedprompt", .caret = 6, .name = "name:qualified", .suffix = "prompt" },
    }) |c| {
        const t = token(c.text, c.caret).?;
        const r = replacementRange(c.text, t, c.name);
        try testing.expectEqualStrings(c.suffix, c.text[r.end..]);
    }
}

test "completion trigger rejects Markdown literal code links and non-invocation punctuation" {
    for ([_][]const u8{ "`/goal", "```\n/goal", "[a](/goal", "https://goal", "$12", "/a=b", "x/goal", "[/goal" }) |text|
        try testing.expect(token(text, text.len) == null);
    try testing.expect(token("/", 1) != null);
    try testing.expect(token("before (/goal", 13) != null);
}
