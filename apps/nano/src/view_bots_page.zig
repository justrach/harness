//! The main column's Bots pages, in the chat's place: the catch-up (what
//! bots did, need, or did not do), one bot's job, routines and memory, and
//! the form that makes a bot.
//!
//! Nothing here runs a bot or reads its files: every button is a request
//! to the engine (bots.zig), and graff owns the store behind it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const workspace = @import("workspace.zig");
const bots = @import("bots.zig");
const folder = @import("view_bots.zig").folder;
const App = @import("app.zig").App;

const phi: f32 = 1.618;
/// The column's inside width this frame: wrapped text needs it up front.
var inner_w: f32 = 640;

fn space(c: *ui.Context, h: f32) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = h } }, .none, null);
}

fn line(c: *ui.Context, text: []const u8, size: f32, color: ui.Color, w: f32) void {
    const box = ui.div(c).column().w(w);
    defer box.end();
    ui.text(c, text, .{ .size = size, .line_height = size * phi, .wrap = true, .color = color });
}

const Tone = enum { plain, solid, danger };

/// A small button; true when clicked.
fn button(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8, tone: Tone, enabled: bool) bool {
    ui.key(c, key);
    var b = ui.div(c).row().px(10).py(5).itemsCenter().rounded(7);
    b = switch (tone) {
        .plain => b.border(k.border).borderW(1).hover(k.ink(0.06)),
        .solid => b.bg(k.solid).border(k.solid).borderW(1),
        .danger => b.border(k.danger.alpha(0.45)).borderW(1).hover(k.danger.alpha(0.08)),
    };
    if (!enabled) b = b.opacity(0.45);
    defer b.end();
    const color = switch (tone) {
        .plain => if (b.hovered() and enabled) k.text else k.muted,
        .solid => k.on_solid,
        .danger => k.danger,
    };
    ui.text(c, label, .{ .size = 12, .line_height = 16, .color = color });
    return enabled and b.clicked();
}

/// A text field in its frame; true when Return was pressed in it.
fn field(c: *ui.Context, k: theme.Colors, key: []const u8, buf: *ui.TextBuffer, placeholder: []const u8, mono: bool) bool {
    ui.key(c, key);
    const f = ui.div(c).row().grow().w(0).px(11).py(7).rounded(8).border(k.ink(0.10)).borderW(1).bg(k.ink(0.04));
    defer f.end();
    return ui.textField(c, buf, .{ .placeholder = placeholder, .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 13, .mono = mono }).submitted;
}

fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell);
}

fn divider(c: *ui.Context, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}

fn sectionLabel(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    space(c, 22);
    ui.text(c, label, .{ .size = 11.5, .line_height = 16, .weight = theme.ui_medium_weight, .color = k.muted.alpha(0.7) });
    space(c, 8);
}

fn noticeStrip(c: *ui.Context, a: *App, k: theme.Colors) void {
    const b = &a.bots;
    if (b.notice.items.len == 0) return;
    space(c, 12);
    ui.key(c, "bots-notice");
    const s = ui.div(c).row().wFull().px(14).py(10).gap(8).rounded(10).border(k.danger.alpha(0.2)).borderW(1).bg(k.danger.alpha(0.06));
    defer s.end();
    icons.icon(c, .@"danger-triangle", 15, k.danger_muted.alpha(0.9), 0);
    line(c, b.notice.items, 12.5, k.danger_muted.alpha(0.9), @max(inner_w - 2 * 14 - 15 - 8, 80));
    if (s.clicked()) {
        b.notice.clearRetainingCapacity();
        a.redraw();
    }
}

/// The page's top line: the way back to the chat, and what this is.
fn top(c: *ui.Context, a: *App, k: theme.Colors, title: []const u8, quiet: []const u8) void {
    const h = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer h.end();
    {
        ui.key(c, "bots-back");
        const back = ui.div(c).row().size(24, 24).center().rounded(6).hover(k.hover);
        defer back.end();
        icons.icon(c, .@"alt-arrow-left", 14, k.muted, 0);
        if (back.clicked()) bots.close(a);
    }
    ui.text(c, title, .{ .size = 16, .line_height = 22, .weight = .semibold, .color = k.text });
    if (quiet.len > 0) ui.text(c, quiet, .{ .size = 12.5, .line_height = 22, .color = k.muted.alpha(0.75) });
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors, pane_w: f32) void {
    ui.scroll(c, .{ .grow = 1, .width = .fill, .align_items = .center });
    defer ui.end(c);
    ui.key(c, c.print("bots-page-{s}", .{@tagName(a.bots.page)}));
    const w = @min(pane_w, 736);
    inner_w = w - 2 * 24;
    const col = ui.div(c).column().w(w).px(24).pt(20).pb(56);
    defer col.end();
    switch (a.bots.page) {
        .none => {},
        .inbox => inbox(c, a, k),
        .bot => if (a.bots.focused()) |bot| botPage(c, a, k, bot) else top(c, a, k, "Bots", ""),
        .new => newPage(c, a, k),
    }
}

// ── the catch-up ─────────────────────────────────────────────────────

fn kindLabel(c: *ui.Context, it: bots.Item, offset_s: i64) []const u8 {
    var buf: [8]u8 = undefined;
    const at = if (it.at_ms > 0) bots.clock(&buf, it.at_ms, offset_s) else "";
    return switch (it.kind) {
        .waiting => "Needs you",
        .failed => if (at.len > 0) c.print("Failed · {s}", .{at}) else "Failed",
        .done => if (at.len > 0) c.print("Done · {s}", .{at}) else "Done",
        .missed => "Did not run",
    };
}

fn kindColor(k: theme.Colors, kind: bots.Kind) ui.Color {
    return switch (kind) {
        .waiting => k.accent,
        .failed => k.danger,
        .done => k.success,
        .missed => k.warning,
    };
}

fn inbox(c: *ui.Context, a: *App, k: theme.Colors) void {
    const b = &a.bots;
    const at = bots.now(a);
    const offset_s = bots.offset(a);
    const its = bots.items(c.alloc(), b.list.items, a.chats.items, a.sessions.items, at);
    var missed = false;
    for (its) |it| missed = missed or it.kind == .missed;
    top(c, a, k, if (missed) "While you were away" else "To look at", if (its.len > 0) c.print("{d}", .{its.len}) else "");
    noticeStrip(c, a, k);
    // The honest part: what was due did not run because nothing checked.
    var gap_buf: [128]u8 = undefined;
    const gap = if (missed) bots.gapLine(&gap_buf, b.gap_from_ms, b.gap_to_ms, offset_s) else "";
    if (gap.len > 0) {
        space(c, 14);
        const banner = ui.div(c).row().wFull().px(14).py(10).rounded(10).bg(k.warning.alpha(0.10));
        defer banner.end();
        line(c, c.print("{s} Routines run only while Harness is open.", .{gap}), 12.5, k.warning, inner_w - 2 * 14);
    }
    if (its.len == 0) {
        space(c, 28);
        line(c, "Nothing to look at.", 13, k.muted, inner_w);
        space(c, 4);
        line(c, "A finished run, a question waiting for you, a failure, and a routine that was due and did not run all show up here. Routines run only while Harness is open.", 12.5, k.muted.alpha(0.65), inner_w);
        return;
    }
    for (its) |it| {
        space(c, 10);
        ui.key(c, c.print("item-{s}-{s}-{s}", .{ @tagName(it.kind), it.bot, it.routine }));
        const cd = card(c, k);
        defer cd.end();
        const row = ui.div(c).row().wFull().px(16).py(13).gap(14);
        defer row.end();
        {
            const label = ui.div(c).column().w(96);
            defer label.end();
            ui.text(c, kindLabel(c, it, offset_s), .{ .size = 11.5, .line_height = 18, .weight = theme.ui_medium_weight, .color = kindColor(k, it.kind) });
        }
        const body_w = @max(inner_w - 2 - 2 * 16 - 96 - 14, 120);
        const body = ui.div(c).column().w(body_w).gap(3);
        defer body.end();
        const bot = b.find(it.bot);
        const where = if (bot) |x| (if (x.project.len > 0) folder(x.project) else "") else "";
        ui.text(c, if (where.len > 0) c.print("{s} · {s}", .{ it.bot, where }) else it.bot, .{ .size = 13, .line_height = 18, .weight = .medium, .color = k.text });
        switch (it.kind) {
            .missed => {
                var t: [8]u8 = undefined;
                const due = bots.clock(&t, it.at_ms, offset_s);
                line(c, if (it.count > 1) c.print("{s} · due {s} and {d} more times. None started.", .{ it.text, due, it.count - 1 }) else c.print("{s} · due {s}. It did not start.", .{ it.text, due }), 12.5, k.muted, body_w);
            },
            .waiting => line(c, "It stopped on a question. Nothing else runs in its chat until you answer.", 12.5, k.muted, body_w),
            .failed, .done => if (it.text.len > 0) line(c, firstLine(it.text), 12.5, k.muted, body_w),
        }
        space(c, 6);
        const actions = ui.div(c).row().gap(6);
        defer actions.end();
        switch (it.kind) {
            .waiting => if (button(c, k, "open", "Open to answer", .solid, true)) open(a, bot),
            .done => {
                if (button(c, k, "open", "Open", .plain, true)) open(a, bot);
                if (button(c, k, "read", "Mark read", .plain, true)) markRead(a, bot);
            },
            .failed => {
                if (button(c, k, "open", "Open", .plain, true)) open(a, bot);
                if (button(c, k, "dismiss", "Dismiss", .plain, true)) markRead(a, bot);
            },
            .missed => {
                // A new turn, now: the night is not filled in after the fact.
                if (button(c, k, "run", "Run now", .plain, !b.busy)) bots.run(a, it.bot, null, it.routine);
                if (button(c, k, "dismiss", "Dismiss", .plain, !b.busy)) bots.act(a, .{ .action = "missedClear", .bot = it.bot, .routine = it.routine });
            },
        }
    }
}

fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
}

fn open(a: *App, bot: ?bots.Bot) void {
    if (bot) |x| bots.openRow(a, x);
}

fn markRead(a: *App, bot: ?bots.Bot) void {
    const x = bot orelse return;
    if (x.chat.len > 0) a.request(@import("requests.zig").markChatSeen(x.chat), .of(App, a, App.onNotice));
}

// ── one bot ──────────────────────────────────────────────────────────

fn chip(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const ch = ui.div(c).row().px(8).py(2).roundedFull().bg(k.ink(0.06));
    defer ch.end();
    ui.text(c, label, .{ .size = 11.5, .line_height = 16, .color = k.muted });
}

fn botPage(c: *ui.Context, a: *App, k: theme.Colors, bot: bots.Bot) void {
    const b = &a.bots;
    const at = bots.now(a);
    const offset_s = bots.offset(a);
    top(c, a, k, bot.name, "");
    space(c, 6);
    line(c, bot.job, 13, k.text.alpha(0.9), inner_w);
    space(c, 8);
    {
        const chips = ui.div(c).row().gap(6).itemsCenter();
        defer chips.end();
        if (bot.primary) chip(c, k, "Primary · your default contact");
        chip(c, k, if (bot.project.len > 0) c.print("Works in {s}", .{folder(bot.project)}) else "No project");
        if (bot.model.len > 0) chip(c, k, bot.model);
    }
    noticeStrip(c, a, k);

    // A message for it: the first one makes its standing chat.
    space(c, 16);
    {
        const send = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer send.end();
        const entered = field(c, k, "bot-message", &b.message, c.print("Ask {s}…", .{bot.name}), false);
        const text = std.mem.trim(u8, b.message.text(), " \t\r\n");
        const has_chat = bot.chat.len > 0 and a.findChat(bot.chat) != null;
        if ((button(c, k, "bot-send", "Send", .solid, text.len > 0 and !b.busy) or (entered and text.len > 0 and !b.busy))) bots.run(a, bot.name, text, null);
        if (has_chat and button(c, k, "bot-chat", "Open chat", .plain, true)) bots.openRow(a, bot);
    }

    sectionLabel(c, k, "Routines");
    {
        const cd = card(c, k);
        defer cd.end();
        for (bot.routines, 0..) |r, ix| {
            if (ix > 0) divider(c, k);
            ui.key(c, c.print("routine-{s}", .{r.id}));
            const row = ui.div(c).column().wFull().px(16).py(11).gap(4);
            defer row.end();
            {
                const head = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer head.end();
                var e: [40]u8 = undefined;
                const text_w = @max(inner_w - 2 - 2 * 16 - 40 - 2 * 70 - 3 * 8, 120);
                const words = ui.div(c).column().w(text_w).gap(1);
                {
                    defer words.end();
                    ui.text(c, c.print("{s} · {s}", .{ bots.every(&e, r.interval_ms), r.instruction }), .{ .size = 13, .line_height = 18, .wrap = true, .color = if (r.paused or r.done) k.muted else k.text });
                    var u: [24]u8 = undefined;
                    const next = if (r.done) "Spent" else if (r.paused) "Paused" else c.print("Next {s}", .{bots.until(&u, r.at_ms, at)});
                    ui.text(c, c.print("{s} · {s} · {d} {s}", .{ r.id, next, r.runs, if (r.runs == 1) "run" else "runs" }), .{ .size = 11.5, .line_height = 16, .color = k.muted.alpha(0.7) });
                }
                ui.spacer(c);
                if (!r.done) {
                    ui.key(c, "pause");
                    if (@import("view_settings.zig").toggle(c, k, !r.paused, !b.busy)) bots.act(a, .{ .action = if (r.paused) "routineResume" else "routinePause", .bot = bot.name, .routine = r.id });
                }
                if (button(c, k, "now", "Run now", .plain, !b.busy)) bots.run(a, bot.name, null, r.id);
                if (button(c, k, "delete", "Delete", .plain, !b.busy)) bots.act(a, .{ .action = "routineRemove", .bot = bot.name, .routine = r.id });
            }
            if (r.missed_open > 0) {
                var t: [8]u8 = undefined;
                const due = bots.clock(&t, r.missed_at_ms, offset_s);
                const missed = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer missed.end();
                ui.text(c, if (r.missed_open > 1) c.print("Due {s} and {d} more times · did not run", .{ due, r.missed_open - 1 }) else c.print("Due {s} · did not run", .{due}), .{ .size = 12, .line_height = 18, .color = k.warning });
                ui.spacer(c);
                if (button(c, k, "dismiss", "Dismiss", .plain, !b.busy)) bots.act(a, .{ .action = "missedClear", .bot = bot.name, .routine = r.id });
            }
        }
        if (bot.routines.len > 0) divider(c, k);
        {
            const add = ui.div(c).row().wFull().px(16).py(11).gap(8).itemsCenter();
            defer add.end();
            {
                const when = ui.div(c).row().w(112);
                defer when.end();
                _ = field(c, k, "routine-when", &b.when, "@every 2h", true);
            }
            const entered = field(c, k, "routine-what", &b.instruction, "What it does each time", false);
            const when_text = std.mem.trim(u8, b.when.text(), " \t");
            const what = std.mem.trim(u8, b.instruction.text(), " \t\r\n");
            const ready = when_text.len > 0 and what.len > 0 and !b.busy;
            if (button(c, k, "routine-add", "Add", .plain, ready) or (entered and ready)) {
                bots.act(a, .{ .action = "routineAdd", .bot = bot.name, .when = when_text, .text = what });
                b.when.clear();
                b.instruction.clear();
            }
        }
    }
    space(c, 8);
    {
        // Where the person looks: whether anything is checking, and when.
        var t: [8]u8 = undefined;
        const checked = if (b.last_check_ms > 0) c.print("Last checked {s}.", .{bots.clock(&t, b.last_check_ms, offset_s)}) else "Not checked yet.";
        line(c, c.print("Routines run only while Harness is open. {s} A schedule is a delay (30m, once) or @every and a period; there are no weekday or clock times.", .{checked}), 12, k.muted.alpha(0.65), inner_w);
    }

    sectionLabel(c, k, "Memory");
    {
        const cd = card(c, k);
        defer cd.end();
        var any = false;
        var lines = std.mem.tokenizeAny(u8, b.memory.items, "\r\n");
        var ix: usize = 0;
        while (lines.next()) |raw| : (ix += 1) {
            const entry = entryOf(raw);
            if (entry.len == 0) continue;
            if (any) divider(c, k);
            any = true;
            ui.key(c, c.print("memory-{d}", .{ix}));
            const row = ui.div(c).row().wFull().px(16).py(9).gap(10).itemsCenter();
            defer row.end();
            line(c, entry, 12.5, k.text.alpha(0.9), @max(inner_w - 2 - 2 * 16 - 10 - 64, 120));
            ui.spacer(c);
            if (button(c, k, "forget", "Forget", .plain, !b.busy)) bots.act(a, .{ .action = "forget", .bot = bot.name, .text = entry });
        }
        if (!any) {
            const none = ui.div(c).row().wFull().px(16).py(11);
            defer none.end();
            line(c, "Nothing yet. Tell it a rule in its chat and it keeps it here.", 12.5, k.muted.alpha(0.7), inner_w - 2 - 2 * 16);
        }
    }

    sectionLabel(c, k, "About you");
    if (bot.primary) {
        const about = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer about.end();
        const entered = field(c, k, "about", &b.about_edit, "Your name and time zone", false);
        const text = std.mem.trim(u8, b.about_edit.text(), " \t\r\n");
        const changed = !std.mem.eql(u8, text, b.about.items) and !b.busy;
        if (button(c, k, "about-save", "Save", .plain, changed) or (entered and changed)) bots.act(a, .{ .action = "about", .text = text });
    } else {
        line(c, if (b.about.items.len > 0) b.about.items else "Nothing yet.", 12.5, k.text.alpha(0.9), inner_w);
    }
    space(c, 4);
    line(c, if (bot.primary) "Every one of your bots is shown this." else "Shared by all your bots. Edit it on your primary bot.", 12, k.muted.alpha(0.65), inner_w);

    if (b.log.items.len > 0) {
        sectionLabel(c, k, "Recent log");
        const cd = card(c, k);
        defer cd.end();
        const body = ui.div(c).column().wFull().px(16).py(11).gap(2);
        defer body.end();
        var lines = std.mem.tokenizeAny(u8, b.log.items, "\r\n");
        var shown: usize = 0;
        while (lines.next()) |raw| {
            shown += 1;
            if (shown > 12) break;
            const box = ui.div(c).column().w(inner_w - 2 - 2 * 16);
            defer box.end();
            ui.text(c, entryOf(raw), .{ .size = 11.5, .line_height = 17, .mono = true, .wrap = true, .color = k.muted });
        }
    }

    space(c, 26);
    {
        const foot = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer foot.end();
        if (!bot.primary and button(c, k, "make-primary", "Make primary", .plain, !b.busy)) bots.act(a, .{ .action = "setPrimary", .bot = bot.name, .primary = true });
        ui.spacer(c);
        if (b.confirm_delete) {
            ui.text(c, c.print("Delete {s} and everything it remembers?", .{bot.name}), .{ .size = 12.5, .line_height = 18, .color = k.muted });
            if (button(c, k, "delete-yes", "Delete", .danger, !b.busy)) bots.act(a, .{ .action = "remove", .bot = bot.name });
            if (button(c, k, "delete-no", "Keep", .plain, true)) {
                b.confirm_delete = false;
                a.redraw();
            }
        } else if (button(c, k, "delete-bot", "Delete bot", .plain, !b.busy)) {
            // Asked once more before anything is deleted.
            b.confirm_delete = true;
            a.redraw();
        }
    }
}

/// A memory or log line without its list mark.
fn entryOf(raw: []const u8) []const u8 {
    const text = std.mem.trim(u8, raw, " \t");
    return if (std.mem.startsWith(u8, text, "- ") or std.mem.startsWith(u8, text, "* ")) std.mem.trim(u8, text[2..], " \t") else text;
}

// ── a new bot ────────────────────────────────────────────────────────

/// The project a new bot would work in: the sidebar's filter, when it is a
/// project on this device.
fn newProject(a: *const App) ?workspace.Space {
    const s = a.findSpace(a.view.filter orelse return null) orelse return null;
    if (s.device_id) |d| if (a.device_id) |mine| if (!std.mem.eql(u8, d, mine)) return null;
    return s;
}

fn switchLine(c: *ui.Context, a: *App, k: theme.Colors, key: []const u8, title: []const u8, meta: []const u8, on: *bool) void {
    ui.key(c, key);
    const row = ui.div(c).row().wFull().px(16).py(8).gap(12).itemsCenter();
    defer row.end();
    {
        const words = ui.div(c).column().w(@max(inner_w - 2 - 2 * 16 - 12 - 40, 120)).gap(1);
        defer words.end();
        ui.text(c, title, .{ .size = 13, .line_height = 18, .weight = .medium, .color = k.text });
        ui.text(c, meta, .{ .size = 12, .line_height = 17, .wrap = true, .color = k.muted.alpha(0.7) });
    }
    ui.spacer(c);
    if (@import("view_settings.zig").toggle(c, k, on.*, true)) {
        on.* = !on.*;
        a.redraw();
    }
}

fn newPage(c: *ui.Context, a: *App, k: theme.Colors) void {
    const b = &a.bots;
    top(c, a, k, "New bot", "");
    space(c, 6);
    line(c, "A bot keeps one job and its own memory between runs. You can message it from any project.", 13, k.muted, inner_w);
    noticeStrip(c, a, k);
    space(c, 18);
    ui.text(c, "Name", .{ .size = 12.5, .line_height = 18, .weight = .medium, .color = k.text });
    space(c, 6);
    {
        const row = ui.div(c).row().wFull();
        defer row.end();
        _ = field(c, k, "new-name", &b.name, "triage", true);
    }
    const name = std.mem.trim(u8, b.name.text(), " \t");
    space(c, 4);
    line(c, "Lowercase letters, digits, - and _.", 12, if (name.len > 0 and !bots.validName(name)) k.danger else k.muted.alpha(0.65), inner_w);
    space(c, 14);
    ui.text(c, "Job", .{ .size = 12.5, .line_height = 18, .weight = .medium, .color = k.text });
    space(c, 6);
    var entered = false;
    {
        const row = ui.div(c).row().wFull();
        defer row.end();
        entered = field(c, k, "new-job", &b.job, "Label new issues. Never close one.", false);
    }
    const job = std.mem.trim(u8, b.job.text(), " \t\r\n");
    space(c, 18);
    const project = newProject(a);
    {
        const cd = card(c, k);
        defer cd.end();
        if (project) |p| {
            switchLine(c, a, k, "new-project", c.print("Works in {s}", .{p.name}), "Its runs happen in this project's folder. Without one it has no folder to work in.", &b.new_in_project);
            divider(c, k);
        }
        switchLine(c, a, k, "new-primary", "Primary", "Your default contact. It knows your other bots, says whose job a request is, and waits for your yes before anything starts.", &b.new_primary);
    }
    space(c, 18);
    {
        const foot = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer foot.end();
        const ready = bots.validName(name) and job.len > 0 and !b.busy;
        if (button(c, k, "new-create", "Create", .solid, ready) or (entered and ready)) bots.act(a, .{
            .action = "create",
            .bot = name,
            .text = job,
            .project = if (project != null and b.new_in_project) project.?.path else null,
            .primary = if (b.new_primary) true else null,
        });
        if (button(c, k, "new-cancel", "Cancel", .plain, true)) bots.close(a);
    }
}
