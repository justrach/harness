//! Settings › Accounts, as the GPUI app's (settings/accounts.rs, its
//! `SettingsSection::Agents`): CodeGraff's usage and PR-agent jobs, graff's
//! ChatGPT and other provider sign-ins, then the Claude Code, Codex and
//! Cursor logins with their usage meters, Switch and Forget, and Add
//! account (view_settings_accounts_login.zig). The device switcher in the
//! header points every call at another device (`targetDeviceId`).
//!
//! The cloud sandboxes card reads the list the app keeps
//! (app_sandboxes.zig, the GPUI app's `AppState::cloud_sandboxes`). A
//! failed run's "Log in" lands here through `signIn`.
const std = @import("std");
const rules = @import("rules.zig");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const accounts = @import("accounts.zig");
const rows = @import("view_settings_accounts_rows.zig");
const login = @import("view_settings_accounts_login.zig");
const graff = @import("view_settings_accounts_graff.zig");
const cloud = @import("view_settings_accounts_sandboxes.zig");
const sandboxes = @import("sandboxes.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const st = @import("view_settings_accounts_rows.zig").st;

/// While a PR-agent job works, its list is read again this often.
const jobs_poll_s: f64 = 20;
/// How many recent jobs the card shows (`JOBS_SHOWN`).
const jobs_shown: u32 = 8;

pub const Phase = enum { idle, loading, ready, failed };

/// One reply the page shows (`Loadable`), in an arena of its own.
pub fn Slot(comptime T: type) type {
    return struct {
        const Self = @This();
        phase: Phase = .idle,
        arena: ?std.heap.ArenaAllocator = null,
        value: T = undefined,
        why: std.ArrayList(u8) = .empty,
        /// The call whose reply this waits for.
        call: ?u64 = null,

        pub fn deinit(s: *Self, gpa: Allocator) void {
            if (s.arena) |*ar| ar.deinit();
            s.why.deinit(gpa);
        }

        pub fn get(s: *const Self) ?T {
            return if (s.phase == .ready) s.value else null;
        }

        fn take(s: *Self, ar: std.heap.ArenaAllocator, v: T) void {
            if (s.arena) |*old| old.deinit();
            s.arena = ar;
            s.value = v;
            s.phase = .ready;
        }

        fn fail(s: *Self, gpa: Allocator, text: []const u8) void {
            s.phase = .failed;
            s.why.clearRetainingCapacity();
            s.why.appendSlice(gpa, text) catch {};
        }

        /// A reply to `id` is this slot's: the one it waits for, or one
        /// given at once (no engine).
        fn fresh(s: *Self, id: u64) bool {
            if (id != 0 and s.call != id) return false;
            s.call = null;
            return true;
        }
    };
}

/// The page's state, kept between visits.
pub const Page = struct {
    started: bool = false,
    /// Another device's logins (owned); null for this one.
    target: ?[]u8 = null,
    menu: bool = false,
    menu_anchor: ?ui.Rect = null,
    snapshot: Slot(accounts.Snapshot) = .{},
    usage: Slot(?accounts.Usage) = .{},
    jobs: Slot(?[]const accounts.Job) = .{},
    graff: Slot([]const accounts.GraffLogin) = .{},
    jobs_poll_at: ?f64 = null,
    /// An action's error over the page; a click dismisses it.
    notice: std.ArrayList(u8) = .empty,
    /// A failed run's "Update key" (`key_notice`): where graff's rejected API
    /// key is replaced, until a click dismisses it.
    key_notice: bool = false,
    busy_account: ?[]u8 = null,
    busy_graff: ?[]u8 = null,
    cancelling_job: ?[]u8 = null,
    signing_out: bool = false,
    /// "You're using your ChatGPT plan", once, until Got it.
    confirmation: ?[]u8 = null,
    login: login.State = .{},
    /// The cloud sandboxes card's own state (the list is the app's).
    cloud: cloud.Cloud = .{},

    pub fn deinit(p: *Page, gpa: Allocator) void {
        p.cloud.deinit(gpa);
        p.snapshot.deinit(gpa);
        p.usage.deinit(gpa);
        p.jobs.deinit(gpa);
        p.graff.deinit(gpa);
        p.notice.deinit(gpa);
        p.login.deinit(gpa);
        inline for (.{ "target", "busy_account", "busy_graff", "cancelling_job", "confirmation" }) |f| if (@field(p, f)) |x| gpa.free(x);
    }
};

pub fn replace(gpa: Allocator, slot: *?[]u8, text: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (text) |t| gpa.dupe(u8, t) catch null else null;
}

pub fn eqOpt(x: ?[]const u8, y: []const u8) bool {
    return if (x) |v| std.mem.eql(u8, v, y) else false;
}

pub fn setNotice(a: *App, text: []const u8) void {
    const p = &a.view.accounts;
    p.notice.clearRetainingCapacity();
    p.notice.appendSlice(a.gpa, text) catch {};
}

/// The engine's word for "no engine", as the page says it.
pub fn why(e: []const u8) []const u8 {
    return if (std.mem.eql(u8, e, "not connected")) "Engine not connected" else e;
}

/// An engine to ask (the GPUI app's `engine()`): connected, with a client.
pub fn engineUp(a: *App) bool {
    return a.engine.up();
}

pub fn target(a: *App) ?[]const u8 {
    return a.view.accounts.target;
}

// Loading.

/// `load`: with no engine the accounts fail and nothing else is asked.
pub fn load(a: *App, t: accounts.Trigger) void {
    const p = &a.view.accounts;
    p.started = true;
    if (scene_accounts) |text| return loadScene(a, text);
    if (!engineUp(a)) return p.snapshot.fail(a.gpa, "Engine not connected");
    p.snapshot.phase = .loading;
    loadUsage(a);
    loadJobs(a);
    loadGraff(a);
    cloud.refresh(a);
    p.snapshot.call = a.engine.call("ListAgentAccounts", .{ .forceUsage = accounts.forceUsage(t), .targetDeviceId = target(a) }, .of(App, a, handler("snapshot", accounts.parseSnapshot)));
}

fn loadUsage(a: *App) void {
    const p = &a.view.accounts;
    if (!engineUp(a)) return p.usage.fail(a.gpa, "Engine not connected");
    p.usage.phase = .loading;
    p.usage.call = a.engine.call("CodegraffUsage", .{ .targetDeviceId = target(a) }, .of(App, a, handler("usage", accounts.parseUsage)));
}

pub fn loadJobs(a: *App) void {
    const p = &a.view.accounts;
    if (!engineUp(a)) return;
    if (p.jobs.phase == .idle) p.jobs.phase = .loading;
    p.jobs.call = a.engine.call("CodegraffJobs", .{ .limit = jobs_shown, .targetDeviceId = target(a) }, .of(App, a, handler("jobs", accounts.parseJobs)));
}

/// graff's sign-ins: rows on screen stay through a reload.
pub fn loadGraff(a: *App) void {
    const p = &a.view.accounts;
    if (!engineUp(a)) return p.graff.fail(a.gpa, "Engine not connected");
    if (p.graff.phase != .ready) p.graff.phase = .loading;
    p.graff.call = a.engine.call("ListGraffLogins", .{ .targetDeviceId = target(a) }, .of(App, a, handler("graff", accounts.parseGraffLogins)));
}

/// The reply handler for slot `field`, read with `parse`.
fn handler(comptime field: []const u8, comptime parse: anytype) fn (*App, u64, rpc.Reply) void {
    return struct {
        fn on(a: *App, id: u64, r: rpc.Reply) void {
            const s = &@field(a.view.accounts, field);
            if (!s.fresh(id)) return;
            switch (r) {
                .ok => |v| feed(a, field, parse, v),
                .err => |e| s.fail(a.gpa, why(e)),
                else => {},
            }
            a.redraw();
        }
    }.on;
}

fn feed(a: *App, comptime field: []const u8, comptime parse: anytype, v: json.Value) void {
    const s = &@field(a.view.accounts, field);
    var ar: std.heap.ArenaAllocator = .init(a.gpa);
    const got = parse(ar.allocator(), v) catch {
        ar.deinit();
        return s.fail(a.gpa, "Unexpected reply");
    };
    s.take(ar, got);
    if (comptime std.mem.eql(u8, field, "jobs")) {
        // While one works, read them again (`JOBS_POLL`).
        const working = if (got) |jobs| for (jobs) |j| {
            if (accounts.jobActive(j)) break true;
        } else false else false;
        a.view.accounts.jobs_poll_at = if (working) a.now + jobs_poll_s else null;
    }
}

/// The cloud sandboxes' answer, kept on the app
/// (`apply_cloud_sandboxes_value`).
pub fn feedSandboxes(a: *App, v: json.Value) void {
    @import("app_sandboxes.zig").apply(a, v);
}

/// A headless scene's replies in place of the engine's (snap.zig; the GPUI
/// renderer's `SCENE_ACCOUNTS`): `snapshot`, `codegraffUsage`,
/// `codegraffJobs`, `graffLogins` and `codegraffSandboxes`, as JSON text.
pub var scene_accounts: ?[]const u8 = null;

/// Each of the scene's replies read as its call's would be (`load_scene`).
fn loadScene(a: *App, text: []const u8) void {
    var parsed = json.parseFromSlice(json.Value, a.gpa, text, .{}) catch return a.view.accounts.snapshot.fail(a.gpa, "Unexpected scene");
    defer parsed.deinit();
    const o = if (parsed.value == .object) parsed.value.object else return;
    feed(a, "snapshot", accounts.parseSnapshot, o.get("snapshot") orelse .null);
    feed(a, "usage", accounts.parseUsage, o.get("codegraffUsage") orelse .null);
    feed(a, "jobs", accounts.parseJobs, o.get("codegraffJobs") orelse .null);
    if (o.get("codegraffSandboxes")) |v| feedSandboxes(a, v);
    feed(a, "graff", accounts.parseGraffLogins, o.get("graffLogins") orelse .null);
    a.redraw();
}

/// Show replies as if the engine gave them (tests and fixtures).
pub fn setSnapshot(a: *App, v: json.Value) void {
    a.view.accounts.started = true;
    feed(a, "snapshot", accounts.parseSnapshot, v);
}
pub fn setUsage(a: *App, v: json.Value) void {
    feed(a, "usage", accounts.parseUsage, v);
}
pub fn setJobs(a: *App, v: json.Value) void {
    feed(a, "jobs", accounts.parseJobs, v);
}
pub fn setGraffLogins(a: *App, v: json.Value) void {
    feed(a, "graff", accounts.parseGraffLogins, v);
}

// Actions.

/// Show another device's logins (null: this one's), and read them afresh.
fn setTarget(a: *App, to: ?[]const u8) void {
    const p = &a.view.accounts;
    p.menu = false;
    const same = if (p.target) |t| (if (to) |x| std.mem.eql(u8, t, x) else false) else to == null;
    if (same) return;
    // Cancelled against the old device, before retargeting.
    login.cancel(a);
    replace(a.gpa, &p.target, to);
    replace(a.gpa, &p.busy_account, null);
    replace(a.gpa, &p.busy_graff, null);
    if (p.graff.arena) |*ar| ar.deinit();
    p.graff = .{ .why = p.graff.why };
    p.notice.clearRetainingCapacity();
    // The notice was about the last device's key.
    p.key_notice = false;
    load(a, .mount);
}

/// A failed run's "Log in" (`sign_in`): `target_device`'s logins (null:
/// this one's) and, for an agent with a sign-in here (Claude Code, Codex,
/// Cursor), Add account started. Other agents (graff's provider sign-ins
/// among them) just land on the page: the chat says which agent, not which
/// of its providers.
pub fn signIn(a: *App, target_device: ?[]const u8, harness: ?accounts.Harness) void {
    setTarget(a, target_device);
    a.view.accounts.key_notice = false;
    if (harness) |h| for (accounts.providers) |pv| if (pv.harness == h) {
        login.begin(a, h, null);
        break;
    };
    a.redraw();
}

/// A failed run's "Update key" (`update_key`): `target_device`'s logins,
/// with where to replace or remove the rejected API key. Never starts a
/// sign-in: signing in again doesn't fix a bad key.
pub fn updateKey(a: *App, target_device: ?[]const u8) void {
    setTarget(a, target_device);
    a.view.accounts.key_notice = true;
    a.redraw();
}

/// `KEY_REJECTED_NOTICE`.
pub const key_rejected_notice = "graff's API key for this provider was rejected. Your sign-in is not affected. Replace the key on this computer with `graff key set <provider> <key>`, or remove it (or its <PROVIDER>_API_KEY variable) so graff uses the sign-in. The error says which key it used.";

/// Switch (`ActivateAgentAccount`) or Forget (`ForgetAgentAccount`).
fn accountAction(a: *App, method: []const u8, acc: accounts.Account) void {
    const p = &a.view.accounts;
    if (!engineUp(a)) return;
    replace(a.gpa, &p.busy_account, acc.id);
    p.notice.clearRetainingCapacity();
    a.call(method, .{ .id = acc.id, .accountId = acc.id, .harness = acc.harness, .targetDeviceId = target(a) }, .of(App, a, onAccountAction));
}

fn onAccountAction(a: *App, _: u64, r: rpc.Reply) void {
    replace(a.gpa, &a.view.accounts.busy_account, null);
    switch (r) {
        .ok => load(a, .post_action),
        .err => |e| setNotice(a, why(e)),
        else => {},
    }
    a.redraw();
}

fn signOutCodegraff(a: *App) void {
    if (!engineUp(a)) return;
    a.view.accounts.signing_out = true;
    a.view.accounts.notice.clearRetainingCapacity();
    a.call("CodegraffSignOut", rpc.empty, .of(App, a, onSignOut));
}

fn onSignOut(a: *App, _: u64, r: rpc.Reply) void {
    a.view.accounts.signing_out = false;
    if (r == .err) {
        var buf: [256]u8 = undefined;
        setNotice(a, std.fmt.bufPrint(&buf, "Sign out of Codegraff failed: {s}", .{why(r.err)}) catch "Sign out of Codegraff failed");
    }
    loadUsage(a);
    loadJobs(a);
    cloud.refresh(a);
    a.redraw();
}

fn cancelJob(a: *App, id: []const u8) void {
    const p = &a.view.accounts;
    if (!engineUp(a)) return;
    replace(a.gpa, &p.cancelling_job, id);
    p.notice.clearRetainingCapacity();
    a.call("CodegraffCancelJob", .{ .id = id, .targetDeviceId = target(a) }, .of(App, a, onCancelJob));
}

fn onCancelJob(a: *App, _: u64, r: rpc.Reply) void {
    replace(a.gpa, &a.view.accounts.cancelling_job, null);
    if (r == .err) setNotice(a, why(r.err));
    loadJobs(a);
    a.redraw();
}

/// Sign out of one graff provider; the reply is the list again.
pub fn signOutGraff(a: *App, provider: []const u8) void {
    const p = &a.view.accounts;
    if (!engineUp(a)) return;
    replace(a.gpa, &p.busy_graff, provider);
    p.notice.clearRetainingCapacity();
    a.call("SignOutGraffLogin", .{ .provider = provider, .targetDeviceId = target(a) }, .of(App, a, onSignOutGraff));
}

fn onSignOutGraff(a: *App, _: u64, r: rpc.Reply) void {
    replace(a.gpa, &a.view.accounts.busy_graff, null);
    switch (r) {
        .ok => |v| {
            var ar: std.heap.ArenaAllocator = .init(a.gpa);
            if (accounts.parseGraffLogins(ar.allocator(), v)) |got| a.view.accounts.graff.take(ar, got) else |_| {
                ar.deinit();
                setNotice(a, "Sign out failed: unexpected reply");
            }
        },
        .err => |e| {
            var buf: [256]u8 = undefined;
            setNotice(a, std.fmt.bufPrint(&buf, "Sign out failed: {s}", .{why(e)}) catch "Sign out failed");
        },
        else => {},
    }
    a.redraw();
}

/// Escape closes the sign-in dialog (cancelling it), else the device list.
pub fn escape(c: *ui.Context, a: *App) void {
    const p = &a.view.accounts;
    if (!login.open(a) and !p.menu) return;
    if (!c.shortcut(.{ .key = ui.Shortcut.escape })) return;
    if (login.open(a)) login.cancel(a) else p.menu = false;
}

// Rendering.

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.accounts;
    if (!p.started) load(a, .mount);
    if (p.jobs_poll_at) |t| {
        if (c.time >= t) {
            p.jobs_poll_at = null;
            loadJobs(a);
        } else c.frameIn(@floatCast(t - c.time));
    }
    login.tick(c, a);
    const now = a.nowMs();
    header(c, a, k);
    set.subtitle(c, k, "CodeGraff usage, graff's provider sign-ins, and the Claude Code, Codex, and Cursor logins on this device. Harness keeps local agent logins backed up and can swap between them.", false);
    if (p.notice.items.len > 0) if (rows.errorStrip(c, k, p.notice.items, false)) p.notice.clearRetainingCapacity();
    if (p.key_notice) if (rows.warningStrip(c, k, key_rejected_notice)) {
        p.key_notice = false;
    };
    codegraff(c, a, k, now);
    graff.chatgpt(c, a, k);
    graff.providers(c, a, k);
    providerSections(c, a, k, now);
    {
        set.space(c, 24);
        const f = ui.div(c).column().w(set.inner_w);
        defer f.end();
        ui.text(c, "Switching rewrites the CLI\u{2019}s stored login, so new agent sessions use the selected account immediately. On macOS, an already-\u{2060}running Claude Code can hold the previous login for up to ~30 seconds (Keychain cache).", .{ .size = 12, .line_height = 19, .wrap = true, .color = k.muted.alpha(0.6) });
    }
    if (p.menu) deviceMenu(c, a, k);
    login.dialog(c, a, k);
}

/// "Accounts" and its count, Refresh, the device switcher.
fn header(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.accounts;
    const h = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer h.end();
    var count: ?usize = null;
    if (p.snapshot.get()) |s| {
        const n = s.accounts.len + @intFromBool(if (p.usage.get()) |u| u != null else false);
        if (n > 0) count = n;
    }
    set.header(c, k, "Accounts", count);
    ui.spacer(c);
    if (rows.ghost(c, k, .{ .label = "Refresh", .icon = .refresh, .size = 12.5, .dim = p.snapshot.phase == .loading })) load(a, .refresh);
    switcher(c, a, k);
}

/// The devices in a stable order: when added, then id.
fn sortedDevices(c: *ui.Context, a: *App) []@import("workspace.zig").Device {
    const list = c.alloc().dupe(@import("workspace.zig").Device, a.devices.items) catch return &.{};
    std.sort.insertion(@import("workspace.zig").Device, list, {}, struct {
        fn lt(_: void, x: @import("workspace.zig").Device, y: @import("workspace.zig").Device) bool {
            if (x.created_ms != y.created_ms) return x.created_ms < y.created_ms;
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);
    return list;
}

fn platformIcon(platform: []const u8) icons.Name {
    if (std.mem.eql(u8, platform, "macos") or std.mem.eql(u8, platform, "darwin")) return .laptop;
    if (std.mem.eql(u8, platform, "ios") or std.mem.eql(u8, platform, "android")) return .smartphone;
    return .monitor;
}

/// The device whose logins show: the one picked, else this one.
fn effective(a: *App) ?[]const u8 {
    return a.view.accounts.target orelse a.device_id;
}

/// The switcher (`render_device_switcher`): platform, name, presence dot,
/// the sort glyph; a press opens the device list.
fn switcher(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.accounts;
    const eff = effective(a);
    var selected: ?@import("workspace.zig").Device = null;
    if (eff) |id| for (a.devices.items) |d| if (std.mem.eql(u8, d.id, id)) {
        selected = d;
    };
    var t = ui.div(c).row().h(28).px(8).gap(6).itemsCenter().rounded(6);
    t = if (p.menu) t.bg(k.ink(0.06)) else t.hover(k.ink(0.04));
    defer t.end();
    p.menu_anchor = c.rects.get(c.node(t.index).id);
    icons.icon(c, platformIcon(if (selected) |d| d.platform else "macos"), 16, k.muted, 0);
    kit.ellipsisText(c, if (selected) |d| d.name else "This device", st(c, 12.5, .{ .weight = .medium, .color = k.text }), 200);
    const local = if (eff) |e| eqOpt(a.device_id, e) else a.device_id == null;
    kit.dot(c, 6, if (local) k.success else k.ink(0.2));
    icons.icon(c, .@"sort-vertical", 14, k.muted.alpha(if (p.menu) 0.9 else 0.4), 0);
    if (t.clicked()) p.menu = !p.menu;
}

/// The device list (`popover_card` 220 wide): "Devices", then each, this
/// one marked You.
fn deviceMenu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.accounts;
    const at = p.menu_anchor orelse return;
    {
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer back.end();
        if (back.clicked()) {
            p.menu = false;
            return;
        }
    }
    const w: f32 = 220;
    const x = rules.snapToWindow(at.x, w, c.size.w, 8);
    const m = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, at.y + 6).w(w).layer(5).column().p(4 + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer m.end();
    {
        const hd = ui.div(c).row().wFull().px(8).pt(6).pb(4);
        defer hd.end();
        ui.text(c, "D\u{200A}E\u{200A}V\u{200A}I\u{200A}C\u{200A}E\u{200A}S", st(c, 10, .{ .weight = .medium, .color = k.muted }));
    }
    const eff = effective(a);
    for (sortedDevices(c, a)) |d| {
        ui.key(c, c.print("accounts-device-{s}", .{d.id}));
        const active = eqOpt(eff, d.id);
        const local = eqOpt(a.device_id, d.id);
        var r = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7);
        r = if (active) r.bg(k.selected) else r.hover(k.selected);
        defer r.end();
        icons.icon(c, platformIcon(d.platform), 16, k.muted, 0);
        const you_w: f32 = if (local) 10 + c.text.width("You", .{ .size = 10.5 }) else 0;
        {
            const n = ui.div(c).row().grow().w(0);
            defer n.end();
            kit.ellipsisText(c, d.name, st(c, 13, .{ .color = if (active or r.hovered()) k.text else k.text.alpha(0.9) }), w - 10 - 16 - 10 - 10 - 6 - you_w);
        }
        if (local) ui.text(c, "You", st(c, 10.5, .{ .color = k.muted.alpha(0.35) }));
        kit.dot(c, 6, if (local) k.success else k.ink(0.2));
        // This device: no passthrough, the calls stay direct.
        if (r.clicked()) return setTarget(a, if (local) null else d.id);
    }
}

/// A card's quiet line (`px(20) py(24)`), wrapped at its width.
pub fn quietBody(c: *ui.Context, k: theme.Colors, text: []const u8, size: f32) void {
    const b = ui.div(c).column().wFull().px(20).py(24);
    defer b.end();
    const w = ui.div(c).column().w(rows.rowInner());
    defer w.end();
    ui.text(c, text, st(c, size, .{ .wrap = true, .color = k.muted }));
}

fn codegraff(c: *ui.Context, a: *App, k: theme.Colors, now: i64) void {
    const p = &a.view.accounts;
    const signed_in = if (p.usage.get()) |u| u != null else false;
    set.space(c, 24);
    {
        const h = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer h.end();
        rows.sectionHead(c, k, .@"graff-mark", null, "CodeGraff");
        ui.spacer(c);
        // Signing out of Codegraff lives here, beside what it pays for.
        if (signed_in) if (rows.ghost(c, k, .{ .label = if (p.signing_out) "Signing out…" else "Sign out", .dim = p.signing_out }) and !p.signing_out) signOutCodegraff(a);
        if (rows.ghost(c, k, .{ .label = "View usage" })) _ = nanoui.shell.openUrl("https://codegraff.com/dashboard/usage");
    }
    {
        const cd = rows.card(c, k, 8);
        defer cd.end();
        switch (p.usage.phase) {
            .idle, .loading => rows.skeleton(c, k, true, false),
            .failed => quietBody(c, k, c.print("CodeGraff usage unavailable: {s}", .{p.usage.why.items}), 12),
            .ready => if (p.usage.value) |u| usageRow(c, k, u, now) else quietBody(c, k, "Sign in with Codegraff from the account menu to see your usage.", 13),
        }
    }
    jobsCard(c, a, k);
    cloud.card(c, a, k);
}

/// The signed-in CodeGraff account: credits, 30 days' spend, the key budget.
fn usageRow(c: *ui.Context, k: theme.Colors, u: accounts.Usage, now: i64) void {
    const r = ui.div(c).row().wFull().px(20).py(14).gap(12).itemsStretch();
    defer r.end();
    {
        const av = ui.div(c).column().justifyCenter();
        defer av.end();
        rows.avatar(c, k, u.email);
    }
    const right_w = rows.badgeActiveW(c, "Active") + 6 + rows.badgeW(c, u.tier);
    const w = rows.rowInner() - 32 - 12 - 12 - right_w;
    {
        const col = ui.div(c).column().grow().w(0);
        defer col.end();
        rows.title(c, k, u.email, w);
        set.space(c, 6);
        const lines = ui.div(c).column().gap(4);
        defer lines.end();
        const style = st(c, 11.5, .{ .color = k.muted });
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        ui.text(c, "Graff CLI account on this device", style);
        ui.text(c, c.print("{s} credits available", .{accounts.formatMicroUsd(&b1, u.credits_micro_usd)}), style);
        ui.text(c, c.print("{s} spent · {d} requests in 30 days", .{ accounts.formatMicroUsd(&b2, u.spend_30d_micro_usd), u.requests_30d }), style);
        if (accounts.budgetWindow(u)) |m| rows.meter(c, k, m, w, now);
    }
    const b = ui.div(c).row().gap(6).itemsStart();
    defer b.end();
    rows.badgeActive(c, k, "Active");
    rows.badge(c, k, u.tier);
}

/// Recent PR-agent runs (`render_codegraff_jobs`): nothing while signed
/// out or with none.
fn jobsCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.accounts;
    const jobs = (p.jobs.get() orelse return) orelse return;
    if (jobs.len == 0) return;
    set.space(c, 16);
    ui.text(c, "PR agent jobs", st(c, 12, .{ .weight = .medium, .color = k.muted }));
    const cd = rows.card(c, k, 8);
    defer cd.end();
    for (jobs, 0..) |j, ix| {
        ui.key(c, c.print("codegraff-job-{d}", .{ix}));
        const sum = accounts.jobSummary(c.alloc(), j) catch continue;
        const cancelling = eqOpt(p.cancelling_job, j.id);
        const cancel: ?rows.Ghost = if (j.cancellable and accounts.jobActive(j)) .{ .label = if (cancelling) "Cancelling…" else "Cancel", .dim = cancelling } else null;
        const url: ?[]const u8 = if (j.result_url) |u| (if (std.mem.startsWith(u8, u, "https://")) u else null) else null;
        const open: rows.Ghost = .{ .label = "Open" };
        if (ix > 0) rows.line(c, k);
        const r = ui.div(c).row().wFull().px(20).py(10).gap(12).itemsCenter();
        defer r.end();
        const w = rows.rowInner() - (if (cancel) |g| 12 + rows.ghostW(c, g) else 0) - (if (url != null) 12 + rows.ghostW(c, open) else 0);
        {
            const col = ui.div(c).column().grow().w(0);
            defer col.end();
            rows.title(c, k, sum.title, w);
            set.space(c, 2);
            kit.ellipsisText(c, sum.detail, st(c, 11.5, .{ .color = k.muted }), w);
        }
        if (cancel) |g| if (rows.ghost(c, k, g) and !cancelling) cancelJob(a, j.id);
        if (url) |u| if (rows.ghost(c, k, open)) {
            _ = nanoui.shell.openUrl(u);
        };
    }
}

/// Claude Code, Codex and Cursor: ghosts while loading, the failure with
/// Click to retry, or each provider's rows.
fn providerSections(c: *ui.Context, a: *App, k: theme.Colors, now: i64) void {
    const p = &a.view.accounts;
    switch (p.snapshot.phase) {
        .idle, .loading => for (accounts.providers) |pv| rows.providerLoading(c, k, pv),
        .failed => if (rows.errorStrip(c, k, p.snapshot.why.items, true)) load(a, .retry),
        .ready => for (accounts.providers) |pv| {
            const s = p.snapshot.value;
            ui.key(c, c.print("accounts-provider-{s}", .{pv.harness.wire()}));
            if (rows.providerHead(c, k, pv, true)) login.begin(a, pv.harness, null);
            for (s.warnings) |w| if (std.mem.eql(u8, w.harness, pv.harness.wire())) {
                _ = rows.warningStrip(c, k, w.message);
            };
            const cd = rows.card(c, k, 8);
            defer cd.end();
            if (accounts.countOf(s, pv.harness) == 0) {
                var buf: [256]u8 = undefined;
                rows.emptyLine(c, k, c.print("{s}", .{accounts.emptyCopy(&buf, pv)}));
                continue;
            }
            var first = true;
            for (s.accounts) |acc| if (accounts.isOf(acc, pv.harness)) {
                ui.key(c, c.print("account-{s}", .{acc.id}));
                switch (rows.accountRow(c, k, acc, first, eqOpt(p.busy_account, acc.id), now)) {
                    .switch_to => accountAction(a, "ActivateAgentAccount", acc),
                    .forget => accountAction(a, "ForgetAgentAccount", acc),
                    .none => {},
                }
                first = false;
            };
        },
    }
}
