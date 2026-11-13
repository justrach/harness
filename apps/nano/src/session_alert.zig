//! Durable session notification policy. Visual working -> idle transitions
//! also describe cancellation and expiry; only a new successful-turn marker
//! earns a completion alert. Shared by the sound and banner delivery path.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Status = enum { idle, working, awaiting_input, errored };
pub const Kind = enum { done, request, attention };
pub const State = struct {
    status: Status,
    completed: ?[]const u8 = null,
    peer_only: bool = false,
};

pub fn completionAllowed(archived: bool, peer_only: bool) bool {
    return !archived and !peer_only;
}

pub fn since(current: State, previous: State, archived: bool, fresh: bool, send_pending: bool) ?Kind {
    if (current.status == .errored and previous.status != .errored) return .attention;
    if (current.status == .awaiting_input and previous.status != .awaiting_input) return .request;
    if (!send_pending and fresh and completionAllowed(archived, current.peer_only)) {
        if (current.completed) |turn| {
            if (previous.completed == null or !std.mem.eql(u8, turn, previous.completed.?)) return .done;
        }
    }
    return null;
}

/// Owned independently of the replaceable WatchSessions arena, and scoped to
/// that list/App (no process-global notification baseline). Unknown chat rows
/// are not observed; the caller waits until chat/archive metadata is known.
pub const Observer = struct {
    states: std.StringHashMapUnmanaged(State) = .empty,

    pub fn deinit(self: *Observer, a: Allocator) void {
        var it = self.states.iterator();
        while (it.next()) |entry| {
            a.free(entry.key_ptr.*);
            if (entry.value_ptr.completed) |turn| a.free(turn);
        }
        self.states.deinit(a);
    }

    pub fn observe(self: *Observer, a: Allocator, chat_id: []const u8, current: State, archived: bool, fresh: bool, send_pending: bool) !?Kind {
        // Allocate before changing the baseline: an OOM may not leave a dangling
        // token or accidentally consume an alert which could be retried.
        var owned = current;
        owned.completed = if (current.completed) |turn| try a.dupe(u8, turn) else null;
        errdefer if (owned.completed) |turn| a.free(turn);
        if (self.states.getPtr(chat_id)) |previous| {
            const result = since(current, previous.*, archived, fresh, send_pending);
            if (previous.completed) |turn| a.free(turn);
            previous.* = owned;
            return result;
        }
        const key = try a.dupe(u8, chat_id);
        errdefer a.free(key);
        try self.states.put(a, key, owned);
        return null; // Boot/replay always seeds silently.
    }
};

test "retention499 stale and pending completions advance without a late replay" {
    const t = std.testing;
    var observer: Observer = .{};
    defer observer.deinit(t.allocator);
    try t.expectEqual(@as(?Kind, null), try observer.observe(t.allocator, "synthetic", .{ .status = .working }, false, true, false));
    try t.expectEqual(@as(?Kind, null), try observer.observe(t.allocator, "synthetic", .{ .status = .idle, .completed = "stale" }, false, false, false));
    try t.expectEqual(@as(?Kind, null), try observer.observe(t.allocator, "synthetic", .{ .status = .idle, .completed = "stale" }, false, true, false));
    try t.expectEqual(@as(?Kind, null), try observer.observe(t.allocator, "synthetic", .{ .status = .working, .completed = "pending" }, false, true, true));
    try t.expectEqual(@as(?Kind, null), try observer.observe(t.allocator, "synthetic", .{ .status = .idle, .completed = "pending" }, false, true, false));
    try t.expectEqual(@as(?Kind, .done), try observer.observe(t.allocator, "synthetic", .{ .status = .idle, .completed = "human" }, false, true, false));
}

test "retention499 completion eligibility is independent of the status indicator" {
    const t = std.testing;
    const before: State = .{ .status = .working, .completed = "earlier" };
    // Cancelled/expired runs never invent a completion without a new marker.
    try t.expectEqual(@as(?Kind, null), since(.{ .status = .idle, .completed = "earlier" }, before, false, true, false));
    for ([_]bool{ false, true }) |archived| for ([_]bool{ false, true }) |peer_only| {
        try t.expectEqual(!archived and !peer_only, completionAllowed(archived, peer_only));
        const current: State = .{ .status = .working, .completed = "new", .peer_only = peer_only };
        try t.expectEqual(@as(?Kind, if (!archived and !peer_only) .done else null), since(current, before, archived, true, false));
    };
}
