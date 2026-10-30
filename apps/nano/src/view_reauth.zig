//! The in-chat ChatGPT reconnect card under a typed sign-in error, as the
//! GPUI transcript draws it (`render_reauth`, crates/ui/src/transcript.rs):
//! the error's chip, then a card styled like the Accounts ChatGPT sign-in
//! (its mark, primary and ghost buttons, Active badge, spinner and error
//! colour) showing the step reauth_recovery.zig's `cardStep` gives. Its
//! clicks go to app_reauth.zig with this row's chat and id.
const std = @import("std");
const kit = @import("view_kit.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const rows = @import("view_settings_accounts_rows.zig");
const rr = @import("reauth_recovery.zig");
const driver = @import("app_reauth.zig");
const App = @import("app.zig").App;

const st = rows.st;

/// One reconnect row.
pub const Row = struct {
    /// The transcript's chat; none for a chat not yet known.
    chat_id: ?[]const u8,
    /// `<entry>#<part>`, as the GPUI row's id.
    row_id: []const u8,
    message: []const u8,
    provider: rr.Provider,
    /// The chat has a message after this error.
    later_activity: bool,
    /// The transcript column's width.
    col: f32,
};

/// `render_reauth`.
pub fn card(c: *ui.Context, a: *App, k: theme.Colors, r: Row) void {
    const chip_view = @import("view_transcript.zig");
    const outer = ui.div(c).column().wFull().py(4);
    defer outer.end();
    const chat_id = r.chat_id orelse return chip_view.noticeChip(c, k, "ChatGPT sign-in required", r.message).end();
    const chat = a.findChat(chat_id);
    const host = if (chat) |ch| ch.device_id orelse "" else "";
    const host_name: []const u8 = if (a.device_id != null and std.mem.eql(u8, a.device_id.?, host))
        "this computer"
    else for (a.devices.items) |d| {
        if (std.mem.eql(u8, d.id, host)) break d.name;
    } else "the chat's computer";
    const step = rr.cardStep(&a.reauth.rec, .{ .host = host, .provider = r.provider }, .{ .chat_id = chat_id, .row_id = r.row_id }, r.later_activity, if (chat) |ch| driver.running(a, ch) else false, if (chat) |ch| driver.hasConfig(ch) else false);
    if (step == .earlier) return chip_view.noticeChip(c, k, "ChatGPT sign-in required", r.message).end();
    // Resolved: the error stays in history, but the card leads.
    if (step == .reconnected) space(c, 24) else {
        chip_view.noticeChip(c, k, "ChatGPT sign-in required", r.message).end();
        // The column's gap(8), then `section_card`'s mt(24).
        space(c, 8 + 24);
    }
    // `section_card` px(16) py(14); its edge drawn over the box.
    const box = ui.div(c).column().wFull().px(16 + 1).py(14 + 1).gap(10).rounded(12).border(k.border).borderW(1).bg(k.shell);
    defer box.end();
    const w = r.col - 2 * 17;
    const act = struct {
        fn go(a_: *App, r_: Row, id: []const u8, x: rr.Action) void {
            driver.action(a_, id, r_.row_id, r_.provider, x);
        }
    }.go;
    const chatgpt = r.provider == .chatgpt_new;
    switch (step) {
        .earlier => unreachable,
        .offer => {
            header(c, k, "Reconnect ChatGPT", w, false);
            line(c, k, c.print("Sign in again on {s} to keep going in this chat. Your draft and history stay as they are, and nothing is sent until you choose to.", .{host_name}), w);
            if (primary(c, k, if (chatgpt) "Continue with ChatGPT" else "Reconnect ChatGPT")) act(a, r, chat_id, .reconnect);
            note(c, k, w);
        },
        .starting => {
            header(c, k, "Reconnect ChatGPT", w, false);
            waitingLine(c, k, c.print("Starting sign-in on {s}\u{2026}", .{host_name}), w);
            if (ghost(c, k, "Cancel")) act(a, r, chat_id, .cancel);
        },
        .waiting => |wt| {
            header(c, k, "Waiting for approval", w, false);
            line(c, k, if (wt.code != null)
                c.print("Open the ChatGPT sign-in page and enter this code. You can approve on any device; the renewed sign-in is saved on {s}.", .{host_name})
            else
                c.print("Finish signing in in the browser on {s}. ChatGPT's sign-in has to complete on that computer.", .{host_name}), w);
            if (wt.code) |code| {
                const b = ui.div(c).row().px(12 + 1).py(8 + 1).rounded(8).border(k.border).borderW(1).bg(k.ink(0.03));
                defer b.end();
                ui.text(c, code, st(c, 18, .{ .mono = true, .weight = .semibold, .color = k.text }));
            }
            waitingLine(c, k, wt.message orelse c.print("Waiting for approval on {s}\u{2026}", .{host_name}), w);
            {
                const bs = ui.div(c).row().gap(8);
                defer bs.end();
                if (wt.url.len > 0) if (primary(c, k, "Open the sign-in page")) {
                    _ = nanoui.shell.openUrl(wt.url);
                };
                if (ghost(c, k, "Cancel")) act(a, r, chat_id, .cancel);
            }
            note(c, k, w);
        },
        .failed => |e| {
            header(c, k, "Couldn't reconnect ChatGPT", w, false);
            wrapped(c, e, st(c, 12.5, .{ .wrap = true, .color = k.danger_muted.alpha(0.9) }), w);
            if (primary(c, k, if (chatgpt) "Continue with ChatGPT" else "Retry")) act(a, r, chat_id, .retry);
            note(c, k, w);
        },
        .reconnected => |rs| {
            header(c, k, "ChatGPT reconnected", w, true);
            line(c, k, switch (rs) {
                .ready => c.print("Signed in again on {s}. Nothing was resent: resume when you're ready.", .{host_name}),
                .busy => "A turn is running in this chat. Resume once it finishes.",
                .unavailable => "Send a message to continue: this chat has no saved agent and model to resume with.",
                .sent => c.print("Signed in again on {s}.", .{host_name}),
            }, w);
            if (rs == .ready) if (primary(c, k, "Resume conversation")) act(a, r, chat_id, .@"resume");
        },
    }
}

fn space(c: *ui.Context, h: f32) void {
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = h } }, .none, null);
}

/// The OpenAI mark and `row_title`, with Active once reconnected.
fn header(c: *ui.Context, k: theme.Colors, title: []const u8, w: f32, active: bool) void {
    const h = ui.div(c).row().gap(8).itemsCenter();
    defer h.end();
    icons.icon(c, .@"openai-mark", 16, k.muted, 0);
    rows.title(c, k, title, w - 16 - 8 - (if (active) 8 + rows.badgeActiveW(c, "Active") else 0));
    if (active) rows.badgeActive(c, k, "Active");
}

fn wrapped(c: *ui.Context, text: []const u8, style: ui.TextStyle, w: f32) void {
    const b = ui.div(c).column().w(w);
    defer b.end();
    ui.text(c, text, style);
}

/// A step's words: 12.5 muted.
fn line(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    wrapped(c, text, st(c, 12.5, .{ .wrap = true, .color = k.muted }), w);
}

/// `ACCOUNT_SECURITY_NOTE`, quieter.
fn note(c: *ui.Context, k: theme.Colors, w: f32) void {
    wrapped(c, rr.account_security_note, st(c, 11.5, .{ .wrap = true, .color = k.muted.alpha(0.8) }), w);
}

/// The spinner and a line beside it.
fn waitingLine(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    const r = ui.div(c).row().gap(8).itemsCenter();
    defer r.end();
    spinner(c);
    line(c, k, text, w - spinner_w - 8);
}

/// `btn_primary`; true when clicked.
fn primary(c: *ui.Context, k: theme.Colors, label: []const u8) bool {
    const row = ui.div(c).row();
    defer row.end();
    const b = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
    defer b.end();
    ui.text(c, label, st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
    return b.clicked();
}

/// `btn_ghost`; true when clicked.
fn ghost(c: *ui.Context, k: theme.Colors, label: []const u8) bool {
    const b = ui.div(c).row().px(12).py(6).rounded(8).hover(k.ink(0.06));
    defer b.end();
    ui.text(c, label, st(c, 13, .{ .color = if (b.hovered()) k.text else k.muted }));
    return b.clicked();
}

/// The kit's `gradient_spinner`.
const spinner_w = kit.spinner_w;

fn spinner(c: *ui.Context) void {
    kit.gradientSpinner(c);
}
