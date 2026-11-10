//! Multi-Machine Sync Simulation (`reg1` Workspace Registry + `chat2` CRDT Room Relay).
//!
//! Simulates multiple independent machines (`EngineHost` instances, each with its
//! own SQLite `DocsStore`, `RegistryDoc`, `SessionDoc`, and live `Watch*` UI
//! subscriptions) synchronizing over the `chat2` binary wire protocol and `reg1`
//! per-field LWW registry.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const chat2_wire = @import("chat2_wire.zig");
const chat2_client = @import("chat2_client.zig");
const session_doc = @import("session_doc.zig");
const docs_store = @import("docs_store.zig");
const registry_sync = @import("registry_sync.zig");
const engine_host = @import("engine_host.zig");
const transcript = @import("transcript.zig");

pub const EdgeRow = struct {
    seq: u64,
    batch_id: []u8,
    payload: []u8,

    pub fn deinit(self: *EdgeRow, gpa: Allocator) void {
        gpa.free(self.batch_id);
        gpa.free(self.payload);
    }
};

pub const SimulatedEdgeRelay = struct {
    gpa: Allocator,
    chat_id: []u8,
    head_seq: u64 = 0,
    checkpoint_seq: u64 = 0,
    checkpoint_bytes: []u8 = &.{},
    checkpoint_frontier: []u8 = &.{},
    rows: std.ArrayList(EdgeRow) = .empty,

    pub fn init(gpa: Allocator, chat_id: []const u8) !SimulatedEdgeRelay {
        return .{
            .gpa = gpa,
            .chat_id = try gpa.dupe(u8, chat_id),
        };
    }

    pub fn deinit(self: *SimulatedEdgeRelay) void {
        self.gpa.free(self.chat_id);
        if (self.checkpoint_bytes.len > 0) self.gpa.free(self.checkpoint_bytes);
        if (self.checkpoint_frontier.len > 0) self.gpa.free(self.checkpoint_frontier);
        for (self.rows.items) |*r| r.deinit(self.gpa);
        self.rows.deinit(self.gpa);
    }

    /// Compact the current state of `source_doc` at `head_seq` into an edge checkpoint
    /// (mirroring `edge/src/chat-room.ts` R2 checkpoint compaction).
    pub fn compactCheckpointFrom(self: *SimulatedEdgeRelay, source_doc: *const session_doc.SessionDoc) !void {
        const snap = try source_doc.exportSnapshot(self.gpa);
        errdefer self.gpa.free(snap);
        const frontier = try source_doc.exportFrontier(self.gpa);
        errdefer self.gpa.free(frontier);

        if (self.checkpoint_bytes.len > 0) self.gpa.free(self.checkpoint_bytes);
        if (self.checkpoint_frontier.len > 0) self.gpa.free(self.checkpoint_frontier);
        self.checkpoint_bytes = snap;
        self.checkpoint_frontier = frontier;
        self.checkpoint_seq = self.head_seq;
    }

    /// Replicate `reg1` LWW workspace registry rows (spaces + chats) from `sender`
    /// to all `peers`, firing live `WatchSpaces` and `WatchChats` stream items on each peer.
    pub fn syncRegistry(
        self: *SimulatedEdgeRelay,
        sender: *engine_host.EngineHost,
        peers: []const *engine_host.EngineHost,
        ts: i64,
    ) !void {
        _ = self;
        for (peers) |peer| {
            // 1. Merge spaces
            for (sender.spaces.items) |sp| {
                const won_name = try peer.registry.setField(.spaces, sp.id, "name", sp.name, ts, sender.device_id);
                const won_path = try peer.registry.setField(.spaces, sp.id, "path", sp.path, ts, sender.device_id);
                if (won_name or won_path) {
                    var found = false;
                    for (peer.spaces.items) |*existing| {
                        if (std.mem.eql(u8, existing.id, sp.id)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try peer.spaces.append(peer.gpa, .{
                            .id = try peer.gpa.dupe(u8, sp.id),
                            .device_id = try peer.gpa.dupe(u8, sp.device_id),
                            .path = try peer.gpa.dupe(u8, sp.path),
                            .name = try peer.gpa.dupe(u8, sp.name),
                            .git_detected = sp.git_detected,
                        });
                    }
                }
            }
            const sp_json = try peer.spacesJson();
            defer peer.gpa.free(sp_json);
            try peer.broadcastWatch(.spaces, null, sp_json);

            // 2. Merge chats
            for (sender.chats.items) |ch| {
                const won = try peer.registry.setField(.chats, ch.id, "harness", ch.harness, ts, sender.device_id);
                if (won) {
                    var found = false;
                    for (peer.chats.items) |*existing| {
                        if (std.mem.eql(u8, existing.id, ch.id)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try peer.chats.append(peer.gpa, .{
                            .id = try peer.gpa.dupe(u8, ch.id),
                            .space_id = if (ch.space_id) |s| try peer.gpa.dupe(u8, s) else null,
                            .device_id = try peer.gpa.dupe(u8, ch.device_id),
                            .harness = try peer.gpa.dupe(u8, ch.harness),
                            .archived = ch.archived,
                        });
                    }
                }
            }
            const ch_json = try peer.chatsJson();
            defer peer.gpa.free(ch_json);
            try peer.broadcastWatch(.chats, null, ch_json);
            const sess_json = try peer.sessionsJson();
            defer peer.gpa.free(sess_json);
            try peer.broadcastWatch(.sessions, null, sess_json);
        }
    }

    /// Drain pending `chat_outbox` batches for `self.chat_id` from `sender`, encode real
    /// `chat2` binary `push` frames, assign monotonic room `seq`, return binary `ack`
    /// to `sender`, and broadcast binary `row` frames to all online `peers`.
    pub fn flushOutboxAndBroadcast(
        self: *SimulatedEdgeRelay,
        sender: *engine_host.EngineHost,
        peers: []const *engine_host.EngineHost,
        now_ms: i64,
    ) !void {
        const sender_doc = try sender.getOrCreateDoc(self.chat_id);
        var sender_client = chat2_client.Chat2RoomClient{
            .gpa = self.gpa,
            .doc_id = self.chat_id,
            .doc = sender_doc,
            .store = &sender.store,
        };

        // Snapshot current outbox items for `chat_id`
        var pending_batches: std.ArrayList(struct { batch_id: []u8, bytes: []u8 }) = .empty;
        defer {
            for (pending_batches.items) |b| {
                self.gpa.free(b.batch_id);
                self.gpa.free(b.bytes);
            }
            pending_batches.deinit(self.gpa);
        }
        for (sender.store.outbox.items) |item| {
            if (std.mem.eql(u8, item.doc_id, self.chat_id)) {
                try pending_batches.append(self.gpa, .{
                    .batch_id = try self.gpa.dupe(u8, item.batch_id),
                    .bytes = try self.gpa.dupe(u8, item.bytes),
                });
            }
        }

        for (pending_batches.items) |batch| {
            // 1. Encode binary `push` frame from sender and decode on Edge Relay
            const push_hdr_str = try std.fmt.allocPrint(self.gpa, "{{\"batchId\":{f}}}", .{json.fmt(batch.batch_id, .{})});
            defer self.gpa.free(push_hdr_str);
            var push_hdr = try json.parseFromSlice(json.Value, self.gpa, push_hdr_str, .{});
            defer push_hdr.deinit();
            const push_wire = try chat2_wire.encodeValue(self.gpa, chat2_wire.FrameType.push, push_hdr.value, batch.bytes);
            defer self.gpa.free(push_wire);

            var decoded_push = chat2_wire.decode(self.gpa, push_wire) orelse return error.InvalidPushFrame;
            defer decoded_push.deinit(self.gpa);

            self.head_seq += 1;
            const seq = self.head_seq;
            try self.rows.append(self.gpa, .{
                .seq = seq,
                .batch_id = try self.gpa.dupe(u8, batch.batch_id),
                .payload = try self.gpa.dupe(u8, decoded_push.payload),
            });

            // 2. Edge Relay sends binary `ack` back to `sender` -> drains outbox + C2 commit
            const ack_hdr_str = try std.fmt.allocPrint(
                self.gpa,
                "{{\"batchId\":{f},\"seq\":{d}}}",
                .{ json.fmt(batch.batch_id, .{}), seq },
            );
            defer self.gpa.free(ack_hdr_str);
            var ack_hdr = try json.parseFromSlice(json.Value, self.gpa, ack_hdr_str, .{});
            defer ack_hdr.deinit();
            const ack_wire = try chat2_wire.encodeValue(self.gpa, chat2_wire.FrameType.ack, ack_hdr.value, "");
            defer self.gpa.free(ack_wire);
            _ = try sender_client.handleServerFrame(ack_wire, now_ms);

            // 3. Edge Relay broadcasts binary `row(seq)` to all online `peers`
            const row_hdr_str = try std.fmt.allocPrint(self.gpa, "{{\"seq\":{d}}}", .{seq});
            defer self.gpa.free(row_hdr_str);
            var row_hdr = try json.parseFromSlice(json.Value, self.gpa, row_hdr_str, .{});
            defer row_hdr.deinit();
            const row_wire = try chat2_wire.encodeValue(self.gpa, chat2_wire.FrameType.row, row_hdr.value, decoded_push.payload);
            defer self.gpa.free(row_wire);

            for (peers) |peer| {
                const peer_doc = try peer.getOrCreateDoc(self.chat_id);
                var peer_client = chat2_client.Chat2RoomClient{
                    .gpa = self.gpa,
                    .doc_id = self.chat_id,
                    .doc = peer_doc,
                    .store = &peer.store,
                };
                _ = try peer_client.handleServerFrame(row_wire, now_ms);

                // Push live `WatchDocMessages` frame to any UI subscriber on `peer`!
                const reset_json = try peer_doc.toResetFrameJson(peer.gpa);
                defer peer.gpa.free(reset_json);
                try peer.broadcastWatch(.doc_messages, self.chat_id, reset_json);
            }
        }
    }

    /// Connect a late-joining or reconnecting machine (`peer`):
    /// `hello` -> `state` -> `planCatchUp` -> checkpoint (if needed) + tail rows -> C2 commit.
    pub fn catchUpPeer(
        self: *SimulatedEdgeRelay,
        peer: *engine_host.EngineHost,
        now_ms: i64,
    ) !chat2_wire.CatchUpPlan {
        const peer_doc = try peer.getOrCreateDoc(self.chat_id);
        var peer_client = chat2_client.Chat2RoomClient{
            .gpa = self.gpa,
            .doc_id = self.chat_id,
            .doc = peer_doc,
            .store = &peer.store,
        };

        // 1. Peer sends `hello`
        const hello_wire = try peer_client.buildHelloFrame("tok-synthetic", peer.device_id);
        defer self.gpa.free(hello_wire);
        var decoded_hello = chat2_wire.decode(self.gpa, hello_wire) orelse return error.InvalidHelloFrame;
        defer decoded_hello.deinit(self.gpa);

        // 2. Edge Relay replies with `state` frame + checkpoint frontier payload
        const state_hdr_str = try std.fmt.allocPrint(
            self.gpa,
            "{{\"checkpointSeq\":{d},\"checkpointSize\":{d},\"headSeq\":{d},\"seqFloor\":1}}",
            .{ self.checkpoint_seq, self.checkpoint_bytes.len, self.head_seq },
        );
        defer self.gpa.free(state_hdr_str);
        var state_hdr = try json.parseFromSlice(json.Value, self.gpa, state_hdr_str, .{});
        defer state_hdr.deinit();
        const state_wire = try chat2_wire.encodeValue(
            self.gpa,
            chat2_wire.FrameType.state,
            state_hdr.value,
            self.checkpoint_frontier,
        );
        defer self.gpa.free(state_wire);

        const outcome = try peer_client.handleServerFrame(state_wire, now_ms);
        const plan = outcome.catch_up_plan;

        // 3. Execute `CatchUpPlan`
        const after_seq: u64 = switch (plan) {
            .checkpoint_then_rows => |c| blk: {
                try peer_doc.importSnapshot(self.checkpoint_bytes);
                try peer.store.saveSnapshotWithCursor(self.chat_id, self.checkpoint_bytes, self.checkpoint_seq, 2, now_ms);
                break :blk c.after;
            },
            .rows_only => |r| r.after,
        };

        // 4. Stream tail rows `seq > after_seq`
        for (self.rows.items) |row| {
            if (row.seq <= after_seq) continue;
            const row_hdr_str = try std.fmt.allocPrint(self.gpa, "{{\"seq\":{d}}}", .{row.seq});
            defer self.gpa.free(row_hdr_str);
            var row_hdr = try json.parseFromSlice(json.Value, self.gpa, row_hdr_str, .{});
            defer row_hdr.deinit();
            const row_wire = try chat2_wire.encodeValue(self.gpa, chat2_wire.FrameType.row, row_hdr.value, row.payload);
            defer self.gpa.free(row_wire);
            _ = try peer_client.handleServerFrame(row_wire, now_ms);
        }

        const reset_json = try peer_doc.toResetFrameJson(peer.gpa);
        defer peer.gpa.free(reset_json);
        try peer.broadcastWatch(.doc_messages, self.chat_id, reset_json);
        return plan;
    }
};

fn execRpc(host: *engine_host.EngineHost, call_id: u64, method: []const u8, params_json: []const u8) !void {
    var parsed = try json.parseFromSlice(json.Value, host.gpa, params_json, .{});
    defer parsed.deinit();
    var out = try host.handleWithId(call_id, method, parsed.value);
    switch (out) {
        .unary_json => |b| host.gpa.free(b),
        .stream_items_json => |*st| st.deinit(host.gpa),
        .err => return error.UnexpectedRpcError,
    }
}

test "multi-machine sync: Machine A (macOS) <-> Edge Relay <-> Machine B (Linux) <-> late-joining Machine C (iOS)" {
    const gpa = testing.allocator;

    // 3 separate machines, each backed by its own SQLite `:memory:` DocsStore!
    var machine_a = try engine_host.EngineHost.init(gpa, "dev-macbook-a", "MacBook Pro A");
    defer machine_a.deinit();
    machine_a.store.deinit();
    machine_a.store = try docs_store.DocsStore.openSqlite(gpa, ":memory:");

    var machine_b = try engine_host.EngineHost.init(gpa, "dev-linux-b", "Linux Workstation B");
    defer machine_b.deinit();
    machine_b.store.deinit();
    machine_b.store = try docs_store.DocsStore.openSqlite(gpa, ":memory:");

    var machine_c = try engine_host.EngineHost.init(gpa, "dev-ipad-c", "iPad Pro C");
    defer machine_c.deinit();
    machine_c.store.deinit();
    machine_c.store = try docs_store.DocsStore.openSqlite(gpa, ":memory:");

    var relay = try SimulatedEdgeRelay.init(gpa, "chat-shared-1");
    defer relay.deinit();

    // Machine B opens live UI watches (`WatchChats` on sub_id=10, `WatchDocMessages` on sub_id=20)
    try execRpc(&machine_b, 10, "WatchChats", "{}");
    try execRpc(&machine_b, 20, "WatchDocMessages", "{\"chatId\":\"chat-shared-1\"}");

    // -------------------------------------------------------------------------
    // Step 1: Machine A creates a Space + Chat and runs Turn 1
    // -------------------------------------------------------------------------
    try execRpc(&machine_a, 1, "Mutate", "{\"op\":\"createSpace\",\"spaceId\":\"sp-1\",\"path\":\"/workspace/project\",\"name\":\"Project\"}");
    try execRpc(&machine_a, 2, "Mutate", "{\"op\":\"createChat\",\"chatId\":\"chat-shared-1\",\"spaceId\":\"sp-1\",\"config\":{\"harness\":\"mock\"}}");
    try execRpc(&machine_a, 3, "QueueCommand", "{\"chatId\":\"chat-shared-1\",\"command\":{\"kind\":\"run\",\"messageId\":\"msg-u1\",\"request\":{\"prompt\":\"Hello from Machine A!\"}}}");

    // Machine A has 1 pending outbox batch before syncing with Edge Relay
    try testing.expect(machine_a.store.hasPendingChatUpdates("chat-shared-1"));

    // Sync `reg1` registry and `chat2` outbox from Machine A -> Edge Relay -> Machine B
    try relay.syncRegistry(&machine_a, &.{&machine_b}, 1000);
    try relay.flushOutboxAndBroadcast(&machine_a, &.{&machine_b}, 1005);

    // Machine A's outbox was drained by the Edge Relay's `ack(seq=1)`, and both A and B are at cursor=1!
    try testing.expect(!machine_a.store.hasPendingChatUpdates("chat-shared-1"));
    try testing.expectEqual(@as(?u64, 1), machine_a.store.snapshotCursor("chat-shared-1"));
    try testing.expectEqual(@as(?u64, 1), machine_b.store.snapshotCursor("chat-shared-1"));
    try testing.expectEqual(@as(usize, 1), machine_b.chats.items.len);
    try testing.expect(machine_b.pushed_frames.items.len >= 2); // WatchChats + WatchDocMessages pushed!

    // Edge Relay compacts Turn 1 (`seq=1`) into an R2 checkpoint
    const doc_a = try machine_a.getOrCreateDoc("chat-shared-1");
    try relay.compactCheckpointFrom(doc_a);
    try testing.expectEqual(@as(u64, 1), relay.checkpoint_seq);

    // -------------------------------------------------------------------------
    // Step 2: Machine B (the second machine!) sends a follow-up prompt (Turn 2)
    // -------------------------------------------------------------------------
    try execRpc(&machine_b, 4, "QueueCommand", "{\"chatId\":\"chat-shared-1\",\"command\":{\"kind\":\"run\",\"messageId\":\"msg-u2\",\"request\":{\"prompt\":\"Continuing from Machine B!\"}}}");
    try relay.flushOutboxAndBroadcast(&machine_b, &.{&machine_a}, 2005);

    // Both Machine A and Machine B are now at `cursor = 2` with 4 messages (2 user + 2 assistant)!
    const doc_b = try machine_b.getOrCreateDoc("chat-shared-1");
    try testing.expectEqual(@as(?u64, 2), machine_a.store.snapshotCursor("chat-shared-1"));
    try testing.expectEqual(@as(?u64, 2), machine_b.store.snapshotCursor("chat-shared-1"));
    try testing.expectEqual(@as(usize, 4), doc_a.messages.items.len);
    try testing.expectEqual(@as(usize, 4), doc_b.messages.items.len);

    // -------------------------------------------------------------------------
    // Step 3: Machine C joins late from `cursor = 0` -> `planCatchUp` selects
    // `.checkpoint_then_rows = .{ .after = 1 }`, fetches checkpoint (seq=1) +
    // tail row (seq=2), and converges with Machine A and Machine B!
    // -------------------------------------------------------------------------
    const plan_c = try relay.catchUpPeer(&machine_c, 3000);
    try testing.expectEqual(chat2_wire.CatchUpPlan{ .checkpoint_then_rows = .{ .after = 1 } }, plan_c);
    try testing.expectEqual(@as(?u64, 2), machine_c.store.snapshotCursor("chat-shared-1"));

    const doc_c = try machine_c.getOrCreateDoc("chat-shared-1");
    try testing.expectEqual(@as(usize, 4), doc_c.messages.items.len);

    // Verify all 3 machines produce the exact same UI `Transcript` entries!
    for ([_]*session_doc.SessionDoc{ doc_a, doc_b, doc_c }) |doc| {
        const reset_json = try doc.toResetFrameJson(gpa);
        defer gpa.free(reset_json);
        var parsed = try json.parseFromSlice(json.Value, gpa, reset_json, .{});
        defer parsed.deinit();
        var tr: transcript.Transcript = .{ .gpa = gpa };
        defer tr.deinit();
        try tr.apply(parsed.value);
        try testing.expectEqual(@as(usize, 4), tr.entries.items.len);
        try testing.expectEqualStrings("Hello from Machine A!", tr.entries.items[0].parts.items[0].text.items);
        try testing.expectEqualStrings("Continuing from Machine B!", tr.entries.items[2].parts.items[0].text.items);
    }

    // Reconnecting Machine C again when already caught up selects `.rows_only = .{ .after = 2 }` (skips checkpoint!)
    const plan_c_reconnect = try relay.catchUpPeer(&machine_c, 3010);
    try testing.expectEqual(chat2_wire.CatchUpPlan{ .rows_only = .{ .after = 2 } }, plan_c_reconnect);
}
