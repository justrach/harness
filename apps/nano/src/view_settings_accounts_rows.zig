//! Settings › Accounts' pieces (settings/accounts.rs, settings/widgets.rs,
//! popover.rs): the strips, badges and buttons, an account's row with its
//! usage meters, the skeleton row a loading card shows, and the provider
//! sections (Claude Code, Codex, Cursor).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const tip = @import("view_tooltip.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const accounts = @import("accounts.zig");

/// Text at `size` on GPUI's line height, rounded as GPUI rounds it to the
/// device pixel (2x): 11.5-point lines are 18.5 tall, not 18.61, and a
/// card of five rows doesn't come out half a point taller.
pub fn st(c: *ui.Context, size: f32, base: ui.TextStyle) ui.TextStyle {
    var s = set.st(c, size, base);
    s.line_height = @round(s.line_height * 2) / 2;
    return s;
}

/// A card row's inside: the column less the card's edges and `px(20)`.
pub fn rowInner() f32 {
    return set.inner_w - 2 - 2 * 20;
}

/// `section_card` `mt` below what's above.
pub fn card(c: *ui.Context, k: theme.Colors, mt: f32) ui.Div {
    set.space(c, mt);
    return ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
}

/// A row's `border_t_1`.
pub fn line(c: *ui.Context, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}

/// `row_title`, cut with an ellipsis at `w`.
pub fn title(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    kit.ellipsisText(c, text, st(c, 13, .{ .weight = .medium, .color = k.text }), @max(w, 24));
}

/// A section's header: its mark in a 24-point box, the name at 14.
pub fn sectionHead(c: *ui.Context, k: theme.Colors, mark: icons.Name, tint: ?ui.Color, name: []const u8) void {
    icons.icon(c, mark, 16, tint orelse k.muted, 24);
    ui.text(c, name, st(c, 14, .{ .weight = .medium, .color = k.text }));
}

/// The initial avatar: a 32-point circle, its letter at 12 semibold.
pub fn avatar(c: *ui.Context, k: theme.Colors, name: []const u8) void {
    const b = ui.div(c).row().size(32, 32).center().roundedFull().border(k.border).borderW(1).bg(k.ink(0.03));
    defer b.end();
    var buf: [4]u8 = undefined;
    ui.text(c, c.print("{s}", .{accounts.initial(&buf, name)}), st(c, 12, .{ .weight = .semibold, .color = k.muted }));
}

/// `badge`: a hairline pill (its edge inside, as GPUI's).
pub fn badge(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const b = ui.div(c).row().px(9).py(3).roundedFull().border(k.border).borderW(1);
    defer b.end();
    ui.text(c, label, st(c, 10.5, .{ .color = k.muted }));
}

pub fn badgeW(c: *ui.Context, label: []const u8) f32 {
    return 18 + c.text.width(label, .{ .size = 10.5 });
}

/// `badge_active`: the emerald pill.
pub fn badgeActive(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const b = ui.div(c).row().px(8).py(2).roundedFull().bg(k.success.alpha(0.12));
    defer b.end();
    ui.text(c, label, st(c, 10.5, .{ .color = k.success.mix(k.text, 0.25).alpha(0.9) }));
}

pub fn badgeActiveW(c: *ui.Context, label: []const u8) f32 {
    return 16 + c.text.width(label, .{ .size = 10.5 });
}

pub const Ghost = struct {
    label: []const u8,
    icon: ?icons.Name = null,
    size: f32 = 12,
    dim: bool = false,
    /// Its `text_tooltip`, after GPUI's default wait.
    tip: []const u8 = "",
};

/// `ghost_action`: muted words, maybe a 16-point icon, a wash under the
/// pointer. True when clicked.
pub fn ghost(c: *ui.Context, k: theme.Colors, g: Ghost) bool {
    var b = ui.div(c).row().px(10).py(6).gap(6).itemsCenter().rounded(8).hover(k.ink(0.06));
    if (g.dim) b = b.opacity(0.5);
    b = tip.on(b, k, .{ .text = g.tip });
    defer b.end();
    const hot = b.hovered();
    if (g.icon) |i| icons.icon(c, i, 16, k.muted, 0);
    ui.text(c, g.label, st(c, g.size, .{ .color = if (hot) k.text else k.muted }));
    return b.clicked();
}

pub fn ghostW(c: *ui.Context, g: Ghost) f32 {
    return 20 + (if (g.icon != null) @as(f32, 16 + 6) else 0) + c.text.width(g.label, .{ .size = g.size });
}

/// `btn_primary` made small (`px(8) py(4) rounded(6)` at 11.5).
pub fn primary(c: *ui.Context, k: theme.Colors, label: []const u8, dim: bool) bool {
    var b = ui.div(c).row().px(8).py(4).rounded(6).bg(k.solid);
    if (dim) b = b.opacity(0.5);
    defer b.end();
    ui.text(c, label, st(c, 11.5, .{ .weight = .medium, .color = k.on_solid }));
    return b.clicked();
}

pub fn primaryW(c: *ui.Context, label: []const u8) f32 {
    return 16 + c.text.width(label, .{ .size = 11.5, .weight = .medium });
}

/// `btn_ghost` made small, as the ChatGPT row's links.
pub fn link(c: *ui.Context, k: theme.Colors, label: []const u8, dim: bool) bool {
    var b = ui.div(c).row().px(8).py(4).rounded(6).hover(k.ink(0.06));
    if (dim) b = b.opacity(0.5);
    defer b.end();
    ui.text(c, label, st(c, 11.5, .{ .color = if (b.hovered()) k.text else k.muted }));
    return b.clicked();
}

/// The icon-only Forget / sign-out: a trash can.
pub fn trash(c: *ui.Context, k: theme.Colors, dim: bool) bool {
    var b = ui.div(c).row().px(6).py(4).rounded(6).hover(k.ink(0.06));
    if (dim) b = b.opacity(0.5);
    defer b.end();
    icons.icon(c, .@"trash-bin-minimalistic", 14, if (b.hovered()) k.text else k.muted, 0);
    return b.clicked();
}

pub const trash_w: f32 = 26;

/// `error_strip`, its words at most the column's width; with "Click to
/// retry" after them for a failed load. True when clicked.
pub fn errorStrip(c: *ui.Context, k: theme.Colors, message: []const u8, retry: bool) bool {
    set.space(c, 16);
    const s = ui.div(c).row().wFull().px(17).py(13).gap(8).itemsStart().rounded(12).border(k.danger.alpha(0.2)).borderW(1).bg(k.danger.alpha(0.06));
    defer s.end();
    const red = k.danger_muted.alpha(0.9);
    {
        const ic = ui.div(c).column().pt(2);
        defer ic.end();
        icons.icon(c, .@"danger-triangle", 16, red, 0);
    }
    const retry_w: f32 = if (retry) 8 + c.text.width("Click to retry", .{ .size = 11.5 }) else 0;
    const style = st(c, 12.5, .{ .color = red });
    const room = @max(set.inner_w - 2 * 17 - 16 - 8 - retry_w, 80);
    if (c.text.width(message, style) <= room) ui.text(c, message, style) else {
        const w = ui.div(c).column().w(room);
        defer w.end();
        var wrapped = style;
        wrapped.wrap = true;
        ui.text(c, message, wrapped);
    }
    if (retry) {
        const r = ui.div(c).column().pt(4);
        defer r.end();
        ui.text(c, "Click to retry", st(c, 11.5, .{ .color = k.muted }));
    }
    return s.clicked();
}

/// `warning_strip`: amber, 8 points under what's above.
pub fn warningStrip(c: *ui.Context, k: theme.Colors, message: []const u8) void {
    set.space(c, 8);
    const s = ui.div(c).row().wFull().px(17).py(11).gap(8).itemsStart().rounded(12).border(k.warning.alpha(0.2)).borderW(1).bg(k.warning.alpha(0.06));
    defer s.end();
    const amber = k.warning.mix(k.text, 0.25).alpha(0.9);
    {
        const ic = ui.div(c).column().pt(2);
        defer ic.end();
        icons.icon(c, .@"danger-triangle", 14, amber, 0);
    }
    const w = ui.div(c).column().w(@max(set.inner_w - 2 * 17 - 14 - 8, 80));
    defer w.end();
    ui.text(c, message, st(c, 12, .{ .wrap = true, .color = amber }));
}

/// The pulse a skeleton breathes with (`HARNESS_PULSE`, 2.4 s), 0 to 1.
fn pulse(c: *ui.Context) f32 {
    c.frameIn(1.0 / 15.0);
    const t: f32 = @floatCast(@mod(c.time / 2.4, 1.0));
    return (1 - @cos(2 * std.math.pi * t)) / 2;
}

/// A ghost account row (`render_skeleton_row`): avatar, email line, two
/// meter ghosts, a badge, the same geometry as a real row.
pub fn skeleton(c: *ui.Context, k: theme.Colors, first: bool, dim: bool) void {
    if (!first) line(c, k);
    const outer = ui.div(c).row().wFull().px(20).py(14);
    defer outer.end();
    const inner = ui.div(c).row().wFull().gap(12).itemsStretch().opacity((0.55 + 0.35 * pulse(c)) * @as(f32, if (dim) 0.6 else 1));
    defer inner.end();
    {
        const a = ui.div(c).column().justifyCenter();
        defer a.end();
        ui.div(c).size(32, 32).roundedFull().bg(k.ink(0.05)).end();
    }
    const col_w = rowInner() - 32 - 12 - 12 - 64;
    {
        const m = ui.div(c).column().w(col_w);
        defer m.end();
        ui.div(c).w(@min(176, col_w * 0.6)).h(13).rounded(4).bg(k.ink(0.05)).end();
        set.space(c, 8);
        const rows = ui.div(c).column().gap(7);
        defer rows.end();
        for (0..2) |_| {
            const r = ui.div(c).row().gap(8).itemsCenter();
            defer r.end();
            ui.div(c).w(48).h(9).rounded(4).bg(k.ink(0.05)).end();
            ui.div(c).w(std.math.clamp(col_w - 48 - 64 - 16, 56, 230)).h(5).roundedFull().bg(k.ink(0.04)).end();
            ui.div(c).w(64).h(9).rounded(4).bg(k.ink(0.05)).end();
        }
    }
    const right = ui.div(c).column().itemsEnd();
    defer right.end();
    ui.div(c).w(64).h(21).roundedFull().bg(k.ink(0.05)).end();
}

/// One usage window (`render_usage_meter`): label, a 5-point bar (accent,
/// amber at 80%, red at 95%), "NN% used", the quiet reset time.
pub fn meter(c: *ui.Context, k: theme.Colors, w: accounts.Window, width: f32, now_ms: i64) void {
    const fraction = std.math.clamp(w.used_fraction, 0, 1);
    const level = accounts.usageLevel(fraction);
    const fill = switch (level) {
        .normal => k.accent.alpha(0.8),
        .warn => k.warning.alpha(0.85),
        .critical => k.danger.alpha(0.85),
    };
    var rb: [48]u8 = undefined;
    const reset = if (w.resets_ms) |at| accounts.formatReset(&rb, at, now_ms, accounts.localOffset(at)) else null;
    const style = st(c, 11.5, .{ .color = k.muted.alpha(0.7) });
    const reset_w: f32 = if (reset) |r| 8 + c.text.width(r, style) else 0;
    const bar_w = std.math.clamp(width - 48 - 64 - 16 - reset_w, 56, 230);
    const r = ui.div(c).row().gap(8).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).row().w(48);
        defer l.end();
        kit.ellipsisText(c, w.label, style, 48);
    }
    {
        const bar = ui.div(c).row().w(bar_w).h(5).roundedFull().bg(k.ink(0.07)).clip();
        defer bar.end();
        if (fraction > 0) _ = c.leaf(.{ .width = .{ .px = bar_w * @max(fraction, 0.015) }, .height = .{ .px = 5 }, .radius = 2.5, .background = fill }, .none, null);
    }
    {
        const p = ui.div(c).row().w(64).justifyEnd();
        defer p.end();
        var pb: [16]u8 = undefined;
        ui.text(c, c.print("{s}", .{accounts.percentUsed(&pb, fraction)}), style);
    }
    if (reset) |t| ui.text(c, c.print("{s}", .{t}), st(c, 11.5, .{ .color = k.muted.alpha(0.45) }));
}

/// What an account row asks of its page.
pub const RowAction = enum { none, switch_to, forget };

/// One account's row (`render_account_row`): avatar, email and meters (or
/// the quiet fallback), badges over Forget and Switch on an inactive one.
pub fn accountRow(c: *ui.Context, k: theme.Colors, account: accounts.Account, first: bool, busy: bool, now_ms: i64) RowAction {
    var out: RowAction = .none;
    if (!first) line(c, k);
    const r = ui.div(c).row().wFull().px(20).py(14).gap(12).itemsStretch();
    defer r.end();
    const name = account.title();
    {
        const a = ui.div(c).column().justifyCenter();
        defer a.end();
        avatar(c, k, name);
    }
    var badges_w: f32 = 0;
    if (account.active) badges_w += badgeActiveW(c, "Active");
    if (account.plan_label) |p| badges_w += (if (badges_w > 0) @as(f32, 6) else 0) + badgeW(c, p);
    const switch_label: []const u8 = if (busy) "Switching…" else "Switch";
    const actions_w: f32 = if (account.active) 0 else trash_w + (if (account.switchable) 4 + primaryW(c, switch_label) else 0);
    const col_w = rowInner() - 32 - 12 - 12 - @max(badges_w, actions_w);
    {
        const col = ui.div(c).column().grow().w(0);
        defer col.end();
        title(c, k, name, col_w);
        set.space(c, 6);
        if (account.usage.len == 0) {
            kit.ellipsisText(c, if (account.switchable) "Usage unavailable" else "Credentials unavailable", st(c, 11.5, .{ .color = k.muted.alpha(0.6) }), col_w);
        } else {
            const ms = ui.div(c).column().gap(4);
            defer ms.end();
            for (account.usage, 0..) |w, i| {
                ui.key(c, c.print("meter-{d}", .{i}));
                meter(c, k, w, col_w, now_ms);
            }
        }
    }
    const right = ui.div(c).column().itemsEnd().justifyBetween().gap(8);
    defer right.end();
    {
        const b = ui.div(c).row().gap(6).itemsCenter();
        defer b.end();
        if (account.active) badgeActive(c, k, "Active");
        if (account.plan_label) |p| badge(c, k, p);
    }
    if (!account.active) {
        const acts = ui.div(c).row().gap(4).itemsCenter();
        defer acts.end();
        if (trash(c, k, busy) and !busy) out = .forget;
        if (account.switchable) if (primary(c, k, switch_label, busy) and !busy) {
            out = .switch_to;
        };
    }
    return out;
}

/// A provider's brand mark: Claude's keeps its colour.
pub fn providerMark(h: accounts.Harness) struct { name: icons.Name, tint: ?ui.Color } {
    const m = icons.harnessMark(h.wire());
    return .{ .name = m.name, .tint = m.brand };
}

/// A provider section's header row: mark, name, and (once loaded) Add
/// account. True when Add account was clicked.
pub fn providerHead(c: *ui.Context, k: theme.Colors, p: accounts.Provider, add: bool) bool {
    set.space(c, 24);
    const h = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer h.end();
    const m = providerMark(p.harness);
    sectionHead(c, k, m.name, m.tint, p.name);
    if (!add) return false;
    ui.spacer(c);
    return ghost(c, k, .{ .label = "Add account", .icon = .@"add-circle" });
}

/// A loading provider section: its header and two ghost rows, the second
/// dimmed.
pub fn providerLoading(c: *ui.Context, k: theme.Colors, p: accounts.Provider) void {
    ui.key(c, c.print("accounts-skeleton-{s}", .{p.harness.wire()}));
    _ = providerHead(c, k, p, false);
    const cd = card(c, k, 8);
    defer cd.end();
    skeleton(c, k, true, false);
    skeleton(c, k, false, true);
}

/// A card's centred empty line (`px(20) py(32)` at 14).
pub fn emptyLine(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const e = ui.div(c).column().wFull().px(20).py(32).itemsCenter();
    defer e.end();
    const style = st(c, 14, .{ .color = k.muted.alpha(0.6) });
    const room = rowInner();
    if (c.text.width(text, style) <= room) return ui.text(c, text, style);
    const w = ui.div(c).column().w(room).itemsCenter();
    defer w.end();
    var wrapped = style;
    wrapped.wrap = true;
    ui.text(c, text, wrapped);
}
