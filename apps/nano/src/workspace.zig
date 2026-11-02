//! The sidebar's rows, as `WatchSpaces`, `WatchChats` and `WatchSessions`
//! send them (crates/proto/src/entities.rs): each item is the whole list
//! again, so a list is replaced, never patched. Fields are read by name and
//! the rest ignored, so a newer engine's additions don't break the client.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const rules = @import("rules.zig");

pub const Space = struct {
    id: []const u8,
    path: []const u8,
    /// The computer the folder is on.
    device_id: ?[]const u8 = null,
    /// `name`, else the last part of `path`, as the GPUI app shows it.
    name: []const u8,
    /// A git checkout: a new chat offers its checkout and ref.
    git: bool = false,
    /// The project folder's own checkout (`Space::checkout_id`): a chat
    /// working there shares its branch (change_requests.zig).
    checkout_id: ?[]const u8 = null,
};

/// Where a chat's latest run found itself (`ConversationSourceContext`):
/// which checkout, its repository root, the folder and the branch.
pub const Source = struct {
    checkout_id: []const u8,
    repo_root: []const u8,
    cwd: []const u8,
    branch: []const u8,
};

pub const Chat = struct {
    id: []const u8,
    title: ?[]const u8,
    space_id: ?[]const u8,
    device_id: ?[]const u8 = null,
    archived: bool,
    /// A subagent's chat: not listed in the sidebar.
    parent_chat_id: ?[]const u8 = null,
    /// Milliseconds since the epoch, 0 when unknown.
    created_ms: i64 = 0,
    last_message_ms: i64 = 0,
    last_prompt_ms: i64 = 0,
    last_seen_ms: i64 = 0,
    preview: ?[]const u8,
    harness: ?[]const u8,
    model: ?[]const u8,
    reasoning: ?[]const u8 = null,
    cwd: ?[]const u8,
    /// The harness's own id for the chat's latest run (`harnessSessionId`).
    harness_session_id: ?[]const u8 = null,
    /// The branch it runs on now, when known (`conversation_branch`).
    branch: ?[]const u8 = null,
    /// The row's own `branch` (`Chat::branch`), which the composer's
    /// session footer names (pickers.rs `render_footer`).
    row_branch: ?[]const u8 = null,
    /// The source context as sent (`sourceContext`), and whether the latest
    /// run couldn't observe its checkout (`sourceContextUnavailableAt`);
    /// change_requests.zig `currentSource` says when it is current.
    source: ?Source = null,
    source_unavailable: bool = false,

    /// The sidebar's order: "last called" (`last_prompt_at`, then
    /// `last_message_at`, then `created_at`).
    pub fn calledMs(c: Chat) i64 {
        if (c.last_prompt_ms != 0) return c.last_prompt_ms;
        if (c.last_message_ms != 0) return c.last_message_ms;
        return c.created_ms;
    }

    /// What a row's time counts from: the last message, else creation.
    pub fn timeMs(c: Chat) i64 {
        return if (c.last_message_ms != 0) c.last_message_ms else c.created_ms;
    }
};

pub const Status = enum { idle, working, awaiting_input, errored };

pub const Session = struct {
    chat_id: []const u8,
    status: Status,
    started_ms: ?i64 = null,
    updated_ms: i64 = 0,
};

/// A computer on the account (`WatchDevices`): the header's "@ name".
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    platform: []const u8 = "",
    version: ?[]const u8 = null,
    /// When it was last heard from, and when it was added; 0 for never.
    last_seen_ms: i64 = 0,
    created_ms: i64 = 0,
};

/// A list replaced whole by each item, its strings in an arena of its own.
pub fn List(comptime T: type, comptime parse: fn (Allocator, json.ObjectMap) ?T) type {
    return struct {
        const Self = @This();
        arena: std.heap.ArenaAllocator,
        items: []T = &.{},

        pub fn init(gpa: Allocator) Self {
            return .{ .arena = .init(gpa) };
        }

        pub fn deinit(l: *Self) void {
            l.arena.deinit();
        }

        pub fn replace(l: *Self, value: json.Value) !void {
            const arr = switch (value) {
                .array => |a| a.items,
                else => return error.BadItem,
            };
            var next: std.heap.ArenaAllocator = .init(l.arena.child_allocator);
            errdefer next.deinit();
            const a = next.allocator();
            var out: std.ArrayList(T) = try .initCapacity(a, arr.len);
            for (arr) |v| if (v == .object) if (parse(a, v.object)) |t| out.appendAssumeCapacity(t);
            l.arena.deinit();
            l.arena = next;
            l.items = out.items;
        }
    };
}

/// An agent the engine can run (`HarnessDescriptor`, crates/engine/src/registry.rs).
pub const Harness = struct {
    id: []const u8,
    name: []const u8,
    /// Offered for new chats: enabled, or (from an engine that doesn't say)
    /// installed and one of graff, Codex, Claude Code.
    offered: bool,
    /// Its reasoning ladder, for a model that lists none (`trait_ladder`).
    levels: []const []const u8 = &.{},
};

/// A model an agent offers (`Model`, crates/proto/src/agent.rs).
pub const Model = struct {
    id: []const u8,
    label: []const u8,
    /// The real catalog's inline attribution and model maker, as GPUI shows.
    description: ?[]const u8 = null,
    maker: ?[]const u8 = null,
    billing: ?[]const u8 = null,
    /// Its levels; a chat without one picked shows `rules.defaultReasoning`.
    reasoning_default: ?[]const u8 = null,
    levels: []const []const u8 = &.{},
};

pub const Spaces = List(Space, parseSpace);
pub const Harnesses = List(Harness, parseHarness);
pub const Models = List(Model, parseModel);
pub const Chats = List(Chat, parseChat);
pub const Sessions = List(Session, parseSession);
pub const Devices = List(Device, parseDevice);

fn ms(a: Allocator, o: json.ObjectMap, k: []const u8) i64 {
    const s = str(a, o, k) orelse return 0;
    return rules.parseTime(s) orelse 0;
}

fn parseDevice(a: Allocator, o: json.ObjectMap) ?Device {
    const id = str(a, o, "id") orelse return null;
    return .{
        .id = id,
        .name = str(a, o, "name") orelse "Unknown device",
        .platform = str(a, o, "platform") orelse "",
        .version = str(a, o, "version"),
        .last_seen_ms = ms(a, o, "lastSeenAt"),
        .created_ms = ms(a, o, "createdAt"),
    };
}

pub fn str(a: Allocator, o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .string => |s| a.dupe(u8, s) catch null,
        else => null,
    };
}

fn parseSpace(a: Allocator, o: json.ObjectMap) ?Space {
    const path = str(a, o, "path") orelse return null;
    return .{
        .id = str(a, o, "id") orelse return null,
        .path = path,
        .device_id = str(a, o, "deviceId"),
        .name = str(a, o, "name") orelse std.fs.path.basename(path),
        .git = if (o.get("gitDetected")) |v| v == .bool and v.bool else false,
        .checkout_id = str(a, o, "checkoutId"),
    };
}

fn parseChat(a: Allocator, o: json.ObjectMap) ?Chat {
    const config = if (o.get("config")) |c| (if (c == .object) c.object else null) else null;
    return .{
        .id = str(a, o, "id") orelse return null,
        .title = str(a, o, "title"),
        .space_id = str(a, o, "spaceId"),
        .device_id = str(a, o, "deviceId"),
        .archived = if (o.get("archived")) |v| v == .bool and v.bool else false,
        .parent_chat_id = str(a, o, "parentChatId"),
        .created_ms = ms(a, o, "createdAt"),
        .last_message_ms = ms(a, o, "lastMessageAt"),
        .last_prompt_ms = ms(a, o, "lastPromptAt"),
        .last_seen_ms = ms(a, o, "lastSeenAt"),
        .preview = str(a, o, "lastMessagePreview"),
        .harness = if (config) |c| str(a, c, "harness") else null,
        .model = if (config) |c| str(a, c, "model") else null,
        .reasoning = if (config) |c| str(a, c, "reasoning") else null,
        .cwd = str(a, o, "cwd"),
        .harness_session_id = str(a, o, "harnessSessionId"),
        .branch = currentBranch(a, o),
        .row_branch = str(a, o, "branch"),
        .source = parseSource(a, o),
        .source_unavailable = if (o.get("sourceContextUnavailableAt")) |u| u != .null else false,
    };
}

/// `sourceContext`, when it names its checkout, root, folder and branch.
fn parseSource(a: Allocator, o: json.ObjectMap) ?Source {
    const v = o.get("sourceContext") orelse return null;
    if (v != .object) return null;
    return .{
        .checkout_id = str(a, v.object, "checkoutId") orelse return null,
        .repo_root = str(a, v.object, "repoRoot") orelse return null,
        .cwd = str(a, v.object, "cwd") orelse return null,
        .branch = str(a, v.object, "branch") orelse return null,
    };
}

/// The source context's branch, only while it says where the chat runs now
/// (`current_source_context`): not after a run couldn't see its checkout,
/// nor once the chat moved to another folder.
fn currentBranch(a: Allocator, o: json.ObjectMap) ?[]const u8 {
    const v = o.get("sourceContext") orelse return null;
    if (v != .object) return null;
    if (o.get("sourceContextUnavailableAt")) |u| if (u != .null) return null;
    const src = v.object;
    const src_cwd = if (src.get("cwd")) |c| (if (c == .string) c.string else "") else "";
    if (o.get("cwd")) |c| if (c == .string) {
        const trim = "/\\";
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, c.string, trim), std.mem.trimEnd(u8, src_cwd, trim))) return null;
    };
    const b = str(a, src, "branch") orelse return null;
    const t = std.mem.trim(u8, b, " \t\n");
    return if (t.len == 0) null else t;
}

fn parseHarness(a: Allocator, o: json.ObjectMap) ?Harness {
    const id = str(a, o, "id") orelse return null;
    const installed = if (o.get("installed")) |v| v == .bool and v.bool else false;
    const offered = if (o.get("enabled")) |v| v == .bool and v.bool else installed and
        (std.mem.eql(u8, id, "graff") or std.mem.eql(u8, id, "codex") or std.mem.eql(u8, id, "claude-code"));
    return .{ .id = id, .name = str(a, o, "name") orelse id, .offered = offered, .levels = stringList(a, o, "reasoningLevels") };
}

fn parseModel(a: Allocator, o: json.ObjectMap) ?Model {
    const id = str(a, o, "id") orelse return null;
    const levels = stringList(a, o, "reasoningLevels");
    return .{
        .id = id,
        .label = str(a, o, "label") orelse id,
        .description = str(a, o, "description"),
        .maker = str(a, o, "maker"),
        .billing = str(a, o, "billing"),
        .reasoning_default = rules.defaultReasoning(levels),
        .levels = levels,
    };
}

/// The strings of the array `key`, owned.
fn stringList(a: Allocator, o: json.ObjectMap, key: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (o.get(key)) |v| if (v == .array) for (v.array.items) |l| if (l == .string) {
        const item = a.dupe(u8, l.string) catch continue;
        list.append(a, item) catch continue;
    };
    return list.items;
}

fn parseSession(a: Allocator, o: json.ObjectMap) ?Session {
    const s = if (o.get("status")) |v| (if (v == .string) v.string else "") else "";
    const started = ms(a, o, "startedAt");
    return .{
        .chat_id = str(a, o, "chatId") orelse return null,
        .updated_ms = ms(a, o, "updatedAt"),
        .started_ms = if (started == 0) null else started,
        .status = if (std.mem.eql(u8, s, "working"))
            .working
        else if (std.mem.eql(u8, s, "awaitingInput"))
            .awaiting_input
        else if (std.mem.eql(u8, s, "errored"))
            .errored
        else
            .idle,
    };
}

/// Chats newest first, as the sidebar lists them.
pub fn sortChats(chats: []Chat) void {
    sortChatsBy(chats, false);
}

/// Newest first, by when last called or (`created`) when made; ties by id
/// (`compare_sidebar_chats`).
pub fn sortChatsBy(chats: []Chat, created: bool) void {
    std.mem.sort(Chat, chats, created, struct {
        fn lt(by_created: bool, x: Chat, y: Chat) bool {
            const a = if (by_created) x.created_ms else x.calledMs();
            const b = if (by_created) y.created_ms else y.calledMs();
            if (a != b) return a > b;
            // Ties by id, ascending, as `sort_active` breaks them.
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);
}

pub fn statusOf(sessions: []const Session, chat_id: []const u8) Status {
    return (sessionOf(sessions, chat_id) orelse return .idle).status;
}

pub fn sessionOf(sessions: []const Session, chat_id: []const u8) ?Session {
    for (sessions) |s| if (std.mem.eql(u8, s.chat_id, chat_id)) return s;
    return null;
}

/// What a session row's status slot shows (`display_status`,
/// crates/proto/src/view.rs): a working or waiting session counts while it
/// is fresh (updated in the last 45 s); an error shows only until it is
/// seen; otherwise an unseen reply reads as completed.
pub const Mark = enum { working, completed, awaiting_input, errored, idle };

pub const stale_ms = 45_000;

pub fn markOf(chat: Chat, session: ?Session, now_ms: i64) Mark {
    const live: ?Status = if (session) |s| switch (s.status) {
        .idle => null,
        .errored => .errored,
        .working, .awaiting_input => if (now_ms - s.updated_ms > stale_ms) null else s.status,
    } else null;
    if (live) |st| switch (st) {
        .working => return .working,
        .awaiting_input => return .awaiting_input,
        .errored => if (unseen(chat)) return .errored,
        .idle => {},
    };
    return if (unseen(chat)) .completed else .idle;
}

pub fn unseen(chat: Chat) bool {
    return chat.last_message_ms != 0 and chat.last_seen_ms < chat.last_message_ms;
}

const testing = std.testing;

test "the sidebar orders by last called, and marks what finished unseen" {
    var chats = [_]Chat{
        .{ .id = "a", .title = null, .space_id = null, .archived = false, .preview = null, .harness = null, .model = null, .cwd = null, .created_ms = 5, .last_message_ms = 50 },
        .{ .id = "b", .title = null, .space_id = null, .archived = false, .preview = null, .harness = null, .model = null, .cwd = null, .created_ms = 9, .last_prompt_ms = 40, .last_message_ms = 60, .last_seen_ms = 60 },
    };
    sortChats(&chats);
    try testing.expectEqualStrings("a", chats[0].id);
    try testing.expectEqual(Mark.completed, markOf(chats[0], null, 100));
    try testing.expectEqual(Mark.idle, markOf(chats[1], null, 100));
    const working: Session = .{ .chat_id = "b", .status = .working, .updated_ms = 100 };
    try testing.expectEqual(Mark.working, markOf(chats[1], working, 30_000));
    try testing.expectEqual(Mark.idle, markOf(chats[1], working, 100_000));
}

test "a chats item replaces the list, reading only what it knows" {
    var chats: Chats = .init(testing.allocator);
    defer chats.deinit();
    const text =
        \\[{"id":"a","deviceId":"d","title":null,"archived":false,"cwd":"/r","branch":null,"checkoutId":null,
        \\  "config":{"harness":"graff","model":"m1","reasoning":null,"modelOptions":{},"sandbox":"workspace-write"},
        \\  "lastMessagePreview":"hi","lastMessageAt":"2026-10-01T00:00:00Z","createdAt":"2026-09-01T00:00:00Z","future":1},
        \\ {"id":"b","title":"Second","archived":true,"lastMessageAt":"2026-10-02T00:00:00Z","spaceId":"s1"}]
    ;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try chats.replace(parsed.value);
    try testing.expectEqual(@as(usize, 2), chats.items.len);
    try testing.expectEqualStrings("graff", chats.items[0].harness.?);
    try testing.expect(chats.items[0].title == null);
    sortChats(chats.items);
    try testing.expectEqualStrings("b", chats.items[0].id);
    try testing.expectEqualStrings("s1", chats.items[0].space_id.?);
    try testing.expect(chats.items[0].archived);
}

test "a space without a name takes its folder's" {
    var spaces: Spaces = .init(testing.allocator);
    defer spaces.deinit();
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"id":"s","deviceId":"d","path":"/Users/x/harness","gitDetected":true,"createdAt":"t"}]
    , .{});
    defer parsed.deinit();
    try spaces.replace(parsed.value);
    try testing.expectEqualStrings("harness", spaces.items[0].name);
}

test "harnesses offered: enabled, else installed and one of the three" {
    var hs: Harnesses = .init(testing.allocator);
    defer hs.deinit();
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"id":"mock","name":"Mock","installed":true,"enabled":false},{"id":"graff","name":"graff","installed":true},
        \\ {"id":"pi","name":"Pi","installed":true}]
    , .{});
    defer parsed.deinit();
    try hs.replace(parsed.value);
    try testing.expect(!hs.items[0].offered);
    try testing.expect(hs.items[1].offered);
    try testing.expect(!hs.items[2].offered);
}

test "sessions map statuses" {
    var sessions: Sessions = .init(testing.allocator);
    defer sessions.deinit();
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working"},{"chatId":"b","status":"awaitingInput"}]
    , .{});
    defer parsed.deinit();
    try sessions.replace(parsed.value);
    try testing.expectEqual(Status.working, statusOf(sessions.items, "a"));
    try testing.expectEqual(Status.awaiting_input, statusOf(sessions.items, "b"));
    try testing.expectEqual(Status.idle, statusOf(sessions.items, "c"));
}

test "a chat's branch is its source context's while that says where it runs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ \\{"id":"a","cwd":"/w/x/","sourceContext":{"cwd":"/w/x","branch":"feat/one"}}
        , "feat/one" },
        .{ \\{"id":"a","cwd":"/w/y","sourceContext":{"cwd":"/w/x","branch":"feat/one"}}
        , null },
        .{ \\{"id":"a","cwd":"/w/x","sourceContextUnavailableAt":"2026-10-01T00:00:00Z","sourceContext":{"cwd":"/w/x","branch":"main"}}
        , null },
        .{ \\{"id":"a","cwd":"/w/x","sourceContext":{"cwd":"/w/x","branch":"  "}}
        , null },
        .{ \\{"id":"a","cwd":"/w/x"}
        , null },
    };
    for (cases) |case| {
        const v = try json.parseFromSliceLeaky(json.Value, a, case[0], .{});
        const ch = parseChat(a, v.object).?;
        if (case[1]) |want| try std.testing.expectEqualStrings(want, ch.branch.?) else try std.testing.expect(ch.branch == null);
    }
}

test "the row's own branch is kept apart from the source context's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"id":"a","cwd":"/w/x","branch":"feat/footer","sourceContext":{"cwd":"/w/y","branch":"main"}}
    , .{});
    const ch = parseChat(a, v.object).?;
    try std.testing.expectEqualStrings("feat/footer", ch.row_branch.?);
    try std.testing.expect(ch.branch == null);
}
