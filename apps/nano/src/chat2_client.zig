//! `Chat2RoomClient` — per-room `chat2` state machine (`crates/sync/src/chat_client.rs`,
//! `crates/engine/src/chat2_host.rs`).
//!
//! Coordinates `chat2_wire` binary frames (`hello`, `state`, `row`, `push`,
//! `ack`, `error`/quota), `SessionDoc` CRDT merges, and `DocsStore` C2 atomic
//! snapshot+cursor persistence.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const chat2_wire = @import("chat2_wire.zig");
const session_doc = @import("session_doc.zig");
const docs_store = @import("docs_store.zig");

pub const FrameOutcome = union(enum) {
    catch_up_plan: chat2_wire.CatchUpPlan,
    row_applied: u64,
    ack_processed: u64,
    quota_backoff_ms: u64,
    ignored,
};

pub const Chat2RoomClient = struct {
    gpa: Allocator,
    doc_id: []const u8,
    doc: *session_doc.SessionDoc,
    store: *docs_store.DocsStore,
    retry_after_ms: ?u64 = null,

    pub fn buildHelloFrame(self: *const Chat2RoomClient, token: []const u8, device_id: []const u8) ![]u8 {
        const cursor = self.store.snapshotCursor(self.doc_id) orelse 0;
        const epoch = self.store.snapshotEpoch(self.doc_id) orelse 2;
        const hdr_json = try std.fmt.allocPrint(
            self.gpa,
            "{{\"cursor\":{d},\"deviceId\":{f},\"epoch\":{d},\"token\":{f},\"v\":2}}",
            .{
                cursor,
                json.fmt(device_id, .{}),
                epoch,
                json.fmt(token, .{}),
            },
        );
        defer self.gpa.free(hdr_json);
        var parsed = try json.parseFromSlice(json.Value, self.gpa, hdr_json, .{});
        defer parsed.deinit();
        return chat2_wire.encodeValue(self.gpa, chat2_wire.FrameType.hello, parsed.value, "");
    }

    pub fn handleServerFrame(
        self: *Chat2RoomClient,
        raw_frame: []const u8,
        now_ms: i64,
    ) !FrameOutcome {
        var decoded = chat2_wire.decode(self.gpa, raw_frame) orelse return error.MalformedChat2Frame;
        defer decoded.deinit(self.gpa);

        if (decoded.header_parsed.value != .object) return .ignored;
        const hdr = decoded.header_parsed.value.object;

        switch (decoded.kind) {
            chat2_wire.FrameType.state => {
                const state = chat2_wire.StateHeader{
                    .head_seq = if (hdr.get("headSeq")) |v| (if (v == .integer) @intCast(@max(0, v.integer)) else 0) else 0,
                    .seq_floor = if (hdr.get("seqFloor")) |v| (if (v == .integer) @intCast(@max(0, v.integer)) else 0) else 0,
                    .checkpoint_seq = if (hdr.get("checkpointSeq")) |v| (if (v == .integer) @intCast(@max(0, v.integer)) else 0) else 0,
                    .checkpoint_size = if (hdr.get("checkpointSize")) |v| (if (v == .integer) @intCast(@max(0, v.integer)) else 0) else 0,
                };
                const local_cursor = self.store.snapshotCursor(self.doc_id) orelse 0;
                const frontier_ok = self.doc.frontierContained(self.gpa, decoded.payload);
                const plan = chat2_wire.planCatchUp(local_cursor, state, frontier_ok);
                return .{ .catch_up_plan = plan };
            },
            chat2_wire.FrameType.row => {
                const seq: u64 = if (hdr.get("seq")) |v| (if (v == .integer) @intCast(@max(0, v.integer)) else 0) else 0;
                const prev_cursor = self.store.snapshotCursor(self.doc_id) orelse 0;
                const next_cursor = chat2_wire.nextRowCursor(prev_cursor, seq) orelse return error.Chat2GapDetected;
                if (decoded.payload.len > 0) {
                    self.doc.importSnapshot(decoded.payload) catch {};
                }
                const prev_epoch = self.store.snapshotEpoch(self.doc_id) orelse 2;
                const snap = try self.doc.exportSnapshot(self.gpa);
                defer self.gpa.free(snap);
                try self.store.saveSnapshotWithCursor(self.doc_id, snap, next_cursor, prev_epoch, now_ms);
                return .{ .row_applied = next_cursor };
            },
            chat2_wire.FrameType.ack => {
                const batch_id = if (hdr.get("batchId")) |v| (if (v == .string) v.string else "") else "";
                const seq: u64 = if (hdr.get("seq")) |v| (if (v == .integer) @intCast(@max(0, v.integer)) else 0) else 0;
                if (batch_id.len > 0) {
                    self.store.acknowledgeChatUpdate(self.doc_id, batch_id);
                }
                const prev_cursor = self.store.snapshotCursor(self.doc_id) orelse 0;
                const next_cursor = chat2_wire.nextRowCursor(prev_cursor, seq) orelse @max(prev_cursor, seq);
                const prev_epoch = self.store.snapshotEpoch(self.doc_id) orelse 2;
                const snap = try self.doc.exportSnapshot(self.gpa);
                defer self.gpa.free(snap);
                try self.store.saveSnapshotWithCursor(self.doc_id, snap, next_cursor, prev_epoch, now_ms);
                return .{ .ack_processed = next_cursor };
            },
            chat2_wire.FrameType.@"error" => {
                const retry_ms: u64 = if (hdr.get("retryAfterMs")) |v|
                    (if (v == .integer) @intCast(@max(0, v.integer)) else 5000)
                else
                    5000;
                self.retry_after_ms = retry_ms;
                return .{ .quota_backoff_ms = retry_ms };
            },
            else => return .ignored,
        }
    }
};

test "Chat2RoomClient handles state catch-up planning, row C2 commit, ack outbox drain, and quota backoff" {
    const gpa = testing.allocator;
    var store = docs_store.DocsStore.init(gpa);
    defer store.deinit();
    var doc = try session_doc.SessionDoc.init(gpa, "chat-room-1", "dev-local");
    defer doc.deinit();

    try store.saveSnapshotWithCursor("chat-room-1", "HZD1{}", 10, 2, 1000);
    try store.enqueueChatUpdate("chat-room-1", "b-1", "delta");

    var client = Chat2RoomClient{
        .gpa = gpa,
        .doc_id = "chat-room-1",
        .doc = &doc,
        .store = &store,
    };

    // 1. Server sends ACK for batch `b-1` at seq 11 -> drains outbox and advances cursor to 11
    {
        var ack_hdr = try json.parseFromSlice(json.Value, gpa, "{\"batchId\":\"b-1\",\"seq\":11}", .{});
        defer ack_hdr.deinit();
        const frame = try chat2_wire.encodeValue(gpa, chat2_wire.FrameType.ack, ack_hdr.value, "");
        defer gpa.free(frame);
        const out = try client.handleServerFrame(frame, 1005);
        try testing.expectEqual(@as(u64, 11), out.ack_processed);
        try testing.expect(!store.hasPendingChatUpdates("chat-room-1"));
        try testing.expectEqual(@as(?u64, 11), store.snapshotCursor("chat-room-1"));
    }

    // 2. Server sends Error/Quota frame -> sets retry_after_ms without losing state
    {
        var quota_hdr = try json.parseFromSlice(json.Value, gpa, "{\"code\":\"quota_exceeded\",\"retryAfterMs\":3500}", .{});
        defer quota_hdr.deinit();
        const frame = try chat2_wire.encodeValue(gpa, chat2_wire.FrameType.@"error", quota_hdr.value, "");
        defer gpa.free(frame);
        const out = try client.handleServerFrame(frame, 1010);
        try testing.expectEqual(@as(u64, 3500), out.quota_backoff_ms);
        try testing.expectEqual(@as(?u64, 3500), client.retry_after_ms);
    }
}
