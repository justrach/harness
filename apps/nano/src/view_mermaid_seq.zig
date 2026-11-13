//! Native GPU sequence diagram renderer for `harness-nano` (ported from `nanodocs`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const mm = @import("mermaid.zig");
const v = @import("view_mermaid.zig");

pub fn seq(c: *ui.Context, s: mm.Seq, room: f32, pal: v.Palette) void {
    const a = c.alloc();
    const n = s.actors.len;
    const widths = a.alloc(f32, n) catch return;
    const centers = a.alloc(f32, n) catch return;
    var box_h: f32 = 34;
    for (s.actors, widths) |actor, *w| w.* = @max(v.measure(c, actor.label, v.label_style)[0] + 32, 68);

    var x: f32 = 12 + widths[0] / 2;
    for (centers, 0..) |*cx, i| {
        if (i > 0) x += @max(widths[i - 1] / 2 + 36 + widths[i] / 2, 120);
        cx.* = x;
    }
    for (s.steps) |step| switch (step) {
        .message => |m| if (m.from != m.to and m.from < n and m.to < n) {
            const lo = @min(m.from, m.to);
            const hi = @max(m.from, m.to);
            const need = v.measure(c, m.text, v.small_style)[0] + 36;
            const have = centers[hi] - centers[lo];
            if (have < need) for (centers[hi..]) |*cx| {
                cx.* += need - have;
            };
        },
        .note => |nt| if (nt.from < n and nt.to < n) {
            const need = v.measure(c, nt.text, v.small_style)[0] + 28;
            if (nt.side == .over and nt.from != nt.to) {
                const lo = @min(nt.from, nt.to);
                const hi = @max(nt.from, nt.to);
                const have = centers[hi] - centers[lo] + 32;
                if (have < need) for (centers[hi..]) |*cx| {
                    cx.* += need - have;
                };
            } else if (nt.from == nt.to and nt.side == .right and nt.from + 1 < n) {
                const i = nt.from;
                if (centers[i + 1] - centers[i] < need) {
                    const d = need - (centers[i + 1] - centers[i]);
                    for (centers[i + 1 ..]) |*cx| cx.* += d;
                }
            }
        },
        else => {},
    };

    var y: f32 = 12 + box_h + 14;
    const rows = a.alloc(f32, s.steps.len) catch return;
    for (s.steps, rows) |step, *row| {
        row.* = y;
        y += switch (step) {
            .message => |m| v.measure(c, m.text, v.small_style)[1] + (if (m.from == m.to) @as(f32, 36) else 20),
            .note => |nt| v.measure(c, nt.text, v.small_style)[1] + 22,
            .section => 26,
        };
    }
    var bottom = y + 6;
    const raw_w = centers[n - 1] + widths[n - 1] / 2 + 12 + 32;
    const k = std.math.clamp(room / @max(raw_w, 1), 0.38, 1.0);
    if (k < 1.0) {
        box_h *= k;
        bottom *= k;
        for (widths) |*w| w.* *= k;
        for (centers) |*cx| cx.* *= k;
        for (rows) |*r| r.* *= k;
    }
    const W = raw_w * k;
    const H = bottom + box_h + 12 * k;

    const outer = ui.div(c).row().wFull().justifyCenter();
    defer outer.end();
    const canvas = ui.div(c).w(W).h(H);
    defer canvas.end();

    const ink = pal.muted;
    const edge_strong = pal.border.mix(pal.ink, 0.22);
    var small_ink = v.small_style;
    small_ink.size *= k;
    small_ink.color = pal.ink;

    for (centers) |cx| v.line(c, cx, 12 * k + box_h, cx, bottom, .dotted, edge_strong);
    for (s.steps, rows) |step, row| switch (step) {
        .message => |m| {
            if (m.from >= n or m.to >= n) continue;
            const sz = v.measure(c, m.text, small_ink);
            const x0 = centers[m.from];
            const x1 = centers[m.to];
            const kind: mm.Line = if (m.dashed) .dotted else .solid;
            if (m.from == m.to) {
                const ly = row + sz[1] + 4 * k;
                v.line(c, x0, ly, x0 + 30 * k, ly, kind, ink);
                v.line(c, x0 + 30 * k, ly, x0 + 30 * k, ly + 16 * k, kind, ink);
                v.line(c, x0 + 30 * k, ly + 16 * k, x0, ly + 16 * k, kind, ink);
                if (m.head) v.arrow(c, x0, ly + 16 * k, .left, ink);
                v.label(c, x0 + 6 * k, row, sz[0] + 8, sz[1], m.text, small_ink);
            } else {
                const ly = row + sz[1] + 6 * k;
                v.line(c, x0, ly, x1, ly, kind, ink);
                if (m.head) v.arrow(c, x1, ly, if (x1 > x0) .right else .left, ink);
                const mid = (x0 + x1) / 2;
                v.label(c, mid - sz[0] / 2 - 4, row, sz[0] + 8, sz[1], m.text, small_ink);
            }
        },
        .note => |nt| {
            if (nt.from >= n or nt.to >= n) continue;
            const sz = v.measure(c, nt.text, small_ink);
            const w = sz[0] + 20 * k;
            const h = sz[1] + 12 * k;
            const lo = @min(nt.from, nt.to);
            const hi = @max(nt.from, nt.to);
            const nw = if (nt.side == .over and lo != hi) @max(centers[hi] - centers[lo] + 40 * k, w) else w;
            const nx = switch (nt.side) {
                .over => (centers[lo] + centers[hi]) / 2 - nw / 2,
                .right => centers[nt.from] + 10 * k,
                .left => centers[nt.from] - 10 * k - nw,
            };
            const note_bg = pal.bg.mix(.hex(0xd97706), 0.12);
            const note_edge = pal.border.mix(.hex(0xd97706), 0.45);
            v.panel(c, nx, row + 2 * k, nw, h, note_bg, note_edge, 5);
            v.label(c, nx, row + 2 * k, nw, h, nt.text, small_ink);
        },
        .section => |text| {
            const sz = v.measure(c, text, small_ink);
            v.rect(c, 12 * k, row + 12 * k, W - 24 * k, 1, pal.border, 0);
            v.panel(c, 12 * k, row + 3 * k, sz[0] + 16 * k, sz[1] + 4 * k, pal.bg, edge_strong, 4);
            var st = small_ink;
            st.weight = .semibold;
            st.color = pal.muted;
            v.label(c, 12 * k, row + 3 * k, sz[0] + 16 * k, sz[1] + 4 * k, text, st);
        },
    };
    for (s.actors, centers, widths) |actor, cx, w| {
        for ([_]f32{ 12 * k, bottom }) |by| {
            v.panel(c, cx - w / 2, by, w, box_h, pal.bg, edge_strong, if (actor.person) box_h / 2 else 6);
            var st = v.label_style;
            st.size *= k;
            st.weight = .semibold;
            st.color = pal.ink;
            v.label(c, cx - w / 2, by, w, box_h, actor.label, st);
        }
    }
}
