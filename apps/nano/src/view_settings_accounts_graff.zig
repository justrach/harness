//! Settings › Accounts' graff sign-ins (settings/accounts.rs
//! `render_chatgpt_section`, `render_graff_logins_section`,
//! `render_graff_row`): graff's ChatGPT plan sign-in with its links and
//! one-time confirmation, then graff's other providers with the legacy
//! Codex login second.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const accounts = @import("accounts.zig");
const rows = @import("view_settings_accounts_rows.zig");
const login = @import("view_settings_accounts_login.zig");
const page = @import("view_settings_accounts.zig");
const App = @import("app.zig").App;

const st = rows.st;

/// What a graff row asks of its page.
const GraffAction = enum { none, sign_in, sign_out };

/// One graff sign-in (`render_graff_row`): avatar, name and line, Signed
/// in, then sign-out and the sign-in button for a provider of graff's own.
fn graffRow(c: *ui.Context, a: *App, k: theme.Colors, first: bool, provider: ?[]const u8, name: []const u8, status: []const u8, signed_in: bool) GraffAction {
    const p = &a.view.accounts;
    var out: GraffAction = .none;
    const busy = if (provider) |id| page.eqOpt(p.busy_graff, id) else false;
    const label: []const u8 = if (provider != null and std.mem.eql(u8, provider.?, "chatgpt-new")) "Continue with ChatGPT" else if (signed_in) "Sign in again" else "Sign in";
    if (!first) rows.line(c, k);
    const r = ui.div(c).row().wFull().px(20).py(14).gap(12).itemsCenter();
    defer r.end();
    rows.avatar(c, k, name);
    var right_w: f32 = if (signed_in) rows.badgeActiveW(c, "Signed in") else 0;
    if (provider != null) right_w += (if (signed_in) @as(f32, 8 + rows.trash_w + 4) else 0) + rows.primaryW(c, label);
    const w = rows.rowInner() - 32 - 12 - 12 - right_w;
    {
        const col = ui.div(c).column().grow().w(0);
        defer col.end();
        rows.title(c, k, name, w);
        set.space(c, 4);
        kit.ellipsisText(c, status, st(c, 11.5, .{ .color = k.muted.alpha(0.6) }), w);
    }
    const right = ui.div(c).row().gap(8).itemsCenter();
    defer right.end();
    if (signed_in) rows.badgeActive(c, k, "Signed in");
    if (provider != null) {
        const acts = ui.div(c).row().gap(4).itemsCenter();
        defer acts.end();
        if (signed_in) if (rows.trash(c, k, busy)) {
            out = .sign_out;
        };
        if (rows.primary(c, k, label, busy)) out = .sign_in;
    }
    return out;
}

/// graff's ChatGPT (plan) sign-in, separate from the legacy Codex one
/// (`render_chatgpt_section`).
pub fn chatgpt(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.accounts;
    const row = accounts.Chatgpt.fromListing(p.graff.get());
    set.space(c, 24);
    {
        const h = ui.div(c).row().gap(8).itemsCenter();
        defer h.end();
        icons.icon(c, .@"openai-mark", 16, k.muted, 0);
        ui.text(c, "ChatGPT", st(c, 13, .{ .weight = .medium, .color = k.text }));
    }
    set.space(c, 8);
    const box = ui.div(c).column().wFull();
    defer box.end();
    {
        const cd = rows.card(c, k, 0);
        defer cd.end();
        chatgptCard(c, a, k, row);
    }
    // graffRow already paints this row's top border inside the card.
    // Painting an extra rail over it applies the translucent color twice.
}

fn chatgptCard(c: *ui.Context, a: *App, k: theme.Colors, row: accounts.Chatgpt) void {
    const p = &a.view.accounts;
    var buf: [512]u8 = undefined;
    switch (graffRow(c, a, k, false, "chatgpt-new", "ChatGPT", c.print("{s}", .{row.status(&buf)}), row == .ready)) {
        .sign_in => login.begin(a, .graff, "chatgpt-new"),
        .sign_out => page.signOutGraff(a, "chatgpt-new"),
        .none => {},
    }
    switch (row) {
        .ready => {
            const l = ui.div(c).row().wFull().justifyEnd().px(14).pb(10);
            defer l.end();
            if (rows.link(c, k, "Manage usage", false)) _ = nanoui.shell.openUrl("https://chatgpt.com/settings/usage");
        },
        .plan_off => {
            const l = ui.div(c).row().wFull().justifyEnd().gap(4).px(14).pb(10);
            defer l.end();
            if (rows.link(c, k, "Use an API key", false)) _ = nanoui.shell.openUrl("https://platform.openai.com/api-keys");
            if (rows.link(c, k, "Sign out", page.eqOpt(p.busy_graff, "chatgpt-new"))) page.signOutGraff(a, "chatgpt-new");
        },
        else => {},
    }
    if (p.confirmation) |text| {
        rows.line(c, k);
        const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsCenter();
        defer r.end();
        const links_w = 24 + c.text.width("Manage usage", .{ .size = 11.5 }) + c.text.width("Got it", .{ .size = 11.5 }) + 24;
        const w = rows.rowInner() - links_w;
        {
            const col = ui.div(c).column().grow().w(0);
            defer col.end();
            rows.title(c, k, text, w);
            set.space(c, 4);
            const t = ui.div(c).column().w(w);
            defer t.end();
            ui.text(c, "graff's ChatGPT models now run on your plan and count toward its usage limits.", st(c, 11.5, .{ .wrap = true, .color = k.muted }));
        }
        if (rows.link(c, k, "Manage usage", false)) _ = nanoui.shell.openUrl("https://chatgpt.com/settings/usage");
        if (rows.link(c, k, "Got it", false)) page.replace(a.gpa, &p.confirmation, null);
    }
}

/// graff's other sign-ins, with the legacy shared Codex login second
/// (`render_graff_logins_section`).
pub fn providers(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.accounts;
    set.space(c, 24);
    {
        const h = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer h.end();
        rows.sectionHead(c, k, .@"graff-mark", null, "graff providers");
    }
    const cd = rows.card(c, k, 8);
    defer cd.end();
    switch (p.graff.phase) {
        .idle, .loading => rows.skeleton(c, k, true, false),
        .failed => page.quietBody(c, k, c.print("graff sign-ins unavailable: {s}", .{p.graff.why.items}), 12),
        .ready => {
            var list: std.ArrayList(?accounts.GraffLogin) = .empty;
            for (p.graff.value) |g| if (!std.mem.eql(u8, g.id, "chatgpt-new")) list.append(c.alloc(), g) catch {};
            // null: the legacy Codex login, after the first.
            list.insert(c.alloc(), @min(list.items.len, 1), null) catch {};
            const snap = p.snapshot.get();
            for (list.items, 0..) |entry, ix| {
                var buf: [256]u8 = undefined;
                if (entry) |g| {
                    ui.key(c, c.print("graff-login-{s}", .{g.id}));
                    switch (graffRow(c, a, k, ix == 0, g.id, g.name, c.print("{s}", .{accounts.graffStatus(&buf, g)}), g.signed_in)) {
                        .sign_in => login.begin(a, .graff, g.id),
                        .sign_out => page.signOutGraff(a, g.id),
                        .none => {},
                    }
                } else {
                    ui.key(c, "graff-login-codex");
                    const signed = if (snap) |s| accounts.openaiLogin(s).signed_in else false;
                    _ = graffRow(c, a, k, ix == 0, null, "ChatGPT (old Codex)", c.print("{s}", .{accounts.openaiStatus(&buf, snap)}), signed);
                }
            }
        },
    }
}
