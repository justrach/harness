//! Settings › Agents, as the GPUI app's (settings/harnesses.rs): install
//! and switch on agents, one card row per agent, for the device the
//! header's switcher picks (`targetDeviceId` on every call, left out for
//! this one). Above the list, macOS's Screen Recording grant that agents'
//! screenshots use; below it, graff's child agents and the session-title
//! agent and model. The rules are agents.zig's; the rows are
//! view_settings_agents_rows.zig's, the switcher and the other cards
//! view_settings_agents_cards.zig's.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const shots = @import("view_settings_appshots.zig");
const rpc = @import("rpc.zig");
const workspace = @import("workspace.zig");
const agents = @import("agents.zig");
const rows = @import("view_settings_agents_rows.zig");
const cards = @import("view_settings_agents_cards.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Phase = enum { idle, loading, ready, failed };

/// A sign-in that switches its agent on once done (`SignIn`).
pub const SignIn = struct {
    harness: agents.Id,
    /// Known once the engine took the start.
    login_id: ?[]u8 = null,
    message: ?[]const u8 = null,
    phase: agents.SignInPhase = .starting,
    call: ?u64 = null,
    next_poll: ?f64 = null,
    opened: bool = false,

    fn deinit(s: *SignIn, gpa: Allocator) void {
        if (s.login_id) |l| gpa.free(l);
        if (s.message) |m| gpa.free(m);
    }
};

pub const SignInFailure = struct { harness: agents.Id, message: []u8, phase: agents.SignInPhase };

/// The page's state, kept between visits as the GPUI app keeps its page.
pub const Page = struct {
    list: ?agents.Descriptors = null,
    phase: Phase = .idle,
    failure: std.ArrayList(u8) = .empty,
    /// The last refused or failed action, in the error strip.
    err: std.ArrayList(u8) = .empty,
    install_notice: std.ArrayList(u8) = .empty,
    /// The device shown (owned); null is this one.
    target: ?[]u8 = null,
    device_menu: bool = false,
    device_anchor: ?ui.Rect = null,
    list_call: ?u64 = null,
    /// graff's child agents (`GetGraffDraftSubagents`).
    draft: Phase = .idle,
    draft_on: bool = false,
    draft_saving: bool = false,
    draft_call: ?u64 = null,
    /// graff's compaction point; null is graff's default.
    compact: Phase = .idle,
    compact_pct: ?u8 = null,
    compact_saving: bool = false,
    compact_call: ?u64 = null,
    /// The session-title agent and model (`TitleSettings`).
    titles: Phase = .idle,
    title_harness: ?agents.Id = null,
    title_model: ?[]const u8 = null,
    titles_failure: std.ArrayList(u8) = .empty,
    title_saving: bool = false,
    /// Which list is open: false the agents, true the models.
    title_menu: ?bool = null,
    titles_call: ?u64 = null,
    models: Phase = .idle,
    title_models: ?workspace.Models = null,
    models_failure: std.ArrayList(u8) = .empty,
    models_call: ?u64 = null,
    installing: ?agents.Id = null,
    installing_beta: bool = false,
    install_call: ?u64 = null,
    sign_in: ?SignIn = null,
    sign_in_failure: ?SignInFailure = null,
    /// Screen Recording's Allow was used: System Settings and the restart
    /// instead (macOS asks once).
    screen_requested: bool = false,

    pub fn deinit(p: *Page, gpa: Allocator) void {
        if (p.list) |*l| l.deinit();
        if (p.title_models) |*m| m.deinit();
        for ([_]*std.ArrayList(u8){ &p.failure, &p.err, &p.install_notice, &p.titles_failure, &p.models_failure }) |l| l.deinit(gpa);
        if (p.target) |t| gpa.free(t);
        if (p.title_model) |m| gpa.free(m);
        if (p.sign_in) |*s| s.deinit(gpa);
        if (p.sign_in_failure) |f| gpa.free(f.message);
    }

    pub fn descriptors(p: *const Page) []const agents.Descriptor {
        return if (p.list) |l| l.items else &.{};
    }
};

pub fn setText(gpa: Allocator, l: *std.ArrayList(u8), text: []const u8) void {
    l.clearRetainingCapacity();
    l.appendSlice(gpa, text) catch {};
}

fn friendly(e: []const u8) []const u8 {
    return if (std.mem.eql(u8, e, "not connected")) "Engine not connected" else e;
}

/// A reply still wanted: the call in `slot`, or one that failed before it
/// was sent (id 0). A device change forgets the calls before it.
fn current(slot: *?u64, id: u64) bool {
    if (id == 0) return true;
    if (slot.* != id) return false;
    slot.* = null;
    return true;
}

/// An engine to ask: connected, with a socket (the GPUI app's `engine()`;
/// the parity renderer is "connected" with none).
fn live(a: *const App) bool {
    return a.engine.up();
}

/// Sends `method`, remembering its id in `slot`.
fn send(a: *App, slot: *?u64, method: []const u8, params: anytype, h: rpc.Handler) void {
    slot.* = null;
    if (a.engine.call(method, params, h)) |id| slot.* = id;
}

/// `ListHarnesses` and the settings below it, against the shown device.
/// No engine: the page waits, as the GPUI app's does.
pub fn load(a: *App) void {
    const p = &a.view.agents;
    if (!live(a)) return;
    loadTitles(a, null);
    loadDraft(a, null);
    loadCompact(a, .read);
    p.phase = .loading;
    send(a, &p.list_call, "ListHarnesses", .{ .targetDeviceId = p.target }, .of(App, a, onList));
}

fn onList(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    if (!current(&p.list_call, id)) return;
    switch (r) {
        .ok => |v| setList(a, v),
        .err => |e| {
            p.phase = .failed;
            setText(a.gpa, &p.failure, friendly(e));
        },
        else => {},
    }
    a.redraw();
}

/// Show a catalog as if the engine sent it (tests and fixtures).
pub fn setList(a: *App, v: json.Value) void {
    const p = &a.view.agents;
    if (p.list == null) p.list = .init(a.gpa);
    p.list.?.replace(v) catch {
        p.phase = .failed;
        return setText(a.gpa, &p.failure, "Unexpected reply");
    };
    p.phase = .ready;
}

/// The composer's catalog follows this device's changes
/// (`bump_harness_catalog`).
fn bump(a: *App, v: ?json.Value) void {
    if (a.view.agents.target != null) return;
    if (v) |list| return a.harnesses.replace(list) catch {};
    _ = a.engine.call("ListHarnesses", .{}, .of(App, a, onAppHarnesses));
}

fn onAppHarnesses(a: *App, _: u64, r: rpc.Reply) void {
    if (r == .ok) a.harnesses.replace(r.ok) catch {};
    a.redraw();
}

/// Flip one agent; the reply is the device's fresh catalog.
pub fn setEnabled(a: *App, id: agents.Id, on: bool) void {
    const p = &a.view.agents;
    p.err.clearRetainingCapacity();
    _ = a.engine.call("SetHarnessEnabled", .{ .harness = id.wire(), .enabled = on, .targetDeviceId = p.target }, .of(App, a, onEnabled));
}

fn onEnabled(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| {
            setList(a, v);
            bump(a, v);
        },
        .err => |e| setText(a.gpa, &a.view.agents.err, friendly(e)),
        else => {},
    }
    a.redraw();
}

pub fn install(a: *App, id: agents.Id, beta: bool) void {
    const p = &a.view.agents;
    if (p.installing != null) return;
    p.installing = id;
    p.installing_beta = beta;
    p.err.clearRetainingCapacity();
    p.install_notice.clearRetainingCapacity();
    send(a, &p.install_call, "InstallHarness", .{ .harness = id.wire(), .targetDeviceId = p.target, .beta = beta }, .of(App, a, onInstall));
}

fn onInstall(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    if (!current(&p.install_call, id) or p.installing == null) return;
    const which = p.installing.?;
    const beta = p.installing_beta;
    p.installing = null;
    p.installing_beta = false;
    switch (r) {
        .ok => |v| {
            setList(a, v);
            if (which == .graff) setText(a.gpa, &p.install_notice, agents.graffInstallNotice(beta));
            bump(a, v);
        },
        .err => |e| {
            p.err.clearRetainingCapacity();
            p.err.print(a.gpa, "Installation failed — {s}", .{friendly(e)}) catch {};
        },
        else => {},
    }
    a.redraw();
}

pub fn cancelInstall(a: *App) void {
    const p = &a.view.agents;
    const id = p.installing orelse return;
    _ = a.engine.call("CancelInstall", .{ .harness = id.wire(), .targetDeviceId = p.target, .beta = false }, .of(App, a, onCancelInstall));
}

fn onCancelInstall(a: *App, _: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    if (r != .err or p.installing == null) return;
    p.err.clearRetainingCapacity();
    p.err.print(a.gpa, "Cancellation failed — {s}", .{friendly(r.err)}) catch {};
    a.redraw();
}

/// StartAgentLogin, then PollAgentLogin each second until the engine says
/// how it went, opening the sign-in page the first time a poll names it.
pub fn startSignIn(a: *App, id: agents.Id) void {
    const p = &a.view.agents;
    if (p.target != null) {
        // The redirect lands on a loopback port of the agent's device.
        return setText(a.gpa, &p.err, "Sign in to this agent from its own device.");
    }
    p.err.clearRetainingCapacity();
    clearFailure(a);
    if (p.sign_in) |*s| s.deinit(a.gpa);
    p.sign_in = .{ .harness = id };
    send(a, &p.sign_in.?.call, "StartAgentLogin", .{ .harness = id.wire() }, .of(App, a, onSignInStart));
}

fn clearFailure(a: *App) void {
    const p = &a.view.agents;
    if (p.sign_in_failure) |f| a.gpa.free(f.message);
    p.sign_in_failure = null;
}

fn failSignIn(a: *App, message: []const u8) void {
    const p = &a.view.agents;
    var s = p.sign_in orelse return;
    p.sign_in = null;
    defer s.deinit(a.gpa);
    clearFailure(a);
    const owned = a.gpa.dupe(u8, message) catch return;
    p.sign_in_failure = .{ .harness = s.harness, .message = owned, .phase = s.phase };
}

fn onSignInStart(a: *App, id: u64, r: rpc.Reply) void {
    const s = if (a.view.agents.sign_in) |*x| x else return;
    if (!current(&s.call, id)) return;
    switch (r) {
        .ok => |v| {
            const login = if (v == .object) v.object.get("loginId") else null;
            if (login == null or login.? != .string) return failSignIn(a, "Sign-in failed to start: Unexpected reply");
            s.login_id = a.gpa.dupe(u8, login.?.string) catch null;
            s.phase = .starting;
            s.next_poll = a.now + 1;
        },
        .err => |e| {
            var buf: [256]u8 = undefined;
            failSignIn(a, std.fmt.bufPrint(&buf, "Sign-in failed to start: {s}", .{friendly(e)}) catch "Sign-in failed to start");
        },
        else => {},
    }
    a.redraw();
}

fn poll(a: *App) void {
    const s = if (a.view.agents.sign_in) |*x| x else return;
    s.next_poll = null;
    const login = s.login_id orelse return;
    send(a, &s.call, "PollAgentLogin", .{ .loginId = login }, .of(App, a, onPoll));
}

fn onPoll(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    const s = if (p.sign_in) |*x| x else return;
    if (!current(&s.call, id)) return;
    defer a.redraw();
    const v = switch (r) {
        .ok => |v| v,
        .err => |e| return failSignIn(a, friendly(e)),
        else => return,
    };
    if (v != .object) return failSignIn(a, "Unexpected reply");
    const o = v.object;
    const status = workspace.str(a.gpa, o, "status") orelse return failSignIn(a, "Unexpected reply");
    defer a.gpa.free(status);
    const message = workspace.str(a.gpa, o, "message");
    if (std.mem.eql(u8, status, "pending")) {
        if (o.get("url")) |u| if (u == .string) {
            if (!s.opened) {
                s.opened = true;
                _ = nanoui.shell.openUrl(u.string);
            }
            s.phase = .authenticating;
        };
        if (s.message) |m| a.gpa.free(m);
        s.message = message;
        s.next_poll = a.now + 1;
    } else if (std.mem.eql(u8, status, "done")) {
        if (message) |m| a.gpa.free(m);
        clearFailure(a);
        s.deinit(a.gpa);
        p.sign_in = null;
        bump(a, null);
    } else {
        defer if (message) |m| a.gpa.free(m);
        failSignIn(a, message orelse "Unknown error");
    }
}

pub fn cancelSignIn(a: *App) void {
    const p = &a.view.agents;
    var s = p.sign_in orelse return;
    p.sign_in = null;
    defer s.deinit(a.gpa);
    if (s.login_id) |login| _ = a.engine.call("CancelAgentLogin", .{ .loginId = login }, .of(App, a, onIgnored));
    a.redraw();
}

fn onIgnored(_: *App, _: u64, _: rpc.Reply) void {}

/// `save` writes it; null only reads.
pub fn loadDraft(a: *App, save: ?bool) void {
    const p = &a.view.agents;
    if (save == null and !live(a)) return;
    p.draft_saving = save != null;
    if (save) |on| {
        send(a, &p.draft_call, "SetGraffDraftSubagents", .{ .enabled = on, .targetDeviceId = p.target }, .of(App, a, onDraft));
    } else {
        p.draft = .loading;
        send(a, &p.draft_call, "GetGraffDraftSubagents", .{ .targetDeviceId = p.target }, .of(App, a, onDraft));
    }
}

fn onDraft(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    if (!current(&p.draft_call, id)) return;
    const saving = p.draft_saving;
    p.draft_saving = false;
    switch (r) {
        .ok => |v| if (v == .bool) {
            p.draft = .ready;
            p.draft_on = v.bool;
            p.err.clearRetainingCapacity();
        } else problem(a, saving, &p.draft, "Unexpected reply"),
        .err => |e| problem(a, saving, &p.draft, friendly(e)),
        else => {},
    }
    a.redraw();
}

/// A failed write goes to the error strip; a failed read leaves its part
/// unready.
fn problem(a: *App, saving: bool, phase: *Phase, why: []const u8) void {
    if (saving) setText(a.gpa, &a.view.agents.err, why) else phase.* = .failed;
}

pub const CompactLoad = union(enum) { read, save: ?u8 };

/// `.save` writes a point (null restores graff's default); `.read` reads.
pub fn loadCompact(a: *App, what: CompactLoad) void {
    const p = &a.view.agents;
    if (what == .read and !live(a)) return;
    p.compact_saving = what == .save;
    switch (what) {
        .save => |pct| send(a, &p.compact_call, "SetGraffCompactAt", .{ .pct = pct, .targetDeviceId = p.target }, .of(App, a, onCompact)),
        .read => {
            p.compact = .loading;
            send(a, &p.compact_call, "GetGraffCompactAt", .{ .targetDeviceId = p.target }, .of(App, a, onCompact));
        },
    }
}

fn onCompact(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    if (!current(&p.compact_call, id)) return;
    const saving = p.compact_saving;
    p.compact_saving = false;
    switch (r) {
        .ok => |v| switch (v) {
            .null => setCompact(a, null),
            .integer => |n| setCompact(a, std.math.cast(u8, n)),
            else => problem(a, saving, &p.compact, "Unexpected reply"),
        },
        .err => |e| problem(a, saving, &p.compact, friendly(e)),
        else => {},
    }
    a.redraw();
}

/// Show graff's point as if the engine said it (tests and fixtures).
pub fn setCompact(a: *App, pct: ?u8) void {
    const p = &a.view.agents;
    p.compact = .ready;
    p.compact_pct = pct;
    p.err.clearRetainingCapacity();
}

pub const TitleChoice = struct { harness: ?agents.Id, model: ?[]const u8 };

pub fn loadTitles(a: *App, save: ?TitleChoice) void {
    const p = &a.view.agents;
    if (save == null and !live(a)) return;
    p.title_menu = null;
    p.title_saving = save != null;
    if (save) |s| {
        send(a, &p.titles_call, "SetTitleSettings", .{ .harness = if (s.harness) |h| h.wire() else null, .model = s.model, .targetDeviceId = p.target }, .of(App, a, onTitles));
    } else send(a, &p.titles_call, "GetTitleSettings", .{ .targetDeviceId = p.target }, .of(App, a, onTitles));
}

fn onTitles(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    if (!current(&p.titles_call, id)) return;
    const saving = p.title_saving;
    p.title_saving = false;
    defer a.redraw();
    const v = switch (r) {
        .ok => |v| v,
        .err => |e| return if (saving) setText(a.gpa, &p.err, friendly(e)) else {
            p.titles = .failed;
            setText(a.gpa, &p.titles_failure, friendly(e));
        },
        else => return,
    };
    setTitles(a, v);
    p.err.clearRetainingCapacity();
    if (p.title_harness) |h| {
        p.models = .loading;
        send(a, &p.models_call, "ListModels", .{ .harness = h.wire(), .targetDeviceId = p.target }, .of(App, a, onModels));
    } else p.models = .idle;
}

/// Show title settings as if the engine sent them (tests and fixtures).
pub fn setTitles(a: *App, v: json.Value) void {
    const p = &a.view.agents;
    const o = if (v == .object) v.object else json.ObjectMap.empty;
    // An agent from a newer build reads as automatic.
    p.title_harness = if (o.get("harness")) |h| (if (h == .string) agents.Id.parse(h.string) else null) else null;
    if (p.title_model) |m| a.gpa.free(m);
    p.title_model = workspace.str(a.gpa, o, "model");
    p.titles = .ready;
}

fn onModels(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.view.agents;
    if (!current(&p.models_call, id)) return;
    switch (r) {
        .ok => |v| {
            if (p.title_models == null) p.title_models = .init(a.gpa);
            if (p.title_models.?.replace(v)) {
                p.models = .ready;
            } else |_| {
                p.models = .failed;
                setText(a.gpa, &p.models_failure, "Unexpected reply");
            }
        },
        .err => |e| {
            p.models = .failed;
            setText(a.gpa, &p.models_failure, friendly(e));
        },
        else => {},
    }
    a.redraw();
}

/// Another device: another set of installs and switches, so everything
/// is read again through it.
pub fn setTarget(a: *App, target: ?[]const u8) void {
    const p = &a.view.agents;
    p.device_menu = false;
    const same = if (p.target) |t| (if (target) |x| std.mem.eql(u8, t, x) else false) else target == null;
    if (same) return a.redraw();
    cancelSignIn(a);
    clearFailure(a);
    inline for (.{ "list_call", "draft_call", "compact_call", "titles_call", "models_call", "install_call" }) |f| @field(p, f) = null;
    p.draft = .idle;
    p.draft_saving = false;
    p.compact = .idle;
    p.compact_saving = false;
    p.titles = .idle;
    p.models = .idle;
    p.title_menu = null;
    p.title_saving = false;
    p.installing = null;
    p.installing_beta = false;
    p.install_notice.clearRetainingCapacity();
    p.err.clearRetainingCapacity();
    if (p.target) |t| a.gpa.free(t);
    p.target = if (target) |t| a.gpa.dupe(u8, t) catch null else null;
    p.phase = .idle;
    load(a);
    a.redraw();
}

// Rendering.

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.agents;
    if (p.phase == .idle and live(a)) load(a);
    if (p.sign_in) |s| if (s.next_poll) |t| {
        if (c.time >= t) poll(a) else c.frameIn(@floatCast(t - c.time));
    };
    {
        const h = ui.div(c).row().wFull().h(28).itemsCenter();
        defer h.end();
        set.header(c, k, "Agents", null);
        ui.spacer(c);
        cards.switcher(c, a, k);
    }
    set.subtitle(c, k, "This GUI drives whatever agent is installed on the selected device. A custom build can point at its binary with that agent's *_EXECUTABLE variable. Downloads start only when you choose Install.", true);
    if (p.err.items.len > 0) _ = errorStrip(c, k, p.err.items, set.inner_w);
    if (p.install_notice.items.len > 0) set.subtitle(c, k, p.install_notice.items, false);
    // Above the list: a missing grant breaks every agent's screenshots.
    cards.screenAccess(c, a, k);
    switch (p.phase) {
        .idle, .loading => {
            const cd = set.card(c, k);
            defer cd.end();
            const in = ui.div(c).column().wFull().p(16);
            defer in.end();
            skeleton(c, k, 4);
        },
        .failed => {
            _ = errorStrip(c, k, p.failure.items, set.inner_w);
            set.space(c, 8);
            const r = ui.div(c).row();
            defer r.end();
            if (shots.action(c, k, "Retry")) load(a);
        },
        .ready => {
            const cd = set.card(c, k);
            defer cd.end();
            rows.list(c, a, k);
        },
    }
    cards.draftCard(c, a, k);
    cards.titlesCard(c, a, k);
    if (p.device_menu) if (p.device_anchor) |at| cards.deviceMenu(c, a, k, at);
}

/// `section_card` `mt` below what's above.
pub fn card(c: *ui.Context, k: theme.Colors, mt: f32) ui.Div {
    set.space(c, mt);
    return ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
}

/// The inside of a card padded 16 (`section_card().p(16)`).
pub fn cardInner() f32 {
    return set.inner_w - 2 - 2 * 16;
}

/// `error_strip`: red-tinted, a warning triangle, the words wrapped in
/// `w`. True when clicked.
pub fn errorStrip(c: *ui.Context, k: theme.Colors, message: []const u8, w: f32) bool {
    set.space(c, 16);
    const s = ui.div(c).row().w(w).px(17).py(13).gap(8).rounded(12).border(k.danger.alpha(0.2)).borderW(1).bg(k.danger.alpha(0.06));
    defer s.end();
    {
        const ic = ui.div(c).column().pt(2);
        defer ic.end();
        icons.icon(c, .@"danger-triangle", 16, k.danger_muted.alpha(0.9), 0);
    }
    const t = ui.div(c).column().w(@max(w - 2 * 17 - 16 - 8, 80));
    {
        defer t.end();
        ui.text(c, message, set.st(c, 12.5, .{ .wrap = true, .color = k.danger_muted.alpha(0.9) }));
    }
    return s.clicked();
}

/// `skeleton_rows`: bars whose washes breathe one after another.
fn skeleton(c: *ui.Context, k: theme.Colors, count: usize) void {
    const delta: f32 = @floatCast(@mod(c.time / 2.4, 1.0));
    c.frameIn(1.0 / 30.0);
    const col = ui.div(c).column().wFull().gap(6).py(4);
    defer col.end();
    for (0..count) |i| {
        const phase = @mod(delta - @as(f32, @floatFromInt(i)) * 0.08, 1.0);
        const wave = 0.5 - 0.5 * @cos(phase * std.math.tau);
        const bar = ui.div(c).row().wFull().h(28).rounded(6).bg(k.ink(0.04)).opacity(0.35 + 0.4 * wave);
        bar.end();
    }
}

/// The bare `toggle_switch`, dimmed to 0.35 when it can't be used. True
/// when clicked and usable.
pub fn toggle(c: *ui.Context, k: theme.Colors, on: bool, usable: bool) bool {
    var box = ui.div(c).row();
    if (!usable) box = box.opacity(0.35);
    defer box.end();
    const track = ui.div(c).row().w(32).h(18).roundedFull().bg(if (on) k.text else k.ink(0.15)).pl(if (on) 16 else 2).itemsCenter();
    defer track.end();
    _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (on) k.on_solid else k.ink(0.7) }, .none, null);
    return usable and track.clicked();
}

/// `row_title`, cut with an ellipsis at `w`.
pub fn title(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    kit.ellipsisText(c, text, set.st(c, 13, .{ .weight = .medium, .color = k.text }), @max(w, 40));
}

/// `page_subtitle` in a box `w` wide.
pub fn subtitleIn(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    set.space(c, 4);
    const s = ui.div(c).column().w(w);
    defer s.end();
    ui.text(c, text, set.st(c, 13, .{ .wrap = true, .color = k.muted }));
}

/// `badge`: a hairline pill (its edge inside its size, as GPUI's).
pub fn badge(c: *ui.Context, k: theme.Colors, label: []const u8) ui.Div {
    const b = ui.div(c).row().px(9).py(3).roundedFull().border(k.border).borderW(1);
    ui.text(c, label, set.st(c, 10.5, .{ .color = k.muted }));
    return b;
}

pub fn badgeW(c: *ui.Context, label: []const u8) f32 {
    return 2 * 9 + c.text.width(label, .{ .size = 10.5 });
}

pub fn actionW(c: *ui.Context, label: []const u8) f32 {
    return 2 * 10 + c.text.width(label, .{ .size = 12 });
}
