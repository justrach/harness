//! The session footer under an open chat's composer (pickers.rs
//! `render_footer`): for a project with git, read-only labels at the left,
//! where the chat runs ("Graff worktree", "Worktree" or "Local checkout")
//! and its branch (else "No ref"); a Graff worktree adds its actions
//! (`render_graff_worktree_actions`). At the right, the branch's pull
//! request: its merge controls, then its badge (view_change_requests.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const workspace = @import("workspace.zig");
const graff_worktree = @import("graff_worktree.zig");
const actions = @import("app_graff_worktree.zig");
const prs = @import("view_change_requests.zig");
const App = @import("app.zig").App;

/// The slot the composer keeps for it (`SESSION_FOOTER_HEIGHT`), 8 points
/// under the pill.
pub const height: f32 = 24;
pub const gap: f32 = 8;

/// `FOOTER_LABEL_MIN_WIDTH`: two 8-point insets, a 12-point glyph and the
/// 6-point gap; only the words give way.
const label_min_w: f32 = 34;
const label_max_w: f32 = 160;
const phi: f32 = 1.618;

/// Where a chat runs, as the footer names it.
pub const Checkout = enum {
    local,
    worktree,
    graff,

    pub fn label(x: Checkout) []const u8 {
        return switch (x) {
            .local => "Local checkout",
            .worktree => "Worktree",
            .graff => "Graff worktree",
        };
    }

    pub fn icon(x: Checkout) icons.Name {
        return if (x == .local) .folder else .@"folder-with-files";
    }
};

/// A Graff worktree, else another folder than the project's, else the
/// project's own checkout (`render_footer`).
pub fn checkoutOf(chat: workspace.Chat, space: workspace.Space) Checkout {
    const cwd = chat.cwd orelse return .local;
    if (graff_worktree.GraffWorktree.fromPath(cwd) != null) return .graff;
    return if (std.mem.eql(u8, cwd, space.path)) .local else .worktree;
}

/// The footer's row, `w` wide, for the open chat; nothing without a
/// project that has git.
pub fn footer(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const id = a.selected orelse return;
    const chat = a.findChat(id) orelse return;
    const space = a.findSpace(chat.space_id) orelse return;
    if (!space.git) return;
    const kind = checkoutOf(chat, space);
    // `workspace_footer_row().px(10).pr_0()`.
    const row = ui.div(c).row().w(w).h(height).pl(10).gap(4).itemsCenter().clip();
    defer row.end();
    label(c, k, kind.icon(), kind.label());
    label(c, k, .@"git-branch", chat.row_branch orelse "No ref");
    if (kind == .graff) if (chat.cwd) |cwd| if (graff_worktree.GraffWorktree.fromPath(cwd)) |tree| card(c, a, k, chat.id, tree);
    // PR and merge are the trailing group, whatever the branch's length.
    const spring = ui.div(c).grow().w(0);
    spring.end();
    const pr = @import("app_change_requests.zig").forChat(a, chat) orelse return;
    prs.mergeControls(c, a, k, chat, pr[0]);
    prs.badge(c, k, pr[0], pr[1], .composer, true);
}

/// `footer_label`: a 12-point glyph and words, quiet, 20 tall.
fn label(c: *ui.Context, k: theme.Colors, icon: icons.Name, text: []const u8) void {
    const color = k.muted.alpha(0.6);
    const b = ui.div(c).row().h(20).px(8).gap(6).itemsCenter().minW(label_min_w);
    defer b.end();
    icons.icon(c, icon, 12, color, 0);
    kit.ellipsisText(c, text, .{ .size = 12, .line_height = 12 * phi, .weight = .medium, .color = color }, label_max_w - label_min_w);
}

/// `render_graff_worktree_actions`: after a hairline, Merge back, Archive
/// and Remove (and "Discard anyway" once Graff said the tree's work is
/// nowhere else), then Graff's last verdict.
fn card(c: *ui.Context, a: *App, k: theme.Colors, chat_id: []const u8, tree: graff_worktree.GraffWorktree) void {
    const s = &a.graff_worktree;
    const busy = if (s.busy) |b| std.mem.eql(u8, b, chat_id) else false;
    const status = s.statusFor(chat_id);
    // `ml(4)`, then the card's left border and `pl(6)`.
    const outer = ui.div(c).row().pl(4).itemsCenter();
    defer outer.end();
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 20 }, .background = k.border.alpha(0.6) }, .none, null);
    const box = ui.div(c).row().pl(6).gap(2).itemsCenter();
    defer box.end();
    if (button(c, k, "Merge back", false, busy)) actions.run(a, chat_id, "merge");
    if (button(c, k, "Archive", false, busy)) actions.run(a, chat_id, "archive");
    if (button(c, k, "Remove", false, busy)) actions.run(a, chat_id, "remove");
    if (status) |st| if (st.can_discard) {
        if (button(c, k, "Discard anyway", true, busy)) actions.run(a, chat_id, "discard");
    };
    const st: ui.TextStyle = .{ .size = 11.5, .line_height = 11.5 * phi };
    if (busy) {
        verdict(c, c.print("Asking Graff about {s}…", .{tree.name}), k.muted.alpha(0.7), st);
    } else if (status) |v| {
        const color = switch (v.outcome) {
            .done => k.success,
            .kept => k.warning,
            .failed => k.danger,
        };
        verdict(c, v.message, color, st);
    }
}

fn verdict(c: *ui.Context, text: []const u8, color: ui.Color, base: ui.TextStyle) void {
    var st = base;
    st.color = color;
    const v = ui.div(c).row().px(6);
    defer v.end();
    kit.ellipsisText(c, text, st, 320 - 12);
}

/// A worktree action: 20 tall, 12-point medium words, quiet until hovered.
fn button(c: *ui.Context, k: theme.Colors, text: []const u8, danger: bool, busy: bool) bool {
    var b = ui.div(c).row().h(20).px(7).itemsCenter().rounded(6);
    if (busy) b = b.opacity(0.45) else b = b.hover(k.hover);
    defer b.end();
    const hot = !busy and b.hovered();
    const color = if (danger)
        (if (hot) k.danger else k.danger.alpha(0.7))
    else if (hot) k.text.alpha(0.85) else k.muted.alpha(0.7);
    ui.text(c, text, .{ .size = 12, .line_height = 12 * phi, .weight = .medium, .color = color });
    return !busy and b.clicked();
}

const testing = std.testing;

test "where a chat runs: a Graff worktree, another folder, or the project's checkout" {
    const space: workspace.Space = .{ .id = "s", .path = "/work/app", .name = "app", .git = true };
    var chat: workspace.Chat = .{ .id = "a", .title = null, .space_id = "s", .archived = false, .preview = null, .harness = null, .model = null, .cwd = "/work/app" };
    try testing.expectEqual(Checkout.local, checkoutOf(chat, space));
    chat.cwd = null;
    try testing.expectEqual(Checkout.local, checkoutOf(chat, space));
    chat.cwd = "/work/app-wt/feature";
    try testing.expectEqual(Checkout.worktree, checkoutOf(chat, space));
    chat.cwd = "/work/app/.graff/worktrees/harness-ab12";
    try testing.expectEqual(Checkout.graff, checkoutOf(chat, space));
}
