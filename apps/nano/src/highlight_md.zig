//! Markdown's captures, as tree-sitter-md's block and inline queries name
//! them (GPUI injects the inline grammar into every `inline`): a heading's
//! `#`s, list markers, quote markers and rules as punctuation, the
//! heading's text `text.title`; a fenced block `text.literal`, its fences
//! punctuation, its code in its own language over that; inline code,
//! emphasis, strong text, links and escapes.
const std = @import("std");
const hl = @import("highlight.zig");
const Paint = hl.Paint;

/// An open fenced block: its fence and its language.
pub const Fence = struct {
    char: u8,
    len: usize,
    lang: ?hl.Language,
};

fn indent(src: []const u8) usize {
    var i: usize = 0;
    while (i < src.len and src[i] == ' ') i += 1;
    return i;
}

fn run(src: []const u8, from: usize, ch: u8) usize {
    var j = from;
    while (j < src.len and src[j] == ch) j += 1;
    return j - from;
}

fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t").len == 0;
}

pub fn paint(p: Paint, src: []const u8, st: *hl.State) void {
    if (st.fence) |f| {
        const at = indent(src);
        const n = run(src, at, f.char);
        if (at <= 3 and n >= f.len and blank(src[at + n ..])) {
            p.put(0, src.len, .markup_raw);
            p.put(at, at + n, .punctuation);
            st.fence = null;
            return;
        }
        // `fenced_code_block` is `text.literal`; its code (`@none`) keeps
        // that under the language injected into it.
        p.put(0, src.len, .markup_raw);
        if (f.lang) |l| if (l != .markdown) {
            var inner: hl.State = .{ .comment = st.comment, .string = st.string, .raw = st.raw, .depth = st.depth };
            hl.paint(p, src, l, &inner);
            st.comment = inner.comment;
            st.string = inner.string;
            st.raw = inner.raw;
            st.depth = inner.depth;
        };
        return;
    }
    block(p, src, 0, st);
}

/// The block structure of `src[from..]`: quote markers, then a fence, a
/// heading, a rule or a list marker, then its inline text.
fn block(p: Paint, src: []const u8, from: usize, st: *hl.State) void {
    // Deeper than three spaces: a list's continuation, read as one (an
    // `indented_code_block` isn't told apart).
    const i = from + indent(src[from..]);
    if (i >= src.len) return;
    const ch = src[i];
    if (ch == '>') {
        p.put(i, i + 1, .punctuation);
        var j = i + 1;
        if (j < src.len and src[j] == ' ') j += 1;
        return block(p, src, j, st);
    }
    if (ch == '`' or ch == '~') {
        const n = run(src, i, ch);
        const info = src[i + n ..];
        if (n >= 3 and !(ch == '`' and std.mem.indexOfScalar(u8, info, '`') != null)) {
            p.put(i, src.len, .markup_raw);
            p.put(i, i + n, .punctuation);
            st.fence = .{ .char = ch, .len = n, .lang = hl.language(std.mem.trim(u8, info, " \t")) };
            st.comment = false;
            st.string = "";
            return;
        }
    }
    if (ch == '#') {
        const n = run(src, i, '#');
        if (n <= 6 and (i + n == src.len or src[i + n] == ' ' or src[i + n] == '\t')) {
            p.put(i, i + n, .punctuation);
            // The heading's `inline`: its text, less the spaces around it
            // and a closing run of #s.
            var start = i + n;
            while (start < src.len and (src[start] == ' ' or src[start] == '\t')) start += 1;
            var end = src.len;
            while (end > start and (src[end - 1] == ' ' or src[end - 1] == '\t')) end -= 1;
            var close = end;
            while (close > start and src[close - 1] == '#') close -= 1;
            if (close < end and (close == start or src[close - 1] == ' ')) {
                end = close;
                while (end > start and src[end - 1] == ' ') end -= 1;
            }
            p.put(start, end, .markup_heading);
            return inline_(p, src, start, end);
        }
    }
    if (isBreak(src[i..])) return p.put(i, std.mem.trimEnd(u8, src, " \t").len, .punctuation);
    if (src[i..].len > 0 and (isSetext(src[i..], '='))) return p.put(i, std.mem.trimEnd(u8, src, " \t").len, .punctuation);
    if (listMarker(src, i)) |end| {
        p.put(i, end, .punctuation);
        var j = end;
        while (j < src.len and src[j] == ' ') j += 1;
        return block(p, src, j, st);
    }
    if (ch == '[') if (definition(p, src, i)) return;
    inline_(p, src, i, src.len);
}

/// A thematic break: three or more of one of `-*_`, spaces between.
fn isBreak(s: []const u8) bool {
    const t = std.mem.trimEnd(u8, s, " \t");
    if (t.len == 0 or std.mem.indexOfScalar(u8, "-*_", t[0]) == null) return false;
    var n: usize = 0;
    for (t) |ch| {
        if (ch == t[0]) n += 1 else if (ch != ' ' and ch != '\t') return false;
    }
    return n >= 3;
}

/// A setext heading's `===` underline.
fn isSetext(s: []const u8, ch: u8) bool {
    const t = std.mem.trimEnd(u8, s, " \t");
    for (t) |x| if (x != ch) return false;
    return t.len > 0;
}

/// A list item's marker at `i` (`-`, `+`, `*`, `1.`, `1)`): where it ends.
fn listMarker(src: []const u8, i: usize) ?usize {
    const ch = src[i];
    var end = i;
    if (ch == '-' or ch == '+' or ch == '*') {
        end = i + 1;
    } else if (std.ascii.isDigit(ch)) {
        var j = i;
        while (j < src.len and j - i < 9 and std.ascii.isDigit(src[j])) j += 1;
        if (j >= src.len or (src[j] != '.' and src[j] != ')')) return null;
        end = j + 1;
    } else return null;
    if (end < src.len and src[end] != ' ' and src[end] != '\t') return null;
    return end;
}

/// A link reference definition, `[label]: destination`.
fn definition(p: Paint, src: []const u8, i: usize) bool {
    const close = std.mem.indexOfScalarPos(u8, src, i + 1, ']') orelse return false;
    if (close + 1 >= src.len or src[close + 1] != ':') return false;
    p.put(i, close + 1, .markup_reference);
    var j = close + 2;
    while (j < src.len and src[j] == ' ') j += 1;
    var e = j;
    while (e < src.len and src[e] != ' ') e += 1;
    p.put(j, e, .markup_link);
    return true;
}

/// The inline grammar's captures over `src[from..to]`.
fn inline_(p: Paint, src: []const u8, from: usize, to: usize) void {
    var i = from;
    while (i < to) {
        const ch = src[i];
        if (ch == '\\' and i + 1 < to and std.ascii.isPrint(src[i + 1]) and !std.ascii.isAlphanumeric(src[i + 1])) {
            p.put(i, i + 2, .escape);
            i += 2;
            continue;
        }
        if (ch == '`') {
            const n = run(src[0..to], i, '`');
            if (closingRun(src[0..to], i + n, n)) |c| {
                p.put(i, c + n, .markup_raw);
                p.put(i, i + n, .punctuation);
                p.put(c, c + n, .punctuation);
                i = c + n;
                continue;
            }
            i += n;
            continue;
        }
        if (ch == '<') if (autolink(src[0..to], i)) |end| {
            p.put(i, end, .markup_link);
            i = end;
            continue;
        };
        if (ch == '[' or (ch == '!' and i + 1 < to and src[i + 1] == '[')) {
            if (link(p, src[0..to], i)) |end| {
                i = end;
                continue;
            }
        }
        if (ch == '*' or ch == '_') {
            if (emphasis(p, src[0..to], i)) |end| {
                i = end;
                continue;
            }
            i += run(src[0..to], i, ch);
            continue;
        }
        i += 1;
    }
}

/// Where a run of exactly `n` backquotes starts after `from`.
fn closingRun(src: []const u8, from: usize, n: usize) ?usize {
    var j = from;
    while (j < src.len) {
        if (src[j] != '`') {
            j += 1;
            continue;
        }
        const m = run(src, j, '`');
        if (m == n) return j;
        j += m;
    }
    return null;
}

fn autolink(src: []const u8, i: usize) ?usize {
    const close = std.mem.indexOfScalarPos(u8, src, i + 1, '>') orelse return null;
    const inner = src[i + 1 .. close];
    const colon = std.mem.indexOfScalar(u8, inner, ':') orelse return null;
    if (colon < 2 or std.mem.indexOfAny(u8, inner, " <") != null) return null;
    for (inner[0..colon]) |x| if (!(std.ascii.isAlphanumeric(x) or x == '+' or x == '.' or x == '-')) return null;
    return close + 1;
}

/// `[text](destination "title")` or `![alt](src)`: brackets and parens as
/// punctuation, the text a reference, the destination a link. A
/// `[shortcut]` has its brackets and its label.
fn link(p: Paint, src: []const u8, i: usize) ?usize {
    const open = if (src[i] == '!') i + 1 else i;
    const close = std.mem.indexOfScalarPos(u8, src, open + 1, ']') orelse return null;
    if (close + 1 < src.len and src[close + 1] == '(') {
        const end = std.mem.indexOfScalarPos(u8, src, close + 2, ')') orelse return null;
        if (src[i] == '!') p.put(i, i + 1, .punctuation);
        p.put(open, open + 1, .punctuation);
        p.put(open + 1, close, .markup_reference);
        inline_(p, src[0..close], open + 1, close);
        p.put(close, close + 2, .punctuation);
        const dest = src[close + 2 .. end];
        const title = std.mem.indexOfAny(u8, dest, " \t");
        p.put(close + 2, close + 2 + (title orelse dest.len), .markup_link);
        if (title) |t| p.put(close + 2 + t + 1, end, .markup_raw);
        p.put(end, end + 1, .punctuation);
        return end + 1;
    }
    if (src[i] == '!') return null;
    p.put(i, i + 1, .punctuation);
    p.put(i + 1, close, .markup_reference);
    p.put(close, close + 1, .punctuation);
    return close + 1;
}

/// `*emphasis*`, `**strong**` (or with `_`): the whole as `text.emphasis`
/// or `text.strong`, its delimiters punctuation. A `_` within a word
/// opens nothing.
fn emphasis(p: Paint, src: []const u8, i: usize) ?usize {
    const ch = src[i];
    const n = run(src, i, ch);
    if (i + n >= src.len or src[i + n] == ' ') return null;
    if (ch == '_' and i > 0 and std.ascii.isAlphanumeric(src[i - 1])) return null;
    const want = @min(n, 3);
    var j = i + n;
    while (j < src.len) {
        if (src[j] == '`') {
            const m = run(src, j, '`');
            j = if (closingRun(src, j + m, m)) |c| c + m else j + m;
            continue;
        }
        if (src[j] != ch) {
            j += 1;
            continue;
        }
        const m = run(src, j, ch);
        const after_ok = ch != '_' or j + m >= src.len or !std.ascii.isAlphanumeric(src[j + m]);
        if (m >= want and src[j - 1] != ' ' and after_ok) {
            const end = j + want;
            const kind: hl.Kind = if (want >= 2) .markup_strong else .markup_emphasis;
            p.put(i, end, kind);
            p.put(i, i + want, .punctuation);
            p.put(j, end, .punctuation);
            inline_(p, src[0..j], i + want, j);
            return end;
        }
        j += m;
    }
    return null;
}
