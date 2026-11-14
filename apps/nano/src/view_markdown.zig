//! An agent's Markdown, drawn: paragraphs with bold, italics, inline code
//! and links in place; headings; lists with hanging markers and task
//! boxes; quotes with a bar; tables in a grid; code in a panel with its
//! language, syntax colors and a copy button. After nanoterm's
//! view_markdown.zig (markdown.zig, markdown_html.zig and highlight.zig
//! are nanoterm's, unchanged). Reply pictures use the containing chat's
//! host-jailed attachment loader; unavailable sources retain their alt text.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const md = @import("markdown.zig");
const cache_mod = @import("markdown_cache.zig");
var active_cache: ?*cache_mod.Cache = null;
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const veil_mod = @import("veil.zig");

/// Prose: 15 points on 22.5-point lines (`typography.rs`), set per frame.
var body: ui.TextStyle = .{ .size = 15, .leading = 1.5, .wrap = true };

/// The colors of the Markdown being drawn (the UI thread draws one at a time).
var k: theme.Colors = theme.fallback(true);
const LinkOwner = struct { app: *@import("app.zig").App, parent: []const u8 };
var link_owner: ?LinkOwner = null;
var active_veil: ?*veil_mod.RowVeil = null;
var active_streaming: bool = false;
var veil_now_ms: f64 = 0;
var current_elem_ix: usize = 0;
var provider_mode: bool = false;
var mermaid_source_ids: [32]u64 = @splat(0);
var mermaid_source_len: usize = 0;

fn mermaidShowsSource(id: u64) bool {
    for (mermaid_source_ids[0..mermaid_source_len]) |k_id| if (k_id == id) return true;
    return false;
}

fn toggleMermaidSource(id: u64) void {
    for (mermaid_source_ids[0..mermaid_source_len], 0..) |k_id, i| {
        if (k_id == id) {
            mermaid_source_ids[i] = mermaid_source_ids[mermaid_source_len - 1];
            mermaid_source_len -= 1;
            return;
        }
    }
    if (mermaid_source_len < mermaid_source_ids.len) {
        mermaid_source_ids[mermaid_source_len] = id;
        mermaid_source_len += 1;
    } else {
        mermaid_source_ids[0] = id;
    }
}

/// A transcript or workspace preview keeps links in its containing chat,
/// including when a subagent is drawn beside it.
pub fn withLinks(c: *ui.Context, colors: theme.Colors, src: []const u8, a: *@import("app.zig").App, parent: ?[]const u8) void {
    withLinksVeil(c, colors, src, a, parent, null, false);
}

/// Draws Markdown `src` with optional streaming fade-in veil and live
/// inline-mark balancing.
pub fn withLinksVeil(
    c: *ui.Context,
    colors: theme.Colors,
    src: []const u8,
    a: *@import("app.zig").App,
    parent: ?[]const u8,
    row_veil: ?*veil_mod.RowVeil,
    streaming: bool,
) void {
    const old_cache = active_cache;
    active_cache = &a.markdown_cache;
    defer active_cache = old_cache;
    const old_owner = link_owner;
    const old_veil = active_veil;
    const old_streaming = active_streaming;
    const old_now = veil_now_ms;
    const old_elem = current_elem_ix;
    defer {
        link_owner = old_owner;
        active_veil = old_veil;
        active_streaming = old_streaming;
        veil_now_ms = old_now;
        current_elem_ix = old_elem;
    }
    link_owner = if (parent) |p| .{ .app = a, .parent = p } else null;
    active_veil = row_veil;
    active_streaming = streaming;
    veil_now_ms = c.time * 1000.0;
    current_elem_ix = 0;
    markdown(c, colors, src);
}

/// Native provider prose, without transcript or navigation capabilities.
/// Cached parses remain immutable: only the rendered inline views lose their
/// image/link metadata, retaining selectable labels, alt text and formatting.
/// Opening the canonical provider page belongs to the caller's explicit action.
pub fn providerMarkdown(c: *ui.Context, colors: theme.Colors, src: []const u8, a: *@import("app.zig").App) void {
    const old_cache = active_cache;
    const old_owner = link_owner;
    const old_veil = active_veil;
    const old_streaming = active_streaming;
    const old_now = veil_now_ms;
    const old_elem = current_elem_ix;
    const old_mode = provider_mode;
    const old_colors = k;
    const old_body = body;
    defer {
        active_cache = old_cache;
        link_owner = old_owner;
        active_veil = old_veil;
        active_streaming = old_streaming;
        veil_now_ms = old_now;
        current_elem_ix = old_elem;
        provider_mode = old_mode;
        k = old_colors;
        body = old_body;
    }
    active_cache = &a.markdown_cache;
    link_owner = null;
    active_veil = null;
    active_streaming = false;
    veil_now_ms = 0;
    current_elem_ix = 0;
    provider_mode = true;
    markdown(c, colors, src);
}

/// Draws the Markdown `src`.
pub fn markdown(c: *ui.Context, colors: theme.Colors, src: []const u8) void {
    k = colors;
    body = kit.style(c, 15, 22.5, .{ .wrap = true });
    const src_in = if (active_streaming) veil_mod.balanceStreamingMarkdown(c.alloc(), src) else src;
    const palette: md.Palette = .{ .code = k.accent, .code_bg = k.accent_wash, .link = k.text, .muted = k.muted };
    const blocks = if (active_cache) |cache| cache.parse(c.gpa, c.alloc(), src_in, palette) else md.parse(c.alloc(), src_in, palette);
    const col = ui.div(c).column().wFull();
    c.node(col.index).style.selectable = true;
    defer col.end();
    for (blocks, 0..) |b, i| {
        // Items of a list sit 4 apart (the list's `gap(4)`); other blocks
        // 12 (`MD_BLOCK_GAP`).
        if (i > 0) {
            const tight = b == .item and blocks[i - 1] == .item;
            _ = c.leaf(.{ .height = .{ .px = if (tight) 4 else 12 } }, .none, null);
        }
        current_elem_ix = i * 64;
        ui.key(c, c.print("md-{d}", .{i}));
        block(c, b, i == 0);
    }
    if (active_veil) |v| {
        v.finishSeeding();
        if (v.isFading()) c.frameIn(1.0 / 120.0);
    }
}

fn rich(c: *ui.Context, in: md.Inline, style: ui.TextStyle) void {
    if (provider_mode and (in.images.len > 0 or in.links.len > 0)) {
        var prose = in;
        prose.images = &.{};
        prose.links = &.{};
        return rich(c, prose, style);
    }
    if (in.images.len > 0) {
        // Preserve the exact selectable text, styled runs, links and native
        // equations. Pictures follow that prose instead of replacing ranges
        // (which would invalidate all three sets of byte offsets).
        var prose = in;
        prose.images = &.{};
        rich(c, prose, style);
        for (in.images, 0..) |image, i| {
            ui.key(c, c.print("md-picture-{d}", .{i}));
            const alt = in.text[image.start..image.end];
            if (link_owner) |owner| {
                @import("view_reply_images.zig").draw(c, owner.app, k, owner.parent, image.src, alt, image.width);
            } else {
                ui.text(c, c.print("Image unavailable{s}{s}", .{ if (alt.len > 0) ": " else "", alt }), .{ .size = 12, .color = k.muted, .wrap = true });
            }
        }
        return;
    }
    var st = style;
    if (st.color == null) st.color = k.text;
    // Inline code at the text's own size, as `render.rs` sets it (nanoui's
    // `mono_scale`, justrach/nanoui mono-scale; 90% before).
    if (comptime @hasField(ui.TextStyle, "mono_scale")) st.mono_scale = 1;
    // Its wash 2 points past its glyphs, 2 in from the line's box, 4.5
    // round (`INLINE_CODE_PAD_X`, `INLINE_CODE_INSET_Y`,
    // `INLINE_CODE_RADIUS`; nanoui's `span_box`).
    if (comptime @hasField(ui.TextStyle, "span_box")) st.span_box = .{ .pad_x = 2, .inset_y = 2, .radius = 4.5 };
    if (in.maths.len > 0) return @import("native_math_flow.zig").draw(c, in, st, k.text, rich);
    const spans: []const ui.Span = if (active_veil) |v| blk: {
        const v_spans = v.advance(c.gpa, c.alloc(), current_elem_ix, in.text, veil_now_ms);
        current_elem_ix += 1;
        break :blk veil_mod.applyVeil(c.alloc(), in.text.len, in.spans, v_spans, st.color orelse k.text);
    } else in.spans;
    if (in.links.len == 0) return ui.richText(c, in.text, spans, st);
    const area = ui.div(c).column().wFull();
    defer area.end();
    const at = c.nodes.items.len;
    ui.richText(c, in.text, spans, st);
    const rect = c.rects.get(c.node(@intCast(at)).id) orelse {
        if (link_owner) |owner| {
            if (owner.app.window == null or owner.app.offscreen) c.changed = true else c.frameIn(0);
        } else {
            c.changed = true;
        }
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
            if (link_owner) |owner| @import("view_link_menu.zig").track(c, owner.app, owner.parent, link.url, hit.index, action.right_clicked or action.secondary_clicked);
            const activate = action.clicked or (action.focused and (c.shortcut(.{ .key = ui.Shortcut.enter }) or c.shortcut(.{ .key = ' ' })));
            if (activate) {
                if (link_owner) |owner| {
                    @import("app_browser.zig").openLink(owner.app, owner.parent, link.url);
                } else {
                    _ = nanoui.shell.openUrl(link.url);
                }
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
        .math => |in| {
            ui.key(c, "md-math-block");
            const box = ui.div(c).row().wFull().px(14).py(10).rounded(8).bg(k.ink(0.03)).justifyCenter();
            defer box.end();
            rich(c, in, kit.style(c, 16, 24, .{ .wrap = true }));
        },
        .code => |code| codeBlock(c, code.lang, code.text),
        .table => |t| table(c, t.header, t.rows),
    }
}

fn item(c: *ui.Context, it: @FieldType(md.Block, "item")) void {
    const r = ui.div(c).row().wFull().gap(8).pl(@as(f32, @floatFromInt(it.depth)) * 20);
    defer r.end();
    {
        // The marker's column, 18 points at least, so wrapped lines hang.
        const m = ui.div(c).row().minW(18).h(c.text.lineHeight(body)).itemsCenter().control();
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
    const is_mermaid = std.ascii.eqlIgnoreCase(lang, "mermaid");
    const parsed_mermaid = if (is_mermaid) @import("mermaid.zig").parse(c.alloc(), src) else @import("mermaid.zig").Diagram{ .other = "" };
    const can_draw_mermaid = is_mermaid and parsed_mermaid.drawable();
    const block_id = c.peekId("code-block");
    const show_source = !can_draw_mermaid or mermaidShowsSource(block_id);
    // GPUI's `border_1` is inside the box: header and code a point in.
    const box = ui.div(c).column().wFull().bg(k.code_bg).rounded(10).border(k.border).borderW(1).p(1).clip();
    defer box.end();
    {
        // `CODE_HEADER_HEIGHT` 28 with its `border_b_1`, the hairline under it.
        const h = ui.div(c).row().wFull().h(28 - 1).pl(12).pr(5).gap(2).itemsCenter().bg(k.code_header).control();
        defer h.end();
        ui.text(c, if (lang.len > 0) lang else "code", .{ .size = 11, .color = k.muted });
        ui.spacer(c);
        if (can_draw_mermaid) {
            ui.key(c, "mermaid-source-toggle");
            if (kit.iconButton(c, k, if (show_source) .eye else .@"file-code", .{ .size = 22, .radius = 6, .icon = 13, .tip = .{ .text = if (show_source) "Show diagram" else "Show source" } })) {
                toggleMermaidSource(block_id);
                c.changed = true;
            }
        }
        if (show_source) {
            // The fit toggle (`CodeBlockTooltip`); nano's blocks always scroll.
            _ = kit.iconButton(c, k, .@"wrap-text", .{ .size = 22, .radius = 6, .icon = 13, .tip = .{ .text = "Fit content" } });
        }
        if (kit.iconButton(c, k, .copy, .{ .size = 22, .radius = 5, .icon = 12 })) c.clipboard.write(c.clipboard.ctx, src);
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    if (can_draw_mermaid and !show_source) {
        ui.key(c, "mermaid-diagram");
        const d = ui.div(c).column().wFull().p(12);
        defer d.end();
        const fallback_room = if (link_owner) |o| @max(220, @min(@import("view_transcript.zig").paneWidth(c, o.app) - 32, @import("view_transcript.zig").column_w) - 26) else @max(220, c.size.w - 200);
        const room = if (c.rects.get(c.node(d.index).id)) |r| (if (r.w > 40) r.w - 24 else fallback_room) else fallback_room;
        if (@import("view_mermaid.zig").draw(c, parsed_mermaid, room, k)) return;
    }
    const pal = k.syntax;
    const lines = ui.div(c).column().wFull().px(12).py(10).gap(0);
    defer lines.end();
    const st = kit.style(c, 12.5, 18, .{ .mono = true, .wrap = true, .color = k.text });
    const trimmed_src = std.mem.trimEnd(u8, src, "\n");
    const code_veils: []const veil_mod.VeilSpan = if (active_veil) |v| blk: {
        const vs = v.advance(c.gpa, c.alloc(), current_elem_ix, trimmed_src, veil_now_ms);
        current_elem_ix += 1;
        break :blk vs;
    } else &.{};
    var line_offset: usize = 0;
    const highlighted = if (active_cache) |cache| cache.highlight(c.gpa, c.alloc(), trimmed_src, lang, pal) else cache_mod.highlightLines(c.alloc(), trimmed_src, lang, pal);
    for (highlighted) |line| {
        const l = line.text;
        const raw_spans = line.spans;
        const spans: []const ui.Span = if (code_veils.len > 0 and l.len > 0) blk: {
            const local = veil_mod.sliceSpans(c.alloc(), code_veils, line_offset, line_offset + l.len);
            break :blk veil_mod.applyVeil(c.alloc(), l.len, raw_spans, local, st.color orelse k.text);
        } else raw_spans;
        ui.richText(c, if (l.len == 0) " " else l, spans, st);
        line_offset += l.len + 1;
    }
}

fn table(c: *ui.Context, header: []const md.Inline, rows: []const []const md.Inline) void {
    const cols = tableCols(header, rows);
    if (cols == 0) return;
    // GPUI sizes a cell by its content (`table_columns`), not an equal
    // share of the row. Equal fill made a narrow pane wrap one word a line,
    // so the rest of the cell — the text on the right — never appeared.
    var content: [16]f32 = @splat(0);
    var min_words: [16]f32 = @splat(0);
    const n = @min(cols, content.len);
    measureTable(c, header, &content, &min_words, n, true);
    for (rows) |r| measureTable(c, r, &content, &min_words, n, false);
    const box = ui.div(c).column().wFull().p(1).rounded(8).border(k.border);
    const fallback_room = if (link_owner) |o| @max(220, @min(@import("view_transcript.zig").paneWidth(c, o.app) - 32, @import("view_transcript.zig").column_w) - 2) else 0;
    const room = if (c.rects.get(c.node(box.index).id)) |r| @max(0, r.w - 2) else fallback_room;
    var widths: [16]f32 = @splat(0);
    columnWidthsWithWords(content[0..n], min_words[0..n], room, widths[0..n]);
    defer box.end();
    tableRow(c, header, widths[0..n], true, false);
    for (rows, 0..) |r, i| tableRow(c, r, widths[0..n], false, i % 2 == 1);
}

fn tableCols(header: []const md.Inline, rows: []const []const md.Inline) usize {
    var n = header.len;
    for (rows) |r| n = @max(n, r.len);
    return n;
}

fn measureTable(c: *ui.Context, cells: []const md.Inline, content: []f32, min_words: []f32, n: usize, head: bool) void {
    var st = body;
    st.size = 13;
    st.leading = 1.35;
    st.wrap = false;
    if (head) st.weight = .semibold;
    st = kit.style(c, 13, 20, st);
    for (cells, 0..) |cell, i| {
        if (i >= n) break;
        content[i] = @max(content[i], richWidth(c, cell, st, 0, cell.text.len));
        min_words[i] = @max(min_words[i], longestWordWidth(c, cell, st));
    }
}

/// Width of the widest whitespace-delimited word token in `cell` (capped at
/// 136pt so a long path/URL does not force a wide column floor, while ordinary
/// words like "Comprehensive" or "conversations" never wrap mid-word).
fn longestWordWidth(c: *ui.Context, cell: md.Inline, st: ui.TextStyle) f32 {
    var best: f32 = 0;
    var i: usize = 0;
    const s = cell.text;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
        const start = i;
        while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n' and s[i] != '\r') : (i += 1) {}
        if (i > start) {
            const w = @ceil(richWidth(c, cell, st, start, i));
            best = @max(best, @min(w, 136));
        }
    }
    return best;
}

/// Content-proportional column widths (`table_columns` / `flex_grow(natural)`),
/// with Taffy-style per-column minimum floors (`TABLE_MIN_COLUMN_WIDTH = 96`
/// plus longest-word protection) and demand capped at `room` so multi-sentence
/// prose columns cannot crush a label column into mid-word character wrapping.
fn columnWidths(content: []const f32, room: f32, out: []f32) void {
    var zero_words: [16]f32 = @splat(0);
    columnWidthsWithWords(content, zero_words[0..content.len], room, out);
}

fn columnWidthsWithWords(content: []const f32, min_words: []const f32, room: f32, out: []f32) void {
    const n = content.len;
    if (n == 0) return;
    var sum: f32 = 0;
    for (content) |w| sum += @max(w, 48);
    if (sum < 1 or room < 1) {
        for (content, 0..) |w, i| out[i] = @max(w, 48) + 20;
        return;
    }

    // Per-column natural width, demand weight (capped at `room` because no
    // column in a table of width `room` can render wider than `room` on one
    // line), and minimum floor (at least 96pt or longest word + 22pt padding,
    // bounded by the column's own natural width and a fair share of `room`).
    var weights: [16]f32 = @splat(0);
    var floors: [16]f32 = @splat(0);
    const max_floor = room / @as(f32, @floatFromInt(n)) * 0.85;
    var floor_sum: f32 = 0;
    for (content, 0..) |w, i| {
        const nat = @max(w, 48);
        weights[i] = @min(nat, room);
        const word_pad = if (i < min_words.len and min_words[i] > 0) min_words[i] + 22 else 0;
        const desired_floor = @min(nat, @max(96, @min(word_pad, 158)));
        floors[i] = @min(desired_floor, max_floor);
        floor_sum += floors[i];
    }
    if (floor_sum > room and floor_sum > 0) {
        const scale = room / floor_sum;
        for (0..n) |i| floors[i] *= scale;
    }

    var locked: [16]bool = @splat(false);
    var remaining_room = room;
    var pass: usize = 0;
    while (pass < n) : (pass += 1) {
        var weight_sum: f32 = 0;
        for (0..n) |i| if (!locked[i]) {
            weight_sum += weights[i];
        };
        if (weight_sum <= 0) break;
        var any_locked = false;
        for (0..n) |i| if (!locked[i]) {
            const share = remaining_room * (weights[i] / weight_sum);
            if (share < floors[i]) {
                out[i] = floors[i];
                locked[i] = true;
                remaining_room = @max(0, remaining_room - floors[i]);
                any_locked = true;
            } else {
                out[i] = share;
            }
        };
        if (!any_locked) break;
    }
}

fn tableRow(c: *ui.Context, cells: []const md.Inline, widths: []const f32, head: bool, zebra: bool) void {
    var r = ui.div(c).row().wFull();
    if (head) r = r.bg(k.code_header) else if (zebra) r = r.bg(k.ink(0.02));
    defer r.end();
    for (widths, 0..) |width, i| {
        const cell = if (i < cells.len) cells[i] else md.Inline{ .text = "", .spans = &.{}, .links = &.{} };
        const d = ui.div(c).column().w(width).px(10).py(6);
        defer d.end();
        var st = body;
        st.size = 13;
        st.leading = 1.35;
        if (head) st.weight = .semibold;
        st = kit.style(c, 13, 20, st);
        rich(c, cell, st);
    }
}

test "remote markdown scopes inherited transcript state and restores it exactly" {
    const testing = std.testing;
    const Fixture = struct {
        app: @import("app.zig").App,
        cache: cache_mod.Cache = .{},
        veil: veil_mod.RowVeil = .{ .seeding = true },
        restored: bool = false,

        fn view(f: *@This(), c: *ui.Context) void {
            const previous = .{ active_cache, link_owner, active_veil, active_streaming, veil_now_ms, current_elem_ix, provider_mode, k, body };
            defer {
                active_cache = previous[0];
                link_owner = previous[1];
                active_veil = previous[2];
                active_streaming = previous[3];
                veil_now_ms = previous[4];
                current_elem_ix = previous[5];
                provider_mode = previous[6];
                k = previous[7];
                body = previous[8];
            }
            const old_colors = theme.fallback(false);
            const old_body: ui.TextStyle = .{ .size = 17, .leading = 1.25 };
            active_cache = &f.cache;
            link_owner = .{ .app = &f.app, .parent = "synthetic-owner" };
            active_veil = &f.veil;
            active_streaming = true;
            veil_now_ms = 123;
            current_elem_ix = 19;
            provider_mode = false;
            k = old_colors;
            body = old_body;
            providerMarkdown(c, theme.fallback(true), "*Provider tail\n\n![Retained alt](picture.png) [Label](https://example.invalid)", &f.app);
            f.restored = active_cache == &f.cache and active_veil == &f.veil and
                active_streaming and veil_now_ms == 123 and current_elem_ix == 19 and
                !provider_mode and std.meta.eql(k, old_colors) and std.meta.eql(body, old_body);
            if (link_owner) |owner| {
                f.restored = f.restored and owner.app == &f.app and std.mem.eql(u8, owner.parent, "synthetic-owner");
            } else f.restored = false;
        }
    };
    theme.registerFonts();
    var f: Fixture = .{ .app = .init(testing.allocator, testing.io, 1) };
    defer f.app.deinit();
    defer f.cache.deinit();
    defer f.veil.deinit(testing.allocator);
    f.app.offscreen = true;
    var tester: ui.Tester = undefined;
    try tester.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 620, .height = 500 });
    defer tester.deinit();
    tester.settle(3);
    try testing.expect(f.restored);
    try testing.expect(f.cache.arena == null);
    try testing.expect(f.app.markdown_cache.arena != null);
    try testing.expect(f.veil.seeding);
    try testing.expectEqual(@as(usize, 0), f.veil.elems.count());
    try testing.expect(tester.hasText("*Provider tail"));
    try testing.expect(tester.containsText("Retained alt"));
    try testing.expectEqual(@as(usize, 0), tester.ctx.hits.items.len);
    try testing.expectEqual(@as(usize, 0), f.app.attachments.images.items.items.len);
}

test "a wide table cell keeps its share instead of an equal slice" {
    const content = [_]f32{ 400, 40, 40 };
    var widths: [3]f32 = undefined;
    columnWidths(&content, 520, &widths);
    try std.testing.expect(widths[0] > widths[1] * 4);
    try std.testing.expectApproxEqAbs(@as(f32, 520), widths[0] + widths[1] + widths[2], 0.5);
    columnWidths(&content, 0, &widths);
    try std.testing.expect(widths[0] >= 400);
}

test "a label column beside multi-sentence prose columns keeps its word floor in a split pane" {
    const content = [_]f32{ 230, 1100, 950 };
    const min_words = [_]f32{ 104, 88, 92 };
    var widths: [3]f32 = undefined;
    columnWidthsWithWords(&content, &min_words, 460, &widths);
    try std.testing.expect(widths[0] >= 126);
    try std.testing.expect(widths[1] >= 150);
    try std.testing.expect(widths[2] >= 150);
    try std.testing.expectApproxEqAbs(@as(f32, 460), widths[0] + widths[1] + widths[2], 0.5);
}
