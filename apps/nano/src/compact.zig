//! Compact transcript mode and the final answer's heading, as the GPUI
//! transcript's (crates/ui/src/transcript.rs `rows_for_entry`,
//! `is_compact_work_part`, `final_answer_part`, `worked_for_label`).
//!
//! Compact (Settings › Appearance): a turn's work, its thinking, tool calls
//! and the narration between them, folds into one closed "Worked for …"
//! line, so only the reply shows. Either way a finished reply's answer
//! starts under a thin divider; outside compact mode the divider carries
//! "Worked for …" (or "Final answer") itself.
const std = @import("std");
const tr = @import("transcript.zig");

fn blank(p: *const tr.Part) bool {
    return std.mem.trim(u8, p.text.items, " \t\r\n").len == 0;
}

/// Where the reply begins: the last run of text parts with something in
/// them, as GPUI finds it (even when a call follows it). Text before it is
/// work. A streaming turn has no reply yet (its tail text would fold back
/// in once work resumes), nor does a turn without text.
pub fn replyStart(parts: []const tr.Part, streaming: bool) ?usize {
    if (streaming) return null;
    var start: usize = parts.len;
    var i = parts.len;
    while (i > 0) {
        i -= 1;
        if (parts[i].kind == .text and !blank(&parts[i])) {
            start = i;
            break;
        }
    }
    if (start == parts.len) return null;
    while (start > 0 and parts[start - 1].kind == .text and !blank(&parts[start - 1])) start -= 1;
    return start;
}

/// Whether part `ix` folds into the work line.
pub fn isWork(ix: usize, p: *const tr.Part, reply_start: ?usize) bool {
    return switch (p.kind) {
        .tool => true,
        .reasoning => !blank(p),
        .text => !blank(p) and (if (reply_start) |s| ix < s else true),
        else => false,
    };
}

/// A saved view is what the person asked to see: it stays a row after the
/// fold, never inside it.
pub fn isView(p: *const tr.Part) bool {
    return p.kind == .tool and p.saved_view != null;
}

/// The index of the part the answer starts at: the first text of a
/// complete reply's trailing text, with nothing left unresolved. Narration
/// before more work, an error, or a turn still running has none.
pub fn finalAnswerPart(e: *const tr.Entry) ?usize {
    if (e.role != .assistant or e.status != .complete) return null;
    for (e.parts.items) |*p| switch (p.kind) {
        .input => if (!p.resolved) return null,
        .tool => if (!p.resolved or p.subagent_status == .running) return null,
        else => {},
    };
    var first: ?usize = null;
    var i = e.parts.items.len;
    while (i > 0) {
        i -= 1;
        const p = &e.parts.items[i];
        switch (p.kind) {
            .text => if (!blank(p)) {
                first = i;
            },
            .image, .visual => {},
            else => break,
        }
    }
    return first;
}

/// The turn's working time in whole seconds, at least one, once it says.
pub fn workedSecs(e: *const tr.Entry) ?i64 {
    const ms = e.duration_ms orelse return null;
    if (ms <= 0) return null;
    return @max(1, @divTrunc(ms, 1000));
}

/// `format_elapsed`: at most two units, up to days.
pub fn formatElapsed(buf: []u8, secs_in: i64) []const u8 {
    const secs = @max(0, secs_in);
    return (if (secs < 60)
        std.fmt.bufPrint(buf, "{d}s", .{secs})
    else if (secs < 3_600)
        std.fmt.bufPrint(buf, "{d}m {d}s", .{ @divTrunc(secs, 60), @mod(secs, 60) })
    else if (secs < 86_400)
        std.fmt.bufPrint(buf, "{d}h {d}m", .{ @divTrunc(secs, 3_600), @divTrunc(@mod(secs, 3_600), 60) })
    else
        std.fmt.bufPrint(buf, "{d}d {d}h", .{ @divTrunc(secs, 86_400), @divTrunc(@mod(secs, 86_400), 3_600) })) catch "";
}

pub fn workedFor(buf: []u8, secs: i64) []const u8 {
    var t: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "Worked for {s}", .{formatElapsed(&t, secs)}) catch "";
}

const testing = std.testing;

const Spec = struct { tr.PartKind, []const u8 };

fn entry(status: tr.EntryStatus, specs: []const Spec) !tr.Entry {
    var e: tr.Entry = .{ .id = try testing.allocator.dupe(u8, "a"), .role = .assistant, .status = status };
    errdefer e.deinit(testing.allocator);
    for (specs, 0..) |s, i| {
        var p: tr.Part = .{ .kind = s[0], .id = try std.fmt.allocPrint(testing.allocator, "p{d}", .{i}) };
        p.resolved = true;
        try p.text.appendSlice(testing.allocator, s[1]);
        try e.parts.append(testing.allocator, p);
    }
    return e;
}

test "the reply is the trailing text run; narration before it is work" {
    var e = try entry(.complete, &.{ .{ .text, "Looking." }, .{ .tool, "" }, .{ .reasoning, "hm" }, .{ .text, "Done:" }, .{ .text, " " }, .{ .text, "all good" } });
    defer e.deinit(testing.allocator);
    // A blank text breaks the run: only "all good" is the reply.
    const s = replyStart(e.parts.items, false);
    try testing.expectEqual(@as(?usize, 5), s);
    try testing.expect(isWork(0, &e.parts.items[0], s));
    try testing.expect(isWork(1, &e.parts.items[1], s));
    try testing.expect(isWork(3, &e.parts.items[3], s));
    try testing.expect(!isWork(4, &e.parts.items[4], s));
    try testing.expect(!isWork(5, &e.parts.items[5], s));
}

test "a streaming turn has no reply: all of it folds; a settled one keeps its last text" {
    var e = try entry(.streaming, &.{ .{ .tool, "" }, .{ .text, "Almost there" } });
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), replyStart(e.parts.items, true));
    try testing.expect(isWork(1, &e.parts.items[1], null));
    var w = try entry(.complete, &.{ .{ .text, "Running it" }, .{ .tool, "" } });
    defer w.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 0), replyStart(w.parts.items, false));
    var none = try entry(.complete, &.{ .{ .tool, "" }, .{ .reasoning, "hm" } });
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), replyStart(none.parts.items, false));
}

test "only a complete, settled reply has a final answer, past trailing media" {
    var e = try entry(.complete, &.{ .{ .tool, "" }, .{ .text, "First" }, .{ .text, "Second" }, .{ .image, "x.png" } });
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 1), finalAnswerPart(&e));
    e.parts.items[0].resolved = false;
    try testing.expectEqual(@as(?usize, null), finalAnswerPart(&e));
    e.parts.items[0].resolved = true;
    e.status = .streaming;
    try testing.expectEqual(@as(?usize, null), finalAnswerPart(&e));
    var err = try entry(.complete, &.{ .{ .text, "Tried" }, .{ .@"error", "boom" } });
    defer err.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), finalAnswerPart(&err));
}

test "worked for: at most two units, at least a second" {
    var b: [48]u8 = undefined;
    try testing.expectEqualStrings("Worked for 42s", workedFor(&b, 42));
    try testing.expectEqualStrings("Worked for 2m 5s", workedFor(&b, 125));
    try testing.expectEqualStrings("Worked for 1h 1m", workedFor(&b, 3_660));
    try testing.expectEqualStrings("Worked for 2d 3h", workedFor(&b, 2 * 86_400 + 3 * 3_600 + 59));
    var e = try entry(.complete, &.{});
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(?i64, null), workedSecs(&e));
    e.duration_ms = 400;
    try testing.expectEqual(@as(?i64, 1), workedSecs(&e));
    e.duration_ms = 0;
    try testing.expectEqual(@as(?i64, null), workedSecs(&e));
}
