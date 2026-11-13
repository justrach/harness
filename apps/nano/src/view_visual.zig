//! Native, bounded presentation of an isolated Luau visual (`crates/ui/src/visuals.rs` 1:1).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const kit = @import("view_kit.zig");
const theme = @import("theme.zig");
const tr = @import("transcript.zig");
const vl = @import("visual_luau.zig");
const visuals = @import("app_visuals.zig");

pub const visual_height: f32 = 700.0;
const max_depth: usize = 24;
const max_nodes: usize = 512;
const chart_bars: usize = 12;

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part) void {
    const part_key = c.print("{s}:{s}", .{ e.id, p.id });
    const title = if (p.text.items.len > 0) p.text.items else "Native visual";
    const entry = a.visuals.getOrInit(a, part_key, title, p.script) orelse return;

    ui.key(c, c.print("native-visual-{s}", .{entry.part_id}));
    const card = ui.div(c).column().wFull().h(visual_height).minW(0).clip().rounded(12).border(k.border).borderW(1).bg(k.card);
    defer card.end();

    // Header
    {
        const hdr = ui.div(c).row().wFull().itemsCenter().justifyBetween().gap(12).px(18).py(13);
        defer hdr.end();
        {
            const t_box = ui.div(c).row().grow().minW(0);
            defer t_box.end();
            ui.text(c, entry.title, kit.style(c, 13, 18, .{ .weight = .semibold, .color = k.text }));
        }
        const status = if (entry.busy) "Updating\xe2\x80\xa6" else if (entry.err != null) "Stopped" else "Native \xc2\xb7 Interactive";
        ui.text(c, status, kit.style(c, 11, 15, .{ .color = k.muted }));
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);

    // Scrollable document body
    {
        ui.key(c, c.print("visual-doc-{s}", .{entry.part_id}));
        var doc = ui.div(c).column().grow().wFull().minW(0).scrollY().scrollbar(.{ .overlay = k.faint.alpha(0.5) }).p(18);
        doc.c.node(doc.index).style.min_height = 0;
        defer doc.end();

        if (entry.err) |err_text| {
            const err_box = ui.div(c).column().wFull().p(16).rounded(8).bg(k.danger.alpha(0.08)).gap(8);
            defer err_box.end();
            ui.text(c, "This visual could not run", kit.style(c, 13, 18, .{ .weight = .semibold, .color = k.danger }));
            ui.text(c, err_text, kit.style(c, 13, 18, .{ .color = k.danger, .wrap = true }));
        } else if (entry.node) |*root| {
            var count: usize = 0;
            renderNode(c, a, k, entry, root, 1, &count);
        } else {
            ui.text(c, "Preparing native visual\xe2\x80\xa6", kit.style(c, 13, 18, .{ .color = k.muted }));
        }
    }

    // Footer
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    {
        const ftr = ui.div(c).row().wFull().px(18).py(9);
        defer ftr.end();
        ui.text(c, "Isolated Luau \xc2\xb7 No network or filesystem \xc2\xb7 Tab to controls", kit.style(c, 11, 15, .{ .color = k.muted }));
    }
}

fn renderNode(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    entry: *const visuals.Entry,
    node: *const vl.Node,
    depth: usize,
    count: *usize,
) void {
    count.* += 1;
    if (depth > max_depth or count.* > max_nodes) {
        ui.text(c, "Visual display limit reached", kit.style(c, 13, 18, .{ .color = k.danger }));
        return;
    }
    const id = count.*;
    switch (node.kind) {
        .column => {
            const col = ui.div(c).column().wFull().minW(0).gap(14);
            defer col.end();
            const cap = @min(node.children.len, max_nodes);
            for (node.children[0..cap]) |*child| {
                if (count.* >= max_nodes) break;
                renderNode(c, a, k, entry, child, depth + 1, count);
            }
        },
        .row => {
            const row = ui.div(c).row().wFull().minW(0).itemsCenter().gap(14);
            defer row.end();
            const cap = @min(node.children.len, max_nodes);
            for (node.children[0..cap]) |*child| {
                if (count.* >= max_nodes) break;
                renderNode(c, a, k, entry, child, depth + 1, count);
            }
        },
        .text => {
            const box = ui.div(c).row().wFull().minW(0);
            defer box.end();
            ui.text(c, node.text, kit.style(c, 13, 18, .{ .color = k.text, .wrap = true }));
        },
        .stat => {
            const box = ui.div(c).row().minW(150).grow().p(16).rounded(10).border(k.border).borderW(1).bg(k.background);
            defer box.end();
            ui.text(c, node.text, kit.style(c, 20, 26, .{ .weight = .semibold, .color = k.text, .wrap = true }));
        },
        .rule => {
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        },
        .chart => renderChart(c, k, entry, node, id),
        .button, .toggle => renderButtonOrToggle(c, a, k, entry, node, id),
        .slider => renderSlider(c, a, k, entry, node, id),
    }
}

fn renderButtonOrToggle(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    entry: *const visuals.Entry,
    node: *const vl.Node,
    id: usize,
) void {
    const is_toggle = node.kind == .toggle;
    const on = node.value != 0.0;
    const active = !entry.busy and node.handler != null;
    const label = controlLabel(node);

    ui.key(c, c.print("vc-{s}-{d}", .{ entry.part_id, id }));
    var box = ui.div(c).row().px(14).py(9).rounded(8).border(k.border_strong).borderW(1).itemsCenter().gap(10).bg(if (is_toggle) k.background else k.accent_strong).control();
    box.c.node(box.index).style.min_height = 38;
    const it = c.interact(box.index, .{ .focusable = active });
    if (active and (it.hovered or it.focused)) {
        box.c.node(box.index).style.border = k.accent;
    }
    defer box.end();

    if (is_toggle) {
        var pill = ui.div(c).row().w(30).h(18).roundedFull().circular().bg(if (on) k.accent_strong else k.border_strong).itemsCenter().px(3);
        if (on) pill = pill.justifyEnd();
        defer pill.end();
        _ = c.leaf(.{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .radius = 6, .corner_circular = true, .background = k.solid }, .none, null);
    }

    const fg = if (active) (if (is_toggle) k.text else k.on_accent) else k.muted;
    ui.text(c, label, kit.style(c, 13, 18, .{ .weight = .medium, .color = fg }));
    if (is_toggle) {
        ui.text(c, if (on) "On" else "Off", kit.style(c, 13, 18, .{ .weight = .medium, .color = fg }));
    }

    if (active and it.clicked) {
        if (node.handler) |hid| {
            a.visuals.dispatch(a, entry.part_id, entry.revision, hid, if (is_toggle) .{ .boolean = !on } else .click);
        }
    }
}

fn renderSlider(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    entry: *const visuals.Entry,
    node: *const vl.Node,
    id: usize,
) void {
    const min = node.min;
    const max = node.max;
    const value = std.math.clamp(node.value, min, max);
    const span = max - min;
    const fraction: f32 = if (std.math.isFinite(span) and span > 0.0) @floatCast((value - min) / span) else 0.0;
    const step = span / 100.0;
    const active = !entry.busy and node.handler != null and std.math.isFinite(span) and span > 0.0;
    const label = controlLabel(node);

    ui.key(c, c.print("vs-{s}-{d}", .{ entry.part_id, id }));
    var box = ui.div(c).column().minW(180).wFull().gap(5).rounded(8).border(k.border).borderW(1).p(12).control();
    const box_it = c.interact(box.index, .{ .focusable = active });
    if (active and box_it.focused) {
        box.c.node(box.index).style.border = k.accent;
    }
    defer box.end();

    const val_str = formatNumber(c, value);
    const min_str = formatNumber(c, min);
    const max_str = formatNumber(c, max);

    {
        const top = ui.div(c).row().wFull().justifyBetween().gap(12);
        defer top.end();
        ui.text(c, label, kit.style(c, 13, 18, .{ .color = k.text }));
        ui.text(c, val_str, kit.style(c, 13, 18, .{ .color = k.text }));
    }

    {
        ui.key(c, c.print("vst-{s}-{d}", .{ entry.part_id, id }));
        const track_wrap = ui.div(c).row().wFull().h(28).control();
        const track_it = track_wrap.interaction();
        defer track_wrap.end();

        const tw = if (track_it.rect) |r| @max(1.0, r.w) else 220.0;
        {
            const rail = ui.div(c).absolute().offset(0, 12).wFull().h(4).roundedFull().bg(k.border_strong);
            defer rail.end();
            _ = c.leaf(.{ .width = .{ .px = tw * fraction }, .height = .fill, .radius = 2, .background = k.accent }, .none, null);
        }
        const knob_x = std.math.clamp(tw * fraction - 7.0, 0.0, @max(0.0, tw - 14.0));
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = knob_x, .y = 12 - 5 }, .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .corner_circular = true, .background = k.accent }, .none, null);

        if (active) {
            if (track_it.pressed) if (track_it.rect) |r| if (r.w > 0) {
                const ratio = std.math.clamp((c.input.mouse.x - r.x) / r.w, 0.0, 1.0);
                const next_v = std.math.clamp(min + @as(f64, ratio) * span, min, max);
                if (@abs(next_v - value) > 1e-9) {
                    if (node.handler) |hid| a.visuals.dispatch(a, entry.part_id, entry.revision, hid, .{ .number = next_v });
                }
            };
            if (box_it.a11y_step != 0) {
                const next_v = std.math.clamp(value + step * @as(f64, @floatFromInt(box_it.a11y_step)), min, max);
                if (@abs(next_v - value) > 1e-9) {
                    if (node.handler) |hid| a.visuals.dispatch(a, entry.part_id, entry.revision, hid, .{ .number = next_v });
                }
            } else if (box_it.focused) if (c.input.key) |key| {
                const next_opt: ?f64 = switch (key) {
                    .left, .down => value - step,
                    .right, .up => value + step,
                    .home => min,
                    .end => max,
                    else => null,
                };
                if (next_opt) |raw_next| {
                    const next_v = std.math.clamp(raw_next, min, max);
                    if (@abs(next_v - value) > 1e-9) {
                        if (node.handler) |hid| a.visuals.dispatch(a, entry.part_id, entry.revision, hid, .{ .number = next_v });
                    }
                }
            };
        }
    }

    {
        const bot = ui.div(c).row().wFull().justifyBetween();
        defer bot.end();
        ui.text(c, min_str, kit.style(c, 11, 15, .{ .color = k.muted }));
        ui.text(c, max_str, kit.style(c, 11, 15, .{ .color = k.muted }));
    }
}

fn renderChart(c: *ui.Context, k: theme.Colors, entry: *const visuals.Entry, node: *const vl.Node, id: usize) void {
    var scale: f64 = std.math.floatMin(f64);
    for (node.values) |val| scale = @max(scale, @abs(val));
    var lo: f64 = 0.0;
    var hi: f64 = 0.0;
    for (node.values) |val| {
        const norm = val / scale;
        lo = @min(lo, norm);
        hi = @max(hi, norm);
    }
    const range = @max(hi - lo, std.math.floatMin(f64));
    const zero: f32 = @floatCast(-lo / range);

    const chart = ui.div(c).column().wFull().minW(0).p(16).rounded(10).border(k.border).borderW(1).bg(k.background).gap(10);
    defer chart.end();
    ui.text(c, if (node.text.len == 0) "Chart" else node.text, kit.style(c, 13, 18, .{ .weight = .semibold, .color = k.text }));
    if (node.values.len == 0) {
        ui.text(c, "No data yet", kit.style(c, 13, 18, .{ .color = k.muted }));
        return;
    }

    const shown = @min(node.values.len, chart_bars);
    for (node.values[0..shown], 0..) |val, idx| {
        const lbl = if (idx < node.labels.len and node.labels[idx].len > 0)
            node.labels[idx]
        else
            c.print("{d}", .{idx + 1});
        const val_str = formatNumber(c, val);

        var row = ui.div(c).row().wFull().itemsCenter().gap(12);
        row.c.node(row.index).style.min_height = 24;
        defer row.end();

        {
            const lbox = ui.div(c).row().w(82);
            defer lbox.end();
            ui.text(c, lbl, kit.style(c, 12, 16, .{ .color = k.muted }));
        }
        {
            ui.key(c, c.print("vcb-{s}-{d}-{d}", .{ entry.part_id, id, idx }));
            const bar_box = ui.div(c).row().h(18).grow().w(0).minW(20).bg(k.panel).rounded(3).clip();
            const bw = if (c.rects.get(bar_box.id())) |r| @max(1.0, r.w) else 200.0;
            defer bar_box.end();

            const end_f: f32 = @floatCast((val / scale - lo) / range);
            const bar_left = @min(zero, end_f) * bw;
            const bar_w = @max(0.0, @abs(end_f - zero) * bw);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = bar_left, .y = 0 }, .width = .{ .px = bar_w }, .height = .fill, .radius = 3, .background = k.accent }, .none, null);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = zero * bw, .y = 0 }, .width = .{ .px = 1 }, .height = .fill, .background = k.faint }, .none, null);
        }
        {
            const vbox = ui.div(c).row().w(64);
            defer vbox.end();
            ui.text(c, val_str, kit.style(c, 12, 16, .{ .color = k.text }));
        }
    }

    if (node.values.len > chart_bars) {
        ui.text(c, c.print("Showing the first {d} of {d} values", .{ chart_bars, node.values.len }), kit.style(c, 11, 15, .{ .color = k.muted }));
    }
}

fn controlLabel(node: *const vl.Node) []const u8 {
    const trimmed = std.mem.trim(u8, node.text, " \t\r\n");
    if (trimmed.len > 0) return node.text;
    return switch (node.kind) {
        .toggle => "Toggle",
        .slider => "Value",
        else => "Run",
    };
}

pub fn formatNumber(c: *ui.Context, value: f64) []const u8 {
    if (value == 0.0) return "0";
    const abs = @abs(value);
    if (abs >= 1_000_000.0 or abs < 0.01) {
        return c.print("{e:.2}", .{value});
    }
    const frac = value - @trunc(value);
    if (@abs(frac) < 0.000_001) {
        return c.print("{d:.0}", .{value});
    }
    return c.print("{d:.2}", .{value});
}
