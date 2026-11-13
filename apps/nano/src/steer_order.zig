//! Where a message sent while its turn still works is drawn.
//!
//! The engine writes such a message (a steer) at the document's end at
//! once, and keeps streaming the running reply into the entry before it
//! until the agent takes the message at its next step
//! (`SessionsEngine::steer_with_origin`, then `AgentEvent::Steered`). In
//! the document's order the turn's later work therefore lands above the
//! bubble, which stays last as though it had never been sent.
//!
//! The transcript draws what happened instead: the reply up to where the
//! message arrived, the message, then what the reply gained after it.
//!
//! The document does not say where among a reply's parts a message
//! arrived, so the window remembers it (`Store`) by the ids' hashes for as
//! long as it runs. A transcript first seen later reads in the document's
//! order, and a message found already waiting splits its reply from there.
const std = @import("std");
const tr = @import("transcript.zig");

pub fn hash(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0x7374_6565_72, id);
}

/// A message that arrived while the reply `owner` was streaming.
pub const Cut = struct {
    chat: u64,
    user: u64,
    owner: u64,
    /// How many parts the reply had when the message arrived.
    parts: usize,
    /// What follows the message, as last laid out, for offscreen culling
    /// (an `Entry`'s `cached_h`, `cached_w` and `measured_w`).
    cached_h: f32 = 0,
    cached_w: f32 = 0,
    measured_w: f32 = 0,
};

pub const Store = struct {
    pub const capacity = 64;

    items: [capacity]Cut = undefined,
    len: usize = 0,
    /// The slot a cut past `capacity` takes: the oldest.
    oldest: usize = 0,

    /// Whether `chat` has any message to place: most never do, and their
    /// rows are then drawn without hashing an id.
    pub fn any(s: *const Store, chat: u64) bool {
        for (s.items[0..s.len]) |cut| if (cut.chat == chat) return true;
        return false;
    }

    pub fn find(s: *Store, chat: u64, user: u64) ?*Cut {
        for (s.items[0..s.len]) |*cut| if (cut.chat == chat and cut.user == user) return cut;
        return null;
    }

    fn add(s: *Store, cut: Cut) void {
        if (s.len < capacity) {
            s.items[s.len] = cut;
            s.len += 1;
            return;
        }
        s.items[s.oldest] = cut;
        s.oldest = (s.oldest + 1) % capacity;
    }

    /// Remembers the messages at the transcript's end that follow a reply
    /// still streaming: each splits it at the parts it has now. One already
    /// remembered keeps its place.
    pub fn observe(s: *Store, chat: u64, entries: []const tr.Entry) void {
        var first = entries.len;
        while (first > 0 and entries[first - 1].role == .user) first -= 1;
        if (first == entries.len or first == 0) return;
        const owner = &entries[first - 1];
        if (owner.role != .assistant or owner.status != .streaming) return;
        const owner_hash = hash(owner.id);
        for (entries[first..]) |*u| {
            const user = hash(u.id);
            if (s.find(chat, user) != null) continue;
            s.add(.{ .chat = chat, .user = user, .owner = owner_hash, .parts = owner.parts.items.len });
        }
    }
};

/// The reply the run of messages holding entry `i` follows.
fn ownerOf(entries: []const tr.Entry, i: usize) ?usize {
    var first = i;
    while (first > 0 and entries[first - 1].role == .user) first -= 1;
    if (first == 0 or entries[first - 1].role != .assistant) return null;
    return first - 1;
}

/// How many of reply `i`'s parts are drawn in its own place: all of them,
/// unless a message after it arrived while it streamed.
pub fn headEnd(s: *Store, chat: u64, entries: []const tr.Entry, i: usize) usize {
    const len = entries[i].parts.items.len;
    if (i + 1 >= entries.len or entries[i + 1].role != .user) return len;
    const owner = hash(entries[i].id);
    for (entries[i + 1 ..]) |*u| {
        if (u.role != .user) break;
        if (s.find(chat, hash(u.id))) |cut| if (cut.owner == owner) return @min(cut.parts, len);
    }
    return len;
}

/// The reply's parts `[start, end)` drawn under a message.
pub const Tail = struct {
    owner: usize,
    start: usize,
    end: usize,
    cut: *Cut,
};

/// What is drawn under message `i`: the parts its reply gained after it,
/// up to the next message that arrived while the reply streamed. A reply's
/// head and its tails hold each of its parts once, in order.
pub fn tailAfter(s: *Store, chat: u64, entries: []const tr.Entry, i: usize) ?Tail {
    if (entries[i].role != .user) return null;
    const owner = ownerOf(entries, i) orelse return null;
    const cut = s.find(chat, hash(entries[i].id)) orelse return null;
    if (cut.owner != hash(entries[owner].id)) return null;
    const len = entries[owner].parts.items.len;
    // Never before an earlier message's place, whatever was remembered.
    var start = @min(cut.parts, len);
    for (entries[owner + 1 .. i]) |*u| {
        if (s.find(chat, hash(u.id))) |c| if (c.owner == cut.owner) {
            start = @max(start, @min(c.parts, len));
        };
    }
    var end = len;
    for (entries[i + 1 ..]) |*u| {
        if (u.role != .user) break;
        if (s.find(chat, hash(u.id))) |c| if (c.owner == cut.owner) {
            end = @max(start, @min(c.parts, len));
            break;
        };
    }
    return .{ .owner = owner, .start = start, .end = end, .cut = cut };
}

/// A reply's parts `[start, end)` as an entry to draw, under `id`. Only
/// the piece that ends the reply says how long it worked.
pub fn piece(e: *const tr.Entry, id: []const u8, start: usize, end: usize) tr.Entry {
    return .{
        .id = @constCast(id),
        .role = e.role,
        .status = e.status,
        .parts = .fromOwnedSlice(e.parts.items[start..end]),
        .duration_ms = if (end == e.parts.items.len) e.duration_ms else null,
        .created_ms = e.created_ms,
    };
}

const testing = std.testing;

const Fixture = struct {
    t: tr.Transcript,

    fn init() Fixture {
        return .{ .t = .{ .gpa = testing.allocator } };
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    fn add(f: *Fixture, id: []const u8, role: tr.Role, status: tr.EntryStatus, parts: usize) !void {
        var e: tr.Entry = .{ .id = try testing.allocator.dupe(u8, id), .role = role, .status = status };
        errdefer e.deinit(testing.allocator);
        for (0..parts) |n| {
            var buf: [8]u8 = undefined;
            const part_id = try std.fmt.bufPrint(&buf, "p{d}", .{n});
            try e.parts.append(testing.allocator, .{ .id = try testing.allocator.dupe(u8, part_id), .kind = .text });
        }
        try f.t.entries.append(testing.allocator, e);
    }

    /// Grows entry `i` by one part, as a streamed step does.
    fn grow(f: *Fixture, i: usize) !void {
        const e = &f.t.entries.items[i];
        var buf: [8]u8 = undefined;
        const part_id = try std.fmt.bufPrint(&buf, "p{d}", .{e.parts.items.len});
        try e.parts.append(testing.allocator, .{ .id = try testing.allocator.dupe(u8, part_id), .kind = .text });
    }
};

/// The order the transcript draws: each entry's index and part span.
const Drawn = struct { entry: usize, start: usize, end: usize };

fn drawn(s: *Store, chat: u64, entries: []const tr.Entry, out: []Drawn) []Drawn {
    var n: usize = 0;
    for (entries, 0..) |*e, i| {
        const end = if (e.role == .assistant) headEnd(s, chat, entries, i) else e.parts.items.len;
        out[n] = .{ .entry = i, .start = 0, .end = end };
        n += 1;
        if (tailAfter(s, chat, entries, i)) |t| if (t.start < t.end) {
            out[n] = .{ .entry = t.owner, .start = t.start, .end = t.end };
            n += 1;
        };
    }
    return out[0..n];
}

test "work after a message sent mid-turn is drawn under it, each part once" {
    var f = Fixture.init();
    defer f.deinit();
    var s: Store = .{};
    const chat = hash("chat");
    try f.add("u", .user, .complete, 1);
    try f.add("a", .assistant, .streaming, 2);
    s.observe(chat, f.t.entries.items);
    try testing.expect(!s.any(chat));

    // The message arrives with two parts streamed; three more follow.
    try f.add("s1", .user, .complete, 1);
    s.observe(chat, f.t.entries.items);
    try testing.expect(s.any(chat));
    try testing.expect(!s.any(hash("another chat")));
    for (0..3) |_| try f.grow(1);
    s.observe(chat, f.t.entries.items);
    var buf: [16]Drawn = undefined;
    try testing.expectEqualSlices(Drawn, &.{
        .{ .entry = 0, .start = 0, .end = 1 },
        .{ .entry = 1, .start = 0, .end = 2 },
        .{ .entry = 2, .start = 0, .end = 1 },
        .{ .entry = 1, .start = 2, .end = 5 },
    }, drawn(&s, chat, f.t.entries.items, &buf));

    // A second message, one more part, then the reply to the first.
    try f.add("s2", .user, .complete, 1);
    s.observe(chat, f.t.entries.items);
    try f.grow(1);
    f.t.entries.items[1].status = .complete;
    try f.add("b", .assistant, .streaming, 1);
    s.observe(chat, f.t.entries.items);
    try testing.expectEqualSlices(Drawn, &.{
        .{ .entry = 0, .start = 0, .end = 1 },
        .{ .entry = 1, .start = 0, .end = 2 },
        .{ .entry = 2, .start = 0, .end = 1 },
        .{ .entry = 1, .start = 2, .end = 5 },
        .{ .entry = 3, .start = 0, .end = 1 },
        .{ .entry = 1, .start = 5, .end = 6 },
        .{ .entry = 4, .start = 0, .end = 1 },
    }, drawn(&s, chat, f.t.entries.items, &buf));

    // The other chat's transcript, and one with fewer parts than
    // remembered, still draw every part once.
    try testing.expectEqual(@as(usize, 6), headEnd(&s, hash("another chat"), f.t.entries.items, 1));
    s.find(chat, hash("s1")).?.parts = 40;
    const order = drawn(&s, chat, f.t.entries.items, &buf);
    var covered: usize = 0;
    for (order) |d| if (d.entry == 1) {
        try testing.expectEqual(covered, d.start);
        covered = d.end;
    };
    try testing.expectEqual(@as(usize, 6), covered);
}

test "a message after a finished reply splits nothing, and the oldest place is forgotten first" {
    var f = Fixture.init();
    defer f.deinit();
    var s: Store = .{};
    const chat = hash("chat");
    try f.add("u", .user, .complete, 1);
    try f.add("a", .assistant, .complete, 3);
    try f.add("next", .user, .complete, 1);
    s.observe(chat, f.t.entries.items);
    try testing.expect(!s.any(chat));
    try testing.expectEqual(@as(usize, 3), headEnd(&s, chat, f.t.entries.items, 1));
    try testing.expect(tailAfter(&s, chat, f.t.entries.items, 2) == null);

    for (0..Store.capacity + 1) |n| s.add(.{ .chat = chat, .user = n, .owner = 1, .parts = n });
    try testing.expectEqual(Store.capacity, s.len);
    try testing.expect(s.find(chat, 0) == null);
    try testing.expect(s.find(chat, 1) != null);
    try testing.expect(s.find(chat, Store.capacity) != null);
}
