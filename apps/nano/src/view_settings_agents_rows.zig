//! Settings › Agents' list (harnesses.rs `rows`): one card row per agent,
//! its mark on a tile in its brand colour, its name, a quiet line of
//! fragments (blurb, graff's compaction point, install and sign-in
//! progress, hints) wrapping as GPUI's `meta_line` does, its actions and
//! its switch.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const set = @import("view_settings.zig");
const shots = @import("view_settings_appshots.zig");
const agents = @import("agents.zig");
const page = @import("view_settings_agents.zig");
const App = @import("app.zig").App;

fn successMuted(k: theme.Colors) ui.Color {
    return k.success.mix(k.text, 0.25);
}

fn warningMuted(k: theme.Colors) ui.Color {
    return k.warning.mix(k.text, 0.25);
}

/// A row's actions, in GPUI's order.
const Action = enum { install, update, beta, cancel_install, sign_in, cancel_sign_in, retry };

fn label(act: Action) []const u8 {
    return switch (act) {
        .install => "Install",
        .update => "Update",
        .beta => "Install beta",
        .cancel_install, .cancel_sign_in => "Cancel",
        .sign_in => "Sign in",
        .retry => "Retry",
    };
}

pub fn list(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.agents;
    const shown = agents.visible(c.alloc(), p.descriptors(), agents.mockAllowed()) catch return;
    var enabled_count: usize = 0;
    for (shown) |d| if (agents.descriptorEnabled(d)) {
        enabled_count += 1;
    };
    for (shown, 0..) |d, ix| row(c, a, k, d, ix == 0, enabled_count);
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, d: agents.Descriptor, first: bool, enabled_count: usize) void {
    const p = &a.view.agents;
    const id = d.id;
    const enabled = agents.descriptorEnabled(d);
    const signing = if (p.sign_in) |s| s.harness == id else false;
    const failure: ?page.SignInFailure = if (p.sign_in_failure) |f| (if (f.harness == id) f else null) else null;
    const rule = agents.switchRule(enabled, d.installed, enabled_count, signing);
    const here = p.installing == id;
    const busy = p.installing != null;

    var acts: [4]Action = undefined;
    var n: usize = 0;
    if (agents.offersInstall(id, d.installed, d.can_install) and !here) push(&acts, &n, .install);
    // graff is app-managed: its installer fetches the latest release.
    if (id == .graff and d.installed and d.can_install and !here) push(&acts, &n, .update);
    if (id == .graff and d.can_install and !here) push(&acts, &n, .beta);
    if (here) push(&acts, &n, .cancel_install);
    if (agents.offersSignIn(id, d.installed) and !signing and failure == null) push(&acts, &n, .sign_in);
    if (signing) push(&acts, &n, .cancel_sign_in);
    if (failure != null) push(&acts, &n, .retry);

    ui.key(c, c.print("agents-row-{s}", .{id.wire()}));
    var r = set.row(c, k, first, false);
    if (signing) r = r.opacity(0.65) else if (!d.installed) r = r.opacity(0.55);
    defer r.end();
    {
        // `row_tile` with the brand tint kept (Claude's mark stays orange).
        const mark = icons.harnessMark(id.wire());
        const t = ui.div(c).row().size(36, 36).center().rounded(10).border(k.border).borderW(1).bg(k.ink(0.03));
        defer t.end();
        icons.icon(c, mark.name, 16, mark.brand orelse k.muted, 0);
    }
    var used: f32 = 36 + 14 + 32 + 14;
    for (acts[0..n]) |act| used += page.actionW(c, label(act)) + 14;
    const w = @max(set.inner_w - 2 - 2 * 20 - used, 80);
    {
        const col = ui.div(c).column().w(w);
        defer col.end();
        page.title(c, k, d.name, w);
        meta(c, a, k, d, enabled, signing, failure, w);
    }
    for (acts[0..n]) |act| {
        // While another agent installs, the install actions don't act.
        const inert = busy and (act == .install or act == .update or act == .beta);
        const clicked = if (inert) inertAction(c, k, label(act)) else shots.action(c, k, label(act));
        if (clicked) switch (act) {
            .install, .update => page.install(a, id, false),
            .beta => page.install(a, id, true),
            .cancel_install => page.cancelInstall(a),
            .sign_in, .retry => page.startSignIn(a, id),
            .cancel_sign_in => page.cancelSignIn(a),
        };
    }
    if (page.toggle(c, k, enabled, rule.interactive)) page.setEnabled(a, id, !enabled);
}

fn push(acts: *[4]Action, n: *usize, act: Action) void {
    if (n.* < acts.len) {
        acts[n.*] = act;
        n.* += 1;
    }
}

/// `ghost_action` without its hover or click.
fn inertAction(c: *ui.Context, k: theme.Colors, text: []const u8) bool {
    const b = ui.div(c).row().px(10).py(6).rounded(8).itemsCenter();
    defer b.end();
    ui.text(c, text, set.st(c, 12, .{ .color = k.muted }));
    return false;
}

/// One `meta_line` fragment.
const Frag = union(enum) {
    text: struct { s: []const u8, color: ui.Color },
    /// The spinner and what it's doing.
    working: []const u8,
    /// graff's compaction point.
    compact,
    dot,
};

/// The quiet line under the name: fragments joined by faint dots, 8
/// apart, wrapping onto lines 2 apart; one wider than the row wraps
/// inside it.
fn meta(c: *ui.Context, a: *App, k: theme.Colors, d: agents.Descriptor, enabled: bool, signing: bool, failure: ?page.SignInFailure, w: f32) void {
    const p = &a.view.agents;
    const al = c.alloc();
    const quiet = k.muted.alpha(0.65);
    var frags: std.ArrayList(Frag) = .empty;
    frags.append(al, .{ .text = .{ .s = agents.blurb(d.id), .color = quiet } }) catch return;
    if (d.id == .graff) frags.append(al, .compact) catch {};
    if (d.id == .graff and d.can_install) frags.append(al, .{ .text = .{ .s = "Install beta updates the managed Codegraff CLI for new Graff sessions.", .color = k.muted } }) catch {};
    if (signing) {
        const s = p.sign_in.?;
        frags.append(al, .{ .working = s.message orelse s.phase.pendingLabel() }) catch {};
    }
    if (failure) |f| frags.append(al, .{ .text = .{ .s = c.print("{s} — {s}", .{ f.phase.failureLabel(), f.message }), .color = k.danger_muted.alpha(0.9) } }) catch {};
    if (p.installing == d.id) {
        const what = if (p.installing_beta and d.id == .graff) "Installing Codegraff engine beta…" else agents.installLabel(al, d.name) catch "";
        frags.append(al, .{ .working = what }) catch {};
    }
    if (d.installed and !enabled and !agents.defaultOn(d.id)) frags.append(al, .{ .text = .{ .s = "Off by default — turn on to use", .color = k.muted } }) catch {};
    if (!d.installed) {
        frags.append(al, .{ .text = .{ .s = agents.installHint(al, d.id, enabled, d.can_install) catch "", .color = warningMuted(k).alpha(0.9) } }) catch {};
        if (agents.executableOverride(d.id)) |v| frags.append(al, .{ .text = .{ .s = c.print("Custom build: set {s} to that binary.", .{v}), .color = k.muted } }) catch {};
    }
    // Dots between, then lines as a wrapping row lays them out.
    var items: std.ArrayList(Frag) = .empty;
    for (frags.items, 0..) |f, i| {
        if (i > 0) items.append(al, .dot) catch {};
        items.append(al, f) catch {};
    }
    set.space(c, 1);
    const col = ui.div(c).column().w(w).gap(2);
    defer col.end();
    var i: usize = 0;
    while (i < items.items.len) {
        var j = i;
        var line_w: f32 = 0;
        while (j < items.items.len) : (j += 1) {
            const iw = @min(fragW(c, a, items.items[j], w), w);
            if (j > i and line_w + 8 + iw > w) break;
            line_w += (if (j > i) @as(f32, 8) else 0) + iw;
        }
        const line = ui.div(c).row().gap(8).itemsCenter();
        defer line.end();
        for (items.items[i..j]) |f| drawFrag(c, a, k, f, w);
        i = j;
    }
}

fn fragW(c: *ui.Context, a: *App, f: Frag, w: f32) f32 {
    return switch (f) {
        .text => |t| c.text.width(t.s, .{ .size = 12 }),
        .working => |s| spinner_w + 6 + c.text.width(s, .{ .size = 12 }),
        .compact => compactW(c, a, w),
        .dot => c.text.width("·", .{ .size = 12 }),
    };
}

fn drawFrag(c: *ui.Context, a: *App, k: theme.Colors, f: Frag, w: f32) void {
    switch (f) {
        .text => |t| {
            const box = ui.div(c).column().w(@min(c.text.width(t.s, .{ .size = 12 }) + 1, w));
            defer box.end();
            ui.text(c, t.s, set.st(c, 12, .{ .wrap = true, .color = t.color }));
        },
        .working => |s| {
            const r = ui.div(c).row().gap(6).itemsCenter();
            defer r.end();
            spinner(c, k.muted);
            const box = ui.div(c).column().w(@min(c.text.width(s, .{ .size = 12 }) + 1, w - spinner_w - 6));
            defer box.end();
            ui.text(c, s, set.st(c, 12, .{ .wrap = true, .color = k.muted.alpha(0.65) }));
        },
        .compact => compact(c, a, k, @min(compactW(c, a, w), w)),
        .dot => ui.text(c, "·", set.st(c, 12, .{ .color = k.muted.alpha(0.3) })),
    }
}

const help = "How full the context window gets before Graff compacts. Applies to new Graff chats; /compact-at 70 changes one chat.";

fn pillW(c: *ui.Context, text: []const u8) f32 {
    return 2 * 9 + c.text.width(text, .{ .size = 10.5 });
}

/// The compaction block's natural width: its widest line.
fn compactW(c: *ui.Context, a: *App, w: f32) f32 {
    var choices = c.text.width("Compact context at", .{ .size = 12 });
    for (agents.compact_choices) |ch| choices += 6 + pillW(c, ch.label);
    var most = @max(choices, c.text.width(help, .{ .size = 12 }));
    if (custom(a)) |pct| most = @max(most, c.text.width(c.print("Currently {d}%, set on this device.", .{pct}), .{ .size = 12 }));
    return @min(most, w);
}

fn custom(a: *App) ?u8 {
    const p = &a.view.agents;
    return if (p.compact == .ready) agents.customCompact(p.compact_pct) else null;
}

/// "Compact context at" and its pills, what it means, and a point set
/// some other way (`render_graff_compact_at`).
fn compact(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const p = &a.view.agents;
    const ready = p.compact == .ready;
    const busy = !ready or p.compact_saving;
    const col = ui.div(c).column().w(w).pt(6).gap(4);
    defer col.end();
    {
        // The pills wrap 6 apart, both ways.
        const lines = ui.div(c).column().gap(6);
        defer lines.end();
        var at: usize = 0;
        const total = agents.compact_choices.len + 1;
        while (at < total) {
            var end = at;
            var line_w: f32 = 0;
            while (end < total) : (end += 1) {
                const iw = if (end == 0) c.text.width("Compact context at", .{ .size = 12 }) else pillW(c, agents.compact_choices[end - 1].label);
                if (end > at and line_w + 6 + iw > w) break;
                line_w += (if (end > at) @as(f32, 6) else 0) + iw;
            }
            const line = ui.div(c).row().gap(6).itemsCenter();
            defer line.end();
            for (at..end) |ix| {
                if (ix == 0) {
                    ui.text(c, "Compact context at", set.st(c, 12, .{ .color = k.muted }));
                    continue;
                }
                const ch = agents.compact_choices[ix - 1];
                const selected = ready and p.compact_pct == ch.pct;
                ui.key(c, c.print("graff-compact-at-{d}", .{ix - 1}));
                var pill = ui.div(c).row().roundedFull();
                // `badge_active` has no edge, so it's 2 smaller each way.
                pill = if (selected) pill.px(8).py(2).bg(k.success.alpha(0.12)) else pill.px(9).py(3).border(k.border).borderW(1);
                if (busy) pill = pill.opacity(0.35);
                defer pill.end();
                const hot = !busy and !selected and pill.hovered();
                ui.text(c, ch.label, set.st(c, 10.5, .{ .color = if (selected) successMuted(k).alpha(0.9) else if (hot) k.text else k.muted }));
                if (!busy and !selected and pill.clicked()) page.loadCompact(a, .{ .save = ch.pct });
            }
            at = end;
        }
    }
    {
        const h = ui.div(c).column().w(w);
        defer h.end();
        ui.text(c, help, set.st(c, 12, .{ .wrap = true, .color = k.muted }));
    }
    if (custom(a)) |pct| ui.text(c, c.print("Currently {d}%, set on this device.", .{pct}), set.st(c, 12, .{ .color = k.muted.alpha(0.65) }));
}

const spinner_w: f32 = 2 * 1.5 + 1;

/// `mini_mono_spinner`: the snake in one tone, cells 1.5 across.
fn spinner(c: *ui.Context, color: ui.Color) void {
    const order = [_][2]u8{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } };
    const step: usize = @intFromFloat(@mod(@floor(c.time * 15), 6));
    const box = ui.div(c).column().gap(1);
    defer box.end();
    for (0..3) |rw| {
        const r = ui.div(c).row().gap(1);
        defer r.end();
        for (0..2) |cl| {
            var lit: f32 = 0.22;
            for (0..3) |back| {
                const o = order[(step + 6 - back) % 6];
                if (o[0] == cl and o[1] == rw) lit = @max(lit, 1.0 - @as(f32, @floatFromInt(back)) * 0.3);
            }
            _ = c.leaf(.{ .width = .{ .px = 1.5 }, .height = .{ .px = 1.5 }, .background = color.alpha(lit) }, .none, null);
        }
    }
    c.frameIn(1.0 / 15.0);
}
