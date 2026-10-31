//! A failed run's sign-in recovery, as the GPUI app drives it
//! (crates/ui/src/shell/reauth.rs). An error card's "Log in"
//! (`sign_in_for_chat`) opens Settings › Accounts on the computer the chat
//! runs on, with that agent's sign-in started where Accounts has one. The
//! in-chat ChatGPT reconnect (`on_reauth_action`) makes the same
//! StartAgentLogin / PollAgentLogin / CancelAgentLogin calls Accounts makes,
//! aimed at the chat's execution host, every 1.5 seconds while it waits;
//! the draft, the history and the open pane are never touched. Both route
//! by the chat's own device and agent, never by the error text.
const std = @import("std");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const accounts = @import("accounts.zig");
const workspace = @import("workspace.zig");
const rr = @import("reauth_recovery.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

/// `POLL_EVERY`: how often a waiting approval is checked (as Accounts).
pub const poll_s: f64 = 1.5;

/// `sidebar_notice` when the chat's owner isn't known: the sign-in must
/// never go to the viewer instead.
pub const host_unavailable = "Chat host unavailable. Open the chat's host in Accounts to sign in.";

/// A call whose reply may come before `engine.call` returns (no engine, or
/// a send that failed): its handler matches this, then the id.
const in_call: u64 = std.math.maxInt(u64);

/// A Resume being sent, for its failure.
const Resume = struct { call: u64, row: rr.Row };

/// The recoveries and the Resumes in flight.
pub const State = struct {
    rec: rr.Recoveries,
    resumes: std.ArrayList(Resume) = .empty,

    pub fn init(gpa: Allocator) State {
        return .{ .rec = .init(gpa) };
    }

    pub fn deinit(s: *State) void {
        for (s.resumes.items) |r| freeRow(s.rec.gpa, r.row);
        s.resumes.deinit(s.rec.gpa);
        s.rec.deinit();
    }
};

fn freeRow(gpa: Allocator, row: rr.Row) void {
    gpa.free(row.chat_id);
    gpa.free(row.row_id);
}

/// The chat with a known owner, or null.
fn owned(a: *App, chat_id: []const u8) ?workspace.Chat {
    const chat = a.findChat(chat_id) orelse return null;
    const host = chat.device_id orelse return null;
    return if (host.len == 0) null else chat;
}

/// The agent Accounts signs in for `harness` (its wire name), if any.
fn harnessOf(harness: ?[]const u8) ?accounts.Harness {
    const h = harness orelse return null;
    for (std.enums.values(accounts.Harness)) |x| if (std.mem.eql(u8, h, x.wire())) return x;
    return null;
}

/// `sign_in_for_chat`: an error card's "Log in".
pub fn signInForChat(a: *App, chat_id: []const u8) void {
    const chat = owned(a, chat_id) orelse {
        a.setNotice(host_unavailable);
        return a.redraw();
    };
    const host = chat.device_id.?;
    const local = if (a.device_id) |d| std.mem.eql(u8, d, host) else false;
    const settings_view = @import("view_settings.zig");
    settings_view.open(a);
    a.settings.setSection(.agents);
    @import("view_settings_accounts.zig").signIn(a, if (local) null else host, harnessOf(chat.harness));
}

/// `on_reauth_action`: a step on a reconnect card.
pub fn action(a: *App, chat_id: []const u8, row_id: []const u8, provider: rr.Provider, act: rr.Action) void {
    defer a.redraw();
    const chat = owned(a, chat_id) orelse return a.setNotice(host_unavailable);
    const key: rr.Key = .{ .host = chat.device_id.?, .provider = provider };
    const row: rr.Row = .{ .chat_id = chat_id, .row_id = row_id };
    switch (act) {
        // Already starting or waiting: this card attaches to it.
        .reconnect, .retry => if (a.reauth.rec.request(key, row) catch false) start(a, key),
        .cancel => cancel(a, key),
        .@"resume" => resumeAfter(a, chat, row),
    }
}

fn setPhase(a: *App, key: rr.Key, p: rr.Phase) void {
    a.reauth.rec.set(key, p) catch {};
    a.redraw();
}

/// Start (or attach to, on the host) the recovery for `key`; its reply
/// moves it on (`start_reauth`).
fn start(a: *App, key: rr.Key) void {
    if (!@import("view_settings_accounts.zig").engineUp(a)) return setPhase(a, key, .{ .failed = "Harness's engine isn't connected." });
    const rec = a.reauth.rec.find(key) orelse return;
    rec.start_attempt = rec.attempts;
    rec.start_call = in_call;
    const id = a.engine.call("StartAgentLogin", rr.startParams(key.provider, key.host), .of(App, a, onStart));
    if (rec.start_call == in_call) rec.start_call = id;
}

fn recOf(a: *App, comptime field: []const u8, id: u64) ?*rr.Rec {
    for (a.reauth.rec.recs.items) |rec| if (@field(rec, field)) |x| if (x == id or x == in_call) {
        @field(rec, field) = null;
        return rec;
    };
    return null;
}

fn cancelLogin(a: *App, login_id: []const u8, host: []const u8) void {
    a.call("CancelAgentLogin", .{ .loginId = login_id, .targetDeviceId = host }, .of(App, a, ignore));
}

/// Best effort (`CancelAgentLogin failed`, debug only).
fn ignore(_: *App, _: u64, _: rpc.Reply) void {}

pub fn onStart(a: *App, id: u64, r: rpc.Reply) void {
    const rec = recOf(a, "start_call", id) orelse return;
    const key = rec.key();
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const parsed: ?accounts.Start = switch (r) {
        .ok => |v| accounts.parseStart(arena.allocator(), v) catch null,
        else => null,
    };
    // Cancelled while starting, or replaced by a newer attempt.
    if (!a.reauth.rec.starting(key, rec.start_attempt)) {
        // Cancelled with no newer attempt: end the sign-in that just
        // started. A newer attempt attaches to it on the host.
        if (rec.attempts == rec.start_attempt) if (parsed) |s| cancelLogin(a, s.login_id, key.host);
        return;
    }
    var buf: [256]u8 = undefined;
    const s = parsed orelse return setPhase(a, key, .{ .failed = switch (r) {
        .err => |e| std.fmt.bufPrint(&buf, "Sign-in didn't start: {s}", .{e}) catch "Sign-in didn't start",
        else => "Sign-in didn't start: unexpected reply",
    } });
    if (!rr.startSupported(key.provider, s)) {
        // An older or different host: end what it started.
        cancelLogin(a, s.login_id, key.host);
        return setPhase(a, key, .{ .failed = "Update Harness on the chat's computer to reconnect from here." });
    }
    setPhase(a, key, .{ .waiting = .{ .start = s } });
    rec.poll_at = a.now + poll_s;
}

/// From the frame: ask after each waiting approval when it's time. The
/// seconds until the next.
pub fn tick(a: *App, now: f64) ?f64 {
    var next: ?f64 = null;
    for (a.reauth.rec.recs.items) |rec| {
        const at = rec.poll_at orelse continue;
        const login_id = a.reauth.rec.loginId(rec.key()) orelse {
            rec.poll_at = null;
            continue;
        };
        if (now < at) {
            next = if (next) |n| @min(n, at) else at;
            continue;
        }
        rec.poll_at = null;
        rec.poll_call = in_call;
        const id = a.engine.call("PollAgentLogin", .{ .loginId = login_id, .targetDeviceId = rec.host }, .of(App, a, onPoll));
        if (rec.poll_call == in_call) rec.poll_call = id;
    }
    return next;
}

pub fn onPoll(a: *App, id: u64, r: rpc.Reply) void {
    const rec = recOf(a, "poll_call", id) orelse return;
    const key = rec.key();
    // Cancelled while it was asked: stop quietly.
    const old = a.reauth.rec.phase(key) orelse return;
    if (old != .waiting) return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const poll: ?accounts.Poll = switch (r) {
        .ok => |v| accounts.parsePoll(arena.allocator(), v) catch null,
        else => null,
    };
    var buf: [256]u8 = undefined;
    const p = poll orelse return setPhase(a, key, .{ .failed = switch (r) {
        .err => |e| std.fmt.bufPrint(&buf, "Couldn't check the sign-in: {s}", .{e}) catch "Couldn't check the sign-in",
        else => "Couldn't check the sign-in: unexpected reply",
    } });
    switch (p.status) {
        // Only the host's own Done counts: it verified the renewed login.
        .done => setPhase(a, key, .reconnected),
        .@"error" => setPhase(a, key, .{ .failed = p.message orelse "Sign-in failed." }),
        .pending => {
            const same = if (old.waiting.message) |m| (if (p.message) |n| std.mem.eql(u8, m, n) else false) else p.message == null;
            if (!same) setPhase(a, key, .{ .waiting = .{ .start = old.waiting.start, .message = p.message } });
            rec.poll_at = a.now + poll_s;
        },
    }
}

/// `cancel_reauth`: ends the approval on the host for everyone waiting on
/// it. A start still in flight sees it was cancelled and ends the sign-in
/// it gets back.
fn cancel(a: *App, key: rr.Key) void {
    const rec = a.reauth.rec.find(key) orelse return;
    const was_starting = if (rec.phase) |p| p == .starting else false;
    if (!was_starting) {
        rec.start_call = null;
        rec.poll_call = null;
    }
    rec.poll_at = null;
    var buf: [256]u8 = undefined;
    const login_id: ?[]const u8 = if (a.reauth.rec.loginId(key)) |l| (if (l.len <= buf.len) blk: {
        @memcpy(buf[0..l.len], l);
        break :blk buf[0..l.len];
    } else null) else null;
    a.reauth.rec.clear(key);
    if (login_id) |l| if (@import("view_settings_accounts.zig").engineUp(a)) cancelLogin(a, l, rec.host);
}

/// A turn is running, or waiting on the person, in `chat`.
pub fn running(a: *App, chat: workspace.Chat) bool {
    const m = workspace.markOf(chat, workspace.sessionOf(a.sessions.items, chat.id), a.nowMs());
    return m == .working or m == .awaiting_input;
}

/// The chat's own agent and model are known, so a Resume never falls back
/// to a default.
pub fn hasConfig(chat: workspace.Chat) bool {
    return chat.harness != null and chat.model != null;
}

/// `resume_after_reauth`: a new turn in the same chat, from its session.
/// The failed prompt isn't replayed, the composer isn't read or cleared,
/// and the chat's own agent and model run it.
fn resumeAfter(a: *App, chat: workspace.Chat, row: rr.Row) void {
    if (!hasConfig(chat)) return;
    if (running(a, chat) or !(a.reauth.rec.claimResume(row) catch false)) return;
    if (!@import("view_settings_accounts.zig").engineUp(a)) return a.reauth.rec.releaseResume(row);
    const owned_row: rr.Row = .{
        .chat_id = a.gpa.dupe(u8, row.chat_id) catch return a.reauth.rec.releaseResume(row),
        .row_id = a.gpa.dupe(u8, row.row_id) catch return a.reauth.rec.releaseResume(row),
    };
    a.reauth.resumes.append(a.gpa, .{ .call = in_call, .row = owned_row }) catch {
        freeRow(a.gpa, owned_row);
        return a.reauth.rec.releaseResume(row);
    };
    var mb: [36]u8 = undefined;
    const message_id = @import("ids.zig").uuid(a.io, &mb);
    const id = a.engine.call("QueueCommand", requests.run(chat.id, message_id, .{
        .prompt = rr.resume_prompt,
        .harness = chat.harness,
        .model = chat.model,
        .reasoning = chat.reasoning,
        .cwd = chat.cwd orelse ".",
    }).params, .of(App, a, onResume));
    for (a.reauth.resumes.items) |*x| if (x.call == in_call) {
        x.call = id orelse 0;
    };
}

fn onResume(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.reauth;
    const i = for (s.resumes.items, 0..) |x, i| {
        if (x.call == id or x.call == in_call) break i;
    } else return;
    const done = s.resumes.swapRemove(i);
    defer freeRow(a.gpa, done.row);
    switch (r) {
        .err => |e| {
            s.rec.releaseResume(done.row);
            var buf: [256]u8 = undefined;
            a.setNotice(std.fmt.bufPrint(&buf, "Couldn't resume the chat: {s}", .{e}) catch "Couldn't resume the chat");
            a.redraw();
        },
        else => {},
    }
}
