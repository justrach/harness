//! Append-only JSONL Crash-Recovery Run Journal (`crates/engine/src/run_journal.rs`).
//!
//! Records turn starts (`begin`), streaming checkpoints (`delta`), and completions
//! (`finish`) so a crashed engine daemon recovers incomplete turns cleanly on restart.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const session_doc = @import("session_doc.zig");

pub const RunJournal = struct {
    gpa: Allocator,
    lines: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: Allocator) RunJournal {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RunJournal) void {
        for (self.lines.items) |l| self.gpa.free(l);
        self.lines.deinit(self.gpa);
    }

    pub fn recordBegin(self: *RunJournal, chat_id: []const u8, msg_id: []const u8, now_ms: i64) !void {
        const line = try std.fmt.allocPrint(
            self.gpa,
            "{{\"kind\":\"begin\",\"chatId\":{f},\"msgId\":{f},\"ts\":{d}}}",
            .{ json.fmt(chat_id, .{}), json.fmt(msg_id, .{}), now_ms },
        );
        errdefer self.gpa.free(line);
        try self.lines.append(self.gpa, line);
    }

    pub fn recordDelta(self: *RunJournal, chat_id: []const u8, msg_id: []const u8, part_id: []const u8, text: []const u8) !void {
        const line = try std.fmt.allocPrint(
            self.gpa,
            "{{\"kind\":\"delta\",\"chatId\":{f},\"msgId\":{f},\"partId\":{f},\"text\":{f}}}",
            .{ json.fmt(chat_id, .{}), json.fmt(msg_id, .{}), json.fmt(part_id, .{}), json.fmt(text, .{}) },
        );
        errdefer self.gpa.free(line);
        try self.lines.append(self.gpa, line);
    }

    pub fn recordFinish(self: *RunJournal, chat_id: []const u8, msg_id: []const u8, status: []const u8) !void {
        const line = try std.fmt.allocPrint(
            self.gpa,
            "{{\"kind\":\"finish\",\"chatId\":{f},\"msgId\":{f},\"status\":{f}}}",
            .{ json.fmt(chat_id, .{}), json.fmt(msg_id, .{}), json.fmt(status, .{}) },
        );
        errdefer self.gpa.free(line);
        try self.lines.append(self.gpa, line);
    }

    /// Replay journal lines into `doc`; any turn that had a `begin` without a
    /// matching `finish` is marked `"aborted"` on crash recovery.
    pub fn replayIntoDoc(self: *const RunJournal, doc: *session_doc.SessionDoc) !usize {
        var open_turns = std.StringHashMapUnmanaged(void).empty;
        defer {
            var it = open_turns.iterator();
            while (it.next()) |e| self.gpa.free(e.key_ptr.*);
            open_turns.deinit(self.gpa);
        }

        for (self.lines.items) |line| {
            var parsed = json.parseFromSlice(json.Value, self.gpa, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const o = parsed.value.object;
            const kind = if (o.get("kind")) |v| (if (v == .string) v.string else "") else "";
            const chat_id = if (o.get("chatId")) |v| (if (v == .string) v.string else "") else "";
            if (!std.mem.eql(u8, chat_id, doc.chat_id)) continue;
            const msg_id = if (o.get("msgId")) |v| (if (v == .string) v.string else "") else "";
            if (msg_id.len == 0) continue;

            if (std.mem.eql(u8, kind, "begin")) {
                const ts: i64 = if (o.get("ts")) |v| (if (v == .integer) v.integer else 0) else 0;
                try doc.beginAssistantMessage(msg_id, ts);
                const gop = try open_turns.getOrPut(self.gpa, msg_id);
                if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, msg_id);
            } else if (std.mem.eql(u8, kind, "delta")) {
                const part_id = if (o.get("partId")) |v| (if (v == .string) v.string else "p-1") else "p-1";
                const txt = if (o.get("text")) |v| (if (v == .string) v.string else "") else "";
                _ = try doc.appendPartDelta(msg_id, part_id, "text", txt);
            } else if (std.mem.eql(u8, kind, "finish")) {
                const st = if (o.get("status")) |v| (if (v == .string) v.string else "complete") else "complete";
                try doc.setMessageStatus(msg_id, st);
                if (open_turns.fetchRemove(msg_id)) |kv| self.gpa.free(kv.key);
            }
        }

        var aborted_count: usize = 0;
        var it = open_turns.iterator();
        while (it.next()) |e| {
            try doc.setMessageStatus(e.key_ptr.*, "aborted");
            aborted_count += 1;
        }
        return aborted_count;
    }
};

test "RunJournal replays streaming deltas and marks unfinished turns aborted on crash recovery" {
    const gpa = testing.allocator;
    var journal = RunJournal.init(gpa);
    defer journal.deinit();

    try journal.recordBegin("chat-1", "msg-crashed", 1000);
    try journal.recordDelta("chat-1", "msg-crashed", "p-1", "Partial output before crash...");

    var doc = try session_doc.SessionDoc.init(gpa, "chat-1", "dev-1");
    defer doc.deinit();

    const aborted = try journal.replayIntoDoc(&doc);
    try testing.expectEqual(@as(usize, 1), aborted);
    try testing.expectEqualStrings("Partial output before crash...", doc.messages.items[0].parts.items[0].text.items);
    try testing.expectEqualStrings("aborted", doc.messages.items[0].status.?);
}
