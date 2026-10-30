//! An agent's Markdown, drawn: paragraphs with bold, italics, inline code
//! and links in place; headings; lists with hanging markers and task
//! boxes; quotes with a bar; tables in a grid; code in a panel with its
//! language, syntax colors and a copy button. After nanoterm's
//! view_markdown.zig (markdown.zig, markdown_html.zig and highlight.zig
//! are nanoterm's, unchanged), without its pictures and diagrams: a
//! picture shows as its alt text.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const md = @import("markdown.zig");
const highlight = @import("highlight.zig");
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");

/// Prose: 14 points on 22-point lines (`render.rs`), set per frame.
var body: ui.TextStyle = .{ .size = 14, .leading = 1.5, .wrap = true };

/// The colors of the Markdown being drawn (the UI thread draws one at a time).
var k: theme.Colors = undefined;
const LinkOwner = struct { app: *@import("app.zig").App, parent: []const u8 };
var link_owner: ?LinkOwner = null;

/// A transcript or workspace preview keeps links in its containing chat,
/// including when a subagent is drawn beside it.
pub fn withLinks(c: *ui.Context, colors: theme.Colors, src: []const u8, a: *@import("app.zig").App, parent: ?[]const u8) void {
    const old = link_owner;
    defer link_owner = old;
    link_owner = if (parent) |p| .{ .app = a, .parent = p } else null;
    markdown(c, colors, src);
}

/// Draws the Markdown `src`.
pub fn markdown(c: *ui.Context, colors: theme.Colors, src: []const u8) void {
    k = colors;
    body = kit.style(c, 14, 22, .{ .wrap = true });
    const blocks = md.parse(c.alloc(), src, .{ .code = k.accent, .code_bg = k.accent_wash, .link = k.text, .muted = k.muted });
    const col = ui.div(c).column().wFull();
    defer col.end();
    for (blocks, 0..) |b, i| {
        // Items of a list sit 4 apart (the list's `gap(4)`); other blocks
        // 12 (`MD_BLOCK_GAP`).
        if (i > 0) {
            const tight = b == .item and blocks[i - 1] == .item;
            _ = c.leaf(.{ .height = .{ .px = if (tight) 4 else 12 } }, .none, null);
        }
        ui.key(c, c.print("md-{d}", .{i}));
        block(c, b, i == 0);
    }
}

fn rich(c: *ui.Context, in: md.Inline, style: ui.TextStyle) void {
    var st = style;
    if (st.color == null) st.color = k.text;
    // Inline code at the text's own size, as `render.rs` sets it (nanoui's
    // `mono_scale`, justrach/nanoui mono-scale; 90% before).
    if (comptime @hasField(ui.TextStyle, "mono_scale")) st.mono_scale = 1;
    // Its wash 2 points past its glyphs, 2 in from the line's box, 4.5
    // round (`INLINE_CODE_PAD_X`, `INLINE_CODE_INSET_Y`,
    // `INLINE_CODE_RADIUS`; nanoui's `span_box`).
    if (comptime @hasField(ui.TextStyle, "span_box")) st.span_box = .{ .pad_x = 2, .inset_y = 2, .radius = 4.5 };
    if (in.links.len == 0 or link_owner == null) return ui.richText(c, in.text, in.spans, st);
    const area = ui.div(c).column().wFull();
    defer area.end();
    const at = c.nodes.items.len;
    ui.richText(c, in.text, in.spans, st);
    const rect = c.rects.get(c.node(@intCast(at)).id) orelse {
        c.changed = true;
        return;
    };
    const origin = c.rects.get(c.node(area.index).id) orelse return;
    const lines = c.text.wrapAttributed(in.text, st, in.spans, rect.w);
    const line_h = c.text.lineHeight(st);
    for (in.links, 0..) |link, li| {
        if (!@import("browser_url.zig").allowedNavigation(link.url)) continue;
        for (lines, 0..) |line, row| {
            const start = @max(@as(usize, link.start), line.start);
            const end = @min(@as(usize, link.end), line.end);
            if (start >= end) continue;
            const x = richWidth(c, in, st, line.start, start);
            const right = richWidth(c, in, st, line.start, end);
            ui.key(c, c.print("link-{d}-{d}", .{ li, row }));
            const hit = @import("view_tooltip.zig").on(ui.div(c).absolute().offset(rect.x - origin.x + x, rect.y - origin.y + @as(f32, @floatFromInt(row)) * line_h).size(@max(right - x, 1), line_h), k, .{ .text = link.url });
            defer hit.end();
            const action = c.interact(hit.index, .{ .focusable = true });
            const activate = action.clicked or (action.focused and (c.shortcut(.{ .key = ui.Shortcut.enter }) or c.shortcut(.{ .key = ' ' })));
            if (activate) {
                const owner = link_owner.?;
                @import("app_browser.zig").openLink(owner.app, owner.parent, link.url);
                c.changed = true;
            }
        }
    }
}

/// The same styled runs used by richText, including bold labels and code.
fn richWidth(c: *ui.Context, in: md.Inline, style: ui.TextStyle, start: usize, end: usize) f32 {
    var at = start;
    var width: f32 = 0;
    for (in.spans) |span| {
        if (span.end <= at or span.start >= end) continue;
        const before = @min(@as(usize, span.start), end);
        if (before > at) {
            width += c.text.width(in.text[at..before], style);
            at = before;
        }
        const stop = @min(@as(usize, span.end), end);
        var st = style;
        st.weight = span.weight orelse st.weight;
        st.italic = span.italic;
        st.mono = span.mono;
        width += c.text.width(in.text[at..stop], st);
        at = stop;
    }
    if (at < end) width += c.text.width(in.text[at..end], style);
    return width;
}

fn block(c: *ui.Context, b: md.Block, first: bool) void {
    switch (b) {
        .paragraph => |in| rich(c, in, body),
        .heading => |h| {
            if (!first) _ = c.leaf(.{ .height = .{ .px = if (h.level <= 2) 6 else 2 } }, .none, null);
            const size: f32, const line: f32 = switch (h.level) {
                1 => .{ 19, 27 },
                2 => .{ 16, 24 },
                3 => .{ 15, 22 },
                else => .{ 14, 22 },
            };
            rich(c, h.text, kit.style(c, size, line, .{ .wrap = true, .weight = .semibold }));
            if (h.level == 1) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        },
        .item => |it| item(c, it),
        .quote => |in| {
            const r = ui.div(c).row().wFull().bg(k.accent.alpha(0.05)).rounded(6);
            defer r.end();
            _ = c.leaf(.{ .width = .{ .px = 2 }, .height = .fill, .background = k.accent.alpha(0.6) }, .none, null);
            var st = body;
            st.color = k.muted;
            const box = ui.div(c).column().grow().pl(12).pr(10).py(6);
            defer box.end();
            rich(c, in, st);
        },
        .rule => _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null),
        .code => |code| codeBlock(c, code.lang, code.text),
        .table => |t| table(c, t.header, t.rows),
    }
}

fn item(c: *ui.Context, it: @FieldType(md.Block, "item")) void {
    const r = ui.div(c).row().wFull().gap(8).pl(@as(f32, @floatFromInt(it.depth)) * 20);
    defer r.end();
    {
        // The marker's column, 18 points at least, so wrapped lines hang.
        const m = ui.div(c).row().minW(18).h(c.text.lineHeight(body)).itemsCenter();
        defer m.end();
        if (it.task) |done| {
            icons.icon(c, .check, 13, if (done) k.success else k.muted, 0);
        } else if (std.mem.eql(u8, it.marker, "•")) {
            _ = c.leaf(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = k.accent, .offset = .{ .x = 1 } }, .none, null);
        } else {
            var st = body;
            st.color = k.accent;
            st.wrap = false;
            ui.text(c, it.marker, st);
        }
    }
    const box = ui.div(c).column().grow();
    defer box.end();
    var st = body;
    if (it.task == true) st.color = k.muted;
    rich(c, it.text, st);
}

fn codeBlock(c: *ui.Context, lang: []const u8, src: []const u8) void {
    // GPUI's `border_1` is inside the box: header and code a point in.
    const box = ui.div(c).column().wFull().bg(k.code_bg).rounded(10).border(k.border).borderW(1).p(1).clip();
    defer box.end();
    {
        // `CODE_HEADER_HEIGHT` 28 with its `border_b_1`, the hairline under it.
        const h = ui.div(c).row().wFull().h(28 - 1).pl(12).pr(5).gap(2).itemsCenter().bg(k.code_header);
        defer h.end();
        ui.text(c, if (lang.len > 0) lang else "code", .{ .size = 11, .color = k.muted });
        ui.spacer(c);
        // The fit toggle (`CodeBlockTooltip`); nano's blocks always scroll.
        _ = kit.iconButton(c, k, .@"wrap-text", .{ .size = 22, .radius = 6, .icon = 13, .tip = .{ .text = "Fit content" } });
        if (kit.iconButton(c, k, .copy, .{ .size = 22, .radius = 5, .icon = 12 })) c.clipboard.write(c.clipboard.ctx, src);
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const pal = k.syntax;
    const lines = ui.div(c).column().wFull().px(12).py(10).gap(0);
    defer lines.end();
    const st = kit.style(c, 12.5, 18, .{ .mono = true, .wrap = true, .color = k.text });
    var in_block: highlight.State = .{};
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, src, "\n"), '\n');
    while (it.next()) |l| {
        const spans = highlight.line(c.alloc(), l, lang, pal, &in_block);
        ui.richText(c, if (l.len == 0) " " else l, spans, st);
    }
}

fn table(c: *ui.Context, header: []const md.Inline, rows: []const []const md.Inline) void {
    const box = ui.div(c).column().wFull().p(1).rounded(8).border(k.border).clip();
    defer box.end();
    tableRow(c, header, true, false);
    for (rows, 0..) |r, i| tableRow(c, r, false, i % 2 == 1);
}

fn tableRow(c: *ui.Context, cells: []const md.Inline, head: bool, zebra: bool) void {
    var r = ui.div(c).row().wFull();
    if (head) r = r.bg(k.code_header) else if (zebra) r = r.bg(k.ink(0.02));
    defer r.end();
    for (cells) |cell| {
        const d = ui.div(c).column().wFull().px(10).py(6);
        defer d.end();
        var st = body;
        st.size = 13;
        st.leading = 1.35;
        if (head) st.weight = .semibold;
        st = kit.style(c, 13, 20, st);
        rich(c, cell, st);
    }
}
