//! Syntax colors for code, as the GPUI app's (crates/syntax: tree-sitter's
//! highlight queries, `HighlightKind` by `precedence`; crates/theme's
//! `syntax` roles): each language's captures read off its query, a line at
//! a time. Markdown is highlight_md.zig; JSON, YAML, TOML, shell, HTML and
//! CSS highlight_data.zig. A fence or file whose language GPUI doesn't
//! bundle (`language_for_alias`) stays plain.
const std = @import("std");
const nanoui = @import("nanoui");
const Span = nanoui.ui.Span;
const Color = nanoui.ui.Color;
const md = @import("highlight_md.zig");
const data = @import("highlight_data.zig");

/// A theme's syntax colors: its twelve (crates/theme/src/builtins.rs
/// `syntax`, in that order), then Markdown's six, which no built-in theme
/// sets (`SyntaxPalette::dark`/`light`'s).
pub const Palette = struct {
    comment: Color,
    keyword: Color,
    string: Color,
    number: Color,
    type: Color,
    function: Color,
    property: Color,
    variable: Color,
    punctuation: Color,
    tag: Color,
    attribute: Color,
    invalid: Color,
    markup_heading: Color,
    markup_raw: Color,
    markup_link: Color,
    markup_reference: Color,
    markup_emphasis: Color,
    markup_strong: Color,

    /// `SyntaxPalette::color` over builtins.rs's role map.
    pub fn color(p: Palette, kind: Kind) Color {
        return switch (kind) {
            .comment => p.comment,
            .keyword, .macro, .variable_special, .operator => p.keyword,
            .string => p.string,
            .string_special, .escape, .attribute => p.attribute,
            .number, .boolean, .constant => p.number,
            .type, .type_builtin, .constructor => p.type,
            .function, .function_builtin, .label => p.function,
            .property => p.property,
            .variable, .parameter => p.variable,
            .punctuation, .embedded => p.punctuation,
            .tag => p.tag,
            .markup_heading => p.markup_heading,
            .markup_raw => p.markup_raw,
            .markup_link => p.markup_link,
            .markup_reference => p.markup_reference,
            .markup_emphasis => p.markup_emphasis,
            .markup_strong => p.markup_strong,
            .invalid => p.invalid,
        };
    }
};

/// `HighlightKind`.
pub const Kind = enum {
    comment,
    keyword,
    string,
    string_special,
    escape,
    number,
    boolean,
    type,
    type_builtin,
    constructor,
    function,
    function_builtin,
    macro,
    property,
    constant,
    variable,
    variable_special,
    parameter,
    operator,
    punctuation,
    tag,
    attribute,
    label,
    markup_heading,
    markup_raw,
    markup_link,
    markup_reference,
    markup_emphasis,
    markup_strong,
    embedded,
    invalid,

    /// `HighlightKind::precedence`: which of overlapping captures shows.
    pub fn precedence(k: Kind) u8 {
        return switch (k) {
            .invalid => 100,
            .escape => 95,
            .macro => 90,
            .property, .attribute => 85,
            .function_builtin, .type_builtin, .variable_special => 80,
            .string_special, .constructor, .parameter => 75,
            .function, .type, .constant, .tag, .label => 70,
            .comment, .keyword, .string, .number, .boolean => 60,
            .variable, .operator => 50,
            .punctuation, .embedded => 40,
            .markup_heading => 30,
            .markup_emphasis => 31,
            .markup_strong => 32,
            .markup_link, .markup_reference => 33,
            .markup_raw => 34,
        };
    }
};

/// A line's kinds, a byte at a time: a capture paints over what ranks no
/// higher, so the innermost of equals shows (`normalize_line`).
pub const Paint = struct {
    kinds: []?Kind,

    pub fn init(arena: std.mem.Allocator, len: usize) Paint {
        const k = arena.alloc(?Kind, len) catch return .{ .kinds = &.{} };
        @memset(k, null);
        return .{ .kinds = k };
    }

    pub fn put(p: Paint, start: usize, end: usize, kind: Kind) void {
        const e = @min(end, p.kinds.len);
        if (start >= e) return;
        for (p.kinds[start..e]) |*x| {
            if (x.*) |old| if (old.precedence() > kind.precedence()) continue;
            x.* = kind;
        }
    }

    /// The painted runs as spans in `pal`'s colors; what no capture
    /// covers keeps the text's color.
    pub fn spans(p: Paint, arena: std.mem.Allocator, pal: Palette) []const Span {
        var out: std.ArrayList(Span) = .empty;
        var i: usize = 0;
        while (i < p.kinds.len) {
            const kind = p.kinds[i] orelse {
                i += 1;
                continue;
            };
            var j = i + 1;
            while (j < p.kinds.len and p.kinds[j] == kind) j += 1;
            out.append(arena, .{ .start = @intCast(i), .end = @intCast(j), .color = pal.color(kind) }) catch {};
            i = j;
        }
        return out.items;
    }
};

/// `LanguageId`.
pub const Language = enum { rust, javascript, jsx, typescript, tsx, python, go, json, jsonc, bash, toml, markdown, html, css, yaml, c, cpp, csharp, java, kotlin, swift, ruby, php, sql, lua, dockerfile, nix, make };

/// `language_for_alias`: a fence's tag (its first word) or a file's
/// extension, any case.
pub fn language(alias: []const u8) ?Language {
    var it = std.mem.tokenizeAny(u8, alias, " \t");
    const word = it.next() orelse return null;
    var buf: [16]u8 = undefined;
    if (word.len > buf.len) return null;
    const w = std.ascii.lowerString(&buf, word);
    const table = .{
        .{ Language.rust, .{ "rust", "rs" } },
        .{ Language.javascript, .{ "javascript", "js", "mjs", "cjs" } },
        .{ Language.jsx, .{"jsx"} },
        .{ Language.typescript, .{ "typescript", "ts", "mts", "cts" } },
        .{ Language.tsx, .{"tsx"} },
        .{ Language.python, .{ "python", "py", "python3" } },
        .{ Language.go, .{ "go", "golang" } },
        .{ Language.json, .{"json"} },
        .{ Language.jsonc, .{"jsonc"} },
        .{ Language.bash, .{ "bash", "sh", "shell", "zsh", "console" } },
        .{ Language.toml, .{"toml"} },
        .{ Language.markdown, .{ "markdown", "md" } },
        .{ Language.html, .{ "html", "htm" } },
        .{ Language.css, .{"css"} },
        .{ Language.yaml, .{ "yaml", "yml" } },
        .{ Language.c, .{"c"} },
        .{ Language.cpp, .{ "cpp", "c++", "cc", "cxx", "hpp" } },
        .{ Language.csharp, .{ "csharp", "c#", "cs" } },
        .{ Language.java, .{"java"} },
        .{ Language.kotlin, .{ "kotlin", "kt", "kts" } },
        .{ Language.swift, .{"swift"} },
        .{ Language.ruby, .{ "ruby", "rb" } },
        .{ Language.php, .{"php"} },
        .{ Language.sql, .{"sql"} },
        .{ Language.lua, .{"lua"} },
        .{ Language.dockerfile, .{ "dockerfile", "docker" } },
        .{ Language.nix, .{"nix"} },
        .{ Language.make, .{ "make", "makefile" } },
    };
    inline for (table) |row| inline for (row[1]) |name| if (std.mem.eql(u8, w, name)) return row[0];
    return null;
}

/// What a line leaves open for the next: a block comment, a string that
/// goes on, a Markdown fence, a CSS rule's braces.
pub const State = struct {
    comment: bool = false,
    /// The quote of a string still open (a Python `"""` is three).
    string: []const u8 = "",
    raw: bool = false,
    fence: ?md.Fence = null,
    depth: u8 = 0,
};

/// Spans coloring one `line` of code in the language `lang` names.
pub fn line(arena: std.mem.Allocator, src: []const u8, lang: []const u8, pal: Palette, st: *State) []const Span {
    const l = language(lang) orelse return &.{};
    const p: Paint = .init(arena, src.len);
    paint(p, src, l, st);
    return p.spans(arena, pal);
}

/// Paints `src`, a line of `l`, into `p` (whose bytes are `src`'s).
pub fn paint(p: Paint, src: []const u8, l: Language, st: *State) void {
    switch (l) {
        .markdown => md.paint(p, src, st),
        .json, .jsonc => data.json(p, src, st),
        .yaml => data.yaml(p, src),
        .toml => data.toml(p, src),
        .bash => data.bash(p, src, st),
        .html => data.html(p, src, st),
        .css => data.css(p, src, st),
        else => code(p, src, profile(l), st),
    }
}

/// A C-family language's captures: what its query names, by token.
pub const Profile = struct {
    line_comment: []const u8 = "//",
    block_comment: bool = true,
    quotes: []const u8 = "\"'",
    /// Quotes whose strings go on past the line's end, and those whose
    /// strings take no escapes (Go's backquote).
    multiline: []const u8 = "",
    raw_quotes: []const u8 = "",
    /// Python's `"""` strings.
    triple: bool = false,
    /// `escape_sequence`s inside strings.
    escapes: bool = false,
    keywords: []const []const u8 = &.{},
    /// `constant.builtin`: true, null, nil.
    constants: []const []const u8 = &.{},
    booleans: []const []const u8 = &.{},
    /// `variable.builtin`: self, this.
    builtins: []const []const u8 = &.{},
    /// Built-in types (`type.builtin`, `primitive_type`).
    types: []const []const u8 = &.{},
    /// Tokens the query names `@operator`, longest first, and tokens it
    /// doesn't that contain them (`&&` where `&` is one).
    operators: []const []const u8 = &.{},
    plain: []const []const u8 = &.{},
    /// `punctuation.bracket` and `punctuation.delimiter`.
    punctuation: []const []const u8 = &.{},
    /// Keywords whose next name a function is (`fn`, `def`).
    defs: []const []const u8 = &.{},
    /// Capitalized names as `constructor`; all-caps ones as `constant`.
    capitals: bool = false,
    all_caps: ?enum { js, python, c } = null,
    /// `name!` as a macro, `#[...]` an attribute, `'a` a lifetime (Rust).
    rust: bool = false,
    /// `@name` as a decorator (Python).
    decorators: bool = false,
    /// Keywords in any case (SQL).
    any_case: bool = false,
    /// A character literal colored as a number (C's query).
    char_number: bool = false,
    /// `#include` and its kind as a keyword.
    preprocessor: bool = false,
};

const brackets = [_][]const u8{ "(", ")", "[", "]", "{", "}" };

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

fn has(list: []const []const u8, word: []const u8, any_case: bool) bool {
    for (list) |k| if (if (any_case) std.ascii.eqlIgnoreCase(k, word) else std.mem.eql(u8, k, word)) return true;
    return false;
}

/// The token of `list` at `rest`'s start, longest first.
fn tokenAt(list: []const []const u8, rest: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (list) |t| if (std.mem.startsWith(u8, rest, t)) {
        if (best == null or t.len > best.?.len) best = t;
    };
    return best;
}

/// Where the string opened by `quote` at `from` ends (past its quote), or
/// null when it goes on; its escapes painted. A raw string has none.
fn stringEnd(p: Paint, src: []const u8, from: usize, quote: []const u8, escapes: bool, raw: bool) ?usize {
    var j = from;
    while (j < src.len) {
        if (src[j] == '\\' and !raw) {
            if (escapes) p.put(j, @min(src.len, j + 2), .escape);
            j += 2;
            continue;
        }
        if (std.mem.startsWith(u8, src[j..], quote)) return j + quote.len;
        j += 1;
    }
    return null;
}

/// A C-family line: comments, strings, numbers, keywords, calls and
/// definitions, operators and punctuation as `pr` names them.
pub fn code(p: Paint, src: []const u8, pr: Profile, st: *State) void {
    var i: usize = 0;
    if (st.comment) {
        const close = std.mem.indexOf(u8, src, "*/");
        const end = if (close) |c| c + 2 else src.len;
        p.put(0, end, .comment);
        if (close == null) return;
        st.comment = false;
        i = end;
    }
    if (st.string.len > 0) {
        const end = stringEnd(p, src, 0, st.string, pr.escapes, st.raw);
        p.put(0, end orelse src.len, .string);
        if (end == null) return;
        i = end.?;
        st.string = "";
        st.raw = false;
    }
    var prev_word: []const u8 = "";
    while (i < src.len) {
        const rest = src[i..];
        const ch = src[i];
        if (pr.line_comment.len > 0 and std.mem.startsWith(u8, rest, pr.line_comment)) {
            p.put(i, src.len, .comment);
            return;
        }
        if (pr.block_comment and std.mem.startsWith(u8, rest, "/*")) {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            const end = if (close) |c| c + 2 else src.len;
            p.put(i, end, .comment);
            if (close == null) st.comment = true;
            i = end;
            continue;
        }
        if (pr.preprocessor and ch == '#' and std.mem.trim(u8, src[0..i], " \t").len == 0) {
            var j = i + 1;
            while (j < src.len and std.ascii.isAlphabetic(src[j])) j += 1;
            p.put(i, j, .keyword);
            i = j;
            continue;
        }
        if (pr.rust and ch == '#' and (std.mem.startsWith(u8, rest, "#[") or std.mem.startsWith(u8, rest, "#!["))) {
            const close = std.mem.lastIndexOfScalar(u8, src, ']') orelse src.len - 1;
            p.put(i, close + 1, .attribute);
            i = close + 1;
            continue;
        }
        if (pr.decorators and ch == '@' and std.mem.trim(u8, src[0..i], " \t").len == 0) {
            var j = i + 1;
            while (j < src.len and (isIdent(src[j]) or src[j] == '.')) j += 1;
            p.put(i, j, .function);
            i = j;
            continue;
        }
        if (pr.rust and ch == '\'') {
            // A character literal ('x', '\n'), else a lifetime: `'` an
            // operator, its name a label.
            const close = std.mem.indexOfScalarPos(u8, src, i + 1, '\'');
            if (close) |c| if (c - i <= 3 or src[i + 1] == '\\' and c - i <= 12) {
                p.put(i, c + 1, .string);
                if (src[i + 1] == '\\') p.put(i + 1, c, .escape);
                i = c + 1;
                continue;
            };
            p.put(i, i + 1, .operator);
            var j = i + 1;
            while (j < src.len and isIdent(src[j])) j += 1;
            p.put(i + 1, j, .label);
            i = j;
            continue;
        }
        if (std.mem.indexOfScalar(u8, pr.quotes, ch) != null or (pr.rust and ch == 'r' and rawStart(rest) != null)) {
            var quote: []const u8 = src[i .. i + 1];
            var body = i + 1;
            const raw = (pr.rust and ch == 'r') or std.mem.indexOfScalar(u8, pr.raw_quotes, ch) != null;
            if (pr.rust and ch == 'r') {
                const n = rawStart(rest).?;
                quote = rawClose(n - 2);
                body = i + n;
            } else if (pr.triple and (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))) {
                quote = src[i .. i + 3];
                body = i + 3;
            }
            const end = stringEnd(p, src, body, quote, pr.escapes, raw);
            p.put(i, end orelse src.len, if (pr.char_number and ch == '\'') .number else .string);
            if (end == null) {
                if (quote.len > 1 or std.mem.indexOfScalar(u8, pr.multiline, ch) != null) {
                    st.string = quote;
                    st.raw = raw;
                }
                return;
            }
            i = end.?;
            continue;
        }
        if (std.ascii.isDigit(ch) and (i == 0 or !isIdent(src[i - 1]))) {
            var j = i;
            while (j < src.len and (isIdent(src[j]) or (src[j] == '.' and j + 1 < src.len and std.ascii.isDigit(src[j + 1])))) j += 1;
            p.put(i, j, .number);
            i = j;
            continue;
        }
        if (isIdent(ch)) {
            var j = i;
            while (j < src.len and isIdent(src[j])) j += 1;
            const word = src[i..j];
            identifier(p, src, i, j, word, prev_word, pr);
            prev_word = word;
            i = j;
            continue;
        }
        if (tokenAt(pr.operators, rest)) |op| {
            if (tokenAt(pr.plain, rest)) |pl| if (pl.len > op.len) {
                i += pl.len;
                continue;
            };
            p.put(i, i + op.len, .operator);
            i += op.len;
            continue;
        }
        if (tokenAt(pr.plain, rest)) |pl| {
            i += pl.len;
            continue;
        }
        if (tokenAt(pr.punctuation, rest)) |t| {
            p.put(i, i + t.len, .punctuation);
            i += t.len;
            continue;
        }
        i += 1;
    }
}

/// A raw string's opening (`r"`, `r#"`): its length.
fn rawStart(rest: []const u8) ?usize {
    var n: usize = 1;
    while (n < rest.len and rest[n] == '#') n += 1;
    return if (n < rest.len and rest[n] == '"') n + 1 else null;
}

/// The close of a raw string opened with `hashes` #s (`r#"` → `"#`).
fn rawClose(hashes: usize) []const u8 {
    return switch (hashes) {
        0 => "\"",
        1 => "\"#",
        2 => "\"##",
        else => "\"###",
    };
}

fn identifier(p: Paint, src: []const u8, i: usize, j: usize, word: []const u8, prev: []const u8, pr: Profile) void {
    if (pr.rust and j < src.len and src[j] == '!' and !(j + 1 < src.len and src[j + 1] == '=')) return p.put(i, j + 1, .macro);
    if (has(pr.keywords, word, pr.any_case)) return p.put(i, j, .keyword);
    if (has(pr.operators, word, false)) return p.put(i, j, .operator);
    if (has(pr.booleans, word, false)) return p.put(i, j, .boolean);
    if (has(pr.constants, word, false)) return p.put(i, j, .constant);
    if (has(pr.builtins, word, false)) return p.put(i, j, .variable_special);
    if (has(pr.types, word, false)) return p.put(i, j, .type_builtin);
    if (j < src.len and src[j] == '(' or has(pr.defs, prev, false)) return p.put(i, j, .function);
    if (pr.capitals and std.ascii.isUpper(word[0])) p.put(i, j, .constructor);
    if (pr.all_caps) |rule| if (allCaps(word, rule)) p.put(i, j, .constant);
}

fn allCaps(word: []const u8, rule: @FieldType(Profile, "all_caps")) bool {
    const first = word[0];
    switch (rule.?) {
        // ^[A-Z_][A-Z\d_]+$
        .js => if (!(std.ascii.isUpper(first) or first == '_') or word.len < 2) return false,
        // ^[A-Z][A-Z_]*$ and ^[A-Z][A-Z\d_]*$
        .python, .c => if (!std.ascii.isUpper(first)) return false,
    }
    for (word[1..]) |ch| {
        const digit_ok = rule.? != .python and std.ascii.isDigit(ch);
        if (!(std.ascii.isUpper(ch) or ch == '_' or digit_ok)) return false;
    }
    return true;
}

pub fn profile(l: Language) Profile {
    const P = @import("highlight_profiles.zig");
    return switch (l) {
        .rust => P.rust,
        .javascript, .jsx => P.javascript,
        .typescript, .tsx => P.typescript,
        .python => P.python,
        .go => P.go,
        .c => P.c,
        .cpp => P.cpp,
        .csharp, .java, .kotlin, .swift, .php, .dockerfile, .nix => P.generic(l),
        .ruby, .make => P.hash_comment(l),
        .sql, .lua => P.dash_comment(l),
        else => P.generic(l),
    };
}

test {
    _ = md;
    _ = data;
    _ = @import("highlight_tests.zig");
}
