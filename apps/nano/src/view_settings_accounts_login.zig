//! Settings › Accounts' sign-in dialog, as the GPUI app's
//! (`render_login_dialog`, `begin_login`, `submit_code`, `spawn_poll`,
//! `cancel_login` in settings/accounts.rs): `StartAgentLogin` opens the
//! browser, then either a code is pasted back (`CompleteAgentLogin`) or the
//! dialog asks every 1.5 seconds until the browser flow lands
//! (`PollAgentLogin`). Cancel tells the engine (`CancelAgentLogin`). A
//! relayed ChatGPT sign-in for another computer is caught on this one's
//! loopback (relay_callback.zig, `spawn_relay_capture`) and sent on; the
//! paste field stays as the way back when the port is busy.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const accounts = @import("accounts.zig");
const page_mod = @import("view_settings_accounts.zig");
const relay_cb = @import("relay_callback.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const st = @import("view_settings_accounts_rows.zig").st;
const phi: f32 = 1.618;

/// How often a browser sign-in is asked after.
const poll_s: f64 = 1.5;
/// How long Copy says "Copied".
const copied_s: f64 = 1.5;
/// The dialog card's inside: 360 less 20 a side and its edge.
const inner: f32 = 360 - 2 * 21;

pub const Stage = enum {
    /// `StartAgentLogin` in flight.
    starting,
    /// Open the page, paste the code (or the address it lands on) back.
    paste,
    /// Open the page, wait for the browser.
    browser,
};

pub const Flow = struct {
    stage: Stage = .starting,
    harness: accounts.Harness,
    /// graff's sign-ins say which provider (owned).
    provider: ?[]u8 = null,
    reauthenticate: bool = false,
    /// The start reply, in its own arena.
    arena: ?std.heap.ArenaAllocator = null,
    start: ?accounts.Start = null,
    submitting: bool = false,
    err: ?[]u8 = null,
    message: ?[]u8 = null,
    call: ?u64 = null,
    poll_at: ?f64 = null,

    fn deinit(f: *Flow, gpa: Allocator) void {
        if (f.arena) |*ar| ar.deinit();
        inline for (.{ "provider", "err", "message" }) |n| if (@field(f, n)) |x| gpa.free(x);
    }

    fn chatgpt(f: *const Flow) bool {
        return if (f.provider) |p| std.mem.eql(u8, p, "chatgpt-new") else false;
    }
};

pub const State = struct {
    flow: ?Flow = null,
    code: ui.TextBuffer = .{},
    focus_code: bool = false,
    copied_until: ?f64 = null,
    /// Listening on this computer's loopback during a relayed sign-in.
    relay: ?*relay_cb.Capture = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.flow) |*f| f.deinit(gpa);
        if (s.relay) |r| r.cancel();
    }
};

fn state(a: *App) *State {
    return &a.view.accounts.login;
}

pub fn open(a: *const App) bool {
    return a.view.accounts.login.flow != null;
}

fn flowPtr(a: *App) ?*Flow {
    return if (state(a).flow) |*f| f else null;
}

fn drop(a: *App) void {
    const s = state(a);
    if (s.flow) |*f| f.deinit(a.gpa);
    s.flow = null;
    stopRelay(a);
}

fn stopRelay(a: *App) void {
    const s = state(a);
    if (s.relay) |r| r.cancel();
    s.relay = null;
}

/// How a landing reaches the UI thread (`nanoui.App.after`); tests hold
/// it and run it themselves.
pub var hop: *const fn (ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void = afterNow;

fn afterNow(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
    nanoui.App.after(0, ctx, func);
}

/// `spawn_relay_capture`: catch the browser's loopback redirect for a
/// relayed sign-in and send it on. A busy port leaves the paste field as
/// the way to finish.
pub fn spawnRelay(a: *App, url: []const u8) void {
    var buf: [2048]u8 = undefined;
    const t = relay_cb.callbackTarget(&buf, url) orelse return;
    state(a).relay = relay_cb.start(a.gpa, a.io, t.port, t.path, .{ .ctx = a, .func = landed }) orelse {
        std.log.info("harness-nano: loopback port {d} busy; relayed sign-in falls back to pasting", .{t.port});
        return;
    };
}

/// On the listener's thread: on to the UI thread.
fn landed(_: ?*anyopaque, cap: *relay_cb.Capture) void {
    hop(cap, delivered);
}

fn delivered(ctx: ?*anyopaque) callconv(.c) void {
    const cap: *relay_cb.Capture = @ptrCast(@alignCast(ctx.?));
    const a: *App = @ptrCast(@alignCast(cap.landed.ctx.?));
    defer cap.release();
    if (cap.isCancelled() or state(a).relay != cap) return;
    const f = flowPtr(a) orelse return;
    if (f.stage != .paste) return;
    state(a).code.set(cap.address);
    submit(a);
    a.redraw();
}

/// Whether the page shows another computer's logins.
fn targetIsRemote(a: *App) bool {
    const t = a.view.accounts.target orelse return false;
    return if (a.device_id) |d| !std.mem.eql(u8, d, t) else true;
}

/// Add account, or a graff provider's sign-in (`begin_login`).
pub fn begin(a: *App, harness: accounts.Harness, provider: ?[]const u8) void {
    if (page_mod.scene_accounts) |text| if (sceneStart(a, harness, provider, text)) return;
    if (!page_mod.engineUp(a)) {
        page_mod.setNotice(a, "Engine not connected");
        return a.redraw();
    }
    drop(a);
    const s = state(a);
    s.flow = .{ .harness = harness, .provider = if (provider) |p| a.gpa.dupe(u8, p) catch null else null };
    a.view.accounts.notice.clearRetainingCapacity();
    // ChatGPT's sign-in lands on the execution device's loopback, which a
    // browser here can't reach: relayed, its address is pasted back.
    const relay = harness == .graff and s.flow.?.chatgpt() and targetIsRemote(a);
    const params = .{
        .harness = harness.wire(),
        .relayBrowser = if (relay) @as(?bool, true) else null,
        .provider = provider,
        .targetDeviceId = page_mod.target(a),
    };
    const id = a.engine.call("StartAgentLogin", params, .of(App, a, onStart));
    if (state(a).flow) |*f| if (f.stage == .starting) {
        f.call = id;
    };
    a.redraw();
}

/// A scene's `loginStart` (the GPUI renderer's too): the dialog as the
/// engine's reply would open it, no call made and no browser opened.
fn sceneStart(a: *App, harness: accounts.Harness, provider: ?[]const u8, text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, a.gpa, text, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const start = parsed.value.object.get("loginStart") orelse return false;
    drop(a);
    state(a).flow = .{ .harness = harness, .provider = if (provider) |p| a.gpa.dupe(u8, p) catch null else null };
    onStart(a, 0, .{ .ok = start });
    return true;
}

fn fresh(f: *Flow, id: u64) bool {
    if (id != 0 and f.call != id) return false;
    f.call = null;
    return true;
}

fn onStart(a: *App, id: u64, r: rpc.Reply) void {
    const f = flowPtr(a) orelse return;
    if (f.stage != .starting or !fresh(f, id)) return;
    switch (r) {
        .ok => |v| {
            var ar: std.heap.ArenaAllocator = .init(a.gpa);
            const start = accounts.parseStart(ar.allocator(), v) catch {
                ar.deinit();
                return failStart(a, "unexpected reply");
            };
            f.arena = ar;
            f.start = start;
            if (start.mode != .host_browser and start.url.len > 0 and page_mod.scene_accounts == null) _ = nanoui.shell.openUrl(start.url);
            switch (start.mode) {
                .paste_code, .relay_browser => {
                    f.stage = .paste;
                    state(a).code.clear();
                    state(a).focus_code = true;
                    if (start.mode == .relay_browser and page_mod.scene_accounts == null) spawnRelay(a, start.url);
                },
                .browser, .host_browser, .device_code => {
                    f.stage = .browser;
                    f.poll_at = a.now + poll_s;
                },
            }
        },
        .err => |e| failStart(a, page_mod.why(e)),
        else => {},
    }
    a.redraw();
}

fn failStart(a: *App, e: []const u8) void {
    drop(a);
    var buf: [256]u8 = undefined;
    page_mod.setNotice(a, std.fmt.bufPrint(&buf, "Login failed to start: {s}", .{e}) catch "Login failed to start");
}

/// Add account / Finish sign-in (`submit_code`).
pub fn submit(a: *App) void {
    const s = state(a);
    const f = flowPtr(a) orelse return;
    if (f.stage != .paste or f.submitting) return;
    const code = std.mem.trim(u8, s.code.text(), " \t\n");
    if (code.len == 0 or !page_mod.engineUp(a)) return;
    f.submitting = true;
    const id = a.engine.call("CompleteAgentLogin", .{ .loginId = f.start.?.login_id, .code = code, .targetDeviceId = page_mod.target(a) }, .of(App, a, onComplete));
    if (state(a).flow) |*g| if (g.submitting) {
        g.call = id;
    };
}

fn onComplete(a: *App, id: u64, r: rpc.Reply) void {
    const f = flowPtr(a) orelse return;
    if (f.stage != .paste or !fresh(f, id)) return;
    switch (r) {
        .ok => {
            drop(a);
            page_mod.load(a, .post_login);
        },
        .err => |e| {
            f.submitting = false;
            page_mod.replace(a.gpa, &f.err, page_mod.why(e));
        },
        else => {},
    }
    a.redraw();
}

/// From the page's frame: ask after a browser sign-in when it's time.
pub fn tick(c: *ui.Context, a: *App) void {
    const s = state(a);
    if (s.copied_until) |t| {
        if (c.time >= t) s.copied_until = null else c.frameIn(@floatCast(t - c.time));
    }
    const f = flowPtr(a) orelse return;
    const at = f.poll_at orelse return;
    if (c.time < at) return c.frameIn(@floatCast(at - c.time));
    f.poll_at = null;
    if (!page_mod.engineUp(a)) return;
    const id = a.engine.call("PollAgentLogin", .{ .loginId = f.start.?.login_id, .targetDeviceId = page_mod.target(a) }, .of(App, a, onPoll));
    if (state(a).flow) |*g| if (g.stage == .browser and g.err == null) {
        g.call = id;
    };
}

fn onPoll(a: *App, id: u64, r: rpc.Reply) void {
    const f = flowPtr(a) orelse return;
    if (f.stage != .browser or !fresh(f, id)) return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const poll: ?accounts.Poll = switch (r) {
        .ok => |v| accounts.parsePoll(arena.allocator(), v) catch null,
        else => null,
    };
    const p = poll orelse {
        var buf: [256]u8 = undefined;
        const text = switch (r) {
            .err => |e| std.fmt.bufPrint(&buf, "Poll failed: {s}", .{page_mod.why(e)}) catch "Poll failed",
            else => "Poll failed: malformed reply",
        };
        page_mod.replace(a.gpa, &f.err, text);
        return a.redraw();
    };
    switch (p.status) {
        .done => {
            // graff's first ChatGPT sign-in here carries the plan confirmation.
            if (f.chatgpt()) if (p.message) |m| page_mod.replace(a.gpa, &a.view.accounts.confirmation, m);
            drop(a);
            page_mod.load(a, .post_login);
        },
        .@"error" => {
            page_mod.replace(a.gpa, &f.err, p.message orelse "Login failed");
            // A sign-in without plan usage still landed: its row says so.
            if (f.chatgpt()) page_mod.loadGraff(a);
        },
        .pending => {
            if (p.message) |m| page_mod.replace(a.gpa, &f.message, m);
            f.poll_at = a.now + poll_s;
        },
    }
    a.redraw();
}

/// Cancel / Close / Escape: the dialog goes, and the engine is told.
pub fn cancel(a: *App) void {
    const f = flowPtr(a) orelse return;
    if (f.start) |start| if (page_mod.engineUp(a)) {
        a.call("CancelAgentLogin", .{ .loginId = start.login_id, .targetDeviceId = page_mod.target(a) }, .of(App, a, ignore));
    };
    drop(a);
    a.redraw();
}

/// Best effort (`CancelAgentLogin failed`, debug only).
fn ignore(_: *App, _: u64, _: rpc.Reply) void {}

// The dialog.

fn body(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const b = ui.div(c).column().w(inner);
    defer b.end();
    ui.text(c, text, .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
}

fn redLine(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const b = ui.div(c).column().w(inner);
    defer b.end();
    ui.text(c, text, st(c, 12, .{ .wrap = true, .color = k.danger_muted.alpha(0.9) }));
}

/// `btn_ghost`: quiet words, a wash under the pointer.
fn ghostButton(c: *ui.Context, k: theme.Colors, label: []const u8, py: f32) bool {
    const b = ui.div(c).row().px(12).py(py).rounded(8).hover(k.ink(0.06));
    defer b.end();
    ui.text(c, label, st(c, 13, .{ .color = if (b.hovered()) k.text else k.muted }));
    return b.clicked();
}

fn primaryButton(c: *ui.Context, k: theme.Colors, label: []const u8, dim: bool) bool {
    var b = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
    if (dim) b = b.opacity(0.5);
    defer b.end();
    ui.text(c, label, st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
    return b.clicked();
}

/// "Reopen the …": a quiet link that opens the page again.
fn urlLink(c: *ui.Context, k: theme.Colors, label: []const u8, url: []const u8) void {
    set.space(c, 6);
    const l = ui.div(c).row();
    defer l.end();
    kit.ellipsisText(c, label, st(c, 12, .{ .color = if (l.hovered()) k.text else k.muted }), inner);
    if (l.clicked()) _ = nanoui.shell.openUrl(url);
}

/// The link itself with Copy, for a browser other than the one that opened.
fn urlField(c: *ui.Context, a: *App, k: theme.Colors, url: []const u8) void {
    const s = state(a);
    set.space(c, 12);
    ui.text(c, "Or copy this link into any browser", st(c, 12, .{ .color = k.muted }));
    set.space(c, 6);
    const label: []const u8 = if (s.copied_until != null) "Copied" else "Copy";
    const r = ui.div(c).row().w(inner).pl(11).pr(5).py(5).gap(8).itemsCenter().rounded(8).border(k.border).borderW(1).bg(k.ink(0.03));
    defer r.end();
    const copy_w = 24 + @ceil(c.text.width(label, .{ .size = 13 }));
    {
        // `flex_1().truncate()`: the rest of the row, whatever Copy takes.
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.ellipsisText(c, url, st(c, 12, .{ .mono = true, .color = k.text }), inner - 2 - 10 - 4 - 8 - copy_w);
    }
    if (ghostButton(c, k, label, 3)) {
        c.clipboard.write(c.clipboard.ctx, url);
        s.copied_until = c.time + copied_s;
    }
}

/// The dialog over the page, while a sign-in is under way.
pub fn dialog(c: *ui.Context, a: *App, k: theme.Colors) void {
    const f = flowPtr(a) orelse return;
    ui.key(c, "accounts-login-scrim");
    const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(6).bg(.{ .a = if (k.dark) 0.35 else 0.32 }).center();
    defer back.end();
    const card = kit.shadowLg(ui.div(c).w(360).p(21).column().rounded(16).bg(k.composer)
        .border(if (k.dark) ui.Color{ .r = 1, .g = 1, .b = 1, .a = 0.10 } else ui.Color{ .a = 0.135 }).borderW(1));
    defer card.end();
    var tb: [64]u8 = undefined;
    ui.text(c, c.print("{s}", .{accounts.loginTitle(&tb, f.harness, f.provider, f.reauthenticate)}), .{ .size = 15, .line_height = kit.measured(15 * phi), .weight = .semibold, .color = k.text });
    if (a.view.accounts.target) |t| body(c, k, c.print("Signing in on {s}", .{deviceName(a, t)}));
    switch (f.stage) {
        .starting => {
            set.space(c, 8);
            const rows = ui.div(c).column().gap(6).py(4);
            defer rows.end();
            c.frameIn(1.0 / 15.0);
            for (0..2) |i| {
                const t: f32 = @floatCast(@mod(c.time / 2.4 - @as(f64, @floatFromInt(i)) * 0.08, 1.0));
                const wave = (1 - @cos(2 * std.math.pi * t)) / 2;
                ui.div(c).w(inner).h(28).rounded(6).bg(k.ink(0.04)).opacity(0.35 + 0.4 * wave).end();
            }
        },
        .paste => pasteBody(c, a, k, f),
        .browser => browserBody(c, a, k, f),
    }
}

fn deviceName(a: *App, id: []const u8) []const u8 {
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, id)) return d.name;
    return id;
}

fn pasteBody(c: *ui.Context, a: *App, k: theme.Colors, f: *Flow) void {
    const s = state(a);
    const start = f.start.?;
    const relayed = start.mode == .relay_browser;
    const anthropic = if (f.provider) |p| std.mem.eql(u8, p, "anthropic") else false;
    set.space(c, 8);
    body(c, k, if (anthropic)
        "A browser window opened. Sign in to your Anthropic Console account and pick a workspace, then paste the code Anthropic shows you below. graff will run Claude models on that workspace's API credits."
    else if (relayed)
        "A browser window opened on this computer. Sign in to ChatGPT there; Harness catches the page it returns to and finishes the sign-in on the computer shown above, which keeps the login. If the browser instead shows a page that can't load (127.0.0.1…), copy its address and paste it below."
    else
        "A browser window opened. Sign in to the account you want to add, approve access, then paste the code Anthropic shows you below. Your current login is untouched until you switch.");
    urlLink(c, k, "Reopen the authorization page", start.url);
    urlField(c, a, k, start.url);
    set.space(c, 12);
    var submitted = false;
    {
        // `dialog_field`: its input's own 22.75-point line; 2 of the 9
        // above and below are the bare field's.
        const fr = ui.div(c).row().wFull().px(13).py(7).rounded(8).border(k.ink(0.08)).borderW(1).bg(k.ink(0.04));
        defer fr.end();
        const at = c.nodes.items.len;
        const opts: ui.TextFieldOptions = .{ .placeholder = "Paste the authorization code", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .line_height = kit.measured(22.75) };
        const r = ui.textField(c, &s.code, opts);
        if (s.focus_code) {
            c.focus = c.node(@intCast(at)).id;
            c.changed = true;
            s.focus_code = false;
        }
        submitted = r.submitted;
    }
    if (f.err) |e| {
        set.space(c, 8);
        redLine(c, k, e);
    }
    set.space(c, 16);
    const b = ui.div(c).row().wFull().gap(8).justifyEnd();
    defer b.end();
    if (ghostButton(c, k, "Cancel", 6)) return cancel(a);
    const label: []const u8 = if (f.submitting) "Verifying…" else if (relayed) "Finish sign-in" else "Add account";
    if (primaryButton(c, k, label, f.submitting) or submitted) submit(a);
}

fn browserBody(c: *ui.Context, a: *App, k: theme.Colors, f: *Flow) void {
    const start = f.start.?;
    set.space(c, 8);
    body(c, k, if (start.mode == .device_code)
        "Open the ChatGPT sign-in page and enter the one-time code below. You can approve on this device or your iPhone. Credentials are saved only on the execution device shown above, and your failed turn is not replayed."
    else if (start.mode == .host_browser)
        "Complete sign-in in the browser on the execution device shown above. ChatGPT's local callback must finish on that desktop. Your failed turn will not be sent again automatically."
    else switch (f.harness) {
        .cursor => "Finish signing in to Cursor in your browser. This mints a harness-named API key you can revoke any time from Cursor's dashboard — it is separate from `cursor-agent login`.",
        .graff => c.print("Finish signing in to {s} in your browser. graff saves the login itself, so nothing is copied into Harness.", .{accounts.graffProviderName(f.provider)}),
        .codex => if (f.reauthenticate)
            "Finish signing in to ChatGPT in your browser. The renewed login replaces the expired Codex login on this device. Your failed turn will not be sent again automatically."
        else
            "Finish signing in to OpenAI in your browser. The new login is captured in an isolated profile — your current session is untouched until you switch.",
        .claude_code => "Finish signing in to OpenAI in your browser. The new login is captured in an isolated profile — your current session is untouched until you switch.",
    });
    if (start.code) |code| {
        // Device-code sign-ins: the page asks for this.
        set.space(c, 12);
        ui.text(c, "Confirm this code on the page", st(c, 12, .{ .color = k.muted }));
        set.space(c, 6);
        const box = ui.div(c).row().px(13).py(9).rounded(8).border(k.border).borderW(1).bg(k.ink(0.03));
        defer box.end();
        ui.text(c, code, st(c, 18, .{ .mono = true, .weight = .semibold, .color = k.text }));
    }
    if (start.url.len > 0) {
        urlLink(c, k, "Reopen the sign-in page", start.url);
        urlField(c, a, k, start.url);
    }
    if (f.err) |e| {
        set.space(c, 12);
        redLine(c, k, e);
    } else {
        set.space(c, 16);
        const w = ui.div(c).row().gap(8).itemsCenter();
        defer w.end();
        kit.gradientSpinner(c);
        ui.text(c, f.message orelse "Waiting for the browser…", st(c, 12.5, .{ .color = k.muted }));
    }
    set.space(c, 16);
    const b = ui.div(c).row().wFull().justifyEnd();
    defer b.end();
    if (ghostButton(c, k, if (f.err != null) "Close" else "Cancel", 6)) cancel(a);
}
