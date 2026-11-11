//! The main bot's work, on its page: what it has in progress, what is
//! scheduled, and what it finished, across every project. All of it is read
//! from what the app already has: the chats its thread started (bots.zig
//! `work`) and every bot's routines. Nothing here starts or stops anything
//! but a click that opens a chat or a bot.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const workspace = @import("workspace.zig");
const bots = @import("bots.zig");
const group = @import("view_bots.zig");
const page = @import("view_bots_page.zig");
const App = @import("app.zig").App;

/// Rows a section shows before it says how many more there are.
const cap = 8;

fn glyph(c: *ui.Context, k: theme.Colors, mark: workspace.Mark) void {
    const s = ui.div(c).row().size(13, 13).center();
    defer s.end();
    switch (mark) {
        .working => kit.snake(c, k),
        .awaiting_input => kit.dot(c, 6, k.accent),
        .errored => kit.dot(c, 6, k.danger.alpha(0.8)),
        .completed => icons.icon(c, .check, 11, k.success.alpha(0.9), 0),
        .idle => kit.dot(c, 6, k.ink(0.14)),
    }
}

/// One chat the main bot started: what it is, where, and how it stands.
fn workRow(c: *ui.Context, a: *App, k: theme.Colors, w: bots.Work, inner_w: f32, at: i64) void {
    ui.key(c, c.print("work-{s}", .{w.chat.id}));
    const row = ui.div(c).row().wFull().px(16).py(10).gap(10).itemsCenter().hover(k.ink(0.04));
    defer row.end();
    glyph(c, k, w.mark);
    const where = group.projectOf(a, w.chat);
    const note: []const u8 = switch (w.mark) {
        .working => "Working",
        .awaiting_input => "Needs you",
        .errored => "Failed",
        .completed, .idle => rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, at, w.chat.timeMs()),
    };
    const where_w: f32 = if (where.len > 0) c.text.width(where, .{ .size = 12 }) + 10 else 0;
    const note_w: f32 = c.text.width(note, .{ .size = 12 }) + 10;
    kit.fadeText(c, w.chat.title orelse "New chat", kit.style(c, 13, 18, .{ .color = k.text }), @max(inner_w - 2 - 2 * 16 - 13 - 10 - where_w - note_w - 10, 80));
    if (where.len > 0) ui.text(c, where, .{ .size = 12, .line_height = 18, .color = k.muted.alpha(0.75) });
    ui.spacer(c);
    ui.text(c, note, .{ .size = 12, .line_height = 18, .color = switch (w.mark) {
        .awaiting_input => k.accent,
        .errored => k.danger,
        else => k.muted.alpha(0.75),
    } });
    if (row.clicked()) {
        a.bots.page = .none;
        a.openChatInTab(w.chat.id);
    }
}

fn empty(c: *ui.Context, k: theme.Colors, text: []const u8, inner_w: f32) void {
    const none = ui.div(c).row().wFull().px(16).py(11);
    defer none.end();
    page.line(c, text, 12.5, k.muted.alpha(0.7), inner_w - 2 - 2 * 16);
}

fn more(c: *ui.Context, k: theme.Colors, left: usize) void {
    if (left == 0) return;
    page.divider(c, k);
    const row = ui.div(c).row().wFull().px(16).py(8);
    defer row.end();
    ui.text(c, c.print("and {d} more", .{left}), .{ .size = 12, .line_height = 17, .color = k.muted.alpha(0.65) });
}

const Slot = struct { bot: []const u8, routine: bots.Routine };

/// In progress, Scheduled and Completed, under the main bot's message box.
pub fn sections(c: *ui.Context, a: *App, k: theme.Colors, bot: bots.Bot, inner_w: f32) void {
    const at = bots.now(a);
    const all = bots.work(c.alloc(), bot, a.chats.items, a.sessions.items, at);

    page.sectionLabel(c, k, "In progress");
    {
        const cd = page.card(c, k);
        defer cd.end();
        var shown: usize = 0;
        var total: usize = 0;
        for (all) |w| if (w.open()) {
            total += 1;
            if (shown == cap) continue;
            if (shown > 0) page.divider(c, k);
            shown += 1;
            workRow(c, a, k, w, inner_w, at);
        };
        if (total == 0) empty(c, k, c.print("Nothing right now. Ask {s} for something in any project: it starts a chat there and tells you here what came back.", .{bot.name}), inner_w);
        more(c, k, total - shown);
    }

    // Every bot's routines: the main bot's own, and its helpers'.
    var slots: std.ArrayList(Slot) = .empty;
    for (a.bots.list.items) |other| for (other.routines) |r| {
        if (!r.done and !r.paused) slots.append(c.alloc(), .{ .bot = other.name, .routine = r }) catch {};
    };
    std.sort.insertion(Slot, slots.items, {}, struct {
        fn sooner(_: void, x: Slot, y: Slot) bool {
            return x.routine.at_ms < y.routine.at_ms;
        }
    }.sooner);
    page.sectionLabel(c, k, "Scheduled");
    {
        const cd = page.card(c, k);
        defer cd.end();
        for (slots.items[0..@min(slots.items.len, cap)], 0..) |s, ix| {
            if (ix > 0) page.divider(c, k);
            ui.key(c, c.print("slot-{s}-{s}", .{ s.bot, s.routine.id }));
            const row = ui.div(c).row().wFull().px(16).py(10).gap(10).itemsCenter().hover(k.ink(0.04));
            defer row.end();
            var e: [40]u8 = undefined;
            var u: [24]u8 = undefined;
            // Copied into the frame: the text outlives this row's buffer.
            const next = c.print("{s}", .{bots.until(&u, s.routine.at_ms, at)});
            const next_w = c.text.width(next, .{ .size = 12 }) + 10;
            kit.fadeText(c, c.print("{s} · {s} · {s}", .{ s.bot, bots.every(&e, s.routine.interval_ms), s.routine.instruction }), kit.style(c, 13, 18, .{ .color = k.text }), @max(inner_w - 2 - 2 * 16 - next_w - 10, 80));
            ui.spacer(c);
            ui.text(c, next, .{ .size = 12, .line_height = 18, .color = if (s.routine.missed_open > 0) k.warning else k.muted.alpha(0.75) });
            if (row.clicked() and !std.mem.eql(u8, s.bot, bot.name)) bots.openBot(a, s.bot);
        }
        if (slots.items.len == 0) empty(c, k, "Nothing scheduled. A routine is added on a bot's page. Routines run only while Harness is open.", inner_w);
        more(c, k, slots.items.len - @min(slots.items.len, cap));
    }

    page.sectionLabel(c, k, "Completed");
    {
        const cd = page.card(c, k);
        defer cd.end();
        var shown: usize = 0;
        var total: usize = 0;
        for (all) |w| if (!w.open()) {
            total += 1;
            if (shown == cap) continue;
            if (shown > 0) page.divider(c, k);
            shown += 1;
            workRow(c, a, k, w, inner_w, at);
        };
        if (total == 0) empty(c, k, "Nothing yet.", inner_w);
        more(c, k, total - shown);
    }
}
