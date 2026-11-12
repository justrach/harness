//! Markdown, as agents write it: headings, paragraphs, bullet, numbered
//! and task lists, quotes, rules, fenced code, tables; and inline
//! **bold**, *italics*, `code`, ~~struck~~ text and [links](…); and the
//! HTML READMEs mix in (`markdown_html.zig`). Parsed into blocks whose
//! text carries nanoui spans, in the frame's memory.
const std = @import("std");
test {
    _ = @import("tests_native_math.zig");
}
const nanoui = @import("nanoui");
const html = @import("markdown_html.zig");
const Span = nanoui.ui.Span;
const Color = nanoui.ui.Color;

/// The colors inline marks take.
pub const Palette = struct {
    code: Color,
    code_bg: Color,
    link: Color,
    /// HTML's small print (`<sub>`, `<small>`).
    muted: ?Color = null,
};

/// Text with its spans: sorted, never overlapping.
pub const Inline = struct {
    text: []const u8,
    spans: []const Span,
    /// Pictures (`![alt](src)`): their source, and where their alt text is
    /// in `text` (drawn as a link where the picture can't be shown).
    images: []const Image = &.{},
    /// Destinations and rendered byte ranges, retained separately from style.
    links: []const Link = &.{},
    /// Atomic equations retain their exact delimited source in `text` for
    /// selection/Copy, alongside the raw body for native layout.
    maths: []const Math = &.{},
    /// Centered, as HTML's `align="center"` asks.
    center: bool = false,
};

/// A picture: its source, where its alt text is in the text, and the
/// width HTML gave it.
pub const Image = struct { src: []const u8, start: u32, end: u32, width: ?f32 = null };
pub const Link = struct { url: []const u8, start: u32, end: u32 };
pub const Math = struct { source: []const u8, start: u32, end: u32, display: bool };

pub const Block = union(enum) {
    paragraph: Inline,
    heading: struct { level: u8, text: Inline },
    code: struct { lang: []const u8, text: []const u8 },
    math: Inline,
    item: struct { depth: u8, marker: []const u8, task: ?bool = null, text: Inline },
    quote: Inline,
    rule,
    table: struct { header: []const Inline, rows: []const []const Inline },
};

/// Test-only work counter: performance regressions assert parsing work, not timings.
pub var test_parse_calls: usize = 0;

pub fn parse(arena: std.mem.Allocator, src: []const u8, pal: Palette) []const Block {
    if (@import("builtin").is_test) test_parse_calls += 1;
    var p: Parser = .{ .arena = arena, .pal = pal };
    p.run(src) catch {};
    return p.blocks.items;
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    pal: Palette,
    blocks: std.ArrayList(Block) = .empty,
    /// Lines of the paragraph (or list item, quote) being gathered.
    para: std.ArrayList(u8) = .empty,
    para_kind: enum { none, paragraph, item, quote } = .none,
    item_depth: u8 = 0,
    item_marker: []const u8 = "",
    item_task: ?bool = null,

    fn flush(p: *Parser) !void {
        if (p.para_kind == .none) return;
        const text = try p.inlines(std.mem.trim(u8, p.para.items, " \n"));
        switch (p.para_kind) {
            .paragraph => try p.blocks.append(p.arena, .{ .paragraph = text }),
            .item => try p.blocks.append(p.arena, .{ .item = .{ .depth = p.item_depth, .marker = p.item_marker, .task = p.item_task, .text = text } }),
            .quote => try p.blocks.append(p.arena, .{ .quote = text }),
            .none => {},
        }
        p.para = .empty;
        p.para_kind = .none;
    }

    fn gather(p: *Parser, line: []const u8) !void {
        if (p.para.items.len > 0) {
            // Two trailing spaces break the line; otherwise lines join.
            const hard = std.mem.endsWith(u8, p.para.items, "  ");
            try p.para.append(p.arena, if (hard) '\n' else ' ');
        }
        try p.para.appendSlice(p.arena, std.mem.trim(u8, line, " \t"));
    }

    fn run(p: *Parser, src: []const u8) !void {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |l| try lines.append(p.arena, std.mem.trimEnd(u8, l, "\r"));
        var i: usize = 0;
        while (i < lines.items.len) : (i += 1) {
            const line = lines.items[i];
            const t = std.mem.trim(u8, line, " \t");
            const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
            if (t.len == 0) {
                try p.flush();
                continue;
            }
            // A fence: everything to the closing fence (or the end, while it streams).
            if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
                try p.flush();
                const fence = t[0..3];
                const lang = std.mem.trim(u8, t[3..], " `~");
                var body: std.ArrayList(u8) = .empty;
                i += 1;
                while (i < lines.items.len) : (i += 1) {
                    const l = lines.items[i];
                    if (std.mem.startsWith(u8, std.mem.trimStart(u8, l, " \t"), fence)) break;
                    if (body.items.len > 0) try body.append(p.arena, '\n');
                    try body.appendSlice(p.arena, if (l.len >= indent and indent > 0) l[indent..] else l);
                }
                // A fence still streaming ends at its last full line.
                try p.blocks.append(p.arena, .{ .code = .{ .lang = lang, .text = std.mem.trimEnd(u8, body.items, "\n ") } });
                continue;
            }
            // Display math (`$$ ... $$` or `\[ ... \]`), once its closing delimiter has arrived.
            if ((std.mem.startsWith(u8, t, "$$") and (t.len == 2 or t[2] != '$')) or std.mem.startsWith(u8, t, "\\[")) {
                const close_delim = if (t[0] == '$') "$$" else "\\]";
                if (t.len >= 4 and std.mem.endsWith(u8, t, close_delim)) {
                    const inner = std.mem.trim(u8, t[2 .. t.len - 2], " \t");
                    if (inner.len > 0) {
                        try p.flush();
                        try p.blocks.append(p.arena, .{ .math = try p.mathInline(inner, t) });
                        continue;
                    }
                } else {
                    var close_line: ?usize = null;
                    var j = i + 1;
                    while (j < lines.items.len) : (j += 1) {
                        const lt = std.mem.trim(u8, lines.items[j], " \t");
                        // Display delimiters cannot swallow another paragraph
                        // or a fenced literal region while streaming.
                        if (lt.len == 0 or std.mem.startsWith(u8, lt, "```") or std.mem.startsWith(u8, lt, "~~~")) break;
                        if (std.mem.endsWith(u8, lt, close_delim)) {
                            close_line = j;
                            break;
                        }
                    }
                    if (close_line) |end_ix| {
                        try p.flush();
                        var body: std.ArrayList(u8) = .empty;
                        const first_rest = std.mem.trim(u8, t[2..], " \t");
                        if (first_rest.len > 0) try body.appendSlice(p.arena, first_rest);
                        var k = i + 1;
                        while (k <= end_ix) : (k += 1) {
                            const lt = std.mem.trim(u8, lines.items[k], " \t");
                            const slice = if (k == end_ix) std.mem.trim(u8, lt[0 .. lt.len - 2], " \t") else lt;
                            if (slice.len > 0) {
                                if (body.items.len > 0) try body.append(p.arena, '\n');
                                try body.appendSlice(p.arena, slice);
                            }
                        }
                        try p.blocks.append(p.arena, .{ .math = try p.mathInline(body.items, try std.mem.join(p.arena, "\n", lines.items[i .. end_ix + 1])) });
                        i = end_ix;
                        continue;
                    }
                }
            }
            // HTML, to the blank line that ends it (a comment to its end).
            if (html.starts(t)) {
                try p.flush();
                const comment = std.mem.startsWith(u8, t, "<!--");
                var body: std.ArrayList(u8) = .empty;
                while (i < lines.items.len) : (i += 1) {
                    const l = lines.items[i];
                    if (!comment and std.mem.trim(u8, l, " \t").len == 0) break;
                    try body.appendSlice(p.arena, l);
                    try body.append(p.arena, '\n');
                    if (comment and std.mem.indexOf(u8, l, "-->") != null) break;
                }
                try html.convert(p.arena, p.pal, body.items, &p.blocks);
                continue;
            }
            if (heading(t)) |level| {
                try p.flush();
                try p.blocks.append(p.arena, .{ .heading = .{ .level = level, .text = try p.inlines(std.mem.trim(u8, t[level..], " #")) } });
                continue;
            }
            if (isRule(t)) {
                try p.flush();
                try p.blocks.append(p.arena, .rule);
                continue;
            }
            if (t[0] == '|' and i + 1 < lines.items.len and isTableRule(lines.items[i + 1])) {
                try p.flush();
                const header = try p.cells(t);
                var rows: std.ArrayList([]const Inline) = .empty;
                i += 2;
                while (i < lines.items.len) : (i += 1) {
                    const r = std.mem.trim(u8, lines.items[i], " \t");
                    if (r.len == 0 or r[0] != '|') break;
                    try rows.append(p.arena, try p.cells(r));
                }
                if (i < lines.items.len) i -= 1;
                try p.blocks.append(p.arena, .{ .table = .{ .header = header, .rows = rows.items } });
                continue;
            }
            if (t[0] == '>') {
                if (p.para_kind != .quote) try p.flush();
                p.para_kind = .quote;
                try p.gather(std.mem.trimStart(u8, t[1..], " "));
                continue;
            }
            if (listItem(t)) |li| {
                try p.flush();
                p.para_kind = .item;
                p.item_depth = @intCast(@min(indent / 2, 6));
                p.item_marker = li.marker;
                p.item_task = li.task;
                try p.gather(li.rest);
                continue;
            }
            // A continuation of the open item or quote, or a paragraph's line.
            if (p.para_kind == .none) p.para_kind = .paragraph;
            try p.gather(t);
        }
        try p.flush();
    }

    fn cells(p: *Parser, row: []const u8) ![]const Inline {
        var out: std.ArrayList(Inline) = .empty;
        const inner = std.mem.trim(u8, row, " \t|");
        var it = std.mem.splitScalar(u8, inner, '|');
        while (it.next()) |cell| try out.append(p.arena, try p.inlines(std.mem.trim(u8, cell, " ")));
        return out.items;
    }

    // Inline marks.

    pub const Flags = struct { bold: bool = false, italic: bool = false, code: bool = false, strike: bool = false, link: bool = false, muted: bool = false };

    fn inlines(p: *Parser, src: []const u8) !Inline {
        var b: Builder = .{ .arena = p.arena, .pal = p.pal };
        try b.parse(src, .{});
        return .{ .text = b.text.items, .spans = b.spans.items, .images = b.images.items, .links = b.links.items, .maths = b.maths.items };
    }

    fn mathInline(p: *Parser, src: []const u8, original: []const u8) !Inline {
        var b: Builder = .{ .arena = p.arena, .pal = p.pal };
        try b.emitMath(src, original, true, .{});
        return .{ .text = b.text.items, .spans = b.spans.items, .maths = b.maths.items, .center = true };
    }

    pub const Builder = struct {
        arena: std.mem.Allocator,
        pal: Palette,
        text: std.ArrayList(u8) = .empty,
        spans: std.ArrayList(Span) = .empty,
        images: std.ArrayList(Image) = .empty,
        links: std.ArrayList(Link) = .empty,
        maths: std.ArrayList(Math) = .empty,

        pub fn emit(b: *Builder, s: []const u8, f: Flags) !void {
            if (s.len == 0) return;
            const start: u32 = @intCast(b.text.items.len);
            try b.text.appendSlice(b.arena, s);
            const end: u32 = @intCast(b.text.items.len);
            if (!f.bold and !f.italic and !f.code and !f.strike and !f.link and !f.muted) return;
            const span: Span = .{
                .start = start,
                .end = end,
                .weight = if (f.bold) .semibold else null,
                .italic = f.italic,
                .mono = f.code,
                .color = if (f.code) b.pal.code else if (f.link) b.pal.link else if (f.muted) b.pal.muted else null,
                .background = if (f.code) b.pal.code_bg else null,
                .underline = f.link,
                .strike = f.strike,
            };
            if (b.spans.items.len > 0) {
                const last = &b.spans.items[b.spans.items.len - 1];
                var same = last.*;
                same.start = span.start;
                same.end = span.end;
                if (last.end == start and std.meta.eql(same, span)) {
                    last.end = end;
                    return;
                }
            }
            try b.spans.append(b.arena, span);
        }

        pub fn emitMath(b: *Builder, raw: []const u8, original: []const u8, display: bool, base: Flags) !void {
            const start: u32 = @intCast(b.text.items.len);
            try b.emit(original, base);
            // Large equations remain literal without invoking native parsing.
            if (raw.len <= 4096) try b.maths.append(b.arena, .{ .source = raw, .start = start, .end = @intCast(b.text.items.len), .display = display });
        }

        fn parse(b: *Builder, src: []const u8, f: Flags) anyerror!void {
            var i: usize = 0;
            var plain: usize = 0;
            while (i < src.len) {
                const ch = src[i];
                const rest = src[i..];
                if (!f.link and !f.code and ch == '\\' and i + 1 < src.len and (src[i + 1] == '(' or src[i + 1] == '[')) {
                    const close_delim = if (src[i + 1] == '(') "\\)" else "\\]";
                    if (mathClose(src, i + 2, close_delim)) |close| {
                        if (close > i + 2) {
                            try b.emit(src[plain..i], f);
                            try b.emitMath(src[i + 2 .. close], src[i .. close + 2], src[i + 1] == '[', f);
                            i = close + 2;
                            plain = i;
                            continue;
                        }
                    } else {
                        // A streaming/incomplete explicit delimiter is literal,
                        // including its backslash and any script markers.
                        try b.emit(src[plain..], f);
                        return;
                    }
                }
                if (ch == '\\' and i + 1 < src.len and std.mem.indexOfScalar(u8, "\\`$*_{}[]()#+-.!~|<>", src[i + 1]) != null) {
                    try b.emit(src[plain..i], f);
                    plain = i + 1;
                    i += 2;
                    continue;
                }
                if (ch == '`') {
                    var n: usize = 0;
                    while (i + n < src.len and src[i + n] == '`') n += 1;
                    if (std.mem.indexOf(u8, src[i + n ..], src[i .. i + n])) |close| {
                        try b.emit(src[plain..i], f);
                        const code_text = std.mem.trim(u8, src[i + n .. i + n + close], " ");
                        var cf = f;
                        cf.code = true;
                        const is_code_url = !f.link and @import("browser_url.zig").allowedNavigation(code_text);
                        if (is_code_url) cf.link = true;
                        const at: u32 = @intCast(b.text.items.len);
                        try b.emit(code_text, cf);
                        if (is_code_url) {
                            try b.links.append(b.arena, .{ .url = code_text, .start = at, .end = @intCast(b.text.items.len) });
                        }
                        i += n + close + n;
                        plain = i;
                        continue;
                    }
                }
                if (ch == '$' and !f.code and !f.link) {
                    if (rest.len >= 3 and rest[1] == '$' and rest[2] == '$') {
                        while (i < src.len and src[i] == '$') i += 1;
                        continue;
                    }
                    if (rest.len >= 4 and rest[1] == '$') {
                        if (mathClose(src, i + 2, "$$")) |close| {
                            const inner = std.mem.trim(u8, src[i + 2 .. close], " \t");
                            if (inner.len > 0) {
                                try b.emit(src[plain..i], f);
                                try b.emitMath(inner, src[i .. close + 2], true, f);
                                i = close + 2;
                                plain = i;
                                continue;
                            }
                        } else {
                            try b.emit(src[plain..], f);
                            return;
                        }
                    } else if (inlineMathEnd(src, i)) |close| {
                        try b.emit(src[plain..i], f);
                        try b.emitMath(src[i + 1 .. close], src[i .. close + 1], false, f);
                        i = close + 1;
                        plain = i;
                        continue;
                    } else if (rest.len > 1 and !std.ascii.isWhitespace(rest[1]) and std.mem.indexOfAny(u8, rest, "\\_^") != null and std.mem.indexOfScalar(u8, rest[1..], '$') == null) {
                        // An unfinished equation is not Markdown emphasis.
                        // Preserve script/group markers while it streams.
                        try b.emit(src[plain..], f);
                        return;
                    }
                }
                if (ch == '*' or ch == '_' or ch == '~') {
                    const double = rest.len > 1 and rest[1] == ch;
                    const mark = if (double) rest[0..2] else rest[0..1];
                    // `_` inside a word (snake_case) is not a mark; `~` needs two.
                    const in_word = ch == '_' and i > 0 and std.ascii.isAlphanumeric(src[i - 1]);
                    const opens = rest.len > mark.len and rest[mark.len] != ' ';
                    if (!in_word and opens and (ch != '~' or double)) {
                        if (closing(src, i + mark.len, mark)) |close| {
                            try b.emit(src[plain..i], f);
                            var nf = f;
                            if (ch == '~') nf.strike = true else if (double) nf.bold = true else nf.italic = true;
                            try b.parse(src[i + mark.len .. close], nf);
                            i = close + mark.len;
                            plain = i;
                            continue;
                        }
                    }
                }
                if (ch == '[' or (ch == '!' and rest.len > 1 and rest[1] == '[')) {
                    const open = if (ch == '!') i + 1 else i;
                    if (std.mem.indexOfScalarPos(u8, src, open, ']')) |close| {
                        if (close + 1 < src.len and src[close + 1] == '(') {
                            if (std.mem.indexOfScalarPos(u8, src, close + 2, ')')) |end| {
                                try b.emit(src[plain..i], f);
                                var lf = f;
                                lf.link = true;
                                const at: u32 = @intCast(b.text.items.len);
                                try b.parse(src[open + 1 .. close], lf);
                                const destination = std.mem.trim(u8, src[close + 2 .. end], " <>");
                                if (ch == '!') try b.images.append(b.arena, .{ .src = destination, .start = at, .end = @intCast(b.text.items.len) }) else try b.links.append(b.arena, .{ .url = destination, .start = at, .end = @intCast(b.text.items.len) });
                                i = end + 1;
                                plain = i;
                                continue;
                            }
                        }
                    }
                }
                // An inline HTML tag: a line break, or a mark left out.
                if (ch == '<') if (html.inlineTag(rest)) |tag| {
                    try b.emit(src[plain..i], f);
                    if (tag.br) try b.emit("\n", f);
                    i += tag.len;
                    plain = i;
                    continue;
                };
                if (!f.link and (i == 0 or !std.ascii.isAlphanumeric(src[i - 1])) and (ch == 'h' or ch == 'H')) {
                    const url_len = @import("browser_url.zig").bareUrlLen(rest);
                    if (url_len > 0) {
                        const end = i + url_len;
                        try b.emit(src[plain..i], f);
                        var lf = f;
                        lf.link = true;
                        const at: u32 = @intCast(b.text.items.len);
                        try b.emit(src[i..end], lf);
                        try b.links.append(b.arena, .{ .url = src[i..end], .start = at, .end = @intCast(b.text.items.len) });
                        i = end;
                        plain = i;
                        continue;
                    }
                }
                i += 1;
            }
            try b.emit(src[plain..], f);
        }
    };
};

/// Currency-safe closing `$` index for an inline `$ ... $` span starting at `open`.
/// Returns `null` for `$5 and $10`, `$ 5`, unclosed streaming `$`, or `$` followed by digits.
pub fn inlineMathEnd(src: []const u8, open: usize) ?usize {
    if (open + 2 > src.len or src[open] != '$' or escapedMath(src, open)) return null;
    if (src[open + 1] == '$' or std.ascii.isWhitespace(src[open + 1])) return null;
    if (open > 0 and src[open - 1] == '$') return null;
    var j = open + 1;
    while (j < src.len and j - open <= 4097) : (j += 1) {
        const ch = src[j];
        if (ch == '`' or ch == '\n' or ch == '\r') return null;
        if (ch != '$' or escapedMath(src, j)) continue;
        if (j == open + 1 or std.ascii.isWhitespace(src[j - 1])) return null;
        if (j + 1 < src.len and (src[j + 1] == '$' or std.ascii.isDigit(src[j + 1]))) return null;
        if (j + 2 < src.len and src[j + 1] == '.' and std.ascii.isDigit(src[j + 2])) return null;
        // In `pay $5 ($x^2$)`, the price must not steal the opening
        // delimiter of the following equation. Bare `$5$` remains math.
        const body = src[open + 1 .. j];
        if (std.ascii.isDigit(body[0]) or (body[0] == '.' and body.len > 1 and std.ascii.isDigit(body[1]))) {
            var n: usize = 0;
            while (n < body.len and (std.ascii.isDigit(body[n]) or body[n] == '.' or body[n] == ',')) n += 1;
            if (n < body.len) {
                var price = true;
                for (body[n..]) |b| if (!std.ascii.isWhitespace(b) and b != '(' and b != '[' and b != '{') {
                    price = false;
                    break;
                };
                if (price) return null;
            }
        }
        return j;
    }
    return null;
}

fn escapedMath(src: []const u8, at: usize) bool {
    var n: usize = 0;
    var i = at;
    while (i > 0 and src[i - 1] == '\\') : (i -= 1) n += 1;
    return n % 2 != 0;
}

fn mathClose(src: []const u8, from: usize, close: []const u8) ?usize {
    var at = from;
    while (at + close.len <= src.len and at - from <= 4096) : (at += 1) {
        if (src[at] == '`' or (src[at] == '\n' and at + 1 < src.len and src[at + 1] == '\n')) return null;
        if (std.mem.startsWith(u8, src[at..], close) and !escapedMath(src, at)) return at;
    }
    return null;
}

/// Lossy plain-text compatibility utility, not equation rendering. Native
/// Markdown uses retained source plus native_math's AST/box layout instead.
pub fn formatLatexMath(arena: std.mem.Allocator, raw_in: []const u8) ![]const u8 {
    const raw = std.mem.trim(u8, raw_in, " \t\n\r");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            if (i + 1 < raw.len and (raw[i + 1] == '{' or raw[i + 1] == '}' or raw[i + 1] == '$' or raw[i + 1] == '%' or raw[i + 1] == '_' or raw[i + 1] == '&' or raw[i + 1] == '#')) {
                try out.append(arena, raw[i + 1]);
                i += 2;
                continue;
            }
            if (i + 1 < raw.len and (raw[i + 1] == ',' or raw[i + 1] == ';' or raw[i + 1] == ':' or raw[i + 1] == ' ')) {
                try out.append(arena, ' ');
                i += 2;
                continue;
            }
            if (i + 1 < raw.len and raw[i + 1] == '!') {
                i += 2;
                continue;
            }
            var end = i + 1;
            while (end < raw.len and std.ascii.isAlphabetic(raw[end])) : (end += 1) {}
            const cmd = raw[i + 1 .. end];
            if (std.mem.eql(u8, cmd, "frac")) {
                var pos = skipMathSpaces(raw, end);
                if (takeBraceGroup(raw, pos)) |num| {
                    pos = skipMathSpaces(raw, num.next);
                    if (takeBraceGroup(raw, pos)) |den| {
                        const n_fmt = try formatLatexMath(arena, num.inner);
                        const d_fmt = try formatLatexMath(arena, den.inner);
                        const wrap_n = needsParenInFraction(n_fmt);
                        const wrap_d = needsParenInFraction(d_fmt);
                        if (wrap_n) try out.append(arena, '(');
                        try out.appendSlice(arena, n_fmt);
                        if (wrap_n) try out.append(arena, ')');
                        try out.append(arena, '/');
                        if (wrap_d) try out.append(arena, '(');
                        try out.appendSlice(arena, d_fmt);
                        if (wrap_d) try out.append(arena, ')');
                        i = den.next;
                        continue;
                    }
                }
            } else if (std.mem.eql(u8, cmd, "sqrt")) {
                const pos = skipMathSpaces(raw, end);
                if (takeBraceGroup(raw, pos)) |arg| {
                    const inner = try formatLatexMath(arena, arg.inner);
                    const multi_cp = (std.unicode.utf8CountCodepoints(inner) catch inner.len) > 1;
                    try out.appendSlice(arena, "√");
                    if (multi_cp) try out.append(arena, '(');
                    try out.appendSlice(arena, inner);
                    if (multi_cp) try out.append(arena, ')');
                    i = arg.next;
                    continue;
                }
            } else if (std.mem.eql(u8, cmd, "text") or std.mem.eql(u8, cmd, "mathrm") or std.mem.eql(u8, cmd, "mathbf") or std.mem.eql(u8, cmd, "mathcal") or std.mem.eql(u8, cmd, "operatorname")) {
                const pos = skipMathSpaces(raw, end);
                if (takeBraceGroup(raw, pos)) |arg| {
                    try out.appendSlice(arena, arg.inner);
                    i = arg.next;
                    continue;
                }
            } else if (std.mem.eql(u8, cmd, "left") or std.mem.eql(u8, cmd, "right")) {
                i = skipMathSpaces(raw, end);
                if (i < raw.len and raw[i] == '.') i += 1;
                continue;
            } else if (latexSymbol(cmd)) |sym| {
                try out.appendSlice(arena, sym);
                i = end;
                continue;
            } else if (cmd.len > 0) {
                try out.appendSlice(arena, cmd);
                i = end;
                continue;
            }
        }
        if ((raw[i] == '^' or raw[i] == '_') and i + 1 < raw.len) {
            const is_sup = raw[i] == '^';
            if (takeBraceGroup(raw, i + 1)) |grp| {
                const inner = try formatLatexMath(arena, grp.inner);
                if (!try appendScript(arena, &out, inner, is_sup)) {
                    const multi_cp = (std.unicode.utf8CountCodepoints(inner) catch inner.len) > 1;
                    try out.append(arena, raw[i]);
                    if (multi_cp) try out.append(arena, '(');
                    try out.appendSlice(arena, inner);
                    if (multi_cp) try out.append(arena, ')');
                }
                i = grp.next;
                continue;
            } else if (raw[i + 1] != '\\') {
                const tok = raw[i + 1 .. i + 2];
                if (!try appendScript(arena, &out, tok, is_sup)) {
                    try out.append(arena, raw[i]);
                    try out.appendSlice(arena, tok);
                }
                i += 2;
                continue;
            }
        }
        if (raw[i] == '{' or raw[i] == '}') {
            i += 1;
            continue;
        }
        if (raw[i] == '\n' or raw[i] == '\r' or raw[i] == '\t') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(arena, ' ');
            i += 1;
            continue;
        }
        try out.append(arena, raw[i]);
        i += 1;
    }
    return out.items;
}

fn skipMathSpaces(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return i;
}

fn takeBraceGroup(s: []const u8, from: usize) ?struct { inner: []const u8, next: usize } {
    if (from >= s.len or s[from] != '{') return null;
    var depth: usize = 1;
    var i = from + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == '{') depth += 1 else if (s[i] == '}') {
            depth -= 1;
            if (depth == 0) return .{ .inner = s[from + 1 .. i], .next = i + 1 };
        }
    }
    return null;
}

fn needsParenInFraction(s: []const u8) bool {
    for (s) |ch| {
        if (ch == ' ' or ch == '+' or ch == '-' or ch == '=') return true;
    }
    return false;
}

fn appendScript(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, is_sup: bool) !bool {
    if (s.len == 0) return true;
    for (s) |ch| {
        if ((is_sup and supChar(ch) == null) or (!is_sup and subChar(ch) == null)) return false;
    }
    for (s) |ch| {
        try out.appendSlice(arena, if (is_sup) supChar(ch).? else subChar(ch).?);
    }
    return true;
}

fn supChar(ch: u8) ?[]const u8 {
    return switch (ch) {
        '0' => "⁰",
        '1' => "¹",
        '2' => "²",
        '3' => "³",
        '4' => "⁴",
        '5' => "⁵",
        '6' => "⁶",
        '7' => "⁷",
        '8' => "⁸",
        '9' => "⁹",
        '+' => "⁺",
        '-' => "⁻",
        '=' => "⁼",
        '(' => "⁽",
        ')' => "⁾",
        'n' => "ⁿ",
        'i' => "ⁱ",
        else => null,
    };
}

fn subChar(ch: u8) ?[]const u8 {
    return switch (ch) {
        '0' => "₀",
        '1' => "₁",
        '2' => "₂",
        '3' => "₃",
        '4' => "₄",
        '5' => "₅",
        '6' => "₆",
        '7' => "₇",
        '8' => "₈",
        '9' => "₉",
        '+' => "₊",
        '-' => "₋",
        '=' => "₌",
        '(' => "₍",
        ')' => "₎",
        'a' => "ₐ",
        'e' => "ₑ",
        'i' => "ᵢ",
        'j' => "ⱼ",
        'k' => "ₖ",
        'm' => "ₘ",
        'n' => "ₙ",
        'o' => "ₒ",
        'p' => "ₚ",
        'r' => "ᵣ",
        's' => "ₛ",
        't' => "ₜ",
        'u' => "ᵤ",
        'v' => "ᵥ",
        'x' => "ₓ",
        else => null,
    };
}

fn latexSymbol(cmd: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "alpha", "α" },
        .{ "beta", "β" },
        .{ "gamma", "γ" },
        .{ "delta", "δ" },
        .{ "epsilon", "ε" },
        .{ "varepsilon", "ε" },
        .{ "zeta", "ζ" },
        .{ "eta", "η" },
        .{ "theta", "θ" },
        .{ "vartheta", "θ" },
        .{ "iota", "ι" },
        .{ "kappa", "κ" },
        .{ "lambda", "λ" },
        .{ "mu", "μ" },
        .{ "nu", "ν" },
        .{ "xi", "ξ" },
        .{ "pi", "π" },
        .{ "rho", "ρ" },
        .{ "sigma", "σ" },
        .{ "tau", "τ" },
        .{ "upsilon", "υ" },
        .{ "phi", "φ" },
        .{ "varphi", "φ" },
        .{ "chi", "χ" },
        .{ "psi", "ψ" },
        .{ "omega", "ω" },
        .{ "Gamma", "Γ" },
        .{ "Delta", "Δ" },
        .{ "Theta", "Θ" },
        .{ "Lambda", "Λ" },
        .{ "Xi", "Ξ" },
        .{ "Pi", "Π" },
        .{ "Sigma", "Σ" },
        .{ "Phi", "Φ" },
        .{ "Psi", "Ψ" },
        .{ "Omega", "Ω" },
        .{ "int", "∫" },
        .{ "sum", "∑" },
        .{ "prod", "∏" },
        .{ "infty", "∞" },
        .{ "partial", "∂" },
        .{ "nabla", "∇" },
        .{ "pm", "±" },
        .{ "mp", "∓" },
        .{ "times", "×" },
        .{ "div", "÷" },
        .{ "cdot", "·" },
        .{ "dots", "…" },
        .{ "ldots", "…" },
        .{ "cdots", "⋯" },
        .{ "leq", "≤" },
        .{ "le", "≤" },
        .{ "geq", "≥" },
        .{ "ge", "≥" },
        .{ "neq", "≠" },
        .{ "ne", "≠" },
        .{ "approx", "≈" },
        .{ "equiv", "≡" },
        .{ "sim", "∼" },
        .{ "to", "→" },
        .{ "rightarrow", "→" },
        .{ "leftarrow", "←" },
        .{ "leftrightarrow", "↔" },
        .{ "Rightarrow", "⇒" },
        .{ "Leftarrow", "⇐" },
        .{ "Leftrightarrow", "⇔" },
        .{ "iff", "⇔" },
        .{ "mapsto", "↦" },
        .{ "in", "∈" },
        .{ "notin", "∉" },
        .{ "subset", "⊂" },
        .{ "subseteq", "⊆" },
        .{ "cup", "∪" },
        .{ "cap", "∩" },
        .{ "emptyset", "∅" },
        .{ "forall", "∀" },
        .{ "exists", "∃" },
        .{ "neg", "¬" },
        .{ "land", "∧" },
        .{ "lor", "∨" },
    });
    return map.get(cmd);
}

/// Where `mark` closes, after `from`: not after a space, not escaped.
fn closing(src: []const u8, from: usize, mark: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, src, i, mark)) |at| {
        const before_ok = at > from and src[at - 1] != ' ' and src[at - 1] != '\\';
        // `**a**b`: a single mark must not be half of a double one.
        const doubled = mark.len == 1 and at + 1 < src.len and src[at + 1] == mark[0];
        if (before_ok and !doubled) return at;
        i = at + if (doubled) @as(usize, 2) else 1;
    }
    return null;
}

fn heading(t: []const u8) ?u8 {
    var n: u8 = 0;
    while (n < t.len and n < 6 and t[n] == '#') n += 1;
    if (n == 0 or n >= t.len or t[n] != ' ') return null;
    return n;
}

fn isRule(t: []const u8) bool {
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (t) |x| if (x != ch and x != ' ') return false;
    return true;
}

fn isTableRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3 or std.mem.indexOfScalar(u8, t, '-') == null) return false;
    for (t) |x| if (std.mem.indexOfScalar(u8, "|-: ", x) == null) return false;
    return true;
}

const ListItem = struct { marker: []const u8, rest: []const u8, task: ?bool };

fn listItem(t: []const u8) ?ListItem {
    var marker: []const u8 = "";
    var rest: []const u8 = "";
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') {
        marker = "•";
        rest = t[2..];
    } else {
        var n: usize = 0;
        while (n < t.len and n < 4 and std.ascii.isDigit(t[n])) n += 1;
        if (n == 0 or n + 1 >= t.len or (t[n] != '.' and t[n] != ')') or t[n + 1] != ' ') return null;
        marker = t[0 .. n + 1];
        rest = t[n + 2 ..];
    }
    rest = std.mem.trimStart(u8, rest, " ");
    if (std.mem.startsWith(u8, rest, "[ ] ")) return .{ .marker = marker, .rest = rest[4..], .task = false };
    if (std.mem.startsWith(u8, rest, "[x] ") or std.mem.startsWith(u8, rest, "[X] ")) return .{ .marker = marker, .rest = rest[4..], .task = true };
    return .{ .marker = marker, .rest = rest, .task = null };
}

const test_pal: Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };

test "blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# Title
        \\
        \\A paragraph
        \\on two lines.
        \\
        \\- one
        \\  more of one
        \\- [x] done
        \\  1. nested
        \\
        \\> quoted
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\| a | b |
        \\|---|:-:|
        \\| 1 | 2 |
        \\
        \\---
    ;
    const blocks = parse(arena.allocator(), src, test_pal);
    try std.testing.expectEqual(@as(usize, 9), blocks.len);
    try std.testing.expectEqual(@as(u8, 1), blocks[0].heading.level);
    try std.testing.expectEqualStrings("A paragraph on two lines.", blocks[1].paragraph.text);
    try std.testing.expectEqualStrings("one more of one", blocks[2].item.text.text);
    try std.testing.expectEqual(@as(?bool, true), blocks[3].item.task);
    try std.testing.expectEqualStrings("1.", blocks[4].item.marker);
    try std.testing.expectEqual(@as(u8, 1), blocks[4].item.depth);
    try std.testing.expectEqualStrings("quoted", blocks[5].quote.text);
    try std.testing.expectEqualStrings("zig", blocks[6].code.lang);
    try std.testing.expectEqualStrings("const x = 1;", blocks[6].code.text);
    try std.testing.expectEqual(@as(usize, 2), blocks[7].table.header.len);
    try std.testing.expectEqualStrings("2", blocks[7].table.rows[0][1].text);
    try std.testing.expect(blocks[8] == .rule);
}

test "inline marks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "Run **`zig build` now**, *see* [the docs](https://x.io) or ~~not~~ snake_case_name and a*b.", test_pal);
    const in = blocks[0].paragraph;
    try std.testing.expectEqualStrings("Run zig build now, see the docs or not snake_case_name and a*b.", in.text);
    // "zig build" is bold code; " now" bold; "see" italic; link; struck.
    try std.testing.expectEqual(@as(usize, 5), in.spans.len);
    try std.testing.expect(in.spans[0].mono and in.spans[0].weight == .semibold);
    try std.testing.expectEqualStrings("zig build", in.text[in.spans[0].start..in.spans[0].end]);
    try std.testing.expectEqualStrings(" now", in.text[in.spans[1].start..in.spans[1].end]);
    try std.testing.expect(in.spans[2].italic);
    try std.testing.expect(in.spans[3].underline);
    try std.testing.expectEqualStrings("the docs", in.text[in.spans[3].start..in.spans[3].end]);
    try std.testing.expect(in.spans[4].strike);
}
