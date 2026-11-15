//! The composer footer's account-usage ring cluster and switcher popover
//! (crates/ui/src/account_usage.rs): sits immediately left of `#context-usage`
//! for providers that report usage (`claude-code`, `codex`, `cursor`).
//! Clicking `#account-usage` opens `#account-usage-menu` listing the harness's
//! accounts with compact usage meters and 1-click optimistic switching via
//! `ActivateAgentAccount`.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const rpc = @import("rpc.zig");
const accounts = @import("accounts.zig");
const agent = @import("app_agent.zig");
const view_accounts = @import("view_settings_accounts.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const refresh_interval_s: f64 = 300.0;
pub const force_min_interval_s: f64 = 30.0;
pub const card_w: f32 = 400.0;

pub const State = struct {
    open: bool = false,
    anchor: ?ui.Rect = null,
    card: ?ui.Rect = null,
    card_id: u64 = 0,
    hovered_last_frame: bool = false,
    loading: bool = false,
    switching_prev_id: ?[]u8 = null,
    switching_harness: ?[]u8 = null,
    err: std.ArrayList(u8) = .empty,
    last_loaded_at: ?f64 = null,
    last_forced_at: ?f64 = null,
    probed_key: [160]u8 = undefined,
    probed_key_len: usize = 0,
    remote_target: ?[]u8 = null,
    remote_slot: view_accounts.Slot(accounts.Snapshot) = .{},

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.switching_prev_id) |p| gpa.free(p);
        if (s.switching_harness) |h| gpa.free(h);
        if (s.remote_target) |rt| gpa.free(rt);
        s.err.deinit(gpa);
        s.remote_slot.deinit(gpa);
    }
};

fn chatTargetDevice(a: *const App) ?[]const u8 {
    const id = a.selected orelse return null;
    const chat = a.findChat(id) orelse return null;
    const chat_dev = chat.device_id orelse return null;
    const me = a.device_id orelse return null;
    return if (!std.mem.eql(u8, chat_dev, me)) chat_dev else null;
}

fn eqOpt(x: ?[]const u8, y: ?[]const u8) bool {
    if (x) |a_s| return if (y) |b_s| std.mem.eql(u8, a_s, b_s) else false;
    return y == null;
}

fn usesSharedSettingsSlot(a: *const App) bool {
    return eqOpt(a.view.accounts.target, chatTargetDevice(a));
}

fn slotKey(dev: ?[]const u8) []const u8 {
    return dev orelse "__local__";
}

fn constSnapshot(a: *const App) ?accounts.Snapshot {
    if (usesSharedSettingsSlot(a)) return a.view.accounts.snapshot.get();
    const s = &a.view.account_usage;
    const want = slotKey(chatTargetDevice(a));
    if (s.remote_target) |rt| {
        if (std.mem.eql(u8, rt, want)) return s.remote_slot.get();
    }
    return null;
}

fn slotMut(a: *App) *view_accounts.Slot(accounts.Snapshot) {
    if (usesSharedSettingsSlot(a)) return &a.view.accounts.snapshot;
    const s = &a.view.account_usage;
    const want = slotKey(chatTargetDevice(a));
    const same = if (s.remote_target) |rt| std.mem.eql(u8, rt, want) else false;
    if (!same) {
        if (s.remote_target) |old| a.gpa.free(old);
        s.remote_target = a.gpa.dupe(u8, want) catch null;
        s.remote_slot.clear();
    }
    return &s.remote_slot;
}

/// Only probe automatically when talking to a live engine WebSocket, a parity
/// `scene_accounts` fixture, or a scene fixture that explicitly defines `ListAgentAccounts`
/// so unrelated UI scene tests never see spurious RPC frames in `a.engine.sent`.
fn canAutoProbe(a: *const App) bool {
    if (view_accounts.scene_accounts != null and chatTargetDevice(a) == null) return true;
    if (a.engine.state != .connected) return false;
    if (a.engine.client != null) return true;
    if (a.engine.scene) |sc| {
        if (sc.value == .object and sc.value.object.get("ListAgentAccounts") != null) return true;
    }
    return false;
}

fn maybeProbe(c: *ui.Context, a: *App) void {
    const s = &a.view.account_usage;
    if (a.selected == null) return;
    const t = agent.target(a);
    if (!accounts.reportsUsage(t.harness)) return;
    const key = std.fmt.bufPrint(&s.probed_key, "{s}:{s}", .{ slotKey(chatTargetDevice(a)), t.harness }) catch "";
    if (!std.mem.eql(u8, s.probed_key[0..s.probed_key_len], key)) {
        if (constSnapshot(a) == null and canAutoProbe(a)) {
            s.probed_key_len = key.len;
            requestLoad(a, c.time, false);
        } else if (constSnapshot(a) != null) {
            s.probed_key_len = key.len;
        }
        return;
    }
    if (a.selectedStatus() == .working) {
        if (s.last_loaded_at) |last| {
            if (c.time - last >= refresh_interval_s and canAutoProbe(a)) {
                requestLoad(a, c.time, false);
            }
        }
    }
}

fn requestForceRefresh(a: *App, now_s: f64) void {
    const s = &a.view.account_usage;
    if (!canAutoProbe(a)) return;
    if (s.last_forced_at) |last| {
        if (now_s - last < force_min_interval_s) return;
    }
    s.last_forced_at = now_s;
    requestLoad(a, now_s, true);
}

fn requestLoad(a: *App, now_s: f64, force_usage: bool) void {
    const s = &a.view.account_usage;
    if (s.loading) return;
    const dev = chatTargetDevice(a);
    if (view_accounts.scene_accounts) |text| if (dev == null) {
        var parsed = json.parseFromSlice(json.Value, a.gpa, text, .{}) catch return;
        defer parsed.deinit();
        const o = if (parsed.value == .object) parsed.value.object else return;
        const snap_val = o.get("snapshot") orelse return;
        var ar: std.heap.ArenaAllocator = .init(a.gpa);
        const snap = accounts.parseSnapshot(ar.allocator(), snap_val) catch {
            ar.deinit();
            return;
        };
        slotMut(a).take(ar, snap);
        s.last_loaded_at = now_s;
        a.redraw();
        return;
    };
    if (!a.engine.up()) return;
    s.loading = true;
    s.last_loaded_at = now_s;
    _ = a.engine.call(
        "ListAgentAccounts",
        .{ .targetDeviceId = dev, .forceUsage = force_usage },
        .of(App, a, onLoaded),
    );
}

fn onLoaded(a: *App, _: u64, r: rpc.Reply) void {
    const s = &a.view.account_usage;
    s.loading = false;
    switch (r) {
        .ok => |val| {
            var ar: std.heap.ArenaAllocator = .init(a.gpa);
            const snap = accounts.parseSnapshot(ar.allocator(), val) catch {
                ar.deinit();
                return;
            };
            slotMut(a).take(ar, snap);
            a.redraw();
        },
        .err => {},
        .item, .done => {},
    }
}

pub fn fraction(a: *const App) ?f32 {
    if (a.selected == null) return null;
    const t = agent.target(a);
    const snap = constSnapshot(a) orelse return null;
    const acc = accounts.activeAccountForHarness(snap, t.harness) orelse return null;
    return accounts.ringFraction(acc, t.harness, t.model);
}

pub fn hasRing(a: *const App) bool {
    return fraction(a) != null;
}

/// The account usage ring rendered immediately left of `#context-usage`.
pub fn indicator(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.account_usage;
    maybeProbe(c, a);
    const f = fraction(a) orelse {
        s.anchor = null;
        s.open = false;
        s.hovered_last_frame = false;
        return;
    };
    const lvl = accounts.usageLevel(f);
    const arc_color = switch (lvl) {
        .normal => k.accent,
        .warn => k.warning,
        .critical => k.danger,
    };
    const text_color = switch (lvl) {
        .normal => k.muted,
        .warn => k.warning,
        .critical => k.danger,
    };
    ui.key(c, "account-usage");
    const hit = ui.div(c).row().minW(32).hFull().center();
    defer hit.end();
    const near = if (s.anchor) |r|
        c.input.mouse.x >= r.x - 2 and c.input.mouse.x < r.x + r.w + 2 and c.input.mouse.y >= r.y and c.input.mouse.y < r.y + r.h
    else
        false;
    const hovered = hit.hovered() or near;
    if (hovered and !s.hovered_last_frame) {
        requestForceRefresh(a, c.time);
    }
    s.hovered_last_frame = hovered;

    var pill = ui.div(c).row().h(24).px(6).gap(5).itemsCenter().rounded(6);
    if (hovered or s.open) pill = pill.bg(k.ink(0.05));
    defer pill.end();
    if (c.rects.get(c.node(pill.index).id)) |r| s.anchor = r;
    if (pill.clicked() or hit.clicked()) {
        s.open = !s.open;
        if (s.open) {
            a.view.context.open = false;
            a.view.context.pinned = false;
            a.picker = .none;
            a.view.model_picker.account_submenu = false;
            s.err.clearRetainingCapacity();
            requestForceRefresh(a, c.time);
        }
        c.changed = true;
    }
    @import("view_context.zig").drawRing(c, f, arc_color, k.faint.alpha(0.25));
    const pct_num: u32 = @intFromFloat(@round(std.math.clamp(f, 0, 1) * 100.0));
    ui.text(c, c.print("{d}%", .{pct_num}), .{ .tabular = true, .size = 12, .line_height = 12 * 1.618, .color = text_color });
}

/// The `400pt` `#account-usage-menu` popover anchored above `#account-usage`.
pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.account_usage;
    if (!s.open or a.selected == null or a.picker != .none) {
        s.card = null;
        if (a.selected == null) s.open = false;
        return;
    }
    const target_cfg = agent.target(a);
    const provider = accounts.providerHarness(target_cfg.harness) orelse {
        s.open = false;
        s.card = null;
        return;
    };
    const snap = constSnapshot(a) orelse {
        s.open = false;
        s.card = null;
        return;
    };
    var matching: std.ArrayList(accounts.Account) = .empty;
    for (snap.accounts) |acc| {
        if (accounts.providerHarness(acc.harness) == provider) {
            matching.append(c.alloc(), acc) catch {};
        }
    }
    if (matching.items.len == 0) {
        s.open = false;
        s.card = null;
        return;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
        s.open = false;
        s.card = null;
        s.err.clearRetainingCapacity();
        c.changed = true;
        return;
    }
    {
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(5);
        defer back.end();
        if (back.clicked()) {
            s.open = false;
            s.card = null;
            s.err.clearRetainingCapacity();
            c.changed = true;
            return;
        }
    }

    const anchor = s.anchor orelse ui.Rect{ .x = c.size.w - 140, .y = c.size.h - 40, .w = 56, .h = 24 };
    const est_h: f32 = if (s.card) |r|
        r.h
    else
        36.0 + @min(220.0, @as(f32, @floatFromInt(matching.items.len)) * 52.0) + (if (s.err.items.len > 0) @as(f32, 26.0) else 0.0);
    const px = rules.snapToWindow(anchor.x + anchor.w - card_w, card_w, c.size.w, 8);
    const py = @import("view_menus.zig").upwardOrBelow(anchor, est_h, c.size.h);

    ui.key(c, "account-usage-menu");
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(
        ui.div(c).fixed().offset(px, py).w(card_w).layer(6).column().p(6).gap(2)
            .bg(k.composer).border(k.border).borderW(1).rounded(12),
    ));
    defer card.end();
    s.card_id = c.node(card.index).id;
    if (c.rects.get(s.card_id)) |r| {
        if (@abs(r.h - est_h) > 0.5) c.changed = true;
        s.card = r;
    }

    {
        const hdr = ui.div(c).row().wFull().px(10).pt(6).pb(4).itemsCenter();
        defer hdr.end();
        ui.text(c, c.print("{s} accounts", .{accounts.providerName(provider)}), .{
            .size = 11.5,
            .line_height = 11.5 * 1.4,
            .weight = theme.ui_medium_weight,
            .color = k.muted,
        });
    }

    const now_ms = std.Io.Clock.Timestamp.now(a.io, .real).raw.toMilliseconds();
    if (matching.items.len > 4) {
        ui.key(c, "account-usage-list");
        const list = ui.div(c).column().wFull().maxH(220).gap(2).scrollY()
            .scrollbar(.{ .overlay = k.faint.alpha(0.5) });
        c.node(list.index).style.scroll_edge_fade = 16;
        defer list.end();
        for (matching.items, 0..) |acc, ix| {
            drawAccountRow(c, a, k, target_cfg.harness, acc, ix, now_ms);
        }
    } else {
        for (matching.items, 0..) |acc, ix| {
            drawAccountRow(c, a, k, target_cfg.harness, acc, ix, now_ms);
        }
    }

    if (s.err.items.len > 0) {
        const ebox = ui.div(c).row().wFull().px(10).py(4);
        defer ebox.end();
        ui.text(c, c.print("{s}", .{s.err.items}), .{ .size = 12, .line_height = 16, .wrap = true, .color = k.danger });
    }
}

fn drawAccountRow(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    harness_wire: []const u8,
    acc: accounts.Account,
    ix: usize,
    now_ms: i64,
) void {
    ui.key(c, c.print("account-usage-row-{d}", .{ix}));
    const interactive = !acc.active and acc.switchable;
    var row = ui.div(c).row().wFull().px(10).py(8).gap(12).itemsCenter().rounded(8);
    if (interactive) row = row.hover(k.hover);
    defer row.end();

    {
        const left = ui.div(c).column().grow().w(0).gap(2);
        defer left.end();
        const left_cap: f32 = if (acc.usage.len > 0) 164 else 350;
        kit.ellipsisText(c, acc.title(), .{
            .size = 12.5,
            .line_height = 12.5 * 1.4,
            .weight = theme.ui_medium_weight,
            .color = k.text,
        }, left_cap);

        const has_plan = if (acc.plan_label) |pl| pl.len > 0 else false;
        const has_err = !acc.active and acc.usage.len == 0 and (if (acc.usage_error) |ue| ue.len > 0 else false);
        if (has_plan or acc.active or has_err) {
            const meta = ui.div(c).row().wFull().gap(6).itemsCenter();
            defer meta.end();
            if (acc.plan_label) |pl| if (pl.len > 0) {
                ui.text(c, pl, .{ .size = 11, .line_height = 15, .color = k.muted });
            };
            if (acc.active) {
                ui.text(c, "In use", .{
                    .size = 11,
                    .line_height = 15,
                    .weight = theme.ui_medium_weight,
                    .color = k.accent,
                });
            } else if (acc.usage.len == 0) {
                if (acc.usage_error) |ue| if (ue.len > 0) {
                    kit.ellipsisText(c, ue, .{ .size = 11, .line_height = 15, .color = k.muted }, 340);
                };
            }
        }
    }

    if (acc.usage.len > 0) {
        const tip_str = accounts.usageResets(c.alloc(), acc.usage, now_ms, null);
        ui.key(c, c.print("account-usage-meters-{d}", .{ix}));
        const base_col = ui.div(c).column().gap(4).itemsEnd();
        const mcol = @import("view_tooltip.zig").on(base_col, k, .{ .text = tip_str });
        defer mcol.end();

        for (acc.usage) |w| {
            const mrow = ui.div(c).row().h(16).gap(8).itemsCenter();
            defer mrow.end();

            {
                const lbox = ui.div(c).row().w(52).itemsCenter().clip();
                defer lbox.end();
                kit.ellipsisText(c, w.label, .{ .size = 11, .line_height = 15, .color = k.muted }, 52);
            }

            const clamped = std.math.clamp(w.used_fraction, 0, 1);
            const vis_f: f32 = if (clamped > 0) @max(clamped, 0.015) else 0;
            const wlvl = accounts.usageLevel(clamped);
            const bar_color = switch (wlvl) {
                .normal => k.accent,
                .warn => k.warning,
                .critical => k.danger,
            };
            {
                const track = ui.div(c).row().size(88, 4).rounded(2).bg(k.ink(0.08)).clip();
                defer track.end();
                if (vis_f > 0) {
                    _ = c.leaf(.{
                        .width = .{ .px = 88.0 * vis_f },
                        .height = .{ .px = 4 },
                        .radius = 2,
                        .background = bar_color,
                    }, .none, null);
                }
            }
            {
                const pbox = ui.div(c).row().w(34).justifyEnd().itemsCenter();
                defer pbox.end();
                const w_pct: u32 = @intFromFloat(@round(clamped * 100.0));
                ui.text(c, c.print("{d}%", .{w_pct}), .{
                    .tabular = true,
                    .size = 11,
                    .line_height = 15,
                    .color = if (wlvl == .normal) k.muted else bar_color,
                });
            }
        }
    }

    if (interactive and row.clicked()) {
        activateAccount(a, harness_wire, acc.id);
    }
}

fn activateAccount(a: *App, harness_wire: []const u8, id: []const u8) void {
    const s = &a.view.account_usage;
    s.err.clearRetainingCapacity();

    if (s.switching_prev_id) |old| {
        a.gpa.free(old);
        s.switching_prev_id = null;
    }
    if (s.switching_harness) |old| {
        a.gpa.free(old);
        s.switching_harness = null;
    }

    if (constSnapshot(a)) |snap| {
        if (accounts.activeAccountForHarness(snap, harness_wire)) |prev| {
            s.switching_prev_id = a.gpa.dupe(u8, prev.id) catch null;
        }
    }
    s.switching_harness = a.gpa.dupe(u8, harness_wire) catch null;

    if (slotMut(a).get()) |snap| {
        accounts.markSwitched(@constCast(snap.accounts), id, harness_wire);
    }
    a.redraw();

    const provider = accounts.providerHarness(harness_wire) orelse return;
    _ = a.engine.call(
        "ActivateAgentAccount",
        .{
            .id = id,
            .accountId = id,
            .harness = provider.wire(),
            .targetDeviceId = chatTargetDevice(a),
        },
        .of(App, a, onActivated),
    );
}

fn onActivated(a: *App, _: u64, r: rpc.Reply) void {
    const s = &a.view.account_usage;
    switch (r) {
        .ok => |val| {
            if (s.switching_prev_id) |p| {
                a.gpa.free(p);
                s.switching_prev_id = null;
            }
            if (s.switching_harness) |h| {
                a.gpa.free(h);
                s.switching_harness = null;
            }
            if (val == .object and val.object.get("accounts") != null) {
                var ar: std.heap.ArenaAllocator = .init(a.gpa);
                if (accounts.parseSnapshot(ar.allocator(), val)) |snap| {
                    slotMut(a).take(ar, snap);
                    s.last_loaded_at = a.now;
                    a.redraw();
                    return;
                } else |_| ar.deinit();
            }
            if (canAutoProbe(a)) requestLoad(a, s.last_loaded_at orelse a.now, false);
            a.redraw();
        },
        .err => |msg| {
            if (s.switching_prev_id) |prev_id| {
                if (s.switching_harness) |h| {
                    if (slotMut(a).get()) |snap| {
                        accounts.markSwitched(@constCast(snap.accounts), prev_id, h);
                    }
                }
            }
            if (s.switching_prev_id) |p| {
                a.gpa.free(p);
                s.switching_prev_id = null;
            }
            if (s.switching_harness) |h| {
                a.gpa.free(h);
                s.switching_harness = null;
            }
            s.err.clearRetainingCapacity();
            s.err.appendSlice(a.gpa, view_accounts.why(msg)) catch {};
            a.redraw();
        },
        .item, .done => {},
    }
}
