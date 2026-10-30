//! The "Cloud sandbox running" strip (shell/cloud_sandbox_strip.rs). A
//! Codegraff cloud sandbox started from Harness keeps running, billed per
//! second, until it is turned off. While one runs the strip stays in the
//! sidebar's foot above the account badge, and in the settings sidebar
//! above Back: a live dot, what it costs or why it will pause, and a
//! one-click Turn off (a pause: memory and files are kept). Its label opens
//! Settings › Accounts, where the card lives. It reads the list the app
//! keeps (app_sandboxes.zig), so it is hidden when signed out, where the
//! feature is off, and when nothing runs.
//!
//! With the sidebar closed the strip is out of sight, so a chip takes its
//! place under the sidebar toggle: the live dot and a cloud (a click opens
//! the card) beside the same Turn off.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const sandboxes = @import("sandboxes.zig");
const state = @import("app_sandboxes.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

const st = @import("view_settings_accounts_rows.zig").st;

/// Settings › Accounts (`open_settings(SettingsSection::Agents)`).
fn openCard(a: *App) void {
    @import("view_settings.zig").open(a);
    a.settings.setSection(.agents);
    a.redraw();
}

/// "Turn off", "Turn off all", or "Turning off…" while the pause is under way.
fn turnOffLabel(a: *const App, running: usize) []const u8 {
    if (a.cloud_sandboxes.turning_off > 0) return sandboxes.turn_off[1];
    return if (running == 1) sandboxes.turn_off[0] else "Turn off all";
}

/// Its width, for the room left beside it.
fn turnOffWidth(c: *ui.Context, label: []const u8) f32 {
    return 2 * 9 + c.text.width(label, .{ .size = 11, .weight = .medium });
}

/// The button (`cloud_turn_off_button`): pauses every one of `ids`; dimmed,
/// and in place, while it works.
fn turnOff(c: *ui.Context, a: *App, k: theme.Colors, ids: []const []const u8) void {
    const busy = a.cloud_sandboxes.turning_off > 0;
    // GPUI's px 8, py 3 and a 1-point border, which nanoui draws inside.
    var b = ui.div(c).row().px(9).py(4).rounded(6).border(k.border).borderW(1).bg(k.raised);
    b = if (busy) b.opacity(0.6) else b.hover(k.raised.mix(k.text, 0.06));
    b = tip.on(b, k, .{ .text = sandboxes.turn_off_hint, .delay = tip.quick });
    defer b.end();
    ui.text(c, turnOffLabel(a, ids.len), st(c, 11, .{ .weight = .medium, .color = k.text }));
    if (!busy and b.clicked()) state.turnOff(a, ids);
}

/// What runs, when anything does.
fn summary(c: *ui.Context, a: *App) ?sandboxes.Summary {
    const l = state.shown(a) orelse return null;
    return sandboxes.runningSummary(c.alloc(), l, a.nowMs()) catch null;
}

/// The strip (`render_cloud_sandbox_strip`), 8 in from the sidebar's sides
/// and 4 below what's above it; `pb` under it.
pub fn strip(c: *ui.Context, a: *App, k: theme.Colors, pb: f32) void {
    const sum = summary(c, a) orelse return;
    const tone = if (sum.warning) k.warning else k.accent;
    const w: f32 = sidebar.width - 2 * 8;
    const pad = ui.div(c).column().wFull().px(8).pt(4).pb(pb);
    defer pad.end();
    ui.key(c, "cloud-sandbox-strip");
    const s = ui.div(c).row().w(w).px(9).py(7).gap(8).itemsCenter().rounded(6)
        .bg(if (sum.warning) k.warning.alpha(0.12) else k.accent_wash).border(tone.alpha(0.3)).borderW(1);
    defer s.end();
    const button_w: f32 = if (sum.running_ids.len > 0) 8 + turnOffWidth(c, turnOffLabel(a, sum.running_ids.len)) else 0;
    const text_w = w - 2 * 9 - button_w;
    {
        const open = ui.div(c).column().w(text_w).gap(1);
        defer open.end();
        {
            const top = ui.div(c).row().gap(6).itemsCenter();
            defer top.end();
            kit.dot(c, 6, tone);
            kit.ellipsisText(c, sum.label, st(c, 11, .{ .weight = .medium, .color = k.text }), text_w - 12);
        }
        {
            const d = ui.div(c).row().pl(12);
            defer d.end();
            kit.ellipsisText(c, sum.detail, st(c, 10.5, .{ .color = if (sum.warning) k.warning else k.muted }), text_w - 12);
        }
        if (open.clicked()) openCard(a);
    }
    if (sum.running_ids.len > 0) turnOff(c, a, k, sum.running_ids);
}

/// Where the chip sits: 12 in, 4 under the title bar (`SPACE_MD`,
/// `TITLEBAR_HEIGHT + 4`).
pub const chip_at: ui.Point = .{ .x = 12, .y = sidebar.titlebar_h + 4 };

/// The closed sidebar's stand-in (`render_cloud_sandbox_chip`): a card
/// under the sidebar toggle with the live dot and a cloud, then Turn off.
pub fn chip(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sum = summary(c, a) orelse return;
    const tone = if (sum.warning) k.warning else k.accent;
    ui.key(c, "cloud-sandbox-chip");
    // GPUI's p 3 inside a 1-point border; the popover's surface.
    const card = shadowMd(ui.div(c).fixed().offset(chip_at.x, chip_at.y).layer(3).row().p(4).gap(4).itemsCenter()
        .rounded(6 + 3).border(tone.alpha(0.35)).borderW(1).bg(k.composer));
    defer card.end();
    {
        // `compact_tooltip`: what runs and what it costs.
        const open = tip.on(ui.div(c).row().px(7).py(4).gap(5).itemsCenter().rounded(6).hover(k.ink(0.06)), k, .{
            .text = sandboxes.compactTooltip(c.alloc(), sum) catch "",
            .delay = tip.quick,
        });
        defer open.end();
        kit.dot(c, 6, tone);
        icons.icon(c, .cloud, 13, k.muted, 0);
        if (open.clicked()) openCard(a);
    }
    if (sum.running_ids.len > 0) turnOff(c, a, k, sum.running_ids);
}

/// GPUI's `shadow_md` (Tailwind's), with a nanoui that has layered
/// shadows; its own medium one before.
fn shadowMd(d: ui.Div) ui.Div {
    if (comptime @hasDecl(ui.Shadow, "lg")) return d.shadows(&.{
        .{ .color = .{ .a = 0.1 }, .blur = 6, .y = 4, .spread = -1 },
        .{ .color = .{ .a = 0.1 }, .blur = 4, .y = 2, .spread = -2 },
    });
    return d.shadowMd();
}
