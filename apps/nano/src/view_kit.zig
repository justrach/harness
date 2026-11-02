//! Pieces the window's regions share: text at an exact line height, the
//! square icon buttons of the title bar and sidebar, a title that fades at
//! its right edge instead of being cut, and the "snake" spinner a working
//! session shows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const icons = @import("icons.zig");
const theme = @import("theme.zig");

/// A text style of `size` points whose lines are `line` points tall, as
/// the GPUI app sets them (14 px text on 22 px lines).
pub fn style(c: *ui.Context, size: f32, line: f32, base: ui.TextStyle) ui.TextStyle {
    var s = base;
    s.size = size;
    s.leading = 1;
    const natural = c.text.lineHeight(s);
    s.leading = if (natural > 0) line / natural else 1;
    return s;
}

pub const IconButton = struct {
    size: f32 = 24,
    radius: f32 = 6,
    icon: f32 = 16,
    color: ?ui.Color = null,
    /// Drawn behind it while its menu or panel is open.
    on: bool = false,
    disabled: bool = false,
    /// Its tooltip, where the GPUI app has one.
    tip: ?@import("view_tooltip.zig").Tip = null,
};

/// A square button holding one icon; true when clicked.
pub fn iconButton(c: *ui.Context, k: theme.Colors, name: icons.Name, o: IconButton) bool {
    var b = ui.div(c).row().size(o.size, o.size).center().rounded(o.radius);
    if (o.on) b = b.bg(k.hover) else if (!o.disabled) b = b.hover(k.hover);
    if (o.tip) |t| b = @import("view_tooltip.zig").on(b, k, t);
    if (!o.disabled) b = pressFeedback(b.control());
    defer b.end();
    const clicked = b.clicked() and !o.disabled;
    const color = o.color orelse k.muted;
    icons.icon(c, name, o.icon, if (o.disabled) color.alpha(0.35) else color, 0);
    return clicked;
}

/// A short, reversible press without changing layout or the hit target.
pub fn pressFeedback(d: ui.Div) ui.Div {
    const held = d.interaction().pressed;
    const scale = ui.motion.number(d.c, "press-feedback", if (held) 0.98 else 1, .{
        .tween = .{ .duration = 0.08, .ease = ui.motion.Easing.css_ease_out },
    });
    return d.motion(.{ .scale = scale });
}

/// Active tool labels carry a quiet travelling highlight instead of a
/// separate loader beside every file. Static/history/reduced-motion rows
/// neither animate nor keep a frame timer alive.
pub fn activityText(c: *ui.Context, k: theme.Colors, text: []const u8, st: ui.TextStyle, active: bool) void {
    if (!active or c.reduced_motion or text.len == 0) return ui.text(c, text, st);
    const base = st.color orelse k.muted;
    var spans: std.ArrayList(ui.Span) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var at: usize = 0;
    const phase: f32 = @floatCast(@mod(c.time / 1.8, 1));
    while (it.nextCodepointSlice()) |cp| {
        const x = @as(f32, @floatFromInt(at)) / @as(f32, @floatFromInt(text.len));
        const wave = @max(0, 1 - @abs(x - (phase * 1.6 - 0.3)) / 0.3);
        spans.append(c.alloc(), .{ .start = @intCast(at), .end = @intCast(at + cp.len), .color = base.mix(k.text, wave * 0.65) }) catch break;
        at += cp.len;
    }
    ui.richText(c, text, spans.items, st);
    c.frameIn(1.0 / 30.0);
}

/// `s` in one line at most `max_w` wide: as is when it fits, else cut and
/// faded over its last 20 points (`fade_title`, crates/ui/src/shell.rs).
pub fn fadeText(c: *ui.Context, s: []const u8, st: ui.TextStyle, max_w: f32) void {
    const base = st.color orelse c.theme.text;
    if (max_w <= 0) return;
    const total = c.text.width(s, st);
    if (total <= max_w) return ui.text(c, s, st);
    // GPUI's `edge_faded` label: a 20-point ramp to the box's right edge,
    // pushed out past it while the text barely overflows
    // (`label_fade_outset`), the glyph cut by the box. GPUI fades each
    // pixel; here each glyph takes the alpha at its middle.
    const band: f32 = 20;
    const p = std.math.clamp((total - max_w) / band, 0, 1);
    const right = max_w + band * (1 - p * p * (3 - 2 * p));
    var spans: std.ArrayList(ui.Span) = .empty;
    var at: usize = 0;
    var x0: f32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (x0 >= max_w) break;
        const x1 = c.text.width(s[0 .. at + cp.len], st);
        const t = std.math.clamp((right - (x0 + x1) / 2) / band, 0, 1);
        if (t < 1) spans.append(c.alloc(), .{ .start = @intCast(at), .end = @intCast(at + cp.len), .color = base.alpha(t) }) catch break;
        at += cp.len;
        x0 = x1;
    }
    const box = ui.div(c).row().w(max_w).clip();
    defer box.end();
    var plain = st;
    plain.color = base;
    ui.richText(c, s[0..at], spans.items, plain);
}

/// `fadeText` with `query`'s words washed as a search result shows them
/// (`popover::search_highlight`): the match in the accent (`code_text`) on
/// its rounded wash (`code_wash`, 1 point past the glyphs, 1.5 in from the
/// line), case aside; no query or no match is `fadeText`.
pub fn highlightText(c: *ui.Context, k: theme.Colors, s: []const u8, st: ui.TextStyle, max_w: f32, query: []const u8) void {
    if (max_w <= 0) return;
    if (std.mem.trim(u8, query, " \t").len == 0) return fadeText(c, s, st, max_w);
    const ranges = @import("palette.zig").matchRanges(c.alloc(), s, query) catch &.{};
    if (ranges.len == 0) return fadeText(c, s, st, max_w);
    const base = st.color orelse c.theme.text;
    const wash = k.accent_wash;
    var plain = st;
    plain.color = base;
    if (comptime @hasField(ui.TextStyle, "span_box")) plain.span_box = .{ .pad_x = 1, .inset_y = 1.5, .radius = 3 };
    const total = c.text.width(s, st);
    const band: f32 = 20;
    const fades = total > max_w;
    const p = std.math.clamp((total - max_w) / band, 0, 1);
    const right = max_w + band * (1 - p * p * (3 - 2 * p));
    var spans: std.ArrayList(ui.Span) = .empty;
    var at: usize = 0;
    var x0: f32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (fades and x0 >= max_w) break;
        const x1 = if (fades) c.text.width(s[0 .. at + cp.len], st) else 0;
        const t: f32 = if (fades) std.math.clamp((right - (x0 + x1) / 2) / band, 0, 1) else 1;
        const lit = for (ranges) |r| {
            if (at >= r.start and at < r.end) break true;
        } else false;
        if (lit or t < 1) spans.append(c.alloc(), .{
            .start = @intCast(at),
            .end = @intCast(at + cp.len),
            .color = if (lit) k.accent.alpha(t) else base.alpha(t),
            .background = if (lit) wash.alpha(t) else null,
        }) catch break;
        at += cp.len;
        x0 = x1;
    }
    if (!fades) return ui.richText(c, s, spans.items, plain);
    const box = ui.div(c).row().w(max_w).clip();
    defer box.end();
    ui.richText(c, s[0..at], spans.items, plain);
}

/// A muted key-cap inside a row or header (`popover::kbd_hint`): 5 across,
/// 1 down, rounded 5, on ink(0.05), 10-point mono.
pub fn kbdHint(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    // Its words as GPUI measures them: a mono run's whole-point width
    // carries a float's excess, which rounding up makes a point more.
    const tw = c.text.width(label, .{ .size = 10, .mono = true });
    const b = ui.div(c).row().w(10 + @floor(tw + 1)).px(5).py(1).rounded(5).bg(k.ink(0.05)).itemsCenter();
    defer b.end();
    // In the frame's memory: the text is drawn after the caller returns.
    ui.text(c, c.alloc().dupe(u8, label) catch return, .{ .size = 10, .line_height = 16, .mono = true, .color = k.muted });
}

/// `s` with its key glyphs (⌘, ⇧, ↵, ↑…), which Geist hasn't, in the
/// system's font, as GPUI falls back to it; the rest in `st`.
pub fn glyphText(c: *ui.Context, s: []const u8, st: ui.TextStyle) void {
    if (!comptime @hasField(ui.TextStyle, "system_font")) return ui.text(c, s, st);
    const r = ui.div(c).row().itemsCenter();
    defer r.end();
    var at: usize = 0;
    while (at < s.len) {
        const ascii = s[at] < 0x80;
        var end = at;
        while (end < s.len and (s[end] < 0x80) == ascii) end += 1;
        // A non-ASCII run ends where an ASCII byte starts.
        var part = st;
        if (!ascii) {
            part.system_font = true;
            part.mono = false;
        }
        ui.text(c, s[at..end], part);
        at = end;
    }
}

/// `s` in one line at most `max_w` wide, cut with an ellipsis (the tab
/// list's titles).
pub fn ellipsisText(c: *ui.Context, s: []const u8, st: ui.TextStyle, max_w: f32) void {
    if (c.text.width(s, st) <= max_w) return ui.text(c, s, st);
    // `truncate_line`: the cut's trailing blanks and ASCII punctuation go.
    const kept = std.mem.trimEnd(u8, s[0..truncateAt(c, s, st, max_w)], " \t\n\r!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
    ui.text(c, c.print("{s}…", .{kept}), st);
}

/// Where GPUI cuts `s` for an ellipsis (`LineWrapper::should_truncate_line`):
/// each character's own width added up, the cut at the last character
/// before which the text and the ellipsis still come in under `max_w`.
pub fn truncateAt(c: *ui.Context, s: []const u8, st: ui.TextStyle, max_w: f32) usize {
    const suffix = c.text.width("…", st);
    var width: f32 = 0;
    var cut: usize = 0;
    var at: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (width + suffix < max_w) cut = at;
        width += c.text.width(cp, st);
        if (@floor(width) > max_w) return cut;
        at += cp.len;
    }
    return s.len;
}

/// The 2×3 "snake" a working session shows: rows in the accent's three
/// tones, lit clockwise at 15 Hz (`loaders.rs`). Asks for its next frame.
pub fn snake(c: *ui.Context, k: theme.Colors) void {
    const order = [_][2]u8{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } };
    const step: usize = if (c.reduced_motion) 0 else @intFromFloat(@mod(@floor(c.time * 15), 6));
    const box = ui.div(c).column().size(5, 8).gap(1);
    defer box.end();
    for (0..3) |row| {
        const r = ui.div(c).row().gap(1);
        defer r.end();
        for (0..2) |col| {
            var lit: f32 = 0.22;
            for (0..3) |back| {
                const p = order[(step + 6 - back) % 6];
                if (p[0] == col and p[1] == row) {
                    lit = @max(lit, 1.0 - @as(f32, @floatFromInt(back)) * 0.3);
                }
            }
            _ = c.leaf(.{ .width = .{ .px = 2 }, .height = .{ .px = 2 }, .background = k.glyph[row].alpha(lit) }, .none, null);
        }
    }
    if (!c.reduced_motion) c.frameIn(1.0 / 15.0);
}

/// A small round dot.
pub fn dot(c: *ui.Context, size: f32, color: ui.Color) void {
    _ = c.leaf(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = size / 2, .background = color }, .none, null);
}

/// GPUI's `shadow_lg` (Tailwind's): two faint layers, with a nanoui that
/// has layered shadows (justrach/nanoui#21); its own large one before.
/// A right-click on `d` (its context menu), with a nanoui that has them
/// (justrach/nanoui secondary clicks); never, before.
pub fn secondaryClicked(d: ui.Div) bool {
    if (comptime @hasDecl(ui.Div, "secondaryClicked")) return d.secondaryClicked();
    return false;
}

/// GPUI's `tab_index(0)` with `focus_visible`: a press focuses the box,
/// and while it has the focus and the keyboard was used last, a ring of
/// `width` in `color` (GPUI's `border_2().border_color(accent)`). True
/// while it shows: GPUI's border grows the box, so the caller pads it by
/// `width` more.
pub fn focusRing(c: *ui.Context, d: ui.Div, color: ui.Color, width: f32) bool {
    const it = c.interact(d.index, .{ .focusable = true });
    const keyboard = if (comptime @hasField(ui.Context, "keyboard_modality")) c.keyboard_modality else false;
    if (!it.focused or !keyboard) return false;
    _ = d.border(color).borderW(width);
    return true;
}

/// A line's height as GPUI's layout measures it: up to the device pixel
/// (a half point at 2x; taffy.rs rounds a measured size up). Where nano's
/// boxes are centred on what text measures (a dialog in the window), the
/// centre lands where GPUI's does.
pub fn measured(line_height: f32) f32 {
    return @ceil(line_height * 2 - 0.001) / 2;
}

/// A box's height as last laid out, kept in `slot` for what's placed by it
/// (a menu kept inside the window); when it changed, another frame, so the
/// placement uses it now rather than at the next redraw.
pub fn rememberHeight(c: *ui.Context, d: ui.Div, slot: *?f32) void {
    const r = c.rects.get(c.node(d.index).id) orelse {
        c.animating = true;
        return;
    };
    if (slot.* == null or slot.*.? != r.h) {
        slot.* = r.h;
        c.animating = true;
    }
}

/// The menu cards drawn (`noteCard`), last frame's and this one's, for
/// `pressedOutside`.
var cards: [2][16]ui.Rect = undefined;
var cards_n: [2]usize = .{ 0, 0 };

/// A secondary press this frame (nanoui 0.7 has none).
fn secondary(c: *ui.Context) bool {
    return if (comptime @hasField(@TypeOf(c.input), "secondary")) c.input.secondary else false;
}

/// A new frame: this frame's cards become last frame's, and whether the
/// pointer moved (or pressed) since the last.
pub fn beginFrame(c: *ui.Context, k: theme.Colors) void {
    surface_frame = .{ .context = c, .frame = c.frame, .frosted = k.frosted, .overlay = k.overlay };
    cards[0] = cards[1];
    cards_n[0] = cards_n[1];
    cards_n[1] = 0;
    const m = c.input.mouse;
    pointer_moved = m.x != last_mouse.x or m.y != last_mouse.y or c.input.pressed or secondary(c);
    last_mouse = m;
}

var last_mouse: ui.Point = .{ .x = -1e6, .y = -1e6 };
var pointer_moved = false;
/// GPUI's `on_hover` listener (`motion::hover_listener`): the box's hover
/// flips only when the pointer moves or presses, so a menu or dialog that
/// opens under a still pointer leaves it hovered, and one that closes
/// doesn't hover what was under it. Its fill eases as `Div.hover`'s.
/// `hovers` keeps each box's, by id.
pub fn listenerHover(hovers: *std.AutoHashMapUnmanaged(u64, bool), d: ui.Div, color: ui.Color) struct { div: ui.Div, hovered: bool } {
    const c = d.c;
    const id = c.node(d.index).id;
    const gop = hovers.getOrPut(c.gpa, id) catch return .{ .div = d.hover(color), .hovered = d.hovered() };
    if (!gop.found_existing) gop.value_ptr.* = false;
    if (pointer_moved) gop.value_ptr.* = d.hovered();
    const on = gop.value_ptr.*;
    const t = c.animate(id, 0x484f56, if (on) 1 else 0, 18);
    const st = &c.node(d.index).style;
    const base = st.background orelse color.alpha(0);
    st.background = base.mix(color, t);
    return .{ .div = d, .hovered = on };
}

/// A menu card, as it was last drawn.
pub fn noteCard(c: *ui.Context, d: ui.Div) void {
    const r = c.rects.get(c.node(d.index).id) orelse return;
    if (cards_n[1] == cards[1].len) return;
    cards[1][cards_n[1]] = r;
    cards_n[1] += 1;
}

/// `on_mouse_down_out`: a press (either button) begun this frame outside
/// every menu card drawn last frame and outside `trigger`. The press goes
/// on to what's under it, as GPUI's does; a menu not yet drawn isn't
/// pressed out of.
pub fn pressedOutside(c: *ui.Context, trigger: ?ui.Rect) bool {
    if (!c.input.pressed and !secondary(c)) return false;
    if (cards_n[0] == 0) return false;
    if (trigger) |t| if (t.contains(c.input.mouse)) return false;
    for (cards[0][0..cards_n[0]]) |r| if (r.contains(c.input.mouse)) return false;
    return true;
}

// Frame-local construction data only: completed nodes own their tints.
// Context/frame guards prevent one window or Tester leaking into another.
var surface_frame: ?struct { context: *ui.Context, frame: u64, frosted: bool, overlay: ui.Color } = null;
const glass_shadows = blk: {
    var shadows = ui.Shadow.lg;
    if (@hasField(ui.Shadow, "knockout")) for (&shadows) |*s| {
        s.knockout = true;
    };
    break :blk shadows;
};

pub fn shadowLg(d: ui.Div) ui.Div {
    var pane = d;
    if (surface_frame) |s| if (s.context == d.c and s.frame == d.c.frame and s.frosted) {
        pane = pane.bg(s.overlay);
        // Transparent glass must not reveal the shadow inside its own box.
        if (comptime @hasField(ui.Shadow, "knockout")) return pane.shadows(&glass_shadows);
        return pane;
    };
    if (comptime @hasDecl(ui.Shadow, "lg")) return pane.shadows(&ui.Shadow.lg);
    return pane.shadowLg();
}

/// `gradient_spinner` with 3-point cells: a 3×3 grid tinted per row from
/// the sunrise gradient (`GSPIN_ROW_TINTS`), each cell pulsing once per
/// 750 ms, the wave travelling upward.
const cell: f32 = 3;
pub const spinner_w: f32 = 3 * cell + 2 * cell / 2;
const tints = [_]u24{ 0xB6D3EF, 0xEDB185, 0xF888A0 };

pub fn gradientSpinner(c: *ui.Context) void {
    const delta: f32 = @floatCast(@mod(c.time / 0.75, 1.0));
    const g = ui.div(c).column().gap(cell / 2);
    defer g.end();
    for (0..3) |row| {
        const r = ui.div(c).row().gap(cell / 2);
        defer r.end();
        for (0..3) |col| {
            const d = 2 - @as(f32, @floatFromInt(row)) + @abs(@as(f32, @floatFromInt(col)) - 1);
            const tint: ui.Color = .hex(tints[row]);
            _ = c.leaf(.{ .width = .{ .px = cell }, .height = .{ .px = cell }, .radius = cell / 2, .background = tint.alpha(gspinOpacity(delta + d / 4, 0.1)) }, .none, null);
        }
    }
    c.frameIn(1.0 / 30.0);
}

/// `gspin_opacity`: full, down to `dim` over 45% of the period, resting,
/// then back up over the last 8%.
pub fn gspinOpacity(t_: f32, dim: f32) f32 {
    const t = @mod(t_, 1.0);
    if (t < 0.45) return 1 + (dim - 1) * (t / 0.45);
    if (t < 0.92) return dim;
    return dim + (1 - dim) * ((t - 0.92) / 0.08);
}

test "the spinner's pulse, as GPUI's" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), gspinOpacity(0, 0.1), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), gspinOpacity(0.45, 0.1), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), gspinOpacity(0.7, 0.1), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), gspinOpacity(0.99999, 0.1), 1e-3);
}
