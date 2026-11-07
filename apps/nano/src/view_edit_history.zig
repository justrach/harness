//! A compact native chart of actual recorded tool-result churn.
//! No synthesized per-edit timestamps, work durations, or git-total history.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const App = @import("app.zig").App;
const history = @import("edit_history.zig");
const kit = @import("view_kit.zig");

pub fn chart(c: *ui.Context, a: *App, k: theme.Colors, width: f32) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const h = history.collect(arena.allocator(), &a.transcript) catch return;
    const active = if (a.selectedStatus() == .working) activePath(a) else null;
    // No activity card in a conversation that never attempted an edit.
    if (h.points.len == 0 and h.missing == 0 and active == null) return;
    ui.key(c, "agent-edit-history");
    const card = ui.div(c).column().wFull().p(16).gap(10).rounded(12).bg(k.code_bg).border(k.border).borderW(1);
    defer card.end();
    const n = h.points.len;
    if (c.shortcut(.{ .key = 'd', .alt = true })) a.view.edit_details = !a.view.edit_details;
    var selected = @min(a.view.edit_selected orelse (n -| 1), n -| 1);
    {
        const row = ui.div(c).row().wFull().itemsCenter().gap(10);
        defer row.end();
        ui.text(c, "Agent edits", .{ .size = 12, .weight = .semibold, .color = k.text });
        ui.spacer(c);
        if (n > 0) {
            const last = h.points[n - 1];
            ui.text(c, c.print("+{d}", .{last.added}), .{ .size = 11, .mono = true, .color = k.diff_add });
            ui.text(c, c.print("−{d}", .{last.removed}), .{ .size = 11, .mono = true, .color = k.diff_del });
            ui.text(c, c.print("{d} files", .{h.files.len}), .{ .size = 11, .color = k.muted });
        }
        const details = ui.div(c).row().px(6).py(3).rounded(4).control();
        ui.text(c, if (a.view.edit_details) "Hide details" else "Details", .{ .size = 11, .color = k.muted });
        if (details.clicked()) a.view.edit_details = !a.view.edit_details;
        details.end();
    }
    if (active) |path| ui.text(c, c.print("Editing {s}", .{path}), kit.style(c, 10, 15, .{ .wrap = true, .color = k.muted }));
    if (n == 0) {
        ui.text(c, if (active != null) "Waiting for the first recorded diff result…" else "Edit history unavailable — these tools did not record diff results.", kit.style(c, 11, 16, .{ .wrap = true, .color = k.muted }));
        return;
    }
    const plot_w = @max(width - 32, 80);
    // A bounded step envelope for long sessions; detail still visits every result.
    const bins = @min(n, 192);
    const step_w = plot_w / @as(f32, @floatFromInt(bins));
    const last = h.points[n - 1];
    const max_y: f32 = @floatFromInt(@max(@max(last.added, last.removed), 1));
    const half: f32 = 56;
    var hover: ?usize = null;
    {
        const plot = ui.div(c).row().wFull().h(half * 2 + 1).clip().control();
        defer plot.end();
        if (plot.hovered()) if (c.rects.get(c.node(plot.index).id)) |r| {
            const x = std.math.clamp((c.input.mouse.x - r.x) / @max(r.w, 1), 0, 0.99999);
            hover = @min(@as(usize, @intFromFloat(x * @as(f32, @floatFromInt(n)))), n - 1);
            c.wants_moves = true;
            if (plot.clicked()) {
                a.view.edit_selected = hover;
                a.view.edit_details = true;
            }
        };
        for (0..bins) |bin| {
            const i = @min((bin + 1) * n / bins - 1, n - 1);
            const p = h.points[i];
            const col = ui.div(c).column().w(step_w).hFull();
            {
                const upper = ui.div(c).column().wFull().h(half).justifyEnd();
                const area = ui.div(c).wFull().h(half * @as(f32, @floatFromInt(p.added)) / max_y).bg(k.diff_add.alpha(0.22));
                if (p.added > 0) {
                    const edge = ui.div(c).wFull().h(1).bg(k.diff_add.alpha(0.8));
                    edge.end();
                }
                area.end();
                upper.end();
            }
            const zero = ui.div(c).wFull().h(1).bg(k.border);
            zero.end();
            {
                const lower = ui.div(c).column().wFull().h(half);
                const area = ui.div(c).column().wFull().h(half * @as(f32, @floatFromInt(p.removed)) / max_y).bg(k.diff_del.alpha(0.2)).justifyEnd();
                if (p.removed > 0) {
                    const edge = ui.div(c).wFull().h(1).bg(k.diff_del.alpha(0.8));
                    edge.end();
                }
                area.end();
                lower.end();
            }
            col.end();
        }
        const cursor = hover orelse selected;
        const x = (@as(f32, @floatFromInt(cursor)) + 0.5) / @as(f32, @floatFromInt(n)) * plot_w;
        const playhead = ui.div(c).absolute().offset(x, 0).w(1).h(half * 2 + 1).bg(k.text.alpha(0.45));
        playhead.end();
        // Dotted cumulative net, distinct from the addition/deletion envelopes.
        for (0..bins) |bin| {
            const p = h.points[@min((bin + 1) * n / bins - 1, n - 1)];
            const net = @as(f32, @floatFromInt(p.added)) - @as(f32, @floatFromInt(p.removed));
            const dot = ui.div(c).absolute().offset((@as(f32, @floatFromInt(bin)) + 0.5) * step_w, half - half * net / max_y).size(2, 2).rounded(1).bg(k.muted.alpha(0.5));
            dot.end();
        }
    }
    {
        const axis = ui.div(c).row().wFull().justifyBetween();
        defer axis.end();
        ui.text(c, "Recorded edit order", .{ .size = 10, .color = k.muted });
        ui.text(c, c.print("{d} results · cumulative churn, not net diff", .{n}), .{ .size = 10, .color = k.muted });
    }
    if (hover) |i| selected = i;
    // Exact discrete result positions, deliberately not invented editing spans.
    for (h.files[0..@min(h.files.len, 4)]) |file| {
        const lane = ui.div(c).row().wFull().h(16).itemsCenter().gap(8);
        const label = ui.div(c).w(@min(160, plot_w * 0.35)).clip();
        ui.text(c, file, .{ .size = 10, .mono = true, .color = if (std.mem.eql(u8, file, h.points[selected].edit.path)) k.text else k.muted });
        label.end();
        const track_w = plot_w - @min(160, plot_w * 0.35) - 8;
        const track = ui.div(c).grow().h(8).bg(k.ink(0.035)).rounded(3);
        for (h.points, 0..) |point, i| if (std.mem.eql(u8, point.edit.path, file)) {
            const mark = ui.div(c).absolute().offset(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * @max(track_w - 3, 1), 0).size(3, 8).rounded(1).bg(if (i == selected) k.diff_add else k.muted.alpha(0.4));
            mark.end();
        };
        track.end();
        lane.end();
    }
    if (h.files.len > 4) ui.text(c, c.print("+{d} more files · inspect with Details", .{h.files.len - 4}), .{ .size = 10, .color = k.muted });
    if (h.missing > 0 or !a.transcript.complete) ui.text(c, "Partial history · some tools or earlier messages have no recorded diff counts.", kit.style(c, 10, 15, .{ .wrap = true, .color = k.muted }));
    if (a.view.edit_details or hover != null) detail(c, a, k, h.points, selected);
}

fn detail(c: *ui.Context, a: *App, k: theme.Colors, points: []const history.Point, index: usize) void {
    var at = index;
    if (a.view.edit_details) {
        if (c.shortcut(.{ .key = '[', .alt = true })) at -|= 1;
        if (c.shortcut(.{ .key = ']', .alt = true })) at = @min(at + 1, points.len - 1);
    }
    const box = ui.div(c).column().wFull().pt(8).gap(6);
    defer box.end();
    {
        const row = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer row.end();
        if (button(c, k, "Previous")) at -|= 1;
        if (button(c, k, "Next")) at = @min(at + 1, points.len - 1);
        ui.text(c, c.print("{d}/{d} · Alt+[ / Alt+]", .{ at + 1, points.len }), .{ .size = 10, .color = k.muted });
    }
    if (at != index) {
        a.view.edit_selected = at;
        a.view.edit_details = true;
    }
    const p = points[at];
    ui.text(c, p.edit.path, kit.style(c, 11, 16, .{ .mono = true, .wrap = true, .color = k.text }));
    {
        const row = ui.div(c).row().gap(10);
        defer row.end();
        if (p.edit.additions) |v| ui.text(c, c.print("+{d}", .{v}), .{ .size = 11, .color = k.diff_add });
        if (p.edit.deletions) |v| ui.text(c, c.print("−{d}", .{v}), .{ .size = 11, .color = k.diff_del });
        if (p.edit.additions == null or p.edit.deletions == null) ui.text(c, "Line counts unavailable", .{ .size = 10, .color = k.muted });
        if (p.edit.new_file) ui.text(c, "New file", .{ .size = 10, .color = k.muted });
    }
    ui.text(c, "Per-edit timestamps and durations are not recorded by this engine.", kit.style(c, 10, 15, .{ .wrap = true, .color = k.muted }));
    if (p.turn_started) |ms| ui.text(c, c.print("Turn started: {s} (not edit time)", .{stamp(c, ms)}), .{ .size = 10, .color = k.muted });
    if (p.edit.old_text) |text| snippet(c, k, text, false);
    if (p.edit.new_text) |text| {
        snippet(c, k, text, true);
    } else ui.text(c, "Diff text unavailable · sidecar-only, legacy or binary result", kit.style(c, 10, 15, .{ .wrap = true, .color = k.muted }));
}
fn button(c: *ui.Context, k: theme.Colors, text: []const u8) bool {
    const b = ui.div(c).row().px(8).py(4).rounded(4).bg(k.ink(0.04)).control();
    defer b.end();
    ui.text(c, text, .{ .size = 11, .color = k.text });
    return b.clicked();
}
fn snippet(c: *ui.Context, k: theme.Colors, text: []const u8, added: bool) void {
    if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) {
        ui.text(c, "Binary/non-text content · preview unavailable", .{ .size = 10, .color = k.muted });
        return;
    }
    ui.text(c, if (added) "After (excerpt)" else "Before (excerpt)", .{ .size = 10, .color = k.muted });
    // These are actual before/after excerpts, not a fabricated unified patch.
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (count == 3) break;
        var end = @min(line.len, 160);
        while (end < line.len and end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
        ui.text(c, line[0..end], kit.style(c, 10, 14, .{ .mono = true, .wrap = true, .color = if (added) k.diff_add else k.diff_del }));
        count += 1;
    }
}
fn stamp(c: *ui.Context, ms: u64) []const u8 {
    if (ms > 253402271999000) return "timestamp outside supported range";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 + 8 * 3600 };
    const day = epoch.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const t = epoch.getDaySeconds();
    return c.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} SGT", .{ day.year, @backingInt(md.month), md.day_index + 1, t.getHoursIntoDay(), t.getMinutesIntoHour(), t.getSecondsIntoMinute() });
}

fn activePath(a: *const App) ?[]const u8 {
    var entry = a.transcript.entries.items.len;
    while (entry > 0) {
        entry -= 1;
        const e = a.transcript.entries.items[entry];
        if (e.role != .assistant or e.status != .streaming) continue;
        var part = e.parts.items.len;
        while (part > 0) {
            part -= 1;
            const p = e.parts.items[part];
            if (p.kind == .tool and !p.resolved and !p.is_error and p.path.len > 0 and
                (p.tool == .writeFile or p.tool == .editFile or p.tool == .applyPatch)) return p.path;
        }
    }
    return null;
}
