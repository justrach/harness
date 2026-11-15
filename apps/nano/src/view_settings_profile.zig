//! Settings › Account (`profile.luau`): signed-out preview card + Sign in,
//! and signed-in member identity + interactive holographic MemberCard.
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
    const layout = if (wide)
        ui.div(c).row().wFull().gap(28).itemsStart()
    else
        ui.div(c).column().wFull().gap(24);
    defer layout.end();

    if (a.account.user) |*u| {
        const display_name = if (u.name) |n| (if (n.len > 0) n else u.email) else u.email;
        const seed_str = if (u.id.len > 0) u.id else if (u.email.len > 0) u.email else display_name;
        const shown_name = if (display_name.len > 0) display_name else "Member";

        // Left column: profile card + sync info + Sign out + link to CLI provider accounts.
        {
            const left = if (wide) ui.div(c).column().grow().w(0).gap(16) else ui.div(c).column().wFull().gap(16);
            defer left.end();

            const card_bg = k.ink(if (k.dark) 0.038 else 0.025);
            const card_edge = if (k.dark) k.border else @import("view_panel_chrome.zig").zenEdge(k);
            const card = ui.div(c).column().wFull().rounded(12).border(card_edge).borderW(1)
                .bg(card_bg).p(20).gap(16);
            defer card.end();

            {
                const top = ui.div(c).row().wFull().gap(14).itemsCenter();
                defer top.end();

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
                    kit.ellipsisText(c, shown_name, set.st(c, 15, .{ .weight = .semibold, .color = k.text }), 260);
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
                    kit.ellipsisText(c, u.email, set.st(c, 12.5, .{ .color = k.muted }), 280);
                }
            }

            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);

            {
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

                const traits = member_card.resolveTraits(seed_str, u.member_number, u.card_scenes, u.card_traits);
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

            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);

            {
                const actions = ui.div(c).row().wFull().gap(10).itemsCenter();
                defer actions.end();

                ui.key(c, "account-sign-out");
                const so = ui.div(c).row().h(32).px(14).center().rounded(8).border(k.border).borderW(1).hover(k.hover).control();
                {
                    defer so.end();
                    ui.text(c, "Sign out", set.st(c, 13, .{ .weight = .medium, .color = k.text }));
                }
                if (so.clicked()) account.signOut(a);

                ui.spacer(c);

                if (set.ghost(c, k, "Provider accounts")) {
                    a.settings.setSection(.agents);
                    a.redraw();
                }
            }
        }

        // Right column: interactive full-size 300×420 member card.
        {
            const right = if (wide) ui.div(c).column().w(member_card.base_w).itemsCenter() else ui.div(c).column().wFull().itemsCenter();
            defer right.end();
            member_card.draw(c, a.gpa, &a.view.profile_card, k, .{
                .seed = seed_str,
                .name = shown_name,
                .member_number = u.member_number,
                .started_at = u.started_at orelse @divFloor(a.nowMs(), 1000),
                .card_scenes = u.card_scenes,
                .card_traits = u.card_traits,
                .preview = false,
            });
        }
    } else {
        // Signed-out state: feature card + Sign in on left, 180×252 preview card on right.
        {
            const left = if (wide) ui.div(c).column().grow().w(0).gap(16) else ui.div(c).column().wFull().gap(16);
            defer left.end();

            const card_bg = k.ink(if (k.dark) 0.038 else 0.025);
            const card_edge = if (k.dark) k.border else @import("view_panel_chrome.zig").zenEdge(k);
            const card = ui.div(c).column().wFull().rounded(12).border(card_edge).borderW(1)
                .bg(card_bg).p(20).gap(14);
            defer card.end();

            {
                const title_row = ui.div(c).row().wFull().gap(10).itemsCenter();
                defer title_row.end();
                const emblem = ui.div(c).row().size(32, 32).center().rounded(8).bg(k.accent_wash);
                {
                    defer emblem.end();
                    icons.icon(c, .@"user-rounded", 16, k.accent, 0);
                }
                ui.text(c, "Harness Account", set.st(c, 15, .{ .weight = .semibold, .color = k.text }));
            }

            {
                const body = ui.div(c).column().wFull();
                defer body.end();
                ui.text(c, "Sync sessions across Macs, iOS, and the web, launch cloud sandboxes, and claim your numbered member card stamped with the date you joined Harness.", .{
                    .size = 13,
                    .line_height = 13 * phi,
                    .wrap = true,
                    .color = k.muted,
                });
            }

            if (a.account.scope == .development) {
                ui.text(c, "Sign-in is disabled in development mode.", set.st(c, 12, .{ .color = k.muted }));
            }

            {
                const actions = ui.div(c).row().wFull().pt(4).gap(10).itemsCenter();
                defer actions.end();

                ui.key(c, "account-sign-in");
                const btn = ui.div(c).row().h(34).px(16).gap(6).center().rounded(8).bg(k.text).hover(k.text.alpha(0.86)).control();
                {
                    defer btn.end();
                    ui.text(c, "Sign in", set.st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
                }
                if (btn.clicked()) account.enableSync(a);

                if (set.ghost(c, k, "Provider accounts")) {
                    a.settings.setSection(.agents);
                    a.redraw();
                }
            }
        }

        // Right column: compact 180×252 preview card ("000·000", "You", "Yours when you sign in").
        {
            const preview_w = member_card.base_w * member_card.preview_zoom;
            const right = if (wide) ui.div(c).column().w(preview_w).itemsCenter() else ui.div(c).column().wFull().itemsCenter();
            defer right.end();
            member_card.draw(c, a.gpa, &a.view.profile_card, k, .{
                .seed = ascii.preview_seed,
                .name = "You",
                .member_number = null,
                .started_at = null,
                .preview = true,
                .caption = "Yours when you sign in",
            });
        }
    }
}

fn infoRow(c: *ui.Context, k: theme.Colors, label: []const u8, value: []const u8) void {
    const r = ui.div(c).row().wFull().itemsCenter();
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
    h.t.settle(0.3);

    try testing.expect(h.t.hasText("Sign in"));
    try testing.expect(h.t.hasText("000\u{00b7}000"));
    try testing.expect(h.t.hasText("You"));
    try testing.expect(h.t.hasText("Yours when you sign in"));

    const signed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"state":"signedIn","user":{"id":"user_synth","email":"ada@example.com","name":"Ada Lovelace","memberNumber":42,"startedAt":1700000000,"cardScenes":20},"orgId":null}
    , .{});
    defer signed.deinit();
    h.a.account.user = try account.readUser(testing.allocator, signed.value);
    h.a.account.scope = .synced;
    h.t.settle(0.3);

    try testing.expect(h.t.hasText("Ada Lovelace"));
    try testing.expect(h.t.hasText("000\u{00b7}042"));
    try testing.expect(h.t.hasText("Nov 14, 2023"));
    try testing.expect(h.t.hasText("Card edition"));
    try testing.expect(h.t.hasText("Founder 1/1 \u{00b7} GOLDEN CRANES"));
    try testing.expect(h.t.hasText("Sign out"));
}
