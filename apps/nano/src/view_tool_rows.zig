//! Task-tree chrome shared by tool rows: desktop geometry, results and
//! bounded motion. The SVG elbow cache has only 33 possible paths.
const std = @import("std");
const ui = @import("nanoui").ui;
const rows = @import("tool_rows.zig");
const kit = @import("view_kit.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const tr = @import("transcript.zig");

/// The disclosure rotates over 140ms; both sizes share 17 cached SVGs.
pub fn chevron(c: *ui.Context, k: theme.Colors, open: bool, size: f32) void {
    const target: f32 = if (open) 1 else 0;
    const t = if (c.reduced_motion) target else ui.motion.number(c, "tool-disclosure", target, .{ .tween = .{ .duration = 0.140, .ease = ui.motion.Easing.css_ease_out } });
    const tick: u32 = @intFromFloat(@round(std.math.clamp(t, 0, 1) * 16));
    const angle = -90 * (1 - @as(f32, @floatFromInt(tick)) / 16);
    _ = ui.svg(c, .{ .key = c.print("tool-disclosure-{d}-{d}", .{ @as(u32, @intFromFloat(size)), tick }), .bytes = c.print("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 14 14\"><path fill=\"none\" stroke=\"black\" stroke-width=\"1.1\" stroke-linecap=\"round\" stroke-linejoin=\"round\" transform=\"rotate({d} 7 7)\" d=\"M4 5.5 L7 8.5 L10 5.5\"/></svg>", .{angle}), .size = size, .color = k.muted });
}

pub fn counts(c: *ui.Context, k: theme.Colors, additions: u64, deletions: u64) void {
    const box = ui.div(c).row().gap(6).itemsCenter();
    defer box.end();
    if (additions > 0) ui.text(c, c.print("+{d}", .{additions}), kit.style(c, 11, 18, .{ .color = k.success }));
    if (deletions > 0) ui.text(c, c.print("−{d}", .{deletions}), kit.style(c, 11, 18, .{ .color = k.danger }));
}

pub fn trail(c: *ui.Context, k: theme.Colors, result: rows.Result, opacity: f32) void {
    var box = ui.div(c).row().itemsCenter().motion(.{ .opacity = opacity });
    if (result.washed()) {
        const label = result.passed;
        box = box.w(@max(80, c.text.width(label, .{ .size = 11, .weight = .semibold }) + 12)).justifyEnd();
    }
    defer box.end();
    switch (result) {
        .settled, .failed => {},
        .running => |ms| if (ms) |elapsed| {
            const buf = c.alloc().alloc(u8, 32) catch return;
            ui.text(c, rows.timer(buf, elapsed), kit.style(c, 11, 18, .{ .color = k.muted }));
            if (c.reduced_motion) c.frameIn(1) else kit.loaderFrame(c, 0.1);
        },
        .summary => |text| ui.text(c, text, kit.style(c, 11, 18, .{ .color = k.muted })),
        .diff => |d| counts(c, k, d.additions, d.deletions),
        .passed => |text| {
            const color = k.success;
            const pill = ui.div(c).row().h(18).px(6).itemsCenter().rounded(5).bg(color);
            defer pill.end();
            // WCAG luminance comparison, as desktop's fg_on(color).
            const on = foreground(color);
            ui.text(c, text, kit.style(c, 11, 18, .{ .weight = .semibold, .color = on }));
        },
    }
}

fn foreground(bg: ui.Color) ui.Color {
    const channels = [_]f32{ bg.r, bg.g, bg.b };
    const weights = [_]f32{ 0.2126, 0.7152, 0.0722 };
    var l: f32 = 0;
    for (channels, weights) |v, w| l += w * (if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4));
    return .hex(if (1.05 / (l + 0.05) >= (l + 0.05) / 0.05) 0xffffff else 0x000000);
}

/// Paint only the rightmost 112 points, leaving result/chevron columns
/// unobscured and the long command clipped before them.
pub fn wash(c: *ui.Context, k: theme.Colors, result: rows.Result, width: f32, height: f32, progress: f32) void {
    if (!result.washed()) return;
    const color = k.success;
    const w = @min(rows.wash_width, width);
    const box = ui.div(c).row().absolute().offset(@max(width - w, 0), 0).size(w, height).rounded(8).clip().motion(.{ .opacity = progress });
    defer box.end();
    // A single cached path/image, not one layout node per dither cell.
    _ = ui.svg(c, .{ .key = "tool-result-wash", .bytes = @embedFile("tool_wash.svg"), .size = rows.wash_width, .color = color });
    if (progress < 1 and !c.reduced_motion) kit.loaderFrame(c, 1.0 / 30.0);
}

/// Rounded 6-point elbow, trunk x=12.5, branch end x=28, glyph x=32.
/// Continuation includes expanded details; it belongs to the preceding
/// row, but is timed to the next arrival.
pub fn rail(c: *ui.Context, k: theme.Colors, icon: icons.Name, failed: bool, height: f32, progress: f32, next: ?f32, predecessor: bool) void {
    const parts = rows.connectorParts(progress, predecessor);
    const color = k.wash(0.12);
    const rail_box = ui.div(c).column().w(rows.gutter).h(height);
    defer rail_box.end();
    const continuation = if (next) |p| std.math.clamp(p / 0.45, 0, 1) else 0;
    const incoming = if (parts.incoming >= 1 and continuation > 0) 10 + @max(height - 10, 0) * continuation else 10 * parts.incoming;
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 12, .y = 0 }, .width = .{ .px = 1 }, .height = .{ .px = incoming }, .background = color }, .none, null);
    if (parts.branch > 0) {
        const box = ui.div(c).row().absolute().offset(12, 10).size(16, 16);
        defer box.end();
        const tick: u32 = @intFromFloat(@round(parts.branch * 32));
        _ = ui.svg(c, .{ .key = c.print("tool-tree-elbow-{d}", .{tick}), .bytes = elbow(c, @as(f32, @floatFromInt(tick)) / 32), .size = 16, .color = color });
    }
    {
        const box = ui.div(c).row().absolute().offset(32, 8).motion(.{ .opacity = parts.branch });
        defer box.end();
        icons.icon(c, icon, 16, if (failed) k.danger else k.muted, 0);
    }
}

const Point = struct { x: f32, y: f32 };
fn distance(a: Point, b: Point) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

fn elbow(c: *ui.Context, progress: f32) []const u8 {
    var points: [26]Point = undefined;
    for (0..25) |i| {
        const t = @as(f32, @floatFromInt(i)) / 24;
        points[i] = .{ .x = 0.5 + 6 * t * t, .y = 6 * (2 * t - t * t) };
    }
    points[25] = .{ .x = 16, .y = 6 };
    var length: f32 = 0;
    for (points[0..25], points[1..]) |a, b| length += distance(a, b);
    var left = length * progress;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(c.alloc(), "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\"><path fill=\"none\" stroke=\"black\" stroke-width=\"1\" d=\"M0.5 0") catch return "";
    for (points[0..25], points[1..]) |a, b| {
        const d = distance(a, b);
        const t = @min(left / @max(d, 0.0001), 1);
        out.print(c.alloc(), " L{d:.3} {d:.3}", .{ a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t }) catch return "";
        left -= d;
        if (left <= 0) break;
    }
    out.appendSlice(c.alloc(), "\"/></svg>") catch return "";
    return out.items;
}

pub fn summary(c: *ui.Context, k: theme.Colors, stats: []const tr.Stat) void {
    const line = ui.div(c).row().h(22).gap(12).itemsCenter().clip();
    defer line.end();
    if (stats.len > 3) {
        var additions: u64 = 0;
        var deletions: u64 = 0;
        for (stats) |s| {
            additions +|= s.additions;
            deletions +|= s.deletions;
        }
        ui.text(c, c.print("{d} files", .{stats.len}), .{ .size = 11, .mono = true, .color = k.muted });
        counts(c, k, additions, deletions);
    } else for (stats) |s| {
        const item = ui.div(c).row().gap(6).itemsCenter();
        defer item.end();
        const path = std.mem.trimEnd(u8, s.path, "/\\");
        const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
        ui.text(c, if (slash) |at| path[at + 1 ..] else path, .{ .size = 11, .mono = true, .color = k.muted });
        counts(c, k, s.additions, s.deletions);
    }
}

/// Slower desktop 3.4s title shimmer (not the per-file scramble clock).
pub fn title(c: *ui.Context, k: theme.Colors, text: []const u8, active: bool, hot: bool, max_w: f32) void {
    const st = kit.style(c, 15, 18, .{ .color = if (hot) k.text else k.muted });
    if (!active or c.reduced_motion) return kit.fadeText(c, text, st, max_w);
    const box = ui.div(c).row().maxW(max_w).clip();
    defer box.end();
    const phase: f32 = @floatCast(@mod(c.time / 3.4, 1));
    var spans: std.ArrayList(ui.Span) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var at: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        const x = @as(f32, @floatFromInt(at)) / @as(f32, @floatFromInt(@max(text.len, 1)));
        const wave = @max(0, 1 - @abs(x - (phase * 1.72 - 0.36)) / 0.36);
        spans.append(c.alloc(), .{ .start = @intCast(at), .end = @intCast(at + cp.len), .color = k.muted.mix(k.text, wave * 0.65) }) catch break;
        at += cp.len;
    }
    ui.richText(c, text, spans.items, st);
    kit.loaderFrame(c, 1.0 / 15.0);
}
