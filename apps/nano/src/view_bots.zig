//! Bots in the sidebar and on a bot's chat. The Bots group sits under the
//! chats on every project filter: a bot is a contact, not a chat in one
//! folder. Its header says how many things need looking at, and opens the
//! catch-up (view_bots_page.zig). A bot's standing chat is listed here and
//! nowhere else, and wears a strip naming the bot.
//!
//! The main bot comes first, with the work it started under it: chats in
//! any project that are still going or have something to read. Its helpers
//! follow.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const workspace = @import("workspace.zig");
const bots = @import("bots.zig");
const App = @import("app.zig").App;

/// Rows shown before the group scrolls: chats keep the rest of the sidebar.
const cap_rows = 6;
const row_h: f32 = 30;

/// The last part of a folder's path: the project a bot works in.
pub fn folder(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const at = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    return trimmed[at + 1 ..];
}

/// The project a chat is in: its project's name, else its folder's.
pub fn projectOf(a: *const App, ch: workspace.Chat) []const u8 {
    if (a.findSpace(ch.space_id)) |s| return s.name;
    return if (ch.cwd) |cwd| folder(cwd) else "";
}

/// How many of the main bot's chats the sidebar lists before its page does.
const cap_work = 4;

/// A chat the main bot started, under its row.
fn workRow(c: *ui.Context, a: *App, k: theme.Colors, w: bots.Work) void {
    ui.key(c, c.print("bot-work-{s}", .{w.chat.id}));
    const selected = a.bots.page == .none and a.selected != null and std.mem.eql(u8, a.selected.?, w.chat.id);
    var r = ui.div(c).row().wFull().h(row_h - 4).pl(27).pr(8).gap(6).itemsCenter().rounded(8);
    r = if (selected) r.bg(k.selected) else r.hover(k.hover);
    defer r.end();
    statusSlot(c, k, w.mark, false);
    const where = projectOf(a, w.chat);
    const where_w: f32 = if (where.len > 0) c.text.width(where, .{ .size = 11 }) + 6 else 0;
    kit.fadeText(c, w.chat.title orelse "New chat", kit.style(c, 12.5, 17, .{ .color = if (selected) k.text else k.text.alpha(0.8) }), @max(@import("view_sidebar.zig").widthOf(a) - 16 - 27 - 8 - 13 - 6 - where_w - 6, 24));
    ui.spacer(c);
    if (where.len > 0) ui.text(c, where, .{ .size = 11, .color = k.faint });
    if (r.clicked()) {
        a.bots.page = .none;
        a.openChatInTab(w.chat.id);
    }
}

fn statusSlot(c: *ui.Context, k: theme.Colors, mark: workspace.Mark, missed: bool) void {
    const s = ui.div(c).row().size(13, 13).center();
    defer s.end();
    switch (mark) {
        .working => kit.snake(c, k),
        .completed => icons.icon(c, .check, 11, k.success.alpha(0.9), 0),
        .awaiting_input => kit.dot(c, 6, k.accent),
        .errored => kit.dot(c, 6, k.danger.alpha(0.8)),
        .idle => kit.dot(c, 6, if (missed) k.warning.alpha(0.85) else k.ink(0.14)),
    }
}

/// What a row says at its right edge: what the bot needs, else when it
/// last spoke.
fn rowNote(c: *ui.Context, a: *App, bot: bots.Bot, mark: workspace.Mark, missed: bool, at: i64) struct { text: []const u8, loud: bool } {
    return switch (mark) {
        .awaiting_input => .{ .text = "Needs you", .loud = true },
        .errored => .{ .text = "Failed", .loud = true },
        .working => .{ .text = "", .loud = false },
        .completed, .idle => blk: {
            if (missed and mark == .idle) break :blk .{ .text = "Did not run", .loud = true };
            // The main bot between turns: how much of what it started is still going.
            if (bot.primary) {
                const going = bots.openCount(bots.work(c.alloc(), bot, a.chats.items, a.sessions.items, at));
                if (going > 0) break :blk .{ .text = c.print("{d} going", .{going}), .loud = false };
            }
            const ch = if (bot.chat.len > 0) a.findChat(bot.chat) else null;
            if (ch) |x| break :blk .{ .text = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, at, x.timeMs()), .loud = false };
            break :blk .{ .text = "", .loud = false };
        },
    };
}

fn botRow(c: *ui.Context, a: *App, k: theme.Colors, bot: bots.Bot, at: i64) void {
    ui.key(c, c.print("bot-{s}", .{bot.name}));
    const on_chat = a.bots.page == .none and a.selected != null and bot.chat.len > 0 and std.mem.eql(u8, a.selected.?, bot.chat);
    const on_page = a.bots.page == .bot and std.mem.eql(u8, a.bots.focus.items, bot.name);
    const selected = on_chat or on_page;
    var r = ui.div(c).row().wFull().h(row_h).px(8).gap(6).itemsCenter().rounded(8);
    r = if (selected) r.bg(k.selected) else r.hover(k.hover);
    defer r.end();
    var missed = false;
    for (bot.routines) |rt| missed = missed or rt.missed_open > 0;
    const mark = bots.markOf(bot, a.chats.items, a.sessions.items, at);
    statusSlot(c, k, mark, missed);
    const note = rowNote(c, a, bot, mark, missed, at);
    const mark_w: f32 = if (bot.project.len > 0) c.text.width(folder(bot.project), .{ .size = 11 }) + 6 else 0;
    const note_w: f32 = if (note.text.len > 0) c.text.width(note.text, .{ .size = 11 }) + 6 else 0;
    const name_w = @max(@import("view_sidebar.zig").widthOf(a) - 16 - 16 - 13 - 6 - mark_w - note_w - 6, 24);
    kit.fadeText(c, bot.name, kit.style(c, 13, 17, .{ .color = if (selected) k.text else k.text.alpha(0.85) }), name_w);
    // The project it works in; the primary bot has none to show.
    if (bot.project.len > 0) ui.text(c, folder(bot.project), .{ .size = 11, .color = k.faint });
    ui.spacer(c);
    if (note.text.len > 0) ui.text(c, note.text, .{ .size = 11, .color = if (note.loud) (if (mark == .errored) k.danger else if (mark == .awaiting_input) k.accent else k.warning) else k.subline });
    if (r.clicked()) bots.openRow(a, bot);
}

/// The Bots group: under the chats, above the footer.
pub fn group(c: *ui.Context, a: *App, k: theme.Colors) void {
    bots.sync(a, c);
    const b = &a.bots;
    // Until the engine has answered there is nothing true to draw, and
    // while bots are off there is nothing to draw at all.
    if (b.phase != .loaded or !b.enabled) return;
    const at = bots.now(a);
    const list = b.list.items;
    const its = bots.items(c.alloc(), list, a.chats.items, a.sessions.items, at);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border.alpha(0.6) }, .none, null);
    const g = ui.div(c).column().wFull().px(8).pt(4).pb(4).gap(2);
    defer g.end();
    {
        ui.key(c, "bots-header");
        const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(8);
        defer h.end();
        const quiet = if (k.is_harp) k.muted else k.muted.alpha(0.5);
        ui.text(c, if (b.group_open or list.len == 0) "Bots" else c.print("Bots ({d})", .{list.len}), .{ .size = 11.5, .weight = theme.ui_medium_weight, .color = quiet });
        ui.spacer(c);
        var acted = false;
        if (its.len > 0) {
            // What needs looking at, in one place: the catch-up.
            ui.key(c, "bots-inbox");
            var pill = ui.div(c).row().h(18).px(7).itemsCenter().roundedFull();
            pill = if (b.page == .inbox) pill.bg(k.accent.alpha(0.28)) else pill.bg(k.accent.alpha(0.16)).hover(k.accent.alpha(0.28));
            defer pill.end();
            ui.text(c, c.print("{d} to look at", .{its.len}), .{ .size = 11, .weight = theme.ui_medium_weight, .color = k.accent });
            if (pill.clicked()) {
                bots.openInbox(a);
                acted = true;
            }
        }
        {
            ui.key(c, "bots-new");
            const add = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
            defer add.end();
            icons.icon(c, .plus, 13, quiet, 0);
            if (add.clicked()) {
                bots.openNew(a);
                acted = true;
            }
        }
        if (list.len > 0) icons.icon(c, if (b.group_open) .@"alt-arrow-down" else .@"alt-arrow-right", 12, quiet, 0);
        if (h.clicked() and !acted and list.len > 0) {
            b.group_open = !b.group_open;
            a.redraw();
        }
    }
    if (list.len == 0) {
        const none = ui.div(c).row().wFull().h(row_h).px(8).itemsCenter();
        defer none.end();
        ui.text(c, "None yet. A bot keeps one job and its own memory.", .{ .size = 11.5, .color = k.faint });
        return;
    }
    if (!b.group_open) return;
    // Under the main bot: what it started that is still going or unread.
    const main_bot = b.main();
    var under: std.ArrayList(bots.Work) = .empty;
    for (bots.work(c.alloc(), main_bot, a.chats.items, a.sessions.items, at)) |w| {
        if (w.mark != .idle and under.items.len < cap_work) under.append(c.alloc(), w) catch {};
    }
    // Many bots scroll; the main bot's work adds its own room above them.
    const scrolls = list.len > cap_rows;
    if (scrolls) ui.scroll(c, .{ .width = .fill, .height = .{ .px = cap_rows * (row_h + 2) + @as(f32, @floatFromInt(under.items.len)) * (row_h - 2) }, .gap = 2 });
    defer if (scrolls) ui.end(c);
    if (main_bot) |bot| {
        botRow(c, a, k, bot, at);
        for (under.items) |w| workRow(c, a, k, w);
    }
    for (list) |bot| if (!bot.primary) botRow(c, a, k, bot, at);
}

/// Over a bot's standing chat: whose conversation this is, and the way to
/// its job, routines and memory.
pub fn strip(c: *ui.Context, a: *App, k: theme.Colors, width: f32) void {
    const id = a.selected orelse return;
    const bot = a.bots.ofChat(id) orelse return;
    ui.key(c, "bot-strip");
    const outer = ui.div(c).row().wFull().justifyCenter();
    defer outer.end();
    const s = ui.div(c).row().w(width).h(34).px(4).gap(8).itemsCenter();
    defer s.end();
    kit.dot(c, 6, k.accent.alpha(0.7));
    ui.text(c, bot.name, .{ .size = 13, .weight = .semibold, .color = k.text });
    const details_w: f32 = 64;
    const job_w = @max(width - 8 - 6 - c.text.width(bot.name, .{ .size = 13, .weight = .semibold }) - 3 * 8 - details_w, 40);
    kit.fadeText(c, bot.job, kit.style(c, 12, 16, .{ .color = k.muted }), job_w);
    ui.spacer(c);
    ui.key(c, "bot-strip-details");
    const d = ui.div(c).row().px(9).py(4).rounded(7).border(k.border).borderW(1).hover(k.ink(0.06));
    defer d.end();
    ui.text(c, "Details", .{ .size = 11.5, .color = if (d.hovered()) k.text else k.muted });
    if (d.clicked()) bots.openBot(a, bot.name);
}

test "the project a bot works in is its folder's name" {
    try std.testing.expectEqualStrings("comet", folder("/Users/alex/code/comet"));
    try std.testing.expectEqualStrings("comet", folder("/repo/comet/"));
    try std.testing.expectEqualStrings("comet", folder("comet"));
    try std.testing.expectEqualStrings("atlas", folder("C:\\code\\atlas"));
}
