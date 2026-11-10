//! graff Bots: the user's standing roles, as the engine reports them
//! (`BotsState`; crates/engine/src/bots.rs). Each has one job, its own
//! memory, routines it starts by itself, and one standing chat.
//!
//! The list is the engine's; what happened while the user was away is
//! worked out here from it and from the chats and sessions the sidebar
//! already has, so there is no second copy of anything to drift.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Routine = struct {
    id: []const u8,
    instruction: []const u8,
    /// The next slot, and the period (0: it runs once).
    at_ms: i64 = 0,
    interval_ms: i64 = 0,
    paused: bool = false,
    done: bool = false,
    runs: i64 = 0,
    last_run_ms: i64 = 0,
    /// The first slot that came due while nothing was checking, and how many.
    missed_at_ms: i64 = 0,
    missed_open: i64 = 0,
};

pub const Bot = struct {
    name: []const u8,
    job: []const u8,
    model: []const u8 = "",
    /// The folder its runs work in; "" when it has none.
    project: []const u8 = "",
    primary: bool = false,
    /// Its standing chat; "" until its first run.
    chat: []const u8 = "",
    routines: []Routine = &.{},
};

fn int(o: json.ObjectMap, key: []const u8) i64 {
    return if (o.get(key)) |v| (if (v == .integer) v.integer else 0) else 0;
}

fn flag(o: json.ObjectMap, key: []const u8) bool {
    return if (o.get(key)) |v| (v == .bool and v.bool) else false;
}

fn parseBot(a: Allocator, o: json.ObjectMap) ?Bot {
    const str = workspace.str;
    var routines: std.ArrayList(Routine) = .empty;
    if (o.get("routines")) |list| if (list == .array) for (list.array.items) |v| if (v == .object) {
        const r = v.object;
        routines.append(a, .{
            .id = str(a, r, "id") orelse continue,
            .instruction = str(a, r, "instruction") orelse "",
            .at_ms = int(r, "atMs"),
            .interval_ms = int(r, "intervalMs"),
            .paused = flag(r, "paused"),
            .done = flag(r, "done"),
            .runs = int(r, "runs"),
            .last_run_ms = int(r, "lastRunMs"),
            .missed_at_ms = int(r, "missedAtMs"),
            .missed_open = int(r, "missedOpen"),
        }) catch {};
    };
    return .{
        .name = str(a, o, "name") orelse return null,
        .job = str(a, o, "job") orelse "",
        .model = str(a, o, "model") orelse "",
        .project = str(a, o, "project") orelse "",
        .primary = flag(o, "primary"),
        .chat = str(a, o, "chat") orelse "",
        .routines = routines.items,
    };
}

pub const List = workspace.List(Bot, parseBot);

/// What the main column shows in the chat's place.
pub const Page = enum { none, inbox, bot, new };

pub const Bots = struct {
    /// `absent`: this engine has no bots at all, so nothing is drawn or asked.
    phase: enum { idle, loading, loaded, failed, absent } = .idle,
    list: List,
    failure: std.ArrayList(u8) = .empty,
    /// An action's error, over the page; cleared by a click.
    notice: std.ArrayList(u8) = .empty,
    /// When routines were last checked, and the last stretch nothing did.
    last_check_ms: i64 = 0,
    gap_from_ms: i64 = 0,
    gap_to_ms: i64 = 0,
    about: std.ArrayList(u8) = .empty,
    /// When the list was last asked for.
    asked_ms: i64 = 0,
    busy: bool = false,
    page: Page = .none,
    /// The bot the `bot` page is about, and the one the memory and log are of.
    focus: std.ArrayList(u8) = .empty,
    detail_of: std.ArrayList(u8) = .empty,
    memory: std.ArrayList(u8) = .empty,
    log: std.ArrayList(u8) = .empty,
    /// A chat a run just made: opened when its row arrives.
    opening: std.ArrayList(u8) = .empty,
    group_open: bool = true,
    /// Whether the first list of this launch has been looked at for a
    /// catch-up. Only a launch moves the window; later it is a line.
    launch_seen: bool = false,
    confirm_delete: bool = false,
    /// A fixed clock for scenes and tests; the wall clock otherwise.
    clock_ms: ?i64 = null,
    new_primary: bool = false,
    new_in_project: bool = true,
    message: ui.TextBuffer = .{},
    name: ui.TextBuffer = .{},
    job: ui.TextBuffer = .{},
    when: ui.TextBuffer = .{},
    instruction: ui.TextBuffer = .{},
    about_edit: ui.TextBuffer = .{},

    pub fn init(gpa: Allocator) Bots {
        return .{ .list = .init(gpa) };
    }

    pub fn deinit(b: *Bots, gpa: Allocator) void {
        b.list.deinit();
        inline for (.{ "failure", "notice", "about", "focus", "detail_of", "memory", "log", "opening" }) |f| @field(b, f).deinit(gpa);
        inline for (.{ "message", "name", "job", "when", "instruction", "about_edit" }) |f| @field(b, f).deinit();
    }

    pub fn find(b: *const Bots, name: []const u8) ?Bot {
        for (b.list.items) |bot| if (std.mem.eql(u8, bot.name, name)) return bot;
        return null;
    }

    /// The bot whose standing chat `chat_id` is.
    pub fn ofChat(b: *const Bots, chat_id: []const u8) ?Bot {
        for (b.list.items) |bot| if (bot.chat.len > 0 and std.mem.eql(u8, bot.chat, chat_id)) return bot;
        return null;
    }

    pub fn focused(b: *const Bots) ?Bot {
        return if (b.focus.items.len > 0) b.find(b.focus.items) else null;
    }
};

/// The time the bots' views read: a scene's, or the wall clock.
pub fn now(a: *const App) i64 {
    return a.bots.clock_ms orelse a.nowMs();
}

/// The user's offset from UTC, for clock times. A scene's clock is UTC.
pub fn offset(a: *const App) i64 {
    return if (a.bots.clock_ms != null) 0 else workspace.utcOffsetSeconds(a.nowMs());
}

fn setText(a: *App, list: *std.ArrayList(u8), text: []const u8) void {
    list.clearRetainingCapacity();
    list.appendSlice(a.gpa, text) catch {};
}

// ── what needs looking at ────────────────────────────────────────────

pub const Kind = enum { waiting, failed, done, missed };

/// Something a bot did, needs, or did not do.
pub const Item = struct {
    kind: Kind,
    bot: []const u8,
    /// A missed routine's id and words; "" otherwise.
    routine: []const u8 = "",
    text: []const u8 = "",
    at_ms: i64 = 0,
    /// How many slots were missed.
    count: i64 = 0,
};

/// A bot's status, from its standing chat (`workspace.markOf`).
pub fn markOf(bot: Bot, chats: []const workspace.Chat, sessions: []const workspace.Session, now_ms: i64) workspace.Mark {
    if (bot.chat.len == 0) return .idle;
    for (chats) |ch| if (std.mem.eql(u8, ch.id, bot.chat)) return workspace.markOf(ch, workspace.sessionOf(sessions, ch.id), now_ms);
    return .idle;
}

fn chatOf(bot: Bot, chats: []const workspace.Chat) ?workspace.Chat {
    if (bot.chat.len == 0) return null;
    for (chats) |ch| if (std.mem.eql(u8, ch.id, bot.chat)) return ch;
    return null;
}

/// Everything to look at, most pressing first: a question waiting on the
/// user, a failed run, a finished one not yet read, then what was due and
/// did not run. An item leaves when its cause does: the question is
/// answered, the chat is read, the missed slot is run or dismissed.
pub fn items(alloc: Allocator, bots: []const Bot, chats: []const workspace.Chat, sessions: []const workspace.Session, now_ms: i64) []const Item {
    var out: std.ArrayList(Item) = .empty;
    inline for (.{ Kind.waiting, Kind.failed, Kind.done }) |want| {
        for (bots) |bot| {
            const kind: ?Kind = switch (markOf(bot, chats, sessions, now_ms)) {
                .awaiting_input => .waiting,
                .errored => .failed,
                .completed => .done,
                .working, .idle => null,
            };
            if (kind != null and kind.? == want) {
                const ch = chatOf(bot, chats);
                out.append(alloc, .{ .kind = want, .bot = bot.name, .text = if (ch) |x| x.preview orelse "" else "", .at_ms = if (ch) |x| x.last_message_ms else 0 }) catch {};
            }
        }
    }
    for (bots) |bot| for (bot.routines) |r| {
        if (r.missed_open > 0) out.append(alloc, .{ .kind = .missed, .bot = bot.name, .routine = r.id, .text = r.instruction, .at_ms = r.missed_at_ms, .count = r.missed_open }) catch {};
    };
    return out.items;
}

/// A launch opens on the catch-up when nothing checked for a while just
/// before it and there is something to report. Ten minutes covers the
/// engine's first check and the list reaching the window.
pub fn opensOnCatchUp(gap_to_ms: i64, now_ms: i64, item_count: usize) bool {
    return item_count > 0 and gap_to_ms > 0 and now_ms - gap_to_ms < 10 * std.time.ms_per_min;
}

/// `22:41` in the user's time.
pub fn clock(buf: []u8, ms: i64, offset_s: i64) []const u8 {
    const day: i64 = @mod(@divFloor(ms, 1000) + offset_s, std.time.s_per_day);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(day, 3600))), @as(u64, @intCast(@divFloor(@mod(day, 3600), 60))) }) catch "";
}

/// The honest line about a night: nothing checked between these times.
/// Why (asleep, quit) is not known, so it is not said.
pub fn gapLine(buf: []u8, from_ms: i64, to_ms: i64, offset_s: i64) []const u8 {
    if (to_ms <= 0 or from_ms <= 0) return "";
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    return std.fmt.bufPrint(buf, "Nothing was checking routines from {s} to {s}. Nothing ran in between.", .{ clock(&a, from_ms, offset_s), clock(&b, to_ms, offset_s) }) catch "";
}

/// `Every 6 hours`, `Every 90 minutes`, `Once`.
pub fn every(buf: []u8, interval_ms: i64) []const u8 {
    if (interval_ms <= 0) return "Once";
    const units = [_]struct { ms: i64, one: []const u8, many: []const u8 }{
        .{ .ms = std.time.ms_per_day, .one = "day", .many = "days" },
        .{ .ms = std.time.ms_per_hour, .one = "hour", .many = "hours" },
        .{ .ms = std.time.ms_per_min, .one = "minute", .many = "minutes" },
    };
    for (units) |u| if (@mod(interval_ms, u.ms) == 0) {
        const n = @divExact(interval_ms, u.ms);
        return if (n == 1) std.fmt.bufPrint(buf, "Every {s}", .{u.one}) catch "" else std.fmt.bufPrint(buf, "Every {d} {s}", .{ n, u.many }) catch "";
    };
    return std.fmt.bufPrint(buf, "Every {d} seconds", .{@divTrunc(interval_ms, 1000)}) catch "";
}

/// `in 1h 52m`, `in 4m`, `now`.
pub fn until(buf: []u8, at_ms: i64, now_ms: i64) []const u8 {
    const mins = @divFloor(at_ms - now_ms + std.time.ms_per_min - 1, std.time.ms_per_min);
    if (mins <= 0) return "now";
    if (mins < 60) return std.fmt.bufPrint(buf, "in {d}m", .{mins}) catch "";
    const hours = @divFloor(mins, 60);
    if (hours < 48) return if (@mod(mins, 60) == 0) std.fmt.bufPrint(buf, "in {d}h", .{hours}) catch "" else std.fmt.bufPrint(buf, "in {d}h {d}m", .{ hours, @mod(mins, 60) }) catch "";
    return std.fmt.bufPrint(buf, "in {d}d", .{@divFloor(hours, 24)}) catch "";
}

/// A bot's name: lowercase letters, digits, - and _, 32 at most.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or name[0] == '-' or name[0] == '_') return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

// ── the engine ───────────────────────────────────────────────────────

/// How often the list is asked for again: with bots, often enough to see a
/// routine's chat appear; without, only to notice one made in a terminal.
const poll_ms = 30 * std.time.ms_per_s;
const idle_poll_ms = 5 * std.time.ms_per_min;

/// Called as the window draws: keeps the list fresh, and opens the chat a
/// run just made once its row is here. The first list is asked for when
/// the engine connects (`connected`), with the sidebar's watches.
pub fn sync(a: *App, c: *ui.Context) void {
    const b = &a.bots;
    if (b.opening.items.len > 0 and a.findChat(b.opening.items) != null) {
        var id: [64]u8 = undefined;
        const n = @min(id.len, b.opening.items.len);
        @memcpy(id[0..n], b.opening.items[0..n]);
        b.opening.clearRetainingCapacity();
        b.page = .none;
        a.openChatInTab(id[0..n]);
    }
    if (!a.engine.up() or a.offscreen) return;
    if (b.phase != .loaded and b.phase != .failed) return;
    const every_ms: i64 = if (b.list.items.len > 0) poll_ms else idle_poll_ms;
    if (a.nowMs() - b.asked_ms >= every_ms) refresh(a);
    c.frameIn(@as(f32, @floatFromInt(every_ms)) / 1000);
}

/// The engine is here: ask for the bots, as the sidebar asks for its lists.
pub fn connected(a: *App) void {
    if (a.bots.phase == .absent) return;
    // Each of the sidebar's streams reopening calls this; one ask is enough.
    if (a.bots.asked_ms != 0 and a.nowMs() - a.bots.asked_ms < 2 * std.time.ms_per_s) return;
    refresh(a);
}

pub fn refresh(a: *App) void {
    if (a.bots.phase == .idle) a.bots.phase = .loading;
    a.bots.asked_ms = a.nowMs();
    a.request(requests.none("BotsState"), .of(App, a, onState));
}

fn onState(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| apply(a, v) catch fail(a, "Unexpected reply"),
        // An engine from before bots has no such method: no bots, no error.
        .err => |e| if (std.mem.startsWith(u8, e, "unknown method")) {
            a.bots.phase = .absent;
        } else fail(a, if (std.mem.eql(u8, e, "not connected")) "Engine not connected" else e),
        else => {},
    }
    a.redraw();
}

fn fail(a: *App, why: []const u8) void {
    // A list already shown stays; the failure is for a first load.
    if (a.bots.phase == .loaded) return;
    a.bots.phase = .failed;
    setText(a, &a.bots.failure, why);
}

/// Take a `BotsState` reply. The first one of a launch decides whether the
/// window opens on the catch-up.
pub fn apply(a: *App, v: json.Value) !void {
    if (v != .object) return error.BadItem;
    const b = &a.bots;
    try b.list.replace(v.object.get("bots") orelse return error.BadItem);
    b.last_check_ms = int(v.object, "lastCheckMs");
    b.gap_from_ms = int(v.object, "gapFromMs");
    b.gap_to_ms = int(v.object, "gapToMs");
    setText(a, &b.about, if (v.object.get("about")) |s| (if (s == .string) s.string else "") else "");
    b.phase = .loaded;
    // A bot that is gone takes its page with it.
    if (b.page == .bot and b.focused() == null) b.page = .none;
    if (!b.launch_seen) {
        b.launch_seen = true;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const at = now(a);
        if (opensOnCatchUp(b.gap_to_ms, at, items(arena.allocator(), b.list.items, a.chats.items, a.sessions.items, at).len)) openInbox(a);
    }
}

pub fn openInbox(a: *App) void {
    a.view.settings_open = false;
    a.bots.page = .inbox;
    a.redraw();
}

/// A bot's page: its job, routines and memory. Its memory is asked for.
pub fn openBot(a: *App, name: []const u8) void {
    const b = &a.bots;
    a.view.settings_open = false;
    setText(a, &b.focus, name);
    b.page = .bot;
    b.confirm_delete = false;
    b.notice.clearRetainingCapacity();
    if (!std.mem.eql(u8, b.detail_of.items, name)) {
        b.memory.clearRetainingCapacity();
        b.log.clearRetainingCapacity();
        setText(a, &b.detail_of, name);
    }
    if (std.mem.eql(u8, b.about_edit.text(), "")) b.about_edit.set(b.about.items);
    a.request(requests.botDetail(name), .of(App, a, onDetail));
    a.redraw();
}

/// A row in the Bots group: its chat when it has one, else its page.
pub fn openRow(a: *App, bot: Bot) void {
    if (bot.chat.len > 0 and a.findChat(bot.chat) != null) {
        a.bots.page = .none;
        return a.openChatInTab(bot.chat);
    }
    openBot(a, bot.name);
}

pub fn openNew(a: *App) void {
    const b = &a.bots;
    a.view.settings_open = false;
    b.page = .new;
    b.notice.clearRetainingCapacity();
    b.name.clear();
    b.job.clear();
    b.new_primary = b.list.items.len == 0;
    b.new_in_project = true;
    a.redraw();
}

pub fn close(a: *App) void {
    a.bots.page = .none;
    a.redraw();
}

fn onDetail(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| if (v == .object) {
            const o = v.object;
            setText(a, &a.bots.memory, if (o.get("memory")) |s| (if (s == .string) s.string else "") else "");
            setText(a, &a.bots.log, if (o.get("log")) |s| (if (s == .string) s.string else "") else "");
        },
        else => {},
    }
    a.redraw();
}

/// One change to the bots. The reply is the list after it.
pub fn act(a: *App, p: requests.BotAction) void {
    if (a.bots.busy) return;
    a.bots.busy = true;
    a.bots.notice.clearRetainingCapacity();
    a.request(requests.botAction(p), .of(App, a, onActed));
}

fn onActed(a: *App, _: u64, r: rpc.Reply) void {
    const b = &a.bots;
    b.busy = false;
    switch (r) {
        .ok => |v| {
            apply(a, v) catch setText(a, &b.notice, "Unexpected reply");
            // A page that made a bot becomes that bot's page.
            if (b.page == .new) {
                var name: [32]u8 = undefined;
                const typed = std.mem.trim(u8, b.name.text(), " \t");
                const n = @min(name.len, typed.len);
                @memcpy(name[0..n], typed[0..n]);
                if (b.find(name[0..n]) != null) openBot(a, name[0..n]);
            } else if (b.page == .bot) {
                if (b.focused()) |bot| a.request(requests.botDetail(bot.name), .of(App, a, onDetail));
            }
            b.confirm_delete = false;
        },
        .err => |e| setText(a, &b.notice, e),
        else => {},
    }
    a.redraw();
}

/// Start a turn in the bot's standing chat: a message, or a routine now.
pub fn run(a: *App, bot: []const u8, message: ?[]const u8, routine: ?[]const u8) void {
    if (a.bots.busy) return;
    a.bots.busy = true;
    a.bots.notice.clearRetainingCapacity();
    a.request(requests.runBot(bot, message, routine), .of(App, a, onRan));
}

fn onRan(a: *App, _: u64, r: rpc.Reply) void {
    const b = &a.bots;
    b.busy = false;
    switch (r) {
        .ok => |v| {
            b.message.clear();
            if (v == .object) if (v.object.get("chatId")) |id| if (id == .string) setText(a, &b.opening, id.string);
            refresh(a);
        },
        .err => |e| setText(a, &b.notice, e),
        else => {},
    }
    a.redraw();
}

const testing = std.testing;

fn made(name: []const u8, chat: []const u8, routines: []Routine) Bot {
    return .{ .name = name, .job = "job", .chat = chat, .routines = routines };
}

test "what needs looking at: a question first, then a failure, a finished run, a missed routine" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at: i64 = 1_000_000;
    var missed = [_]Routine{ .{ .id = "r1", .instruction = "Label unlabeled issues", .missed_at_ms = 400, .missed_open = 2 }, .{ .id = "r2", .instruction = "quiet" } };
    const bots = [_]Bot{ made("ada", "", &.{}), made("notes", "c-notes", &.{}), made("triage", "c-triage", &missed), made("deps", "c-deps", &.{}), made("busy", "c-busy", &.{}), made("read", "c-read", &.{}) };
    const base: workspace.Chat = .{ .id = "", .title = null, .space_id = null, .archived = false, .preview = null, .harness = null, .model = null, .cwd = null };
    var chats: [5]workspace.Chat = @splat(base);
    chats[0].id = "c-notes";
    chats[0].last_message_ms = 900;
    chats[0].last_seen_ms = 100;
    chats[0].preview = "Draft is ready";
    chats[1].id = "c-triage";
    chats[1].last_message_ms = 800;
    chats[2].id = "c-deps";
    chats[3].id = "c-busy";
    chats[4].id = "c-read";
    chats[4].last_message_ms = 500;
    chats[4].last_seen_ms = 600;
    const sessions = [_]workspace.Session{
        .{ .chat_id = "c-triage", .status = .errored, .updated_ms = at },
        .{ .chat_id = "c-deps", .status = .awaiting_input, .updated_ms = at },
        .{ .chat_id = "c-busy", .status = .working, .updated_ms = at },
    };
    const got = items(arena.allocator(), &bots, &chats, &sessions, at);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqual(Kind.waiting, got[0].kind);
    try testing.expectEqualStrings("deps", got[0].bot);
    try testing.expectEqual(Kind.failed, got[1].kind);
    try testing.expectEqualStrings("triage", got[1].bot);
    try testing.expectEqual(Kind.done, got[2].kind);
    try testing.expectEqualStrings("Draft is ready", got[2].text);
    try testing.expectEqual(Kind.missed, got[3].kind);
    try testing.expectEqualStrings("r1", got[3].routine);
    try testing.expectEqual(@as(i64, 2), got[3].count);
    // A bot with no chat, one working, and one already read are not items.
    for (got) |it| for ([_][]const u8{ "ada", "busy", "read" }) |quiet| try testing.expect(!std.mem.eql(u8, it.bot, quiet));
}

test "a launch opens on the catch-up only after a gap, and only with something to report" {
    const min = std.time.ms_per_min;
    try testing.expect(opensOnCatchUp(100 * min, 101 * min, 3));
    try testing.expect(!opensOnCatchUp(100 * min, 101 * min, 0));
    // No gap on record, or one from yesterday that this launch did not make.
    try testing.expect(!opensOnCatchUp(0, 101 * min, 3));
    try testing.expect(!opensOnCatchUp(100 * min, 200 * min, 3));
}

test "times read as a person says them" {
    var buf: [96]u8 = undefined;
    const h = std.time.ms_per_hour;
    const m = std.time.ms_per_min;
    try testing.expectEqualStrings("22:41", clock(&buf, 22 * h + 41 * m, 0));
    try testing.expectEqualStrings("06:41", clock(&buf, 22 * h + 41 * m, 8 * 3600));
    try testing.expectEqualStrings("21:41", clock(&buf, 22 * h + 41 * m, -3600));
    try testing.expectEqualStrings("Nothing was checking routines from 22:41 to 08:06. Nothing ran in between.", gapLine(&buf, 22 * h + 41 * m, 32 * h + 6 * m, 0));
    try testing.expectEqualStrings("", gapLine(&buf, 0, 0, 0));
    try testing.expectEqualStrings("Every 6 hours", every(&buf, 6 * h));
    try testing.expectEqualStrings("Every hour", every(&buf, h));
    try testing.expectEqualStrings("Every 90 minutes", every(&buf, 90 * m));
    try testing.expectEqualStrings("Every 2 days", every(&buf, 48 * h));
    try testing.expectEqualStrings("Once", every(&buf, 0));
    try testing.expectEqualStrings("in 1h 52m", until(&buf, 112 * m, 0));
    try testing.expectEqualStrings("in 4m", until(&buf, 3 * m + 1, 0));
    try testing.expectEqualStrings("in 2h", until(&buf, 2 * h, 0));
    try testing.expectEqualStrings("now", until(&buf, 5, 10));
    try testing.expectEqualStrings("in 3d", until(&buf, 80 * h, 0));
}

test "a bot's name is a safe word" {
    for ([_][]const u8{ "triage", "release-notes", "bot_2" }) |ok| try testing.expect(validName(ok));
    for ([_][]const u8{ "", "Triage", "a b", "-lead", "--yolo", "../x" }) |bad| try testing.expect(!validName(bad));
}
