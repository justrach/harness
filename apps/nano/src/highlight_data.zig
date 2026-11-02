//! The languages whose captures follow their shape more than their words,
//! as their queries name them: JSON's keys, YAML's and TOML's keys and
//! values, a shell's commands and flags, HTML's tags and attributes, CSS's
//! selectors and declarations.
const std = @import("std");
const hl = @import("highlight.zig");
const Paint = hl.Paint;

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch >= 0x80;
}

fn skipSpace(src: []const u8, from: usize) usize {
    var j = from;
    while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
    return j;
}

/// A quoted string from `i` (at its quote): its end, its escapes painted.
fn quoted(p: Paint, src: []const u8, i: usize, escapes: bool) usize {
    const q = src[i];
    var j = i + 1;
    while (j < src.len and src[j] != q) : (j += 1) {
        if (src[j] == '\\' and q != '\'') {
            if (escapes) p.put(j, @min(src.len, j + 2), .escape);
            j += 1;
        }
    }
    return @min(src.len, j + 1);
}

fn number(src: []const u8, i: usize) ?usize {
    var j = i;
    if (j < src.len and (src[j] == '-' or src[j] == '+')) j += 1;
    if (j >= src.len or !std.ascii.isDigit(src[j])) return null;
    while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '.' or src[j] == '_' or ((src[j] == '-' or src[j] == '+') and (src[j - 1] == 'e' or src[j - 1] == 'E')))) j += 1;
    return j;
}

/// tree-sitter-json: a pair's key `string.special.key`, strings, numbers,
/// true/false/null `constant.builtin`, comments.
pub fn json(p: Paint, src: []const u8, st: *hl.State) void {
    var i: usize = 0;
    if (st.comment) {
        const close = std.mem.indexOf(u8, src, "*/");
        p.put(0, if (close) |c| c + 2 else src.len, .comment);
        if (close == null) return;
        st.comment = false;
        i = close.? + 2;
    }
    while (i < src.len) {
        const rest = src[i..];
        if (std.mem.startsWith(u8, rest, "//")) return p.put(i, src.len, .comment);
        if (std.mem.startsWith(u8, rest, "/*")) {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            p.put(i, if (close) |c| c + 2 else src.len, .comment);
            if (close == null) {
                st.comment = true;
                return;
            }
            i = close.? + 2;
            continue;
        }
        if (src[i] == '"') {
            const end = quoted(p, src, i, true);
            const after = skipSpace(src, end);
            p.put(i, end, if (after < src.len and src[after] == ':') .string_special else .string);
            i = end;
            continue;
        }
        if (number(src, i)) |end| if (i == 0 or !isWord(src[i - 1])) {
            p.put(i, end, .number);
            i = end;
            continue;
        };
        if (std.ascii.isAlphabetic(src[i])) {
            var j = i;
            while (j < src.len and std.ascii.isAlphabetic(src[j])) j += 1;
            const w = src[i..j];
            if (std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false") or std.mem.eql(u8, w, "null")) p.put(i, j, .constant);
            i = j;
            continue;
        }
        i += 1;
    }
}

/// tree-sitter-yaml: keys `property`, scalars by type (a plain one is a
/// string), anchors and aliases, tags, and its indicators as punctuation.
pub fn yaml(p: Paint, src: []const u8) void {
    var i = skipSpace(src, 0);
    const t = std.mem.trimEnd(u8, src, " \t");
    if (std.mem.eql(u8, t[i..], "---") or std.mem.eql(u8, t[i..], "...")) return p.put(i, t.len, .punctuation);
    while (i < src.len) {
        const ch = src[i];
        if (ch == '#' and (i == 0 or src[i - 1] == ' ' or src[i - 1] == '\t')) return p.put(i, src.len, .comment);
        if (ch == ' ' or ch == '\t') {
            i += 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, "[]{}", ch) != null) {
            p.put(i, i + 1, .punctuation);
            i += 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, ",-:?|>", ch) != null and (i + 1 == src.len or src[i + 1] == ' ' or ch == ',')) {
            p.put(i, i + 1, .punctuation);
            i += 1;
            continue;
        }
        if (ch == '&' or ch == '*') {
            var j = i + 1;
            while (j < src.len and src[j] != ' ' and src[j] != ',') j += 1;
            p.put(i, i + 1, .punctuation);
            p.put(i + 1, j, .label);
            i = j;
            continue;
        }
        if (ch == '!') {
            var j = i + 1;
            while (j < src.len and src[j] != ' ') j += 1;
            p.put(i, j, .type);
            i = j;
            continue;
        }
        // A scalar: to a `: `, a ` #`, or a flow indicator.
        var end = i;
        if (ch == '"' or ch == '\'') {
            end = quoted(p, src, i, ch == '"');
        } else {
            while (end < src.len) : (end += 1) {
                const x = src[end];
                if (x == ':' and (end + 1 == src.len or src[end + 1] == ' ')) break;
                if (x == '#' and src[end - 1] == ' ') break;
                if (x == ',' or x == ']' or x == '}') break;
            }
            while (end > i and src[end - 1] == ' ') end -= 1;
        }
        const after = skipSpace(src, end);
        const key = after < src.len and src[after] == ':' and (after + 1 == src.len or src[after + 1] == ' ');
        p.put(i, end, if (key) .property else scalar(src[i..end]));
        i = end;
    }
}

fn scalar(s: []const u8) hl.Kind {
    const bools = [_][]const u8{ "true", "false", "True", "False", "TRUE", "FALSE" };
    for (bools) |b| if (std.mem.eql(u8, s, b)) return .boolean;
    if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~") or std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL")) return .constant;
    if (number(s, 0)) |end| if (end == s.len) return .number;
    return .string;
}

/// tree-sitter-toml: a pair with a bare key is `property` whole (its
/// values under it), a dotted key's parts each; a table's keys `type`;
/// `=` an operator, brackets and dots punctuation; values by type.
pub fn toml(p: Paint, src: []const u8) void {
    const i = skipSpace(src, 0);
    if (i >= src.len) return;
    if (src[i] == '#') return p.put(i, src.len, .comment);
    if (src[i] == '[') {
        const n: usize = if (std.mem.startsWith(u8, src[i..], "[[")) 2 else 1;
        p.put(i, i + n, .punctuation);
        const close = std.mem.indexOfScalarPos(u8, src, i + n, ']') orelse src.len;
        keys(p, src, i + n, close, .type);
        p.put(close, @min(src.len, close + n), .punctuation);
        return comment(p, src, close + n);
    }
    const eq = std.mem.indexOfScalar(u8, src, '=') orelse return;
    const key = std.mem.trim(u8, src[i..eq], " \t");
    var end = values(p, src, eq + 1);
    while (end > eq and (src[end - 1] == ' ' or src[end - 1] == '\t')) end -= 1;
    if (key.len > 0 and key[0] != '"' and key[0] != '\'' and std.mem.indexOfScalar(u8, key, '.') == null) {
        p.put(i, end, .property);
    } else keys(p, src, i, eq, .property);
    p.put(eq, eq + 1, .operator);
}

/// Keys from `from` to `to`: bare ones as `kind`, quoted ones strings,
/// dots punctuation.
fn keys(p: Paint, src: []const u8, from: usize, to: usize, kind: hl.Kind) void {
    var i = from;
    while (i < to) {
        const ch = src[i];
        if (ch == '"' or ch == '\'') {
            const end = quoted(p, src[0..to], i, false);
            p.put(i, end, .string);
            i = end;
        } else if (ch == '.') {
            p.put(i, i + 1, .punctuation);
            i += 1;
        } else if (isWord(ch)) {
            var j = i;
            while (j < to and isWord(src[j])) j += 1;
            p.put(i, j, kind);
            i = j;
        } else i += 1;
    }
}

/// TOML values from `from`: where they end (before a comment).
fn values(p: Paint, src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) {
        const ch = src[i];
        if (ch == '#') {
            comment(p, src, i);
            return i;
        }
        if (ch == '"' or ch == '\'') {
            const end = quoted(p, src, i, false);
            p.put(i, end, .string);
            i = end;
        } else if (std.mem.indexOfScalar(u8, "[]{}", ch) != null) {
            p.put(i, i + 1, .punctuation);
            i += 1;
        } else if (ch == ',' or ch == '.') {
            p.put(i, i + 1, .punctuation);
            i += 1;
        } else if (number(src, i)) |end| {
            const date = std.mem.indexOfAny(u8, src[i + 1 .. end], "-:") != null and !std.mem.startsWith(u8, src[i..], "-");
            p.put(i, end, if (date) .string_special else .number);
            i = end;
        } else if (std.mem.startsWith(u8, src[i..], "true") or std.mem.startsWith(u8, src[i..], "false")) {
            const n: usize = if (src[i] == 't') 4 else 5;
            p.put(i, i + n, .boolean);
            i += n;
        } else if (ch == '=') {
            p.put(i, i + 1, .operator);
            i += 1;
        } else i += 1;
    }
    return src.len;
}

fn comment(p: Paint, src: []const u8, from: usize) void {
    if (std.mem.indexOfScalarPos(u8, src, @min(from, src.len), '#')) |c| p.put(c, src.len, .comment);
}

const shell_keywords = [_][]const u8{ "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "select", "then", "unset", "until", "while" };

/// tree-sitter-bash: a command's name `function`, its `-flags`
/// `constant`, strings, comments, `$ && > >> < |` operators, a variable's
/// name `property`, an expansion `embedded`.
pub fn bash(p: Paint, src: []const u8, st: *hl.State) void {
    _ = st;
    shell(p, src, 0, src.len);
}

fn shell(p: Paint, src: []const u8, from: usize, to: usize) void {
    var i = from;
    var command = true; // the next word names a command
    var in_command = false; // words are a command's arguments
    while (i < to) {
        const ch = src[i];
        if (ch == ' ' or ch == '\t') {
            i += 1;
            continue;
        }
        if (ch == '#') return p.put(i, to, .comment);
        if (ch == '"' or ch == '\'') {
            const end = @min(to, quoted(p, src[0..to], i, false));
            p.put(i, end, .string);
            i = end;
            in_command = in_command or !command;
            command = false;
            continue;
        }
        if (ch == '$') {
            if (i + 1 < to and src[i + 1] == '(') {
                const close = matching(src[0..to], i + 1) orelse to;
                p.put(i, @min(to, close + 1), .embedded);
                shell(p, src, i + 2, close);
                i = @min(to, close + 1);
                continue;
            }
            p.put(i, i + 1, .operator);
            if (i + 1 < to and src[i + 1] == '{') {
                const close = std.mem.indexOfScalarPos(u8, src[0..to], i + 2, '}') orelse to - 1;
                p.put(i + 1, close + 1, .embedded);
                p.put(i, i + 1, .operator);
                var j = i + 2;
                while (j < close and isWord(src[j])) j += 1;
                p.put(i + 2, j, .property);
                i = close + 1;
                continue;
            }
            var j = i + 1;
            while (j < to and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
            p.put(i + 1, j, .property);
            i = @max(j, i + 1);
            continue;
        }
        const ops = [_][]const u8{ "&&", "||", ">>", ">", "<", "|", ";", "(", ")", "&" };
        var op: ?[]const u8 = null;
        for (ops) |o| if (std.mem.startsWith(u8, src[i..to], o)) {
            op = o;
            break;
        };
        if (op) |o| {
            if (!std.mem.eql(u8, o, "||") and !std.mem.eql(u8, o, ";") and !std.mem.eql(u8, o, "(") and !std.mem.eql(u8, o, ")") and !std.mem.eql(u8, o, "&")) p.put(i, i + o.len, .operator);
            const redirect = o[0] == '>' or o[0] == '<';
            if (!redirect) {
                command = true;
                in_command = false;
            }
            i += o.len;
            continue;
        }
        var j = i;
        while (j < to and std.mem.indexOfScalar(u8, " \t;|&<>()\"'", src[j]) == null) j += 1;
        if (j == i) {
            i += 1;
            continue;
        }
        const word = src[i..j];
        if (j < to and src[j] == '>' and std.ascii.isDigit(word[0]) and word.len == 1) {
            p.put(i, j, .number); // a file descriptor: `2>`
        } else if (inList(&shell_keywords, word)) {
            p.put(i, j, .keyword);
            command = !std.mem.eql(u8, word, "export") and !std.mem.eql(u8, word, "unset") and !std.mem.eql(u8, word, "for") and !std.mem.eql(u8, word, "in") and !std.mem.eql(u8, word, "case") and !std.mem.eql(u8, word, "function");
            if (std.mem.eql(u8, word, "export") or std.mem.eql(u8, word, "unset") or std.mem.eql(u8, word, "for")) {
                // A declaration's name is a variable's.
                const k = skipSpace(src[0..to], j);
                var e = k;
                while (e < to and (std.ascii.isAlphanumeric(src[e]) or src[e] == '_')) e += 1;
                p.put(k, e, .property);
                j = e;
            }
            in_command = false;
        } else if (command and std.mem.indexOfScalar(u8, word, '=') != null and std.ascii.isAlphabetic(word[0])) {
            // An assignment before a command: its name.
            p.put(i, i + std.mem.indexOfScalar(u8, word, '=').?, .property);
        } else if (command) {
            const def = j + 1 < to and src[j] == '(' and src[j + 1] == ')';
            p.put(i, j, .function);
            command = false;
            in_command = !def;
        } else if (in_command and word[0] == '-') {
            p.put(i, j, .constant);
        }
        i = j;
    }
}

fn matching(src: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var j = open;
    while (j < src.len) : (j += 1) {
        if (src[j] == '(') depth += 1;
        if (src[j] == ')') {
            depth -= 1;
            if (depth == 0) return j;
        }
    }
    return null;
}

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

/// tree-sitter-html: tag names `tag`, attribute names `attribute`, their
/// values strings (not their quotes), comments, a doctype `constant`, and
/// `< > </ />` punctuation. `depth` 1: inside a tag that goes on.
pub fn html(p: Paint, src: []const u8, st: *hl.State) void {
    var i: usize = 0;
    if (st.comment) {
        const close = std.mem.indexOf(u8, src, "-->");
        p.put(0, if (close) |c| c + 3 else src.len, .comment);
        if (close == null) return;
        st.comment = false;
        i = close.? + 3;
    }
    while (i < src.len) {
        const rest = src[i..];
        if (st.depth == 0) {
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const close = std.mem.indexOfPos(u8, src, i + 4, "-->");
                p.put(i, if (close) |c| c + 3 else src.len, .comment);
                if (close == null) {
                    st.comment = true;
                    return;
                }
                i = close.? + 3;
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(rest, "<!doctype")) {
                const close = std.mem.indexOfScalarPos(u8, src, i, '>') orelse src.len - 1;
                p.put(i, close + 1, .constant);
                i = close + 1;
                continue;
            }
            if (src[i] == '<' and i + 1 < src.len and (std.ascii.isAlphabetic(src[i + 1]) or src[i + 1] == '/')) {
                const n: usize = if (src[i + 1] == '/') 2 else 1;
                p.put(i, i + n, .punctuation);
                var j = i + n;
                while (j < src.len and isWord(src[j])) j += 1;
                p.put(i + n, j, .tag);
                st.depth = 1;
                i = j;
                continue;
            }
            i += 1;
            continue;
        }
        // Inside a tag.
        const ch = src[i];
        if (std.mem.startsWith(u8, rest, "/>")) {
            p.put(i, i + 2, .punctuation);
            st.depth = 0;
            i += 2;
        } else if (ch == '>') {
            p.put(i, i + 1, .punctuation);
            st.depth = 0;
            i += 1;
        } else if (ch == '"' or ch == '\'') {
            const end = quoted(p, src, i, false);
            p.put(i + 1, end - 1, .string);
            i = end;
        } else if (ch == '=') {
            i += 1;
            if (i < src.len and src[i] != '"' and src[i] != '\'') {
                var j = i;
                while (j < src.len and src[j] != ' ' and src[j] != '>') j += 1;
                p.put(i, j, .string);
                i = j;
            }
        } else if (isWord(ch) or ch == ':' or ch == '@') {
            var j = i;
            while (j < src.len and (isWord(src[j]) or src[j] == ':' or src[j] == '@' or src[j] == '.')) j += 1;
            p.put(i, j, .attribute);
            i = j;
        } else i += 1;
    }
}

/// tree-sitter-css, as far as a line shows: in a selector (`depth` 0)
/// tags, classes and ids, pseudo-classes, combinators; in a block its
/// properties, values, numbers and their units, colors, functions;
/// at-rules keywords; braces and delimiters punctuation.
pub fn css(p: Paint, src: []const u8, st: *hl.State) void {
    var i: usize = 0;
    if (st.comment) {
        const close = std.mem.indexOf(u8, src, "*/");
        p.put(0, if (close) |c| c + 2 else src.len, .comment);
        if (close == null) return;
        st.comment = false;
        i = close.? + 2;
    }
    var value = false; // after a declaration's colon
    while (i < src.len) {
        const rest = src[i..];
        const ch = src[i];
        if (std.mem.startsWith(u8, rest, "/*")) {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            p.put(i, if (close) |c| c + 2 else src.len, .comment);
            if (close == null) {
                st.comment = true;
                return;
            }
            i = close.? + 2;
            continue;
        }
        if (ch == '{' or ch == '}' or ch == '(' or ch == ')') {
            p.put(i, i + 1, .punctuation);
            if (ch == '{') st.depth +|= 1;
            if (ch == '}') st.depth -|= 1;
            value = false;
            i += 1;
            continue;
        }
        if (ch == ';' or ch == ',') {
            p.put(i, i + 1, .punctuation);
            if (ch == ';') value = false;
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            const end = quoted(p, src, i, false);
            p.put(i, end, .string);
            i = end;
            continue;
        }
        if (ch == '@') {
            var j = i + 1;
            while (j < src.len and isWord(src[j])) j += 1;
            p.put(i, j, .keyword);
            i = j;
            continue;
        }
        if (ch == '!' and std.mem.startsWith(u8, rest, "!important")) {
            p.put(i, i + 10, .keyword);
            i += 10;
            continue;
        }
        const in_block = st.depth > 0;
        if (in_block and value) {
            if (ch == '#') {
                var j = i + 1;
                while (j < src.len and std.ascii.isAlphanumeric(src[j])) j += 1;
                p.put(i, j, .string_special);
                i = j;
                continue;
            }
            if (std.ascii.isDigit(ch) or (ch == '.' and i + 1 < src.len and std.ascii.isDigit(src[i + 1])) or (ch == '-' and i + 1 < src.len and std.ascii.isDigit(src[i + 1]))) {
                var j = i + 1;
                while (j < src.len and (std.ascii.isDigit(src[j]) or src[j] == '.')) j += 1;
                p.put(i, j, .number);
                var u = j;
                while (u < src.len and (std.ascii.isAlphabetic(src[u]) or src[u] == '%')) u += 1;
                p.put(j, u, .type);
                i = u;
                continue;
            }
            if (std.mem.indexOfScalar(u8, "+-*/", ch) != null and (i + 1 == src.len or src[i + 1] == ' ')) {
                p.put(i, i + 1, .operator);
                i += 1;
                continue;
            }
        }
        if (isWord(ch)) {
            var j = i;
            while (j < src.len and isWord(src[j])) j += 1;
            const word = src[i..j];
            if (j < src.len and src[j] == '(') {
                p.put(i, j, .function);
            } else if (in_block and !value) {
                p.put(i, j, if (std.mem.startsWith(u8, word, "--")) .variable else .property);
            } else if (!in_block) {
                const op = [_][]const u8{ "and", "or", "not", "only" };
                if (inList(&op, word)) p.put(i, j, .operator) else if (!std.ascii.isDigit(word[0])) p.put(i, j, .tag);
            } else if (std.mem.startsWith(u8, word, "--")) p.put(i, j, .variable);
            i = j;
            continue;
        }
        if (ch == ':') {
            const n: usize = if (std.mem.startsWith(u8, rest, "::")) 2 else 1;
            p.put(i, i + n, .punctuation);
            if (in_block) {
                value = true;
                i += n;
                continue;
            }
            var j = i + n;
            while (j < src.len and isWord(src[j])) j += 1;
            p.put(i + n, j, .attribute);
            i = j;
            continue;
        }
        if (!in_block and (ch == '.' or ch == '#')) {
            p.put(i, i + 1, .punctuation);
            var j = i + 1;
            while (j < src.len and isWord(src[j])) j += 1;
            p.put(i + 1, j, .property);
            i = j;
            continue;
        }
        if (!in_block and std.mem.indexOfScalar(u8, "*&", ch) != null) {
            p.put(i, i + 1, .tag);
            i += 1;
            continue;
        }
        if (!in_block and std.mem.indexOfScalar(u8, ">+~", ch) != null) {
            p.put(i, i + 1, .operator);
            i += 1;
            continue;
        }
        i += 1;
    }
}
