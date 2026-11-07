//! Cumulative recorded tool activity, NOT net checkout changes.
//! The protocol has message timestamps but no per-edit clock/duration. Keep
//! transcript order, expose that limitation, and never synthesize a time axis.
const std = @import("std");
const tr = @import("transcript.zig");
pub const Point = struct {
    edit: tr.Edit,
    turn_started: ?u64,
    added: u64,
    removed: u64,
};
pub const History = struct {
    points: []const Point,
    files: []const []const u8,
    missing: usize,
    first_turn: ?u64,
    last_turn: ?u64,
};
pub fn collect(arena: std.mem.Allocator, transcript: *const tr.Transcript) !History {
    var points: std.ArrayList(Point) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var added: u64 = 0;
    var removed: u64 = 0;
    var missing: usize = 0;
    var first: ?u64 = null;
    var last: ?u64 = null;
    for (transcript.entries.items) |entry| {
        if (entry.role != .assistant) continue;
        for (entry.parts.items) |part| {
            if (part.kind != .tool or !part.resolved or part.is_error) continue;
            if (part.edits.len == 0 and (part.tool == .writeFile or part.tool == .editFile or part.tool == .applyPatch)) missing += 1;
            for (part.edits) |edit| {
                if (entry.created_at) |at| if (at > 0) {
                    first = @min(first orelse at, at);
                    last = @max(last orelse at, at);
                };
                if (edit.additions == null or edit.deletions == null) missing += 1;
                added +|= edit.additions orelse 0;
                removed +|= edit.deletions orelse 0;
                try points.append(arena, .{ .edit = edit, .turn_started = entry.created_at, .added = added, .removed = removed });
                const found = try seen.getOrPut(arena, edit.path);
                if (!found.found_existing) try files.append(arena, edit.path);
            }
        }
    }
    return .{ .points = try points.toOwnedSlice(arena), .files = try files.toOwnedSlice(arena), .missing = missing, .first_turn = first, .last_turn = last };
}

const testing = std.testing;
test "empty history has no invented range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const h = try collect(arena.allocator(), &.{ .gpa = testing.allocator });
    try testing.expectEqual(@as(usize, 0), h.points.len);
    try testing.expect(h.first_turn == null);
}
test "recorded order, cumulative churn, distinct files and out-of-order turn times" {
    var t: tr.Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    const text =
        \\{"reset":[{"id":"a","createdAt":2000,"role":"assistant","parts":[{"kind":"tool","id":"x","resolved":true,"call":{"kind":"editFile","path":"a"},"diffStats":[{"path":"a","additions":3,"deletions":1}]}]},{"id":"b","createdAt":1000,"role":"assistant","parts":[{"kind":"tool","id":"y","resolved":true,"diffStats":[{"path":"a","additions":2,"deletions":4},{"path":"image.png","additions":0,"deletions":0}]}]}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const h = try collect(arena.allocator(), &t);
    try testing.expectEqual(@as(usize, 3), h.points.len);
    try testing.expectEqual(@as(u64, 5), h.points[2].added);
    try testing.expectEqual(@as(u64, 5), h.points[2].removed);
    try testing.expectEqual(@as(usize, 2), h.files.len);
    try testing.expectEqual(@as(?u64, 2000), h.points[0].turn_started);
    try testing.expectEqual(@as(?u64, 1000), h.first_turn);
    try testing.expectEqual(@as(?u64, 2000), h.last_turn);
    // Replacing a result doesn't double count an observed live update.
    try t.apply(parsed.value);
    const reset = try collect(arena.allocator(), &t);
    try testing.expectEqual(@as(u64, 5), reset.points[2].added);
}

fn fromJson(t: *tr.Transcript, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
}
test "new file counts exact trailing newline and preserves real excerpts" {
    var t: tr.Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try fromJson(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"id":"new","kind":"tool","resolved":true,"diff":{"path":"new.zig","newText":"one\ntwo\n"}}]}]}
    );
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const h = try collect(arena.allocator(), &t);
    try testing.expectEqual(@as(usize, 1), h.points.len);
    try testing.expect(h.points[0].edit.new_file);
    try testing.expectEqual(@as(u64, 2), h.points[0].added);
    try testing.expect(h.points[0].turn_started == null);
    try testing.expect(h.first_turn == null);
}
test "missing, failed, pending and binary-style sidecar results do not invent lines" {
    var t: tr.Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try fromJson(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"id":"missing","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"missing"}},{"id":"failed","kind":"tool","resolved":true,"isError":true,"diffStats":[{"path":"failed","additions":99,"deletions":99}]},{"id":"pending","kind":"tool","resolved":false,"diffStats":[{"path":"pending","additions":99,"deletions":99}]},{"id":"binary","kind":"tool","resolved":true,"diffStats":[{"path":"image.png","additions":0,"deletions":0}]},{"id":"legacy","kind":"tool","resolved":true,"diff":{"path":"legacy","oldText":"old","newText":"new"}}]}],"historyPending":true}
    );
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const h = try collect(arena.allocator(), &t);
    try testing.expectEqual(@as(usize, 2), h.points.len);
    try testing.expectEqual(@as(usize, 2), h.missing);
    try testing.expectEqual(@as(u64, 0), h.points[1].added);
    try testing.expectEqual(@as(?u64, null), h.points[1].edit.additions);
    try testing.expectEqualStrings("image.png", h.points[0].edit.path);
    try testing.expect(h.points[0].edit.new_text == null);
    try testing.expect(!t.complete);
}

test "live upsert replaces counts and removed results leave no stale history" {
    var t: tr.Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try fromJson(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"id":"x","kind":"tool","resolved":true,"diffStats":[{"path":"a","additions":2,"deletions":1}]}]}]}
    );
    try fromJson(&t,
        \\{"upsert":[{"after":null,"entry":{"id":"a","role":"assistant","parts":[{"id":"x","kind":"tool","resolved":true,"diffStats":[{"path":"a","additions":5,"deletions":3}]}]}}],"count":1}
    );
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const h = try collect(arena.allocator(), &t);
    try testing.expectEqual(@as(usize, 1), h.points.len);
    try testing.expectEqual(@as(u64, 5), h.points[0].added);
    try fromJson(&t,
        \\{"remove":["a"],"count":0}
    );
    const empty = try collect(arena.allocator(), &t);
    try testing.expectEqual(@as(usize, 0), empty.points.len);
    try testing.expectEqual(@as(usize, 0), empty.files.len);
}
