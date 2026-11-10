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
    const strip = @import("view_tab_strip.zig");
    const v = &a.view;
    // Footer triggers retain their own anchor, but use the same retained,
    // keyboard-accessible project search rather than a second flat list.
    if (v.space_menu) if (v.space_anchor) |anchor| {
        v.space_menu = false;
        strip.open(a, .folder, .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 }, anchor);
        v.strip.footer_folder = true;
    };
    strip.menus(c, a, k);
    if (!v.account_menu and !v.space_menu and !v.checkout_menu and !v.ref_menu) return;
    {
        // Behind the menu: a click anywhere else closes it.
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer back.end();
        if (back.clicked()) {
            v.account_menu = false;
            v.space_menu = false;
            v.checkout_menu = false;
            v.ref_menu = false;
            return;
        }
    }
    // Where the new chat runs (`render_checkout_popover`): the project's
    // own checkout, or a fresh worktree made off the base on send. Opens
    // upward when the trigger is docked near the bottom of the window.
    if (v.checkout_menu) if (v.checkout_anchor) |r| {
        const w: f32 = 224;
        const h: f32 = 2 * 32 + 10;
        const x = rules.snapToWindow(r.x, w, c.size.w, 8);
        const y = upwardOrBelow(r, h, c.size.h);
        ui.key(c, "checkout-popover");
        const m = panel(c, k, x, y, w);
        defer m.end();
        const newchat = @import("view_newchat.zig");
        inline for (.{ .{ true, icons.Name.folder }, .{ false, icons.Name.@"folder-with-files" } }) |opt| {
            if (item(c, k, opt[1], newchat.checkoutLabel(opt[0]), a.new_checkout_local == opt[0])) {
                a.new_checkout_local = opt[0];
                v.checkout_menu = false;
            }
        }
    };
    if (v.ref_menu) if (v.ref_anchor) |r| {
        refMenu(c, a, k, r);
    };
    if (v.account_menu) if (v.account_anchor) |r| accountMenu(c, a, k, r);
}

/// Place a compact popover above `anchor` when docked near the bottom edge
/// (6pt gap), falling back below when the anchor is near the top.
pub fn upwardOrBelow(anchor: ui.Rect, h: f32, win_h: f32) f32 {
    const below = @max(0, win_h - (anchor.y + anchor.h) - 10);
    if (below < h and anchor.y > h + 14) {
        return @max(8, anchor.y - h - 6);
    }
    return rules.snapToWindow(anchor.y + anchor.h + 6, h, win_h, 8);
}

pub fn ensureRefs(a: *App, space: @import("workspace.zig").Space) void {
    const v = &a.view;
    if (v.ref_space) |prev| {
        if (!std.mem.eql(u8, prev, space.id)) {
            a.retireSlice(prev);
            v.ref_space = null;
            for (v.refs.items) |r| a.retireSlice(r);
            v.refs.clearRetainingCapacity();
        }
    }
    if (v.ref_space == null) {
        v.ref_space = a.gpa.dupe(u8, space.id) catch null;
    }
    if (v.ref_loading or !a.engine.up()) return;
    v.ref_loading = true;
    const host: ?[]const u8 = if (space.device_id) |dev| (if (a.device_id) |me| (if (std.mem.eql(u8, me, dev)) null else dev) else dev) else null;
    a.request(@import("requests.zig").listRefs(space.path, host), .of(App, a, onRefs));
}

fn onRefs(a: *App, _: u64, reply: @import("rpc.zig").Reply) void {
    const v = &a.view;
    v.ref_loading = false;
    switch (reply) {
        .ok => |val| if (val == .array) {
            for (v.refs.items) |old| a.gpa.free(old);
            v.refs.clearRetainingCapacity();
            for (val.array.items) |entry| {
                if (entry != .object) continue;
                const name_val = entry.object.get("name") orelse continue;
                if (name_val != .string or name_val.string.len == 0) continue;
                const dup = a.gpa.dupe(u8, name_val.string) catch continue;
                v.refs.append(a.gpa, dup) catch a.gpa.free(dup);
            }
        },
        else => {},
    }
    a.redraw();
}

fn refMenu(c: *ui.Context, a: *App, k: theme.Colors, r: ui.Rect) void {
    const v = &a.view;
    const w: f32 = 240;
    const count: usize = 1 + @min(v.refs.items.len, 8);
    const h: f32 = @as(f32, @floatFromInt(count)) * 32 + 12;
    const x = rules.snapToWindow(r.x, w, c.size.w, 8);
    const y = upwardOrBelow(r, h, c.size.h);
    ui.key(c, "branch-popover");
    const m = panel(c, k, x, y, w);
    defer m.end();
    if (item(c, k, .@"git-branch", "Default branch", a.new_ref == null)) {
        if (a.new_ref) |old| a.gpa.free(old);
        a.new_ref = null;
        v.ref_menu = false;
        a.redraw();
    }
    for (v.refs.items[0..@min(v.refs.items.len, 8)]) |branch| {
        const selected = if (a.new_ref) |cur| std.mem.eql(u8, cur, branch) else false;
        if (item(c, k, .@"git-branch", branch, selected)) {
            const copy = a.gpa.dupe(u8, branch) catch return;
            if (a.new_ref) |old| a.gpa.free(old);
            a.new_ref = copy;
            v.ref_menu = false;
            a.redraw();
        }
    }
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
        const id = ui.div(c).column().wFull().px(8).pt(6).pb(4).gap(2);
        defer id.end();
        kit.ellipsisText(c, m.identity, .{ .size = 11, .line_height = 11 * phi, .color = k.muted }, w - 2 * card_inset - 16 - 2);
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
    var row = ui.div(c).row().wFull().px(8).py(5).gap(10).itemsCenter().rounded(12 - 1 - card_inset).hover(k.selected);
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
