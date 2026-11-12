//! Native equation/prose flow. Ordinary paragraphs stay on richText's fast
//! path. Math paragraphs are wrapped at word boundaries with a shared baseline.
//! A single transparent, geometrically mapped source run per line supplies
//! native selection/Copy; visible fragments are controls, not duplicate text.
const std = @import("std");
const ui = @import("nanoui").ui;
const md = @import("markdown.zig");
const math = @import("native_math.zig");
const Rich = *const fn (*ui.Context, md.Inline, ui.TextStyle) void;

const Fragment = struct {
    start: usize,
    end: usize,
    width: f32,
    ascent: f32,
    depth: f32,
    equation: ?math.Equation = null,
    group: usize = 0,
    display: bool = false,
    hard_break: bool = false,
};
const Line = struct { from: usize, end: usize, width: f32, ascent: f32, depth: f32, centered: bool = false };

pub fn slice(c: *ui.Context, in: md.Inline, start: usize, end: usize) md.Inline {
    var spans: std.ArrayList(ui.Span) = .empty;
    for (in.spans) |span| {
        if (span.end <= start or span.start >= end) continue;
        var s = span;
        s.start = @intCast(@max(start, span.start) - start);
        s.end = @intCast(@min(end, span.end) - start);
        spans.append(c.alloc(), s) catch {};
    }
    var links: std.ArrayList(md.Link) = .empty;
    for (in.links) |link| {
        if (link.end <= start or link.start >= end) continue;
        links.append(c.alloc(), .{ .start = @intCast(@max(start, link.start) - start), .end = @intCast(@min(end, link.end) - start), .url = link.url }) catch {};
    }
    return .{ .text = in.text[start..end], .spans = spans.items, .links = links.items };
}

fn width(c: *ui.Context, in: md.Inline, st: ui.TextStyle) f32 {
    var x: f32 = 0;
    var at: usize = 0;
    for (in.spans) |s| {
        if (s.start > at) x += c.text.width(in.text[at..s.start], st);
        var style = st;
        style.weight = s.weight orelse st.weight;
        style.mono = s.mono;
        style.italic = s.italic;
        x += c.text.width(in.text[s.start..s.end], style);
        at = s.end;
    }
    if (at < in.text.len) x += c.text.width(in.text[at..], st);
    return x;
}

pub fn draw(c: *ui.Context, in: md.Inline, style: ui.TextStyle, color: ui.Color, rich: Rich) void {
    const area = ui.div(c).column().wFull();
    defer area.end();
    const old = c.rects.get(c.node(area.index).id);
    if (old == null) c.changed = true;
    const room = @max(1, if (old) |r| r.w else c.size.w - 40);
    var st = style;
    st.wrap = false;
    const font = c.text.font(st);
    const lh = c.text.lineHeight(st);
    const ascent = (lh - font.ascent - font.descent) / 2 + font.ascent;
    const depth = lh - ascent;
    var fs: std.ArrayList(Fragment) = .empty;
    var at: usize = 0;
    var mi: usize = 0;
    var group: usize = 0;
    while (at < in.text.len) {
        if (mi < in.maths.len and at == in.maths[mi].start) {
            const m = in.maths[mi];
            var bold = @backingInt(st.weight) >= @backingInt(ui.Weight.semibold);
            for (in.spans) |span| if (span.start <= m.start and span.end >= m.end and span.weight != null) {
                bold = @backingInt(span.weight.?) >= @backingInt(ui.Weight.semibold);
                break;
            };
            const source = if (bold) c.print("\\boldsymbol{{{s}}}", .{m.source}) else m.source;
            var equation = math.layout(c.alloc(), source, m.display, st.size, st.color orelse color);
            var w: f32 = 0;
            var a = ascent;
            var d = depth;
            if (equation) |*eq| {
                const scale = @min(1, room / eq.width);
                eq.width *= scale;
                eq.height *= scale;
                eq.ascent *= scale;
                eq.depth *= scale;
                w = eq.width;
                a = eq.ascent;
                d = eq.depth;
            } else {
                w = width(c, slice(c, in, at, m.end), st);
            }
            fs.append(c.alloc(), .{ .start = at, .end = m.end, .width = w, .ascent = a, .depth = d, .equation = equation, .group = group, .display = m.display }) catch return;
            at = m.end;
            mi += 1;
            continue;
        }
        const stop = if (mi < in.maths.len) in.maths[mi].start else in.text.len;
        const start = at;
        if (in.text[at] == '\n') {
            at += 1;
            fs.append(c.alloc(), .{ .start = start, .end = at, .width = 0, .ascent = ascent, .depth = depth, .group = group, .hard_break = true }) catch return;
            group += 1;
            continue;
        }
        while (at < stop and in.text[at] != ' ' and in.text[at] != '\t' and in.text[at] != '\n') at += 1;
        while (at < stop and (in.text[at] == ' ' or in.text[at] == '\t')) at += 1;
        const ends_word = at > start and (in.text[at - 1] == ' ' or in.text[at - 1] == '\t');
        const prose = slice(c, in, start, at);
        const prose_width = width(c, prose, st);
        if (prose_width > room) {
            // Use the same shaped-glyph breaker as ordinary richText for
            // CJK and overlong words/URLs; never cut UTF-8 or combining glyphs.
            const wrapped = c.text.wrapAttributed(prose.text, st, prose.spans, room);
            for (wrapped, 0..) |part, pi| {
                const end = if (pi + 1 < wrapped.len) wrapped[pi + 1].start else prose.text.len;
                fs.append(c.alloc(), .{ .start = start + part.start, .end = start + end, .width = width(c, slice(c, in, start + part.start, start + end), st), .ascent = ascent, .depth = depth, .group = group }) catch return;
                group += 1;
            }
        } else {
            fs.append(c.alloc(), .{ .start = start, .end = at, .width = prose_width, .ascent = ascent, .depth = depth, .group = group }) catch return;
            if (ends_word) group += 1;
        }
    }
    var lines: std.ArrayList(Line) = .empty;
    var line = Line{ .from = 0, .end = 0, .width = 0, .ascent = ascent, .depth = depth };
    var i: usize = 0;
    while (i < fs.items.len) {
        const f = fs.items[i];
        var end = i + 1;
        var w = f.width;
        while (end < fs.items.len and fs.items[end].group == f.group and !fs.items[end].display and !f.display and !fs.items[end].hard_break) : (end += 1) w += fs.items[end].width;
        if (i > line.from and (line.width + w > room or f.display)) {
            lines.append(c.alloc(), line) catch return;
            line = .{ .from = i, .end = i, .width = 0, .ascent = ascent, .depth = depth };
        }
        for (fs.items[i..end]) |frag| {
            line.width += frag.width;
            line.ascent = @max(line.ascent, frag.ascent);
            line.depth = @max(line.depth, frag.depth);
        }
        line.end = end;
        line.centered = f.display;
        if (f.display or f.hard_break) {
            lines.append(c.alloc(), line) catch return;
            line = .{ .from = end, .end = end, .width = 0, .ascent = ascent, .depth = depth };
        }
        i = end;
    }
    if (line.end > line.from) lines.append(c.alloc(), line) catch return;
    for (lines.items, 0..) |ln, li| {
        ui.key(c, c.print("equation-line-{d}", .{li}));
        const row = ui.div(c).wFull().h(ln.ascent + ln.depth);
        defer row.end();
        var x: f32 = if (ln.centered) @max(0, (room - ln.width) / 2) else 0;
        const start_x = x;
        for (fs.items[ln.from..ln.end]) |f| {
            if (f.hard_break) continue;
            const box = ui.div(c).absolute().offset(x, ln.ascent - f.ascent).size(f.width, f.ascent + f.depth).control();
            if (f.equation) |eq| {
                if (!ui.svg(c, .{ .key = eq.svg, .bytes = eq.svg, .width = eq.width, .height = eq.height })) rich(c, slice(c, in, f.start, f.end), st);
            } else rich(c, slice(c, in, f.start, f.end), st);
            box.end();
            x += f.width;
        }
        // A continuous source run prevents Copy from inserting a newline
        // between every word or replacing equations by their visual glyphs.
        const first = fs.items[ln.from].start;
        var last = fs.items[ln.end - 1].end;
        if (last > first and in.text[last - 1] == '\n') last -= 1;
        if (last <= first) continue;
        const source = in.text[first..last];
        const raw = c.text.layout(source, st);
        const glyphs = c.alloc().dupe(@TypeOf(raw.glyphs[0]), raw.glyphs) catch return;
        var fx = start_x;
        var gi: usize = 0;
        for (fs.items[ln.from..ln.end]) |f| {
            if (f.hard_break) continue;
            const lo = f.start - first;
            const hi = @min(last, f.end) - first;
            const raw_width = c.text.width(source[lo..hi], st);
            const raw_start = if (gi < glyphs.len) glyphs[gi].x else raw.width;
            while (gi < glyphs.len and glyphs[gi].index < hi) : (gi += 1) {
                glyphs[gi].x = fx + (glyphs[gi].x - raw_start) * f.width / @max(1, raw_width);
            }
            fx += f.width;
        }
        var invisible = st;
        invisible.color = ui.Color.transparent;
        invisible.line_height = ln.ascent + ln.depth;
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = ln.ascent + ln.depth }, .selectable = true }, .{ .text = .{
            .str = source,
            .style = invisible,
            .color = .transparent,
            .cut_lay = .{ .glyphs = glyphs, .width = fx },
        } }, null);
    }
}
