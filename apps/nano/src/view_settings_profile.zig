//! Settings › Account (`profile.luau`): signed-out preview card + outside
//! Sign in action, and signed-in member identity + interactive 3D MemberCard
//! floating outside the settings card.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const account = @import("app_account.zig");
const ascii = @import("ascii_field.zig");
const member_card = @import("member_card.zig");
const App = @import("app.zig").App;

const phi: f32 = 1.618;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.header(c, k, "Account", null);
    set.subtitle(c, k, "Sign in with Harness to sync sessions across devices and unlock your numbered Harness member card.", true);
    set.space(c, 24);

    const wide = set.inner_w >= 560;
    const card_bg = k.ink(if (k.dark) 0.038 else 0.025);
    const card_edge = if (k.dark) k.border else @import("view_panel_chrome.zig").zenEdge(k);

    if (a.account.user) |*u| {
        const display_name = if (u.name) |n| (if (n.len > 0) n else u.email) else u.email;
        const seed_str = if (u.id.len > 0) u.id else if (u.email.len > 0) u.email else display_name;
        const shown_name = if (display_name.len > 0) display_name else "Member";
        const card_zoom: f32 = if (!wide or set.inner_w >= 680) 1.0 else 0.78;
        const aside_w: f32 = member_card.base_w * card_zoom + 24;
        const traits = member_card.resolveTraits(seed_str, u.member_number, u.card_scenes, u.card_traits);
        const card_caption = c.print("{s} \u{00b7} {s}", .{ member_card.ensoLabel(traits.enso), traits.holo.label() });

        const layout = if (wide)
            ui.div(c).row().wFull().gap(28).itemsStart()
        else
            ui.div(c).column().wFull().gap(24);
        defer layout.end();

        if (!wide) drawSignedInAside(c, a, k, seed_str, shown_name, u, card_zoom, false, aside_w, card_caption);

        // Left column: profile settings group card + external Sign out / Provider accounts bar.
        {
            const left = if (wide) ui.div(c).column().grow().w(0).gap(12) else ui.div(c).column().wFull().gap(12);
            defer left.end();

            ui.text(c, "Harness Account", set.st(c, 13, .{ .weight = .semibold, .color = k.text }));

            {
                const card = ui.div(c).column().wFull().p(1).rounded(12).border(card_edge).borderW(1).bg(card_bg);
                defer card.end();

                {
                    const hdr = ui.div(c).row().wFull().px(18).py(16).gap(14).itemsCenter();
                    defer hdr.end();

                    const avatar_box = ui.div(c).row().size(44, 44).center().roundedFull().bg(k.accent_wash).border(k.border).borderW(1).clip();
                    {
                        defer avatar_box.end();
                        if (a.account.avatar_bytes) |bytes| {
                            _ = ui.image(c, .{
                                .key = "profile-avatar",
                                .source = .{ .encoded = bytes },
                                .box = .{ .w = 44, .h = 44 },
                                .radius = 22,
                            });
                        } else {
                            ui.text(c, c.print("{c}", .{account.initial(shown_name)}), .{
                                .size = 16,
                                .weight = .semibold,
                                .color = k.accent,
                            });
                        }
                    }

                    const meta = ui.div(c).column().grow().w(0).gap(2);
                    defer meta.end();

                    const name_row = ui.div(c).row().wFull().gap(8).itemsCenter();
                    {
                        defer name_row.end();
                        kit.ellipsisText(c, shown_name, set.st(c, 15, .{ .weight = .semibold, .color = k.text }), 240);
                        if (u.member_number) |num| {
                            var nbuf: [24]u8 = undefined;
                            const pill = ui.div(c).row().px(8).py(2).roundedFull().bg(k.ink(if (k.dark) 0.12 else 0.06));
                            defer pill.end();
                            ui.text(c, c.print("#{s}", .{ascii.formatMemberNumber(&nbuf, num)}), .{
                                .size = 11,
                                .mono = true,
                                .color = k.muted,
                            });
                        }
                    }

                    if (u.email.len > 0) {
                        kit.ellipsisText(c, u.email, set.st(c, 12.5, .{ .color = k.muted }), 260);
                    }
                }

                var dbuf: [32]u8 = undefined;
                const started_label = if (u.started_at) |ts|
                    c.print("{s}", .{ascii.formatSinceDate(&dbuf, ts)})
                else
                    "Active member";
                const scope_label = switch (a.account.scope orelse .local) {
                    .synced => "Synced across devices",
                    .local => "Local workspace",
                    .development => "Development mode",
                };

                const sc_title = member_card.title(traits.scene);
                const is_founder = if (u.member_number) |mn| (mn >= 1 and mn <= 1000) else false;
                const edition_label = if (is_founder)
                    c.print("Founder 1/1 \u{00b7} {s}", .{sc_title})
                else
                    c.print("{s} \u{00b7} {s}", .{ sc_title, traits.holo.label() });

                infoRow(c, k, "Started", started_label);
                infoRow(c, k, "Card edition", edition_label);
                infoRow(c, k, "Workspace", scope_label);
                infoRow(c, k, "Connected devices", c.print("{d}", .{a.devices.items.len}));
            }

            {
                const actions = ui.div(c).row().wFull().pt(2).gap(10).itemsCenter();
                defer actions.end();

                if (set.ghost(c, k, "Provider accounts")) {
                    a.settings.setSection(.agents);
                    a.redraw();
                }

                ui.spacer(c);

                ui.key(c, "account-sign-out");
                const so = ui.div(c).row().h(34).px(16).center().rounded(10).border(k.border).borderW(1).hover(k.hover).control();
                {
                    defer so.end();
                    ui.text(c, "Sign out", set.st(c, 13, .{ .weight = .medium, .color = k.text }));
                }
                if (so.clicked()) account.signOut(a);
            }
        }

        if (wide) drawSignedInAside(c, a, k, seed_str, shown_name, u, card_zoom, true, aside_w, card_caption);
    } else {
        // Signed-out state (`profile.luau`): 3-row Settings group + outside Sign in on left,
        // floating interactive preview card ("You" / "000·000") outside on right (or above when narrow).
        const preview_card_zoom: f32 = if (!wide or set.inner_w >= 660) 0.78 else 0.66;
        const preview_w = member_card.base_w * preview_card_zoom;
        const aside_w = preview_w + 24;
        const left_w = if (wide) @max(220.0, set.inner_w - 28.0 - aside_w) else set.inner_w;
        const row_text_w = @max(120.0, left_w - 84.0);

        const layout = if (wide)
            ui.div(c).row().wFull().gap(28).itemsStart()
        else
            ui.div(c).column().wFull().gap(24);
        defer layout.end();

        if (!wide) drawSignedOutAside(c, a, k, false, aside_w, preview_card_zoom);

        {
            const left = if (wide) ui.div(c).column().grow().w(0).gap(12) else ui.div(c).column().wFull().gap(12);
            defer left.end();

            ui.text(c, "Harness Account", set.st(c, 13, .{ .weight = .semibold, .color = k.text }));

            {
                const card = ui.div(c).column().wFull().p(1).rounded(12).border(card_edge).borderW(1).bg(card_bg);
                defer card.end();

                featureRow(c, k, true, .@"user-rounded", "Your name and profile", "Synced display name, avatar, and Harness identity across workspaces.", row_text_w);
                featureRow(c, k, false, .tag, "Your member card", "Numbered by when you joined, with 1-of-1 Founder editions.", row_text_w);
                featureRow(c, k, false, .smartphone, "Your sessions, everywhere", "Pick up chats on macOS, iOS, and cloud sandboxes.", row_text_w);
            }

            if (a.account.scope == .development) {
                ui.text(c, "Sign-in is disabled in development mode.", set.st(c, 12, .{ .color = k.muted }));
            }

            {
                const actions = ui.div(c).row().wFull().pt(2).gap(10).itemsCenter();
                defer actions.end();

                if (set.ghost(c, k, "Provider accounts")) {
                    a.settings.setSection(.agents);
                    a.redraw();
                }

                ui.spacer(c);

                ui.key(c, "account-sign-in");
                const btn = ui.div(c).row().h(34).px(18).gap(6).center().rounded(10).bg(k.text).hover(k.text.alpha(0.86)).control();
                {
                    defer btn.end();
                    ui.text(c, "Sign in", set.st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
                }
                if (btn.clicked()) account.enableSync(a);
            }
        }

        if (wide) drawSignedOutAside(c, a, k, true, aside_w, preview_card_zoom);
    }
}

fn drawSignedInAside(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    seed_str: []const u8,
    shown_name: []const u8,
    u: *const account.User,
    card_zoom: f32,
    wide: bool,
    aside_w: f32,
    caption: []const u8,
) void {
    const right = if (wide)
        ui.div(c).column().w(aside_w).py(4).itemsCenter()
    else
        ui.div(c).column().wFull().py(4).itemsCenter();
    defer right.end();

    member_card.draw(c, a.gpa, &a.view.profile_card, k, .{
        .seed = seed_str,
        .name = shown_name,
        .member_number = u.member_number,
        .started_at = u.started_at orelse @divFloor(a.nowMs(), 1000),
        .card_scenes = u.card_scenes,
        .card_traits = u.card_traits,
        .preview = false,
        .zoom_override = card_zoom,
        .caption = caption,
    });
}

fn drawSignedOutAside(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    wide: bool,
    aside_w: f32,
    card_zoom: f32,
) void {
    const right = if (wide)
        ui.div(c).column().w(aside_w).py(4).itemsCenter()
    else
        ui.div(c).column().wFull().py(4).itemsCenter();
    defer right.end();

    const now_secs = a.nowMs();
    member_card.draw(c, a.gpa, &a.view.profile_card, k, .{
        .seed = ascii.preview_seed,
        .name = "You",
        .member_number = null,
        .started_at = if (now_secs > 0) @divFloor(now_secs, 1000) else 1794700800,
        .preview = true,
        .zoom_override = card_zoom,
        .caption = "Yours when you sign in",
    });
}

fn featureRow(
    c: *ui.Context,
    k: theme.Colors,
    first: bool,
    icon: icons.Name,
    title: []const u8,
    body: []const u8,
    text_w: f32,
) void {
    if (!first) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const r = ui.div(c).row().wFull().px(16).py(14).gap(14).itemsCenter();
    defer r.end();

    {
        const tile = ui.div(c).row().size(36, 36).center().rounded(10).border(k.border).borderW(1).bg(k.ink(0.03));
        defer tile.end();
        icons.icon(c, icon, 16, k.muted, 0);
    }

    const col = ui.div(c).column().w(text_w).gap(2);
    defer col.end();
    ui.text(c, title, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
    ui.text(c, body, .{
        .size = 12,
        .line_height = 12 * 1.45,
        .wrap = true,
        .color = k.muted,
    });
}

fn infoRow(c: *ui.Context, k: theme.Colors, label: []const u8, value: []const u8) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const r = ui.div(c).row().wFull().px(18).py(12).itemsCenter();
    defer r.end();
    ui.text(c, label, set.st(c, 12.5, .{ .color = k.muted }));
    ui.spacer(c);
    ui.text(c, value, set.st(c, 12.5, .{ .weight = .medium, .color = k.text }));
}

const testing = std.testing;

test "view_settings_profile renders signed-out preview and signed-in member card" {
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    h.a.settings.setSection(.account);
    set.open(&h.a);
    h.t.advance(0.8);
    try testing.expect(!h.t.ctx.animating);

    try testing.expect(h.t.hasText("Harness Account"));
    try testing.expect(h.t.hasText("Sign in"));
    try testing.expect(h.t.hasText("Your name and profile"));
    try testing.expect(h.t.hasText("000\u{00b7}000"));
    try testing.expect(h.t.hasText("You"));
    try testing.expect(h.t.hasText("Yours when you sign in"));

    const signed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"state":"signedIn","user":{"id":"user_synth","email":"ada@example.com","name":"Ada Lovelace","memberNumber":42,"startedAt":1700000000,"cardScenes":20},"orgId":null}
    , .{});
    defer signed.deinit();
    h.a.account.user = try account.readUser(testing.allocator, signed.value);
    h.a.account.scope = .synced;
    h.t.advance(0.8);
    try testing.expect(!h.t.ctx.animating);

    try testing.expect(h.t.hasText("Ada Lovelace"));
    try testing.expect(h.t.hasText("000\u{00b7}042"));
    try testing.expect(h.t.hasText("Nov 14, 2023"));
    try testing.expect(h.t.hasText("Card edition"));
    try testing.expect(h.t.hasText("Founder 1/1 \u{00b7} GOLDEN CRANES"));
    try testing.expect(h.t.hasText("Sign out"));
}
