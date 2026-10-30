//! Each C-family language's captures, read off the query GPUI bundles for
//! it (tree-sitter-rust's, -javascript's and -typescript's, -python's,
//! -go's, -c's and -cpp's `highlights.scm`): which words are keywords,
//! which tokens operators or punctuation. The languages it bundles whose
//! queries aren't read here get their keywords, strings and comments.
const hl = @import("highlight.zig");
const Profile = hl.Profile;

const rust_brackets = [_][]const u8{ "(", ")", "[", "]", "{", "}", "::", ":", ".", ",", ";" };

pub const rust: Profile = .{
    .quotes = "\"",
    .multiline = "\"",
    .escapes = true,
    .rust = true,
    .capitals = true,
    .keywords = &.{ "as", "async", "await", "break", "const", "continue", "default", "dyn", "else", "enum", "extern", "fn", "for", "gen", "if", "impl", "in", "let", "loop", "match", "mod", "move", "pub", "raw", "ref", "return", "static", "struct", "trait", "type", "union", "unsafe", "use", "where", "while", "yield", "crate", "mut", "super" },
    .booleans = &.{ "true", "false" },
    .builtins = &.{"self"},
    .types = &.{ "bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64" },
    .operators = &.{ "*", "&" },
    .plain = &.{ "&&", "&=", "*=", "->", "=>", "..", "..=", "!=" },
    .punctuation = &rust_brackets,
    .defs = &.{"fn"},
};

const js_keywords = [_][]const u8{ "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "get", "if", "import", "in", "instanceof", "let", "new", "of", "return", "set", "static", "switch", "target", "throw", "try", "typeof", "var", "void", "while", "with", "yield" };
const ts_keywords = js_keywords ++ [_][]const u8{ "abstract", "declare", "enum", "implements", "interface", "keyof", "namespace", "private", "protected", "public", "type", "readonly", "override", "satisfies" };
const js_operators = [_][]const u8{ "-", "--", "-=", "+", "++", "+=", "*", "*=", "**", "**=", "/", "/=", "%", "%=", "<", "<=", "<<", "<<=", "=", "==", "===", "!", "!=", "!==", "=>", ">", ">=", ">>", ">>=", ">>>", ">>>=", "~", "^", "&", "|", "^=", "&=", "|=", "&&", "||", "??", "&&=", "||=", "??=" };

pub const javascript: Profile = .{
    .quotes = "\"'`",
    .multiline = "`",
    .capitals = true,
    .all_caps = .js,
    .keywords = &js_keywords,
    .constants = &.{ "true", "false", "null", "undefined" },
    .builtins = &.{ "this", "super", "arguments", "module", "console", "window", "document" },
    .operators = &js_operators,
    .punctuation = &.{ ";", "?.", ".", ",", "(", ")", "[", "]", "{", "}" },
    .defs = &.{"function"},
};

pub const typescript: Profile = p: {
    var p = javascript;
    p.keywords = &ts_keywords;
    p.types = &.{ "string", "number", "boolean", "any", "unknown", "never", "void", "object", "symbol", "bigint" };
    break :p p;
};

pub const python: Profile = .{
    .line_comment = "#",
    .block_comment = false,
    .triple = true,
    .escapes = true,
    .decorators = true,
    .capitals = true,
    .all_caps = .python,
    .keywords = &.{ "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "exec", "finally", "for", "from", "global", "if", "import", "lambda", "nonlocal", "pass", "print", "raise", "return", "try", "while", "with", "yield", "match", "case" },
    .constants = &.{ "None", "True", "False" },
    .operators = &.{ "-", "-=", "!=", "*", "**", "**=", "*=", "/", "//", "//=", "/=", "&", "&=", "%", "%=", "^", "^=", "+", "->", "+=", "<", "<<", "<<=", "<=", "<>", "=", ":=", "==", ">", ">=", ">>", ">>=", "|", "|=", "~", "@=", "and", "in", "is", "not", "or" },
    .defs = &.{"def"},
};

pub const go: Profile = .{
    .quotes = "\"'`",
    .multiline = "`",
    .raw_quotes = "`",
    .escapes = true,
    .keywords = &.{ "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var" },
    .constants = &.{ "true", "false", "nil", "iota" },
    .operators = &.{ "--", "-", "-=", ":=", "!", "!=", "...", "*", "*=", "/", "/=", "&", "&&", "&=", "%", "%=", "^", "^=", "+", "++", "+=", "<-", "<", "<<", "<<=", "<=", "=", "==", ">", ">=", ">>", ">>=", "|", "|=", "||", "~" },
    .defs = &.{"func"},
};

const c_keywords = [_][]const u8{ "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "if", "inline", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while" };
const c_types = [_][]const u8{ "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "size_t" };

pub const c: Profile = .{
    .char_number = true,
    .preprocessor = true,
    .all_caps = .c,
    .keywords = &c_keywords,
    .constants = &.{"NULL"},
    .types = &c_types,
    .operators = &.{ "--", "-", "-=", "->", "=", "!=", "*", "&", "&&", "+", "++", "+=", "<", "==", ">", "||" },
    .plain = &.{ "<=", ">=", "<<", ">>", "*=", "/=", "&=", "|=" },
};

pub const cpp: Profile = p: {
    var p = c;
    p.keywords = &(c_keywords ++ [_][]const u8{ "catch", "class", "co_await", "co_return", "co_yield", "constexpr", "constinit", "consteval", "delete", "explicit", "final", "friend", "mutable", "namespace", "noexcept", "new", "override", "private", "protected", "public", "template", "throw", "try", "typename", "using", "concept", "requires", "virtual" });
    p.constants = &.{ "NULL", "true", "false", "nullptr" };
    p.builtins = &.{"this"};
    p.punctuation = &.{ "::", ";" };
    break :p p;
};

const generic_keywords = [_][]const u8{ "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def", "default", "do", "else", "enum", "export", "extends", "final", "finally", "for", "fun", "func", "function", "guard", "if", "implements", "import", "in", "interface", "is", "let", "namespace", "new", "object", "override", "package", "private", "protected", "public", "return", "static", "struct", "switch", "throw", "throws", "try", "using", "val", "var", "when", "where", "while", "with", "yield", "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "ARG", "WORKDIR", "EXPOSE", "ENTRYPOINT", "USER", "LABEL", "VOLUME", "rec", "inherit", "then", "assert" };

/// Languages GPUI bundles whose queries aren't read here: C-like comments.
pub fn generic(l: hl.Language) Profile {
    var p: Profile = .{
        .keywords = &generic_keywords,
        .constants = &.{ "true", "false", "null", "nil" },
        .builtins = &.{ "this", "self" },
    };
    if (l == .dockerfile or l == .nix) {
        p.line_comment = "#";
        p.block_comment = l == .nix;
    }
    return p;
}

/// Ruby and Make: `#` comments.
pub fn hash_comment(l: hl.Language) Profile {
    _ = l;
    return .{
        .line_comment = "#",
        .block_comment = false,
        .keywords = &.{ "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "then", "unless", "until", "when", "while", "yield", "ifeq", "ifneq", "ifdef", "ifndef", "endif", "include", "define", "endef" },
        .constants = &.{ "true", "false", "nil" },
        .builtins = &.{"self"},
        .defs = &.{"def"},
    };
}

/// SQL and Lua: `--` comments.
pub fn dash_comment(l: hl.Language) Profile {
    if (l == .sql) return .{
        .line_comment = "--",
        .any_case = true,
        .keywords = &.{ "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "index", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "distinct", "union", "all", "primary", "key", "references", "null", "default", "case", "when", "then", "else", "end", "is", "in", "exists", "with", "returning" },
        .constants = &.{ "true", "false", "TRUE", "FALSE" },
    };
    return .{
        .line_comment = "--",
        .block_comment = false,
        .keywords = &.{ "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return", "then", "until", "while" },
        .constants = &.{ "true", "false", "nil" },
        .defs = &.{"function"},
    };
}
