//! The in-chat ChatGPT reconnect, as the GPUI app keeps it
//! (crates/ui/src/reauth_recovery.rs): one recovery per execution host and
//! sign-in route, shared by every transcript that shows a typed sign-in
//! error for it. The engine coalesces recoveries per host, route and
//! account, so a second chat attaches to the approval already waiting;
//! this side keeps the matching phase so every card for that host and route
//! shows the same step. Only an explicit Cancel ends a pending approval.
//!
//! Nothing here replays a failed prompt or a tool. Once the host verifies
//! the sign-in, the card that asked offers "Resume conversation": a new turn
//! in the same chat, sent only when clicked. Pure: app_reauth.zig makes the
//! calls.
const std = @import("std");
const accounts = @import("accounts.zig");
const Allocator = std.mem.Allocator;

/// `ReauthProvider`: the typed sign-in error's route.
pub const Provider = enum {
    chatgpt_new,
    codex,

    pub fn wire(p: Provider) []const u8 {
        return switch (p) {
            .chatgpt_new => "chatgpt-new",
            .codex => "codex",
        };
    }

    /// Only the allowlisted routes; anything else is a plain error.
    pub fn parse(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "chatgpt-new")) return .chatgpt_new;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        return null;
    }
};

/// `ReauthAction`: what the user asked a card to do.
pub const Action = enum {
    /// Start the recovery, or attach to the one already waiting.
    reconnect,
    /// End the pending approval for everyone waiting on it.
    cancel,
    /// Start again after a failure.
    retry,
    /// Continue the same chat with a new turn, once reconnected.
    @"resume",
};

/// `ReauthKey`: the chat's execution host and the sign-in route.
pub const Key = struct {
    host: []const u8,
    provider: Provider,
};

/// `ReauthRow`: the chat and the error row's stable id.
pub const Row = struct {
    chat_id: []const u8,
    row_id: []const u8,

    fn eql(x: Row, y: Row) bool {
        return std.mem.eql(u8, x.chat_id, y.chat_id) and std.mem.eql(u8, x.row_id, y.row_id);
    }
};

/// `RecoveryPhase`.
pub const Phase = union(enum) {
    starting,
    /// `message`: the host's latest progress line, when it sends one.
    waiting: struct { start: accounts.Start, message: ?[]const u8 = null },
    failed: []const u8,
    /// The host verified the renewed sign-in.
    reconnected,
};

/// One host and route's recovery.
pub const Rec = struct {
    host: []u8,
    provider: Provider,
    phase: ?Phase = null,
    /// The phase's strings.
    arena: std.heap.ArenaAllocator,
    attempts: u64 = 0,
    /// The rows that asked: all of them resolve when it succeeds.
    requesters: std.ArrayList(Row) = .empty,
    /// The driver's (app_reauth.zig): its start and poll calls in flight,
    /// the attempt the start was for, and when to poll next.
    start_call: ?u64 = null,
    start_attempt: u64 = 0,
    poll_call: ?u64 = null,
    poll_at: ?f64 = null,

    pub fn key(r: *const Rec) Key {
        return .{ .host = r.host, .provider = r.provider };
    }
};

/// `ReauthRecoveries`: memory only. A restart shows the card's first step
/// again, and the engine attaches to any approval still waiting.
pub const Recoveries = struct {
    gpa: Allocator,
    recs: std.ArrayList(*Rec) = .empty,
    /// Rows whose recovery succeeded.
    resolved: std.ArrayList(Row) = .empty,
    /// Rows whose Resume was sent (or is being sent).
    resumed: std.ArrayList(Row) = .empty,
    /// Bumped on every change.
    generation: u64 = 0,

    pub fn init(gpa: Allocator) Recoveries {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Recoveries) void {
        for (r.recs.items) |rec| {
            r.freeRows(&rec.requesters);
            rec.requesters.deinit(r.gpa);
            rec.arena.deinit();
            r.gpa.free(rec.host);
            r.gpa.destroy(rec);
        }
        r.recs.deinit(r.gpa);
        r.freeRows(&r.resolved);
        r.resolved.deinit(r.gpa);
        r.freeRows(&r.resumed);
        r.resumed.deinit(r.gpa);
    }

    fn freeRows(r: *Recoveries, list: *std.ArrayList(Row)) void {
        for (list.items) |row| freeRow(r.gpa, row);
        list.clearRetainingCapacity();
    }

    /// The record for `key`, if one was ever asked for.
    pub fn find(r: *const Recoveries, key: Key) ?*Rec {
        for (r.recs.items) |rec| if (rec.provider == key.provider and std.mem.eql(u8, rec.host, key.host)) return rec;
        return null;
    }

    fn ensure(r: *Recoveries, key: Key) !*Rec {
        if (r.find(key)) |rec| return rec;
        const rec = try r.gpa.create(Rec);
        errdefer r.gpa.destroy(rec);
        rec.* = .{ .host = try r.gpa.dupe(u8, key.host), .provider = key.provider, .arena = .init(r.gpa) };
        errdefer r.gpa.free(rec.host);
        try r.recs.append(r.gpa, rec);
        return rec;
    }

    pub fn phase(r: *const Recoveries, key: Key) ?Phase {
        return (r.find(key) orelse return null).phase;
    }

    /// `request`: a new demand for `key` from `row`. True when a recovery
    /// has to start; false when one is starting or waiting (it attaches).
    pub fn request(r: *Recoveries, key: Key, row: Row) !bool {
        const rec = try r.ensure(key);
        if (!contains(rec.requesters.items, row)) try rec.requesters.append(r.gpa, try dupeRow(r.gpa, row));
        const starts = if (rec.phase) |p| !(p == .starting or p == .waiting) else true;
        if (starts) {
            r.setPhase(rec, .starting) catch unreachable;
            rec.attempts += 1;
        }
        r.generation += 1;
        return starts;
    }

    /// The current start attempt for `key`.
    pub fn attempt(r: *const Recoveries, key: Key) u64 {
        return (r.find(key) orelse return 0).attempts;
    }

    /// Still the current start: nobody cancelled it and no newer attempt
    /// replaced it.
    pub fn starting(r: *const Recoveries, key: Key, at: u64) bool {
        const rec = r.find(key) orelse return false;
        return rec.attempts == at and rec.phase != null and rec.phase.? == .starting;
    }

    /// `set`: Reconnected resolves exactly the rows that asked, then clears
    /// the phase: a sign-in error that comes later for the same host is a
    /// new failure, not one already fixed. Strings in `p` are copied.
    pub fn set(r: *Recoveries, key: Key, p: Phase) !void {
        const rec = try r.ensure(key);
        if (p == .reconnected) {
            for (rec.requesters.items) |row| {
                if (contains(r.resolved.items, row)) freeRow(r.gpa, row) else try r.resolved.append(r.gpa, row);
            }
            rec.requesters.clearRetainingCapacity();
            try r.setPhase(rec, null);
        } else try r.setPhase(rec, p);
        r.generation += 1;
    }

    fn setPhase(_: *Recoveries, rec: *Rec, p: ?Phase) !void {
        var next: std.heap.ArenaAllocator = .init(rec.arena.child_allocator);
        errdefer next.deinit();
        const a = next.allocator();
        rec.phase = if (p) |x| switch (x) {
            .starting, .reconnected => x,
            .failed => |m| .{ .failed = try a.dupe(u8, m) },
            .waiting => |w| .{ .waiting = .{
                .start = .{
                    .login_id = try a.dupe(u8, w.start.login_id),
                    .url = try a.dupe(u8, w.start.url),
                    .mode = w.start.mode,
                    .code = if (w.start.code) |c| try a.dupe(u8, c) else null,
                },
                .message = if (w.message) |m| try a.dupe(u8, m) else null,
            } },
        } else null;
        rec.arena.deinit();
        rec.arena = next;
    }

    /// `clear`: Cancel or a failed start; the cards go back to their first
    /// step.
    pub fn clear(r: *Recoveries, key: Key) void {
        if (r.find(key)) |rec| {
            r.setPhase(rec, null) catch unreachable;
            r.freeRows(&rec.requesters);
        }
        r.generation += 1;
    }

    /// The pending login, for Cancel and polling.
    pub fn loginId(r: *const Recoveries, key: Key) ?[]const u8 {
        const p = r.phase(key) orelse return null;
        return if (p == .waiting) p.waiting.start.login_id else null;
    }

    /// This row asked for a recovery the host verified.
    pub fn reconnected(r: *const Recoveries, row: Row) bool {
        return contains(r.resolved.items, row);
    }

    /// Claim a row's one Resume: false when it isn't reconnected or was
    /// already claimed.
    pub fn claimResume(r: *Recoveries, row: Row) !bool {
        if (!r.reconnected(row) or contains(r.resumed.items, row)) return false;
        try r.resumed.append(r.gpa, try dupeRow(r.gpa, row));
        r.generation += 1;
        return true;
    }

    /// A Resume that couldn't be sent: the row offers it again.
    pub fn releaseResume(r: *Recoveries, row: Row) void {
        for (r.resumed.items, 0..) |x, i| if (x.eql(row)) {
            freeRow(r.gpa, r.resumed.orderedRemove(i));
            r.generation += 1;
            return;
        };
    }
};

fn contains(list: []const Row, row: Row) bool {
    for (list) |x| if (x.eql(row)) return true;
    return false;
}

fn dupeRow(gpa: Allocator, row: Row) !Row {
    const chat = try gpa.dupe(u8, row.chat_id);
    errdefer gpa.free(chat);
    return .{ .chat_id = chat, .row_id = try gpa.dupe(u8, row.row_id) };
}

fn freeRow(gpa: Allocator, row: Row) void {
    gpa.free(row.chat_id);
    gpa.free(row.row_id);
}

/// `route`: the StartAgentLogin call for a route. Codex device
/// authorization (approvable from a phone), or the ChatGPT route's
/// host-browser sign-in.
pub fn route(p: Provider) struct { harness: []const u8, sign_in: ?[]const u8 } {
    return switch (p) {
        .chatgpt_new => .{ .harness = "graff", .sign_in = "chatgpt-new" },
        .codex => .{ .harness = "codex", .sign_in = null },
    };
}

pub const StartParams = struct {
    harness: []const u8,
    reauthenticate: bool = true,
    targetDeviceId: []const u8,
    deviceAuth: ?bool = null,
    provider: ?[]const u8 = null,
};

/// `start_params`, aimed at the chat's host.
pub fn startParams(p: Provider, host: []const u8) StartParams {
    const r = route(p);
    return .{
        .harness = r.harness,
        .targetDeviceId = host,
        .deviceAuth = if (p == .codex) true else null,
        .provider = r.sign_in,
    };
}

/// `is_safe_device_code`: device authorization never carries an OAuth
/// redirect, token or arbitrary URL.
pub fn isSafeDeviceCode(s: accounts.Start) bool {
    const code = s.code orelse return false;
    if (code.len < 4 or code.len > 32) return false;
    for (code) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    return s.mode == .device_code and s.login_id.len > 0 and std.mem.eql(u8, s.url, "https://auth.openai.com/codex/device");
}

/// `start_supported`: only a safe device code for Codex, and an empty
/// host-browser start for the ChatGPT route (its URL and callback stay on
/// the host). Anything else is an older or different host.
pub fn startSupported(p: Provider, s: accounts.Start) bool {
    return switch (p) {
        .codex => isSafeDeviceCode(s),
        .chatgpt_new => s.mode == .host_browser and s.url.len == 0 and s.code == null and s.login_id.len > 0,
    };
}

/// The new turn Resume sends: a continuation, never the failed prompt.
pub const resume_prompt = "Continue where you left off. The previous turn stopped because " ++
    "ChatGPT needed reconnecting; it is connected again now.";

/// Shown with the first steps. Harness has no signal for either case, so it
/// never says one applies, and never suggests turning account security off.
pub const account_security_note = "If you recently reset your password or enrolled in " ++
    "Advanced Account Security (including Daybreak), ChatGPT may ask you to sign in again.";

pub const ResumeState = enum {
    ready,
    /// A turn is running in this chat.
    busy,
    /// The chat has no stored agent and model, so resuming could fall back
    /// to a default one.
    unavailable,
    sent,
};

/// `CardStep`: what a card shows.
pub const CardStep = union(enum) {
    /// Reconnect ChatGPT on the host.
    offer,
    starting,
    /// Waiting for approval: a device code to enter, or the host's browser.
    waiting: struct { code: ?[]const u8, url: []const u8, message: ?[]const u8 },
    failed: []const u8,
    reconnected: ResumeState,
    /// An error from earlier in the conversation: no action.
    earlier,
};

/// `card_step`. `later_activity`: the chat has a message after this error.
/// `has_config`: the chat has a stored agent and model.
pub fn cardStep(r: *const Recoveries, key: Key, row: Row, later_activity: bool, running: bool, has_config: bool) CardStep {
    if (r.reconnected(row)) {
        const s: ResumeState = if (contains(r.resumed.items, row) or later_activity)
            .sent
        else if (!has_config)
            .unavailable
        else if (running)
            .busy
        else
            .ready;
        return .{ .reconnected = s };
    }
    if (later_activity) return .earlier;
    const p = r.phase(key) orelse return .offer;
    return switch (p) {
        .starting => .starting,
        .waiting => |w| .{ .waiting = .{ .code = w.start.code, .url = w.start.url, .message = w.message } },
        .failed => |m| .{ .failed = m },
        // Never stored (see `set`); a row that didn't ask starts its own.
        .reconnected => .offer,
    };
}

const testing = std.testing;

fn keyOf(host: []const u8) Key {
    return .{ .host = host, .provider = .chatgpt_new };
}

fn rowOf(comptime chat: []const u8) Row {
    return .{ .chat_id = chat, .row_id = chat ++ "-error" };
}

const waiting: Phase = .{ .waiting = .{ .start = .{ .login_id = "login-1", .url = "", .mode = .host_browser } } };

test "a second demand attaches instead of starting again" {
    var r: Recoveries = .init(testing.allocator);
    defer r.deinit();
    try testing.expect(try r.request(keyOf("studio"), rowOf("a")));
    try r.set(keyOf("studio"), waiting);
    try testing.expect(!try r.request(keyOf("studio"), rowOf("b")));
    // A double click attaches too.
    try testing.expect(!try r.request(keyOf("studio"), rowOf("a")));
    try testing.expectEqualStrings("login-1", r.loginId(keyOf("studio")).?);
    // Another host is its own recovery.
    try testing.expect(try r.request(keyOf("laptop"), rowOf("c")));
}

test "success resolves every row that asked, and Resume is claimed once" {
    var r: Recoveries = .init(testing.allocator);
    defer r.deinit();
    _ = try r.request(keyOf("studio"), rowOf("a"));
    _ = try r.request(keyOf("studio"), rowOf("b"));
    try r.set(keyOf("studio"), .reconnected);
    for ([_]Row{ rowOf("a"), rowOf("b") }) |x| try testing.expectEqual(CardStep{ .reconnected = .ready }, cardStep(&r, keyOf("studio"), x, false, false, true));
    try testing.expect(try r.claimResume(rowOf("a")));
    try testing.expect(!try r.claimResume(rowOf("a")));
    try testing.expectEqual(CardStep{ .reconnected = .sent }, cardStep(&r, keyOf("studio"), rowOf("a"), false, false, true));
    r.releaseResume(rowOf("a"));
    try testing.expect(try r.claimResume(rowOf("a")));
    // A row that never asked isn't offered Resume, and a later sign-in
    // error for this host is a new failure.
    try testing.expectEqual(CardStep.offer, cardStep(&r, keyOf("studio"), rowOf("z"), false, false, true));
    try testing.expect(!try r.claimResume(rowOf("z")));
}

test "Resume waits for a running turn and never guesses an agent" {
    var r: Recoveries = .init(testing.allocator);
    defer r.deinit();
    _ = try r.request(keyOf("studio"), rowOf("a"));
    try r.set(keyOf("studio"), .reconnected);
    try testing.expectEqual(CardStep{ .reconnected = .busy }, cardStep(&r, keyOf("studio"), rowOf("a"), false, true, true));
    try testing.expectEqual(CardStep{ .reconnected = .unavailable }, cardStep(&r, keyOf("studio"), rowOf("a"), false, false, false));
    // A message after the error: the conversation already moved on.
    try testing.expectEqual(CardStep{ .reconnected = .sent }, cardStep(&r, keyOf("studio"), rowOf("a"), true, false, true));
}

test "earlier errors offer nothing, and Cancel returns to the first step" {
    var r: Recoveries = .init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(CardStep.earlier, cardStep(&r, keyOf("studio"), rowOf("a"), true, false, true));
    try testing.expectEqual(CardStep.offer, cardStep(&r, keyOf("studio"), rowOf("a"), false, false, true));
    _ = try r.request(keyOf("studio"), rowOf("a"));
    try testing.expectEqual(CardStep.starting, cardStep(&r, keyOf("studio"), rowOf("a"), false, false, true));
    try r.set(keyOf("studio"), waiting);
    const w = cardStep(&r, keyOf("studio"), rowOf("a"), false, false, true);
    try testing.expect(w == .waiting and w.waiting.code == null);
    try r.set(keyOf("studio"), .{ .failed = "Sign-in timed out" });
    const f = cardStep(&r, keyOf("studio"), rowOf("a"), false, false, true);
    try testing.expectEqualStrings("Sign-in timed out", f.failed);
    const before = r.attempt(keyOf("studio"));
    // Retry starts again.
    try testing.expect(try r.request(keyOf("studio"), rowOf("a")));
    const at = r.attempt(keyOf("studio"));
    try testing.expectEqual(before + 1, at);
    try testing.expect(r.starting(keyOf("studio"), at));
    r.clear(keyOf("studio"));
    // A start that returns after Cancel knows it was cancelled…
    try testing.expect(!r.starting(keyOf("studio"), at));
    try testing.expect(try r.request(keyOf("studio"), rowOf("a")));
    // …and a newer attempt replaces it.
    try testing.expect(!r.starting(keyOf("studio"), at));
    r.clear(keyOf("studio"));
    try testing.expectEqual(CardStep.offer, cardStep(&r, keyOf("studio"), rowOf("a"), false, false, true));
}

fn paramsJson(p: Provider, host: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(testing.allocator, startParams(p, host), .{ .emit_null_optional_fields = false });
}

test "routes and supported starts" {
    const g = try paramsJson(.chatgpt_new, "studio");
    defer testing.allocator.free(g);
    try testing.expectEqualStrings("{\"harness\":\"graff\",\"reauthenticate\":true,\"targetDeviceId\":\"studio\",\"provider\":\"chatgpt-new\"}", g);
    const c = try paramsJson(.codex, "studio");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("{\"harness\":\"codex\",\"reauthenticate\":true,\"targetDeviceId\":\"studio\",\"deviceAuth\":true}", c);
    const host_browser: accounts.Start = .{ .login_id = "l", .url = "", .mode = .host_browser };
    try testing.expect(startSupported(.chatgpt_new, host_browser));
    // Codex recovery needs a device code.
    try testing.expect(!startSupported(.codex, host_browser));
    var leaks = host_browser;
    leaks.url = "https://auth.example/authorize?id_token_hint=x";
    // The ChatGPT route keeps its URL on the host.
    try testing.expect(!startSupported(.chatgpt_new, leaks));
    const device: accounts.Start = .{ .login_id = "l", .url = "https://auth.openai.com/codex/device", .mode = .device_code, .code = "ABCD-1234" };
    try testing.expect(startSupported(.codex, device));
    var odd = device;
    odd.code = "AB CD";
    try testing.expect(!startSupported(.codex, odd));
    try testing.expectEqual(@as(?Provider, .codex), Provider.parse("codex"));
    try testing.expectEqual(@as(?Provider, null), Provider.parse("arbitrary-command"));
}
