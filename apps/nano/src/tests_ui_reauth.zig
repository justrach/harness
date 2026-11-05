//! A failed run's sign-in recovery driven as a person would, headlessly
//! (nanoui's Tester), on made-up chats and transcripts and no engine: the
//! error chip's "Log in" (`sign_in_for_chat`), the in-chat ChatGPT
//! reconnect card's steps (`render_reauth`), and a relayed sign-in caught
//! on the loopback.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const rr = @import("reauth_recovery.zig");
const driver = @import("app_reauth.zig");
const accounts_page = @import("view_settings_accounts.zig");

const testing = std.testing;

const chats =
    \\[{"id":"claude-here","deviceId":"here","title":"Tidy the notes","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z",
    \\  "config":{"harness":"claude-code","model":"sonnet","reasoning":null,"modelOptions":{},"sandbox":"workspace-write"}},
    \\ {"id":"codex-away","deviceId":"away","title":"Sketch a flow","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z",
    \\  "config":{"harness":"codex","model":"gpt-5","reasoning":null,"modelOptions":{},"sandbox":"workspace-write"}},
    \\ {"id":"graff-here","deviceId":"here","title":"Plan the week","archived":false,"lastMessageAt":"2026-10-01T00:00:00Z",
    \\  "config":{"harness":"graff","model":"chatgpt/gpt-5","reasoning":null,"modelOptions":{},"sandbox":"workspace-write"}},
    \\ {"id":"orphan","title":"Unowned","archived":false,"lastMessageAt":"2026-09-30T00:00:00Z",
    \\  "config":{"harness":"codex","model":null,"reasoning":null,"modelOptions":{},"sandbox":"workspace-write"}}]
;

const devices =
    \\[{"id":"here","name":"Studio","platform":"macos"},{"id":"away","name":"Field laptop","platform":"macos"}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.device_id = try testing.allocator.dupe(u8, "here");
        try replace(&h.a.chats, chats);
        try replace(&h.a.devices, devices);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// Opens `chat` with `entries` as its transcript.
    fn show(h: *Harness, chat: []const u8, entries: []const u8) !void {
        h.a.openChat(chat, null);
        var buf: [4096]u8 = undefined;
        const frame = try std.fmt.bufPrint(&buf, "{{\"reset\":{s}}}", .{entries});
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
    }

    /// `NANO_SNAP_DIR=dir zig build test` saves what the test saw.
    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }

    fn expectText(h: *Harness, want: []const u8) !void {
        if (!h.t.containsText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.containsText(want));
    }
};

fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}

/// A user's prompt, then the agent's reply that failed with `error_part`.
fn failed(comptime error_part: []const u8) []const u8 {
    return
    \\[{"id":"u1","role":"user","parts":[{"kind":"text","id":"t","text":"Summarise the release notes."}]},
    \\ {"id":"a1","role":"assistant","status":"complete","parts":[
    ++ error_part ++ "]}]";
}

/// `failed`, then the person's next message.
fn movedOn(comptime error_part: []const u8) []const u8 {
    const f = comptime failed(error_part);
    return f[0 .. f.len - 1] ++
        \\,{"id":"u2","role":"user","parts":[{"kind":"text","id":"t","text":"Carry on another way."}]}]
    ;
}

const signed_out = failed(
    \\{"kind":"error","id":"e","message":"Claude Code isn't signed in.\nUse Settings → Agents → Sign in."}
);

test "an error signing in fixes reads Signed out, with Log in; Log in opens Accounts with that agent's sign-in started" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.show("claude-here", signed_out);
    try h.expectText("Signed out");
    try h.expectText("Log in");
    // One line, as the GPUI chip shows it.
    try h.expectText("Claude Code isn't signed in. Use Settings → Agents → Sign in.");
    try testing.expect(!h.t.hasText("Error"));
    h.snap("error-sign-in");
    // The engine's reply to StartAgentLogin, as a scene gives it.
    accounts_page.scene_accounts =
        \\{"loginStart":{"loginId":"l1","url":"https://claude.example/oauth/authorize?state=demo","mode":"paste-code"}}
    ;
    defer accounts_page.scene_accounts = null;
    try h.t.clickText("Log in");
    h.t.settle(1);
    try testing.expect(h.a.view.settings_open);
    try testing.expectEqual(@import("settings.zig").Section.agents, h.a.settings.section);
    // This computer's logins, and Claude Code's Add account under way.
    try testing.expect(h.a.view.accounts.target == null);
    const flow = h.a.view.accounts.login.flow orelse return error.NoSignIn;
    try testing.expectEqual(@import("accounts.zig").Harness.claude_code, flow.harness);
    try h.expectText("Add Claude account");
    h.snap("error-sign-in-accounts");
}

test "a remote chat's Log in shows its computer's logins; a graff chat's, this one's, with nothing guessed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.show("codex-away", failed(
        \\{"kind":"error","id":"e","message":"Request failed (401) Unauthorized"}
    ));
    try h.expectText("Signed out");
    try h.t.clickText("Log in");
    h.t.settle(1);
    // Codex's sign-in started on the chat's computer; no engine here, so
    // the page says so.
    try testing.expectEqualStrings("away", h.a.view.accounts.target.?);
    try testing.expectEqualStrings("Engine not connected", h.a.view.accounts.notice.items);
    try testing.expect(h.a.view.accounts.login.flow == null);
    // graff's own sign-ins are listed on the page; none is started.
    @import("view_settings.zig").close(&h.a);
    try h.show("graff-here", failed(
        \\{"kind":"error","id":"e","message":"You've hit your usage limit. Upgrade to Pro or try again later."}
    ));
    try h.expectText("Limit reached");
    try h.t.clickText("Log in");
    h.t.settle(1);
    try testing.expect(h.a.view.accounts.target == null);
    try testing.expectEqualStrings("", h.a.view.accounts.notice.items);
    try testing.expect(h.a.view.accounts.login.flow == null);
}

test "a chat with no known computer: Log in opens nothing and says why" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.show("orphan", signed_out);
    try h.t.clickText("Log in");
    h.t.settle(1);
    try testing.expect(!h.a.view.settings_open);
    try testing.expectEqualStrings(driver.host_unavailable, h.a.noticeText().?);
}

test "an error signing in doesn't fix keeps its plain chip, with no Log in" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    inline for (.{
        failed(
            \\{"kind":"error","id":"e","message":"Claude is overloaded right now — try again shortly."}
        ),
        failed(
            \\{"kind":"error","id":"e","message":"Your Codegraff credit is used up. Add credit and try again."}
        ),
        failed(
            \\{"kind":"error","id":"e","message":"ChatGPT plan usage limit reached for this period."}
        ),
    }) |t| {
        try h.show("claude-here", t);
        try testing.expect(h.t.hasText("Error"));
        try testing.expect(!h.t.hasText("Log in"));
    }
}

const reauth_part =
    \\{"kind":"error","id":"e","message":"ChatGPT needs you to sign in again.","reauth":"chatgpt-new"}
;
const reauth_error = failed(reauth_part);

fn key(host: []const u8) rr.Key {
    return .{ .host = host, .provider = .chatgpt_new };
}

const row: rr.Row = .{ .chat_id = "graff-here", .row_id = "a1#e" };

fn reply(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

test "the reconnect card: Offer, a start with no engine, Starting and Cancel, Waiting and its poll" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.show("graff-here", reauth_error);
    for ([_][]const u8{
        "ChatGPT sign-in required",
        "ChatGPT needs you to sign in again.",
        "Reconnect ChatGPT",
        "Sign in again on this computer to keep going in this chat.",
        "Continue with ChatGPT",
        "If you recently reset your password",
    }) |want| try h.expectText(want);
    // Never "Log in": the typed error has its own card.
    try testing.expect(!h.t.hasText("Log in"));
    h.snap("reauth-offer");
    // No engine: the start fails in place, and offers it again.
    try h.t.clickText("Continue with ChatGPT");
    h.t.settle(1);
    try h.expectText("Couldn't reconnect ChatGPT");
    try h.expectText("Harness's engine isn't connected.");
    try h.expectText("Continue with ChatGPT");
    h.snap("reauth-failed");
    // Starting: the spinner's line and Cancel, which goes back to Offer.
    _ = try h.a.reauth.rec.request(key("here"), row);
    h.t.settle(0.1);
    try h.expectText("Starting sign-in on this computer…");
    h.snap("reauth-starting");
    try h.t.clickText("Cancel");
    h.t.settle(0.1);
    try testing.expect(h.a.reauth.rec.phase(key("here")) == null);
    try h.expectText("Reconnect ChatGPT");
    // The host's reply moves it to Waiting, and polling begins.
    _ = try h.a.reauth.rec.request(key("here"), row);
    const rec = h.a.reauth.rec.find(key("here")).?;
    rec.start_call = 7;
    rec.start_attempt = rec.attempts;
    {
        var p = try reply("{\"loginId\":\"login-1\",\"url\":\"\",\"mode\":\"host-browser\"}");
        defer p.deinit();
        driver.onStart(&h.a, 7, .{ .ok = p.value });
    }
    h.t.settle(0.1);
    try h.expectText("Waiting for approval");
    try h.expectText("Finish signing in in the browser on this computer. ChatGPT's sign-in has to complete on that computer.");
    try h.expectText("Waiting for approval on this computer…");
    try testing.expect(!h.t.hasText("Open the sign-in page"));
    h.snap("reauth-waiting");
    // A progress line from the host takes the waiting line's place.
    rec.poll_at = null;
    rec.poll_call = 9;
    {
        var p = try reply("{\"status\":\"pending\",\"message\":\"Browser opened on Studio.\"}");
        defer p.deinit();
        driver.onPoll(&h.a, 9, .{ .ok = p.value });
    }
    h.t.settle(0.1);
    try h.expectText("Browser opened on Studio.");
    // Its next poll, 1.5 s on, finds no engine.
    h.t.advance(1.6);
    h.t.settle(0.1);
    try h.expectText("Couldn't check the sign-in: not connected");
}

test "the reconnect card: an unsupported start, then Reconnected with Resume, busy and history" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.show("graff-here", reauth_error);
    // An older host's start that leaks its URL: ended, and said so.
    _ = try h.a.reauth.rec.request(key("here"), row);
    const rec = h.a.reauth.rec.find(key("here")).?;
    rec.start_call = 3;
    rec.start_attempt = rec.attempts;
    {
        var p = try reply("{\"loginId\":\"l\",\"url\":\"https://auth.example/authorize\",\"mode\":\"browser\"}");
        defer p.deinit();
        driver.onStart(&h.a, 3, .{ .ok = p.value });
    }
    h.t.settle(0.1);
    try h.expectText("Update Harness on the chat's computer to reconnect from here.");
    // The host verified the renewed sign-in: the card leads, the chip goes.
    _ = try h.a.reauth.rec.request(key("here"), row);
    try h.a.reauth.rec.set(key("here"), .reconnected);
    h.t.settle(0.1);
    try h.expectText("ChatGPT reconnected");
    try h.expectText("Active");
    try h.expectText("Signed in again on this computer. Nothing was resent: resume when you're ready.");
    try h.expectText("Resume conversation");
    try testing.expect(!h.t.hasText("ChatGPT sign-in required"));
    h.snap("reauth-reconnected");
    // Without an engine, Resume sends nothing and stays on offer.
    try h.t.clickText("Resume conversation");
    h.t.settle(0.1);
    try h.expectText("Resume conversation");
    try testing.expectEqual(@as(usize, 0), h.a.reauth.rec.resumed.items.len);
    // A running turn: Resume waits for it.
    var buf: [256]u8 = undefined;
    var date: [32]u8 = undefined;
    try replace(&h.a.sessions, try std.fmt.bufPrint(&buf, "[{{\"chatId\":\"graff-here\",\"status\":\"working\",\"updatedAt\":\"{s}\"}}]", .{isoNow(&date, h.a.nowMs())}));
    h.t.settle(0.1);
    try h.expectText("A turn is running in this chat. Resume once it finishes.");
    try testing.expect(!h.t.hasText("Resume conversation"));
    // A message after the error: the conversation moved on.
    try replace(&h.a.sessions, "[]");
    try h.show("graff-here", movedOn(reauth_part));
    try h.expectText("Signed in again on this computer.");
    try testing.expect(!h.t.hasText("Resume conversation"));
}

test "the reconnect card names the chat's own computer; an error the chat moved on from is only its chip" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const codex_part =
        \\{"kind":"error","id":"e","message":"Codex needs you to sign in again.","reauth":"codex"}
    ;
    try h.show("codex-away", failed(codex_part));
    try h.expectText("Sign in again on Field laptop to keep going in this chat.");
    try h.expectText("Reconnect ChatGPT");
    // The Codex route: device authorization, its code to enter.
    try h.a.reauth.rec.set(.{ .host = "away", .provider = .codex }, .{ .waiting = .{ .start = .{ .login_id = "l", .url = "https://auth.openai.com/codex/device", .mode = .device_code, .code = "WXYZ-1234" } } });
    h.t.settle(0.1);
    try h.expectText("Open the ChatGPT sign-in page and enter this code. You can approve on any device; the renewed sign-in is saved on Field laptop.");
    try h.expectText("WXYZ-1234");
    try h.expectText("Open the sign-in page");
    h.snap("reauth-device-code");
    try h.show("codex-away", movedOn(codex_part));
    try h.expectText("ChatGPT sign-in required");
    try testing.expect(!h.t.hasText("Waiting for approval"));
    try testing.expect(!h.t.hasText("Reconnect ChatGPT"));
}

/// "YYYY-MM-DDTHH:MM:SSZ" for `ms` since the epoch.
fn isoNow(buf: []u8, ms: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch "";
}

/// The landing's hop to the UI thread, held for the test to run.
const Held = struct {
    var ctx: std.atomic.Value(?*anyopaque) = .init(null);
    var func: ?*const fn (?*anyopaque) callconv(.c) void = null;

    fn hold(c: ?*anyopaque, f: *const fn (?*anyopaque) callconv(.c) void) void {
        func = f;
        ctx.store(c, .release);
    }
};

test "a relayed ChatGPT sign-in: the browser's redirect, caught here, fills the dialog to be sent on" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const login = @import("view_settings_accounts_login.zig");
    const net = std.Io.net;
    // A free loopback port for the authorize page's redirect.
    const port = blk: {
        var probe = try (try net.IpAddress.parseIp4("127.0.0.1", 0)).listen(testing.io, .{});
        defer probe.deinit(testing.io);
        break :blk probe.socket.address.getPort();
    };
    var ub: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "https://auth.example/authorize?client_id=c&redirect_uri=http%3A%2F%2F127.0.0.1%3A{d}%2Fauth%2Fcallback&state=s", .{port});
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .agents;
    h.a.view.accounts.login.flow = .{ .stage = .paste, .harness = .graff, .provider = try testing.allocator.dupe(u8, "chatgpt-new"), .start = .{ .login_id = "l1", .url = url, .mode = .relay_browser } };
    h.t.settle(1);
    try h.expectText("Harness catches the page it returns to");
    const old_hop = login.hop;
    login.hop = Held.hold;
    defer login.hop = old_hop;
    login.spawnRelay(&h.a, url);
    try testing.expect(h.a.view.accounts.login.relay != null);
    // The browser lands on this computer's loopback.
    {
        const s = try (try net.IpAddress.parseIp4("127.0.0.1", port)).connect(testing.io, .{ .mode = .stream });
        defer s.close(testing.io);
        var wb: [256]u8 = undefined;
        var w = s.writer(testing.io, &wb);
        try w.interface.writeAll("GET /auth/callback?code=abc&state=s HTTP/1.1\r\nHost: x\r\n\r\n");
        try w.interface.flush();
        var rb: [64]u8 = undefined;
        var bufs = [_][]u8{&rb};
        _ = s.readWithControl(testing.io, &bufs, &.{}) catch {};
    }
    var waited: usize = 0;
    while (Held.ctx.load(.acquire) == null and waited < 500) : (waited += 1) try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    // On the UI thread, as the main queue would run it.
    (Held.func orelse return error.NotLanded)(Held.ctx.load(.acquire));
    h.t.settle(0.1);
    var want: [96]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "http://127.0.0.1:{d}/auth/callback?code=abc&state=s", .{port}), h.a.view.accounts.login.code.text());
    // Cancel lets the port go.
    login.cancel(&h.a);
    try testing.expect(h.a.view.accounts.login.relay == null);
}
