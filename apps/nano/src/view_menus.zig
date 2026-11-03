//! The sidebar's popovers, drawn over the window under the control that
//! opened them: the new session's project, and the account badge's (the
//! header's are view_sidebar_menus.zig).
//! A click outside closes them.
const std = @import("std");
const rules = @import("rules.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const account = @import("app_account.zig");
const kit = @import("view_kit.zig");
const App = @import("app.zig").App;

pub fn menus(c: *ui.Context, a: *App, k: theme.Colors) void {
    const v = &a.view;
    if (!v.account_menu and !v.space_menu) return;
    {
        // Behind the menu: a click anywhere else closes it.
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer back.end();
        if (back.clicked()) {
            v.account_menu = false;
            v.space_menu = false;
            return;
        }
    }
    if (v.space_menu) if (v.space_anchor) |r| {
        const m = panel(c, k, r.x, r.y + r.h + 4, 240);
        defer m.end();
        const current = a.newChatSpace();
        for (a.spaces.items) |s| {
            ui.key(c, c.print("space-{s}", .{s.id}));
            const on = current != null and std.mem.eql(u8, current.?.id, s.id);
            if (item(c, k, .folder, s.name, on)) {
                a.select(null, s.id);
                v.space_menu = false;
            }
        }
        divider(c, k);
        if (item(c, k, .plus, "Add folder…", false)) {
            v.space_menu = false;
            a.addFolder();
        }
    };
    if (v.account_menu) if (v.account_anchor) |r| accountMenu(c, a, k, r);
}

/// The account badge's menu (`render_user_menu`): who this is, the
/// Codegraff sign-in, the workspace's sync action, then Settings. It opens
/// right of the badge, kept 8 points inside the window (`anchored_menu_right`).
fn accountMenu(c: *ui.Context, a: *App, k: theme.Colors, r: ui.Rect) void {
    const acc = &a.account;
    const m = account.menu(acc.scope, acc.user, acc.codegraff);
    const w = @import("view_sidebar.zig").width - 2 * 8;
    // Its height as last drawn; a first guess before that.
    const h = a.view.account_h orelse 150;
    const x = rules.snapToWindow(r.x + r.w + 6, w, c.size.w, 8);
    const y = rules.snapToWindow(r.y, h, c.size.h, 8);
    // The inset, and the 1-point border GPUI insets by too.
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(card_inset + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer card.end();
    kit.rememberHeight(c, card, &a.view.account_h);
    {
        const id = ui.div(c).row().wFull().px(8).pt(6).pb(4);
        defer id.end();
        @import("view_kit.zig").ellipsisText(c, m.identity, .{ .size = 11, .line_height = 11 * phi, .color = k.muted }, w - 2 * card_inset - 16 - 2);
    }
    switch (m.codegraff) {
        .account => |who| if (menuRow(c, k, .global, k.accent, c.print("Codegraff · {s}", .{who}), 1)) {
            a.view.account_menu = false;
            a.setNotice("Settings aren't in Harness Nano yet: Codegraff is in Harness's Settings › Agents.");
        },
        .pending => if (menuRow(c, k, .global, k.muted, "Waiting for browser… (click to reopen)", 0.7)) account.signIn(a),
        .sign_in => if (menuRow(c, k, .global, k.muted, "Sign in with Codegraff", 1)) account.signIn(a),
    }
    separator(c, a, w);
    if (m.action) |act| {
        const clicked = switch (act) {
            .enable_sync => menuRow(c, k, .global, k.muted, "Enable sync", 1),
            .sign_out => menuRow(c, k, .@"logout-2", k.muted, "Sign out", 1),
        };
        if (clicked) {
            a.view.account_menu = false;
            a.setNotice(switch (act) {
                .enable_sync => "Turning on sync isn't in Harness Nano yet: use Harness.",
                .sign_out => "Signing out isn't in Harness Nano yet: use Harness.",
            });
        }
        separator(c, a, w);
    }
    if (menuRow(c, k, .@"settings-minimalistic", k.muted, "Settings", 1)) @import("view_settings.zig").open(a);
}

/// GPUI's line height, as a multiple of the text's size.
const phi: f32 = 1.618;

/// The popover card's inset (`CARD_INSET`).
const card_inset: f32 = 4;

/// A menu row (`popover::menu_row`): a 16-point icon, 10 points, the label
/// at 13 points; the selected-card wash under the pointer.
fn menuRow(c: *ui.Context, k: theme.Colors, icon: icons.Name, tint: ui.Color, label: []const u8, opacity: f32) bool {
    var row = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(12 - 1 - card_inset).hover(k.selected);
    if (opacity < 1) row = row.opacity(opacity);
    defer row.end();
    const hot = row.hovered();
    icons.icon(c, icon, 16, tint, 0);
    const t = ui.div(c).row().grow().w(0).clip();
    defer t.end();
    ui.text(c, label, .{ .size = 13, .line_height = 13 * phi, .color = if (hot) k.text else k.text.alpha(0.9) });
    return row.clicked();
}

/// A hairline from border to border, through the card's inset
/// (`menu_separator`).
fn separator(c: *ui.Context, a: *App, w: f32) void {
    const dark = a.dark orelse nanoui.isDark();
    const line: ui.Color = if (dark) .{ .r = 1, .g = 1, .b = 1, .a = 0.07 } else .{ .r = 0, .g = 0, .b = 0, .a = @min(0.07 * 1.35, 0.5) };
    const box = ui.div(c).column().wFull().py(2);
    defer box.end();
    _ = c.leaf(.{ .width = .{ .px = w - 2 }, .height = .{ .px = 1 }, .background = line, .offset = .{ .x = -card_inset } }, .none, null);
}

fn panel(c: *ui.Context, k: theme.Colors, x: f32, y: f32, w: f32) ui.Div {
    return @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(4).gap(1)
        .bg(k.composer).border(k.border).borderW(1).rounded(10)));
}

fn item(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8, on: bool) bool {
    var r = ui.div(c).row().wFull().h(30).px(8).gap(8).itemsCenter().rounded(7).hover(k.hover);
    if (on) r = r.bg(k.selected);
    defer r.end();
    const clicked = r.clicked();
    icons.icon(c, icon, 15, k.muted, 0);
    ui.text(c, label, .{ .size = 13, .color = k.text });
    ui.spacer(c);
    if (on) icons.icon(c, .check, 12, k.accent, 0);
    return clicked;
}

fn divider(c: *ui.Context, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().py(3);
    defer d.end();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}
