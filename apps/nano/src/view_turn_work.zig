//! Legacy composer cue helpers. Current desktop removed this separate
//! card (e941a1f0d): per-file changes now live in the task-tree footer.
//! Keep the drawing API while shared layout callers migrate, but never
//! offer a second summary above the composer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const turn_work = @import("turn_work.zig");
const panels = @import("app_panels.zig");
const App = @import("app.zig").App;

/// The card's least height (`min_h(44)`), and the gap it keeps over the
/// pill: it grows upward from there as its names wrap (`bottom_full`,
/// `mb(SPACE_SM)`).
pub const min_height: f32 = 44;
pub const gap: f32 = 8;

const title_st: ui.TextStyle = .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium };
const names_st: ui.TextStyle = .{ .size = 11, .line_height = 11 * 1.618, .wrap = true };
const badge_st: ui.TextStyle = .{ .size = 11, .line_height = 11 * 1.618, .weight = .medium };
const mono: ui.TextStyle = .{ .size = 12, .mono = true };
/// The border and `py(SPACE_SM)` above and below the content.
const inset: f32 = 1 + 8;
/// The Review pill: `py(4)` round its line, at least 24 (`min_h(24)`).
const badge_h: f32 = @max(24, 2 * 4 + 11 * 1.618);

/// What the names have once the glyph, the counts and the badge are in.
fn namesRoom(c: *ui.Context, t: turn_work.TurnChanges, w: f32, on: bool) f32 {
    var room = w - 2 * (12 + 1) - 16 - 8 - (8 + 2 * 8 + c.text.width(if (on) "Showing" else "Review", badge_st));
    if (t.additions + t.deletions > 0) room -= 8 + c.text.width(c.print("+{d}", .{t.additions}), mono) + 6 + c.text.width(c.print("-{d}", .{t.deletions}), mono);
    return @max(64, room);
}

/// The card's height at `w`: the title over the wrapped names, or the
/// badge if taller, inside the inset; never under `min_height`.
pub fn cardHeight(c: *ui.Context, a: *App, t: turn_work.TurnChanges, w: f32) f32 {
    const lines = c.text.wrap(t.names(c.alloc()), names_st, namesRoom(c, t, w, showing(a))).len;
    const words = 13 * 1.618 + @as(f32, @floatFromInt(@max(1, lines))) * 11 * 1.618;
    return @max(min_height, 2 * inset + @max(words, badge_h));
}

/// Tailwind's `shadow-sm`, as GPUI's `shadow_sm`.
const shadow_sm = [_]ui.Shadow{
    .{ .color = .{ .a = 0.1 }, .blur = 3, .y = 1 },
    .{ .color = .{ .a = 0.1 }, .blur = 2, .y = 1, .spread = -1 },
};

/// No detached cue in current desktop; the tree owns its file summaries.
pub fn changes(c: *ui.Context, a: *App) ?turn_work.TurnChanges {
    _ = c;
    _ = a;
    return null;
}

/// Whether the right pane shows the working tree's diff now.
fn showing(a: *App) bool {
    if (!a.panels.host_open) return false;
    const t = a.panels.activeTab() orelse return false;
    return t.kind == .diffs;
}

/// Open the right pane on the Changes tab, reusing an open one
/// (`show_turn_changes`).
fn show(a: *App) void {
    for (a.panels.tabs.items, 0..) |t, i| if (t.kind == .diffs) {
        a.panels.host_open = true;
        return panels.showTab(a, i);
    };
    panels.addDiffsTab(a);
}

/// The card, `w` wide.
pub fn card(c: *ui.Context, a: *App, k: theme.Colors, t: turn_work.TurnChanges, w: f32) void {
    ui.key(c, "turn-changes-card");
    var b = ui.div(c).row().w(w).h(cardHeight(c, a, t, w)).px(12 + 1).py(inset).gap(8).itemsCenter().rounded(10).border(k.border).borderW(1).bg(k.card).shadows(&shadow_sm);
    if (b.hovered()) b = b.bg(k.raised);
    defer b.end();
    if (b.clicked()) show(a);
    icons.icon(c, .document, 16, k.accent, 0);
    const on = showing(a);
    const stats = t.additions + t.deletions > 0;
    const plus = c.print("+{d}", .{t.additions});
    const minus = c.print("-{d}", .{t.deletions});
    const badge = if (on) "Showing" else "Review";
    {
        // The names wrap rather than cut off (75560f0fb).
        const words = ui.div(c).column().w(namesRoom(c, t, w, on));
        defer words.end();
        // The frame keeps the words: not a buffer on this stack.
        const buf = c.alloc().alloc(u8, 32) catch return;
        var st = title_st;
        st.color = k.text;
        ui.text(c, t.title(buf), st);
        var ns = names_st;
        ns.color = k.muted;
        ui.text(c, t.names(c.alloc()), ns);
    }
    if (stats) {
        const counts = ui.div(c).row().gap(6).itemsCenter();
        defer counts.end();
        var st = mono;
        st.color = k.success;
        ui.text(c, plus, st);
        st.color = k.danger;
        ui.text(c, minus, st);
    }
    const pill = ui.div(c).row().h(badge_h).px(8).itemsCenter().rounded(6).bg(if (on) k.accent_wash else k.raised);
    defer pill.end();
    var st = badge_st;
    st.color = if (on) k.accent else k.muted;
    ui.text(c, badge, st);
}
