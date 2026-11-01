//! Above the composer once the latest turn is done (shell.rs
//! `render_turn_work_cue`): a solid "N files changed" card that opens the
//! Changes pane. Nothing while the turn works: the transcript shows the
//! command and the composer has Stop.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const turn_work = @import("turn_work.zig");
const panels = @import("app_panels.zig");
const App = @import("app.zig").App;

/// The card's height, and how far above the composer's top it starts
/// (`top(px(-52.0))`): 8 clear of the pill.
pub const height: f32 = 44;
pub const lift: f32 = 52;

/// Tailwind's `shadow-sm`, as GPUI's `shadow_sm`.
const shadow_sm = [_]ui.Shadow{
    .{ .color = .{ .a = 0.1 }, .blur = 3, .y = 1 },
    .{ .color = .{ .a = 0.1 }, .blur = 2, .y = 1, .spread = -1 },
};

/// The latest turn's edits, when the card should show them.
pub fn changes(c: *ui.Context, a: *App) ?turn_work.TurnChanges {
    if (a.selected == null or a.wizard != null) return null;
    if (a.selectedStatus() == .working) return null;
    return turn_work.latestTurnChanges(c.alloc(), a.transcript.entries.items);
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
    var b = ui.div(c).row().w(w).h(height).px(12 + 1).gap(8).itemsCenter().rounded(10).border(k.border).borderW(1).bg(k.card).shadows(&shadow_sm);
    if (b.hovered()) b = b.bg(k.raised);
    defer b.end();
    if (b.clicked()) show(a);
    icons.icon(c, .document, 16, k.accent, 0);
    const on = showing(a);
    const stats = t.additions + t.deletions > 0;
    const plus = c.print("+{d}", .{t.additions});
    const minus = c.print("-{d}", .{t.deletions});
    const mono: ui.TextStyle = .{ .size = 12, .mono = true };
    const badge = if (on) "Showing" else "Review";
    const badge_st: ui.TextStyle = .{ .size = 11, .line_height = 11 * 1.618, .weight = .medium };
    // What the words have once the glyph, the counts and the badge are in.
    var room = w - 2 * 13 - 16 - 8 - (8 + 2 * 8 + c.text.width(badge, badge_st));
    if (stats) room -= 8 + c.text.width(plus, mono) + 6 + c.text.width(minus, mono);
    {
        const words = ui.div(c).column().grow().w(0).clip();
        defer words.end();
        // The frame keeps the words: not a buffer on this stack.
        const buf = c.alloc().alloc(u8, 32) catch return;
        ui.text(c, t.title(buf), .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = k.text });
        kit.ellipsisText(c, t.names(c.alloc()), .{ .size = 11, .line_height = 11 * 1.618, .color = k.muted }, @max(0, room));
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
    const pill = ui.div(c).row().h(24).px(8).itemsCenter().rounded(6).bg(if (on) k.accent_wash else k.raised);
    defer pill.end();
    var st = badge_st;
    st.color = if (on) k.accent else k.muted;
    ui.text(c, badge, st);
}
