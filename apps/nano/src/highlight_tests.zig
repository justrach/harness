//! The highlighter's captures against what GPUI's queries name, on
//! made-up code.
const std = @import("std");
const hl = @import("highlight.zig");
const Kind = hl.Kind;
const testing = std.testing;

/// Highlights `lines` in `lang` and returns the kind every byte of
/// `needle` (on line `at`) has: null when plain, an error when mixed.
fn kindOf(lines: []const []const u8, lang: []const u8, at: usize, needle: []const u8) !?Kind {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var st: hl.State = .{};
    const l = hl.language(lang) orelse return error.NoLanguage;
    for (lines, 0..) |src, n| {
        const p: hl.Paint = .init(arena.allocator(), src.len);
        hl.paint(p, src, l, &st);
        if (n != at) continue;
        const from = std.mem.indexOf(u8, src, needle) orelse return error.NoNeedle;
        const first = p.kinds[from];
        for (p.kinds[from .. from + needle.len]) |x| if (x != first) {
            std.debug.print("{s}: mixed in {s}\n", .{ needle, src });
            return error.Mixed;
        };
        return first;
    }
    return error.NoLine;
}

fn expectKind(want: ?Kind, lines: []const []const u8, lang: []const u8, at: usize, needle: []const u8) !void {
    const got = try kindOf(lines, lang, at, needle);
    if (got != want) std.debug.print("{s} in {s}: want {?}, got {?}\n", .{ needle, lines[at], want, got });
    try testing.expectEqual(want, got);
}

test "Markdown: a heading's #s punctuation and its text the heading's; list markers punctuation" {
    const src = [_][]const u8{ "## Parser", "- Nested lists keep their indentation" };
    try expectKind(.punctuation, &src, "md", 0, "##");
    try expectKind(.markup_heading, &src, "md", 0, "Parser");
    try expectKind(null, &src, "md", 0, " ");
    try expectKind(.punctuation, &src, "md", 1, "-");
    try expectKind(null, &src, "md", 1, "Nested lists");
    // The colors GPUI paints them in (Codegraff Dark): muted #s, an
    // indigo heading.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pal = @import("theme.zig").colors(true).syntax;
    var st: hl.State = .{};
    const spans = hl.line(arena.allocator(), "## Parser", "md", pal, &st);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(nanoColor(0x9a9384), spans[0].color.?);
    try testing.expectEqual(nanoColor(0x8f96ed), spans[1].color.?);
    try testing.expectEqual(@as(u32, 3), spans[1].start);
}

fn nanoColor(h: u24) @import("nanoui").ui.Color {
    return .hex(h);
}

test "Markdown inline: code, emphasis, strong, links, escapes; snake_case opens nothing" {
    const src = [_][]const u8{"Use `zig build` and **bold** or *soft*, [the docs](https://example.com) \\* and snake_case_name"};
    try expectKind(.punctuation, &src, "markdown", 0, "`");
    try expectKind(.markup_raw, &src, "markdown", 0, "zig build");
    try expectKind(.markup_strong, &src, "markdown", 0, "bold");
    try expectKind(.punctuation, &src, "markdown", 0, "**");
    try expectKind(.markup_emphasis, &src, "markdown", 0, "soft");
    try expectKind(.markup_reference, &src, "markdown", 0, "the docs");
    try expectKind(.markup_link, &src, "markdown", 0, "https://example.com");
    try expectKind(.punctuation, &src, "markdown", 0, "](");
    try expectKind(.escape, &src, "markdown", 0, "\\*");
    try expectKind(null, &src, "markdown", 0, "snake_case_name");
}

test "Markdown: a fence is raw text, its code in its language over it; rules and quotes" {
    const src = [_][]const u8{ "```rust", "let x = 42;", "```", "> quoted", "---", "1. first" };
    try expectKind(.punctuation, &src, "md", 0, "```");
    try expectKind(.markup_raw, &src, "md", 0, "rust");
    try expectKind(.keyword, &src, "md", 1, "let");
    try expectKind(.markup_raw, &src, "md", 1, "x =");
    try expectKind(.number, &src, "md", 1, "42");
    try expectKind(.punctuation, &src, "md", 1, ";");
    try expectKind(.punctuation, &src, "md", 2, "```");
    try expectKind(.punctuation, &src, "md", 3, ">");
    try expectKind(null, &src, "md", 3, "quoted");
    try expectKind(.punctuation, &src, "md", 4, "---");
    try expectKind(.punctuation, &src, "md", 5, "1.");
}

test "Rust: keywords, definitions, macros, attributes, lifetimes, raw strings, punctuation" {
    const src = [_][]const u8{
        "#[derive(Debug)]",
        "pub fn build<'life>(value: &'life str) -> Widget {",
        "    let name = format!(\"item-{}\\n\", 42);",
        "    let raw = r#\"a\\b\"#; self.call(true)",
    };
    try expectKind(.attribute, &src, "rust", 0, "#[derive(Debug)]");
    try expectKind(.keyword, &src, "rust", 1, "pub");
    try expectKind(.function, &src, "rust", 1, "build");
    try expectKind(.operator, &src, "rust", 1, "&");
    try expectKind(.label, &src, "rust", 1, "life");
    try expectKind(.type_builtin, &src, "rust", 1, "str");
    try expectKind(null, &src, "rust", 1, "->");
    try expectKind(.constructor, &src, "rust", 1, "Widget");
    try expectKind(.punctuation, &src, "rust", 1, "{");
    try expectKind(.macro, &src, "rust", 2, "format!");
    try expectKind(.escape, &src, "rust", 2, "\\n");
    try expectKind(.number, &src, "rust", 2, "42");
    try expectKind(null, &src, "rust", 2, "=");
    try expectKind(.string, &src, "rust", 3, "r#\"a\\b\"#");
    try expectKind(.variable_special, &src, "rust", 3, "self");
    try expectKind(.function, &src, "rust", 3, "call");
    try expectKind(.boolean, &src, "rust", 3, "true");
}

test "Python: decorators, definitions, word operators, constants, a docstring across lines" {
    const src = [_][]const u8{ "@cache", "def load(path) -> None:", "    \"\"\"Reads it.", "    Twice.\"\"\"", "    return x if y is not None else MAX" };
    try expectKind(.function, &src, "py", 0, "@cache");
    try expectKind(.keyword, &src, "py", 1, "def");
    try expectKind(.function, &src, "py", 1, "load");
    try expectKind(.operator, &src, "py", 1, "->");
    try expectKind(.constant, &src, "py", 1, "None");
    try expectKind(.string, &src, "py", 2, "\"\"\"Reads it.");
    try expectKind(.string, &src, "py", 3, "Twice.\"\"\"");
    try expectKind(.operator, &src, "py", 4, "is");
    try expectKind(.operator, &src, "py", 4, "not");
    try expectKind(.constructor, &src, "py", 4, "MAX");
    try expectKind(null, &src, "py", 1, "(");
}

test "JavaScript and Go: operators, punctuation, builtins, constants" {
    const js = [_][]const u8{"const total = items.reduce((a, b) => a + b, 0) ?? null; // sum"};
    try expectKind(.keyword, &js, "js", 0, "const");
    try expectKind(.operator, &js, "js", 0, "=>");
    try expectKind(.operator, &js, "js", 0, "??");
    try expectKind(.function, &js, "js", 0, "reduce");
    try expectKind(.punctuation, &js, "js", 0, ".");
    try expectKind(.constant, &js, "js", 0, "null");
    try expectKind(.comment, &js, "js", 0, "// sum");
    const go = [_][]const u8{"func main() { x := `raw\\n`; fmt.Println(x, nil) }"};
    try expectKind(.keyword, &go, "go", 0, "func");
    try expectKind(.function, &go, "go", 0, "main");
    try expectKind(.operator, &go, "go", 0, ":=");
    try expectKind(.string, &go, "go", 0, "`raw\\n`");
    try expectKind(null, &go, "go", 0, "{");
    try expectKind(.constant, &go, "go", 0, "nil");
}

test "JSON's keys, YAML's keys and scalars, TOML's pairs" {
    const json = [_][]const u8{"{ \"name\": \"nano\", \"size\": 12, \"on\": true }"};
    try expectKind(.string_special, &json, "json", 0, "\"name\"");
    try expectKind(.string, &json, "json", 0, "\"nano\"");
    try expectKind(.number, &json, "json", 0, "12");
    try expectKind(.constant, &json, "json", 0, "true");
    try expectKind(null, &json, "json", 0, "{");
    const yaml = [_][]const u8{ "name: harness # the app", "- port: 8080", "  on: true" };
    try expectKind(.property, &yaml, "yaml", 0, "name");
    try expectKind(.punctuation, &yaml, "yaml", 0, ":");
    try expectKind(.string, &yaml, "yaml", 0, "harness");
    try expectKind(.comment, &yaml, "yaml", 0, "# the app");
    try expectKind(.punctuation, &yaml, "yaml", 1, "-");
    try expectKind(.number, &yaml, "yaml", 1, "8080");
    try expectKind(.boolean, &yaml, "yaml", 2, "true");
    // A bare key's pair is `property` whole, values and all.
    const toml = [_][]const u8{ "[package]", "name = \"nano\"", "a.b = 3" };
    try expectKind(.punctuation, &toml, "toml", 0, "[");
    try expectKind(.type, &toml, "toml", 0, "package");
    try expectKind(.property, &toml, "toml", 1, "name = \"nano\"");
    try expectKind(.property, &toml, "toml", 2, "a");
    try expectKind(.punctuation, &toml, "toml", 2, ".");
    try expectKind(.operator, &toml, "toml", 2, "=");
    try expectKind(.number, &toml, "toml", 2, "3");
}

test "Shell: commands, flags, variables, operators, strings, comments" {
    const src = [_][]const u8{"ls -la $HOME | grep \"x\" && echo ${USER} > out.txt # done"};
    try expectKind(.function, &src, "sh", 0, "ls");
    try expectKind(.constant, &src, "sh", 0, "-la");
    try expectKind(.operator, &src, "sh", 0, "$");
    try expectKind(.property, &src, "sh", 0, "HOME");
    try expectKind(.operator, &src, "sh", 0, "|");
    try expectKind(.function, &src, "sh", 0, "grep");
    try expectKind(.string, &src, "sh", 0, "\"x\"");
    try expectKind(.operator, &src, "sh", 0, "&&");
    try expectKind(.function, &src, "sh", 0, "echo");
    try expectKind(.embedded, &src, "sh", 0, "{");
    try expectKind(.property, &src, "sh", 0, "USER");
    try expectKind(null, &src, "sh", 0, "out.txt");
    try expectKind(.comment, &src, "sh", 0, "# done");
}

test "HTML and CSS: tags, attributes, values; selectors, properties, numbers and units" {
    const html = [_][]const u8{"<a href=\"/x\" class=yes>Go</a>"};
    try expectKind(.punctuation, &html, "html", 0, "<");
    try expectKind(.tag, &html, "html", 0, "a");
    try expectKind(.attribute, &html, "html", 0, "href");
    try expectKind(.string, &html, "html", 0, "/x");
    try expectKind(null, &html, "html", 0, "=\"");
    try expectKind(.string, &html, "html", 0, "yes");
    try expectKind(null, &html, "html", 0, "Go");
    try expectKind(.punctuation, &html, "html", 0, "</");
    const css = [_][]const u8{ ".card:hover > p {", "  margin: 12px #fff;", "}" };
    try expectKind(.property, &css, "css", 0, "card");
    try expectKind(.attribute, &css, "css", 0, "hover");
    try expectKind(.operator, &css, "css", 0, ">");
    try expectKind(.tag, &css, "css", 0, "p");
    try expectKind(.property, &css, "css", 1, "margin");
    try expectKind(.number, &css, "css", 1, "12");
    try expectKind(.type, &css, "css", 1, "px");
    try expectKind(.string_special, &css, "css", 1, "#fff");
}

test "a language GPUI doesn't bundle stays plain; aliases are GPUI's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var st: hl.State = .{};
    const pal = @import("theme.zig").colors(true).syntax;
    try testing.expectEqual(@as(usize, 0), hl.line(arena.allocator(), "const x = 1; // zig", "zig", pal, &st).len);
    try testing.expectEqual(@as(usize, 0), hl.line(arena.allocator(), "+added", "diff", pal, &st).len);
    try testing.expectEqual(hl.Language.bash, hl.language("Console").?);
    try testing.expectEqual(hl.Language.markdown, hl.language("md title=x").?);
    try testing.expectEqual(hl.Language.cpp, hl.language("c++").?);
    try testing.expect(hl.language("text") == null);
}

test "the palette maps kinds as the theme's roles: operators in the keyword's color, booleans the number's" {
    const pal = @import("theme.zig").colors(true).syntax;
    try testing.expectEqual(pal.keyword, pal.color(.operator));
    try testing.expectEqual(pal.keyword, pal.color(.macro));
    try testing.expectEqual(pal.number, pal.color(.boolean));
    try testing.expectEqual(pal.number, pal.color(.constant));
    try testing.expectEqual(pal.attribute, pal.color(.string_special));
    try testing.expectEqual(pal.punctuation, pal.color(.embedded));
    try testing.expectEqual(pal.function, pal.color(.label));
}

test "a capture ranks over another: the innermost of equals, the higher of unequal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p: hl.Paint = .init(arena.allocator(), 10);
    p.put(0, 10, .markup_raw);
    p.put(2, 6, .keyword);
    p.put(3, 5, .punctuation); // ranks under keyword: stays keyword
    p.put(4, 8, .markup_heading); // ranks under both
    try testing.expectEqual(Kind.markup_raw, p.kinds[0].?);
    try testing.expectEqual(Kind.keyword, p.kinds[3].?);
    try testing.expectEqual(Kind.markup_raw, p.kinds[7].?);
}
