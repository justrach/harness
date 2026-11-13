//! Synthetic renderer regressions: actual equation image geometry, not a
//! Unicode formatter's output. Every case failed against the v187 renderer.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const testing = std.testing;
const md = @import("markdown.zig");
const pal: md.Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };

test "native math boundaries retain source and protect currency code and unfinished input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "Energy $E=mc^2$ and \\(\\frac{a+b}{c}\\).";
    const in = md.parse(a, raw, pal)[0].paragraph;
    try testing.expectEqualStrings(raw, in.text);
    try testing.expectEqual(@as(usize, 2), in.maths.len);
    try testing.expectEqualStrings("\\frac{a+b}{c}", in.maths[1].source);
    for ([_][]const u8{ "Pay $5 and $10", "Pay $5.00 and $10.00", "$$$x$$$", "`$x_i$`", "\\(x_i", "$x_i", "$x_{a}_b", "$$x_{a}_b", "[literal $x$](https://example.com)" }) |source| {
        const text = md.parse(a, source, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 0), text.maths.len);
        if (source[0] != '`' and source[0] != '[') try testing.expectEqualStrings(source, text.text);
    }
    const price = md.parse(a, "Pay $5 ($x^2$)", pal)[0].paragraph;
    try testing.expectEqual(@as(usize, 1), price.maths.len);
    try testing.expectEqualStrings("x^2", price.maths[0].source);
    const display = "\\[\n\\begin{matrix}a&b\\\\c&d\\end{matrix}\n\\]";
    const block = md.parse(a, display, pal)[0].math;
    try testing.expectEqualStrings(display, block.text);
    try testing.expect(block.maths[0].display);
}

test "native math UI unsupported equations remain literal without losing backslashes" {
    theme.registerFonts();
    var f = Fixture{ .source = "$\\unsupported{x}$" };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{});
    defer t.deinit();
    t.settle(3);
    try testing.expect(t.hasText(f.source));
    for (t.ctx.nodes.items) |node| try testing.expect(node.content != .image);
}

test "native math UI mixed prose selection copies original equation source continuously" {
    theme.registerFonts();
    const source = "Before $\\frac{x_i}{y}$ after.";
    var a: @import("app.zig").App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.openChat("math", null);
    a.settings.set(.transcript_compact_mode, false);
    const data = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"m","role":"assistant","status":"complete","parts":[{"kind":"text","id":"p","text":"Before $\\frac{x_i}{y}$ after."}]}]}
    , .{});
    defer data.deinit();
    try a.transcript.apply(data.value);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1100, .height = 700 });
    defer t.deinit();
    t.settle(3);
    var id: u64 = 0;
    for (t.ctx.nodes.items) |node| if (node.content == .text and std.mem.eql(u8, node.content.text.str, source)) {
        id = node.id;
        break;
    };
    try testing.expect(id != 0);
    t.ctx.selection.anchor = .{ .id = id, .at = 0 };
    t.ctx.selection.focus = .{ .id = id, .at = source.len };
    t.ctx.selection.moved = true;
    t.frame();
    try testing.expectEqualStrings(source, t.ctx.selection.text.items);
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(source, t.clipboard.items);
}

test "native math UI Unicode prose and long links wrap without escaping narrow paragraphs" {
    theme.registerFonts();
    var f = Fixture{ .source = "数学の文章は幅に合わせて折り返されます数学の文章は幅に合わせて折り返されます $\\alpha_i^2$ [averylongsyntheticlabelthatmustwrapacrosslines](https://example.com)." };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 250, .height = 650 });
    defer t.deinit();
    t.settle(4);
    for (t.ctx.nodes.items) |node| {
        if (node.content != .text and node.content != .image) continue;
        const r = t.ctx.rects.get(node.id) orelse continue;
        try testing.expect(r.x >= 19 and r.x + r.w <= 231);
    }
}

test "native math UI inline baseline and narrow wrapping keep equations inside paragraph" {
    theme.registerFonts();
    var f = Fixture{ .source = "Alpha $\\frac{x}{y}$ beta gamma delta epsilon $x_i^n$." };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 250, .height = 500 });
    defer t.deinit();
    t.settle(3);
    var first_image: ?ui.Rect = null;
    var first_prose: ?ui.Rect = null;
    for (t.ctx.nodes.items) |node| {
        const r = t.ctx.rects.get(node.id) orelse continue;
        if (node.content == .image) {
            try testing.expect(r.x >= 19 and r.x + r.w <= 231);
            if (first_image == null) first_image = r;
        }
        if (node.content == .text and std.mem.eql(u8, node.content.text.str, "Alpha ")) first_prose = r;
    }
    try testing.expect(first_image != null and first_prose != null);
    // The fraction rises above the prose but shares the line, not a separate block.
    try testing.expect(first_image.?.y < first_prose.?.y + first_prose.?.h);
    try testing.expect(first_image.?.y + first_image.?.h > first_prose.?.y);
}

const Fixture = struct {
    source: []const u8,
    owner: ?*@import("app.zig").App = null,
    fn view(f: *Fixture, c: *ui.Context) void {
        const page = ui.div(c).column().wFull().p(20);
        defer page.end();
        if (f.owner) |a| @import("view_markdown.zig").withLinks(c, theme.builtin(false), f.source, a, "math") else @import("view_markdown.zig").markdown(c, theme.builtin(false), f.source);
    }
};

fn geometry(source: []const u8, shot: ?[]const u8) !ui.Rect {
    theme.registerFonts();
    var f = Fixture{ .source = source };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 620, .height = 400 });
    defer t.deinit();
    t.settle(3);
    if (shot) |name| if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [2048]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try t.screenshot(path);
    };
    for (t.ctx.nodes.items) |node| {
        if (node.content == .image) return t.ctx.rects.get(node.id) orelse error.MissingEquationRect;
    }
    return error.NativeEquationMissing;
}

test "native math UI paragraph links beside equations still activate their destination" {
    theme.registerFonts();
    var a: @import("app.zig").App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.openChat("math", null);
    var f = Fixture{ .source = "Before $\\frac{x}{y}$ [docs](https://example.com/math) after.", .owner = &a };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 620 });
    defer t.deinit();
    t.settle(4);
    var label: ?ui.Rect = null;
    for (t.ctx.nodes.items) |node| if (node.content == .text and std.mem.startsWith(u8, node.content.text.str, "docs")) {
        label = t.ctx.rects.get(node.id);
        break;
    };
    try testing.expect(label != null);
    t.click(label.?.x + 8, label.?.y + label.?.h / 2);
    t.settle(1);
    try testing.expect(a.panels.pending_browser != null);
    try testing.expectEqualStrings("https://example.com/math", a.panels.pending_browser.?.url);
}

test "native math UI fraction has stacked numerator rule denominator geometry" {
    const frac = try geometry("$$\\frac{a+b}{c}$$", "math-fraction");
    const flat = try geometry("$$a+b/c$$", null);
    try testing.expect(frac.h > flat.h * 1.3);
}

test "native math UI scripts are positioned above and below a baseline" {
    const base = try geometry("$$x$$", null);
    const scripts = try geometry("$$x_i^{n+1}$$", "math-scripts");
    try testing.expect(scripts.h > base.h * 1.3);
    try testing.expect(scripts.w > base.w);
}

test "native math UI radicals enclose their stacked radicand" {
    const base = try geometry("$$\\frac{a}{b}$$", null);
    const root = try geometry("$$\\sqrt[3]{\\frac{a}{b}}$$", "math-root");
    try testing.expect(root.h > base.h);
    try testing.expect(root.w > base.w);
}

test "native math UI matrices retain rows and stretchy delimiters" {
    const one = try geometry("$$\\begin{bmatrix}a&b\\end{bmatrix}$$", null);
    const two = try geometry("$$\\begin{bmatrix}a&b\\\\c&d\\end{bmatrix}$$", "math-matrix");
    try testing.expect(two.h > one.h * 1.3);
}

test "native math UI underbrace annotation and display limits extend both sides" {
    const base = try geometry("$$a+b$$", null);
    const brace = try geometry("$$\\underbrace{a+b}_{n}$$", "math-underbrace");
    try testing.expect(brace.h > base.h * 1.3);
    const sum = try geometry("$$\\sum$$", null);
    const limits = try geometry("$$\\sum_{i=1}^{n}$$", "math-limits");
    try testing.expect(limits.h > sum.h * 1.3);
}
