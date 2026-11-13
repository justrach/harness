//! Native GPU Mermaid renderer for `harness-nano` (ported from `nanodocs`).
//!
//! Renders `mermaid.Diagram` ASTs (`flow`, `seq`, `pie`) directly to `nanoui`
//! GPU primitives using the active `theme.Colors` palette.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const mm = @import("mermaid.zig");
const seq_mod = @import("view_mermaid_seq.zig");

pub const label_style: ui.TextStyle = .{ .size = 12.5, .weight = .medium };
pub const small_style: ui.TextStyle = .{ .size = 11.5 };

pub const Palette = struct {
    bg: ui.Color,
    card: ui.Color,
    code_bg: ui.Color,
    ink: ui.Color,
    muted: ui.Color,
    border: ui.Color,
    accent: ui.Color,

    pub fn fromTheme(k: theme.Colors) Palette {
        return .{
            .bg = k.panel,
            .card = k.code_header,
            .code_bg = k.code_bg,
            .ink = k.text,
            .muted = k.muted,
            .border = k.border,
            .accent = k.accent,
        };
    }
};

pub fn draw(c: *ui.Context, d: mm.Diagram, room: f32, k: theme.Colors) bool {
    const pal = Palette.fromTheme(k);
    switch (d) {
        .flow => |f| if (f.nodes.len > 0) flow(c, f, room, pal) else return false,
        .seq => |s| if (s.actors.len > 0) seq_mod.seq(c, s, room, pal) else return false,
        .pie => |p| if (p.slices.len > 0) pie(c, p, pal) else return false,
        .other => return false,
    }
    return true;
}

pub fn rect(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, color: ui.Color, radius: f32) void {
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = @max(w, 0) },
        .height = .{ .px = @max(h, 0) },
        .background = color,
        .radius = radius,
    }, .none, null);
}

pub fn panel(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, fill: ui.Color, edge: ui.Color, radius: f32) void {
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = w },
        .height = .{ .px = h },
        .background = fill,
        .border = edge,
        .border_width = 1.25,
        .radius = radius,
    }, .none, null);
}

pub fn label(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, text: []const u8, style: ui.TextStyle) void {
    const box = ui.div(c).absolute().offset(x, y).w(w).h(h).column().itemsCenter().justifyCenter();
    defer box.end();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| ui.text(c, l, style);
}

pub fn measure(c: *ui.Context, text: []const u8, style: ui.TextStyle) [2]f32 {
    var w: f32 = 0;
    var n: f32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        w = @max(w, c.text.width(l, style));
        n += 1;
    }
    return .{ @ceil(w), n * c.text.lineHeight(style) };
}

pub fn line(c: *ui.Context, x0: f32, y0: f32, x1: f32, y1: f32, kind: mm.Line, color: ui.Color) void {
    if (kind == .invisible) return;
    const t: f32 = if (kind == .thick) 2.5 else 1.4;
    const horizontal = @abs(y1 - y0) < 0.5;
    const a = if (horizontal) @min(x0, x1) else @min(y0, y1);
    const b = if (horizontal) @max(x0, x1) else @max(y0, y1);
    if (kind != .dotted) {
        if (horizontal) rect(c, a, y0 - t / 2, b - a, t, color, 0) else rect(c, x0 - t / 2, a, t, b - a + t / 2, color, 0);
        return;
    }
    var p = a;
    while (p < b) : (p += 10) {
        const len = @min(5, b - p);
        if (horizontal) rect(c, p, y0 - t / 2, len, t, color, 0) else rect(c, x0 - t / 2, p, t, len, color, 0);
    }
}

pub fn arrow(c: *ui.Context, x: f32, y: f32, dir: mm.Dir, color: ui.Color) void {
    const len: f32 = 8;
    const half: f32 = 4.5;
    var k: f32 = 0;
    while (k < len) : (k += 1) {
        const w = 2 * half * (k + 1) / len;
        switch (dir) {
            .down => rect(c, x - w / 2, y - k - 1, w, 1.2, color, 0),
            .up => rect(c, x - w / 2, y + k, w, 1.2, color, 0),
            .right => rect(c, x - k - 1, y - w / 2, 1.2, w, color, 0),
            .left => rect(c, x + k, y - w / 2, 1.2, w, color, 0),
        }
    }
}

fn strips(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, fill: ui.Color, edge: ui.Color, comptime half: fn (f32) f32) void {
    const step: f32 = 1.5;
    var row: f32 = 0;
    while (row < h) : (row += step) {
        const hw = half((row + step / 2) / h) * w / 2;
        rect(c, x + w / 2 - hw - 0.75, y + row, 2 * hw + 1.5, step, edge, 0);
    }
    row = 1.5;
    while (row < h - 1.5) : (row += step) {
        const hw = half((row + step / 2) / h) * w / 2 - 1.75;
        if (hw > 0) rect(c, x + w / 2 - hw, y + row, 2 * hw, step, fill, 0);
    }
}

fn diamondHalf(t: f32) f32 {
    return 1 - @abs(2 * t - 1);
}

fn hexagonHalf(t: f32) f32 {
    return @min(1, 0.72 + 0.28 * (1 - @abs(2 * t - 1)) / 0.5);
}

const Box = struct { x: f32 = 0, y: f32 = 0, w: f32, h: f32, rank: usize = 0, r0: f32 = 0, r1: f32 = 0, lab: f32 = 0 };

const Pass = enum { lines, labels };
const label_room: f32 = 20;
const trunk_room: f32 = 16;
const min_scale: f32 = 0.38;

fn flow(c: *ui.Context, f: mm.Flow, room: f32, pal: Palette) void {
    const a = c.alloc();
    const n = f.nodes.len;
    const boxes = a.alloc(Box, n) catch return;
    for (f.nodes, boxes, 0..) |node, *b, i| {
        const sz = measure(c, node.label, label_style);
        const r = if (i < f.ranks.len) f.ranks[i] else 0;
        b.* = switch (node.shape) {
            .start, .end => .{ .w = 16, .h = 16, .rank = r },
            .circle => blk: {
                const d = @max(sz[0], sz[1]) + 28;
                break :blk .{ .w = d, .h = d, .rank = r };
            },
            .diamond => .{ .w = sz[0] * 1.4 + 36, .h = sz[1] * 1.6 + 30, .rank = r },
            .hexagon => .{ .w = sz[0] + 48, .h = sz[1] + 22, .rank = r },
            .subroutine => .{ .w = sz[0] + 46, .h = sz[1] + 20, .rank = r },
            else => .{ .w = sz[0] + 32, .h = sz[1] + 20, .rank = r },
        };
    }
    const labels = a.alloc([2]f32, f.edges.len) catch return;
    for (f.edges, labels) |e, *l| l.* = if (e.label.len == 0) .{ 0, 0 } else patch(measure(c, e.label, small_style));

    var dir = f.dir;
    var size = place(a, dir, f, boxes, labels) catch return;
    if (size[0] > room) {
        const turned: mm.Dir = switch (dir) {
            .down => .right,
            .up => .left,
            .right => .down,
            .left => .up,
        };
        const other = place(a, turned, f, boxes, labels) catch return;
        if (other[0] < size[0]) {
            dir = turned;
            size = other;
        } else _ = place(a, dir, f, boxes, labels) catch return;
    }
    const k = std.math.clamp(room / @max(size[0], 1), min_scale, 1);
    for (boxes) |*b| {
        b.x *= k;
        b.y *= k;
        b.w *= k;
        b.h *= k;
        b.r0 *= k;
        b.r1 *= k;
        b.lab *= k;
    }
    const W = size[0] * k;
    const H = size[1] * k;

    const outer = ui.div(c).row().wFull().justifyCenter();
    defer outer.end();
    const canvas = ui.div(c).w(W).h(H);
    defer canvas.end();
    const ink = pal.muted;
    for ([_]Pass{ .lines, .labels }) |pass| {
        var back_k: f32 = 0;
        for (f.edges, 0..) |e, i| {
            if (e.from >= n or e.to >= n) continue;
            const s = boxes[e.from];
            const t = boxes[e.to];
            if (i < f.back.len and f.back[i]) {
                back_k += 1;
                backEdge(c, pass, dir, s, t, e, W, H, back_k, ink, pal, k);
            } else forwardEdge(c, pass, dir, s, t, e, ink, pal, k);
        }
        if (pass == .lines) for (f.nodes, boxes) |node, b| shape(c, node, b, pal, k);
    }
}

fn place(a: std.mem.Allocator, dir: mm.Dir, f: mm.Flow, boxes: []Box, labels: []const [2]f32) ![2]f32 {
    const n = boxes.len;
    const vertical = dir == .down or dir == .up;
    const across_gap: f32 = if (vertical) 24 else 14;
    const along_gap: f32 = 48;
    const ranks = @max(f.num_ranks, 1);
    const thick = try a.alloc(f32, ranks);
    const span = try a.alloc(f32, ranks);
    @memset(thick, 0);
    @memset(span, 0);
    for (boxes) |b| {
        thick[b.rank] = @max(thick[b.rank], if (vertical) b.h else b.w);
        span[b.rank] += (if (vertical) b.w else b.h) + across_gap;
    }
    var widest: f32 = 0;
    for (span) |s| widest = @max(widest, s - across_gap);
    const lab = try a.alloc(f32, ranks);
    @memset(lab, 0);
    for (f.edges, labels, 0..) |e, l, ei| {
        const is_back = ei < f.back.len and f.back[ei];
        if (is_back or e.to >= n or l[0] == 0) continue;
        const r = boxes[e.to].rank;
        lab[r] = @max(lab[r], if (vertical) l[1] else l[0]);
    }
    var along: f32 = 0;
    const starts = try a.alloc(f32, ranks);
    for (0..ranks) |r| {
        if (r > 0) along += if (lab[r] > 0) @max(along_gap, lab[r] + label_room + trunk_room) else along_gap;
        starts[r] = along;
        along += thick[r];
    }
    const cursor = try a.alloc(f32, ranks);
    for (0..ranks) |r| cursor[r] = (widest - (span[r] - across_gap)) / 2;
    const pad: f32 = 12;
    for (f.sorted) |i| {
        const b = &boxes[i];
        const across = if (vertical) b.w else b.h;
        const pos = starts[b.rank] + ((thick[b.rank] - (if (vertical) b.h else b.w)) / 2);
        const forward = dir == .down or dir == .right;
        b.r0 = pad + if (forward) starts[b.rank] else along - starts[b.rank] - thick[b.rank];
        b.r1 = b.r0 + thick[b.rank];
        b.lab = lab[b.rank];
        if (vertical) {
            b.x = pad + cursor[b.rank];
            b.y = pad + if (forward) pos else along - pos - b.h;
        } else {
            b.y = pad + cursor[b.rank];
            b.x = pad + if (forward) pos else along - pos - b.w;
        }
        cursor[b.rank] += across + across_gap;
    }
    const backs: f32 = @floatFromInt(f.back_count);
    const lanes = if (backs > 0) backs * 10 + 10 else 0;
    return .{
        (if (vertical) widest else along) + 2 * pad + (if (vertical) lanes else 0),
        (if (vertical) along else widest) + 2 * pad + (if (vertical) 0 else lanes),
    };
}

fn shape(c: *ui.Context, node: mm.Node, b: Box, pal: Palette, k: f32) void {
    const fill = if (node.shape == .diamond) pal.bg.mix(pal.accent, 0.14) else pal.bg;
    const edge = if (node.shape == .diamond) pal.bg.mix(pal.accent, 0.65) else pal.border.mix(pal.ink, 0.22);
    switch (node.shape) {
        .start => return rect(c, b.x, b.y, b.w, b.h, pal.ink, b.w / 2),
        .end => {
            panel(c, b.x, b.y, b.w, b.h, pal.bg, pal.ink, b.w / 2);
            rect(c, b.x + 4, b.y + 4, b.w - 8, b.h - 8, pal.ink, (b.w - 8) / 2);
            return;
        },
        .diamond => strips(c, b.x, b.y, b.w, b.h, fill, edge, diamondHalf),
        .hexagon => strips(c, b.x, b.y, b.w, b.h, fill, edge, hexagonHalf),
        .circle, .stadium => panel(c, b.x, b.y, b.w, b.h, fill, edge, b.h / 2),
        .round, .cylinder => panel(c, b.x, b.y, b.w, b.h, fill, edge, 10),
        .subroutine => {
            panel(c, b.x, b.y, b.w, b.h, fill, edge, 6);
            rect(c, b.x + 7 * k, b.y + 1, 1.25, b.h - 2, edge, 0);
            rect(c, b.x + b.w - 8 * k, b.y + 1, 1.25, b.h - 2, edge, 0);
        },
        .rect, .flag => panel(c, b.x, b.y, b.w, b.h, fill, edge, 6),
    }
    var st = label_style;
    st.size *= k;
    st.color = pal.ink;
    const inset: f32 = if (node.shape == .subroutine) 9 * k else 0;
    label(c, b.x + inset, b.y, b.w - 2 * inset, b.h, node.label, st);
}

fn forwardEdge(c: *ui.Context, pass: Pass, dir: mm.Dir, s: Box, t: Box, e: mm.Edge, ink: ui.Color, pal: Palette, k: f32) void {
    const head = 8 * k;
    if (dir == .down or dir == .up) {
        const sx = s.x + s.w / 2;
        const tx = t.x + t.w / 2;
        const down = t.y > s.y;
        const sy = if (down) s.y + s.h else s.y;
        const ty = if (down) t.y else t.y + t.h;
        const mid = trunk(s, t, down, ty, k);
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, tx, (mid + if (down) ty - head else ty + head) / 2, e.label, pal, k);
            return;
        }
        line(c, sx, sy, sx, mid, e.line, ink);
        line(c, sx, mid, tx, mid, e.line, ink);
        line(c, tx, mid, tx, ty, e.line, ink);
        if (e.head) arrow(c, tx, ty, if (down) .down else .up, ink);
        if (e.tail) arrow(c, sx, sy, if (down) .up else .down, ink);
    } else {
        const sy = s.y + s.h / 2;
        const ty = t.y + t.h / 2;
        const right = t.x > s.x;
        const sx = if (right) s.x + s.w else s.x;
        const tx = if (right) t.x else t.x + t.w;
        const mid = trunk(s, t, right, tx, k);
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, (mid + if (right) tx - head else tx + head) / 2, ty, e.label, pal, k);
            return;
        }
        line(c, sx, sy, mid, sy, e.line, ink);
        line(c, mid, sy, mid, ty, e.line, ink);
        line(c, mid, ty, tx, ty, e.line, ink);
        if (e.head) arrow(c, tx, ty, if (right) .right else .left, ink);
        if (e.tail) arrow(c, sx, sy, if (right) .left else .right, ink);
    }
}

fn trunk(s: Box, t: Box, forward: bool, to: f32, k: f32) f32 {
    if (t.lab > 0) return if (forward) t.r0 - t.lab - label_room * k else t.r1 + t.lab + label_room * k;
    if (t.rank == s.rank + 1) return gapMid(s, t, forward);
    return if (forward) to - 22 else to + 22;
}

fn gapMid(s: Box, t: Box, forward: bool) f32 {
    return if (forward) (s.r1 + t.r0) / 2 else (s.r0 + t.r1) / 2;
}

fn backEdge(c: *ui.Context, pass: Pass, dir: mm.Dir, s: Box, t: Box, e: mm.Edge, W: f32, H: f32, lane_k: f32, ink: ui.Color, pal: Palette, k: f32) void {
    if (dir == .down or dir == .up) {
        const lane = W - 8 - (lane_k - 1) * 10;
        const sy = s.y + s.h / 2;
        const ty = t.y + t.h / 2;
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, lane, (sy + ty) / 2, e.label, pal, k);
            return;
        }
        line(c, s.x + s.w, sy, lane, sy, e.line, ink);
        line(c, lane, sy, lane, ty, e.line, ink);
        line(c, lane, ty, t.x + t.w, ty, e.line, ink);
        if (e.head) arrow(c, t.x + t.w, ty, .left, ink);
    } else {
        const lane = H - 8 - (lane_k - 1) * 10;
        const sx = s.x + s.w / 2;
        const tx = t.x + t.w / 2;
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, (sx + tx) / 2, lane, e.label, pal, k);
            return;
        }
        line(c, sx, s.y + s.h, sx, lane, e.line, ink);
        line(c, sx, lane, tx, lane, e.line, ink);
        line(c, tx, lane, tx, t.y + t.h, e.line, ink);
        if (e.head) arrow(c, tx, t.y + t.h, .up, ink);
    }
}

fn edgeLabel(c: *ui.Context, x: f32, y: f32, text: []const u8, pal: Palette, k: f32) void {
    var st = small_style;
    st.size *= k;
    st.color = pal.muted;
    const sz = patch(measure(c, text, st));
    rect(c, x - sz[0] / 2, y - sz[1] / 2, sz[0], sz[1], pal.card, 4);
    label(c, x - sz[0] / 2, y - sz[1] / 2, sz[0], sz[1], text, st);
}

fn patch(sz: [2]f32) [2]f32 {
    return .{ sz[0] + 10, sz[1] + 4 };
}

fn pie(c: *ui.Context, p: mm.Pie, pal: Palette) void {
    const colors = [_]ui.Color{
        .hex(0x2563eb),
        .hex(0x16a34a),
        .hex(0xd97706),
        .hex(0x9333ea),
        .hex(0xdc2626),
        .hex(0x0891b2),
    };
    var total: f32 = 0;
    for (p.slices) |s| total += @max(s.value, 0);
    if (total <= 0) total = 1;

    ui.column(c, .{ .width = .fill, .gap = 10 });
    defer ui.end(c);
    if (p.title.len > 0) {
        ui.text(c, p.title, .{ .size = 13.5, .weight = .semibold, .color = pal.ink });
    }
    ui.row(c, .{ .width = .fill, .height = .{ .px = 18 }, .gap = 3 });
    for (p.slices, 0..) |s, i| {
        ui.row(c, .{
            .grow = @max(s.value / total, 0.02),
            .height = .fill,
            .radius = 6,
            .background = colors[i % colors.len],
        });
        ui.end(c);
    }
    ui.end(c);
    ui.row(c, .{ .width = .fill, .gap = 14, .align_items = .center });
    for (p.slices, 0..) |s, i| {
        const pct = @round((s.value / total) * 100.0);
        ui.row(c, .{ .align_items = .center, .gap = 6 });
        ui.row(c, .{ .width = .{ .px = 9 }, .height = .{ .px = 9 }, .radius = 99, .background = colors[i % colors.len] });
        ui.end(c);
        ui.text(c, c.print("{s} ({d:.0}%)", .{ s.label, pct }), .{ .size = 12, .color = pal.ink });
        ui.end(c);
    }
    ui.end(c);
}
