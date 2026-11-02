//! Move loaded transcripts and their live subscriptions between the
//! focused outlet and its peers. Changing focus is not a new chat load.
const std = @import("std");
const App = @import("app.zig").App;
const Peer = @import("app.zig").Peer;

pub fn select(a: *App, next: ?[]const u8) void {
    if (same(a.selected, next)) return;
    // Take the incoming peer before appending: an append may move the list.
    var incoming: ?Peer = null;
    if (next) |id| for (a.peers.items, 0..) |p, ix| {
        if (std.mem.eql(u8, p.id, id)) {
            incoming = a.peers.swapRemove(ix);
            break;
        }
    };
    var kept = false;
    if (a.selected) |old| if (visiblePeer(a, old) and a.peer(old) == null) {
        if (a.gpa.dupe(u8, old)) |id| {
            if (a.peers.append(a.gpa, .{ .id = id, .transcript = a.transcript, .watch = a.w_doc.id, .retry_at = a.w_doc.retry_at })) |_| {
                kept = true;
            } else |_| a.gpa.free(id);
        } else |_| {}
    };
    if (!kept) {
        if (a.w_doc.id) |id| a.engine.cancel(id);
        // This frame may already have built rows from the outgoing data.
        if (a.retired.append(a.gpa, a.transcript)) |_| {} else |_| a.transcript.clear();
    }
    a.transcript = .{ .gpa = a.gpa };
    a.w_doc = .{};
    if (incoming) |p| {
        a.transcript = p.transcript;
        a.w_doc = .{ .id = p.watch, .retry_at = p.retry_at };
        a.retired_ids.append(a.gpa, p.id) catch a.gpa.free(p.id);
    }
}

fn visiblePeer(a: *const App, id: []const u8) bool {
    const split = a.tabs.layout() orelse return false;
    for (split.panes.items, 0..) |p, ix| {
        if (ix != split.focus and same(p, id)) return true;
    }
    return false;
}

fn same(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |x| return if (b) |y| std.mem.eql(u8, x, y) else false;
    return b == null;
}
