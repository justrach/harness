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

fn isEdgeHlcValid(hlc: []const u8) bool {
    // Matches `HLC_RE = /^\d{13}-\d{6}-[A-Za-z0-9_-]{1,128}$/` in `edge/src/registry-core.ts`.
    if (hlc.len < 22 or hlc.len > 149) return false;
    for (hlc[0..13]) |c| if (!std.ascii.isDigit(c)) return false;
    if (hlc[13] != '-') return false;
    for (hlc[14..20]) |c| if (!std.ascii.isDigit(c)) return false;
    if (hlc[20] != '-') return false;
    const dev = hlc[21..];
    if (dev.len == 0 or dev.len > 128) return false;
    for (dev) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

fn isEdgeFieldNameValid(name: []const u8) bool {
    // Matches `FIELD_RE = /^[a-zA-Z][a-zA-Z0-9]{0,63}$/` in `edge/src/registry-core.ts`.
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

test "two-way HTTP Edge sync: local Zig EngineHost session creation, turn execution, and tail sidecar sync to peer clients" {
    const gpa = testing.allocator;
    const io = testing.io;

    const StoredRegRow = struct {
        kind: []u8,
        id: []u8,
        seq: u64,
        deleted: bool,
        del_hlc: ?[]u8 = null,
        fields_json: std.StringHashMapUnmanaged([]u8) = .empty,
        clocks: std.StringHashMapUnmanaged([]u8) = .empty,

        fn maxClock(self: *const @This()) ?[]const u8 {
            var m: ?[]const u8 = self.del_hlc;
            var it = self.clocks.iterator();
            while (it.next()) |e| {
                if (m == null or std.mem.order(u8, e.value_ptr.*, m.?) == .gt) {
                    m = e.value_ptr.*;
                }
            }
            return m;
        }

        fn clearFieldsAndClocks(self: *@This(), alloc: Allocator) void {
            var fit = self.fields_json.iterator();
            while (fit.next()) |e| {
                alloc.free(e.key_ptr.*);
                alloc.free(e.value_ptr.*);
            }
            self.fields_json.clearRetainingCapacity();
            var cit = self.clocks.iterator();
            while (cit.next()) |e| {
                alloc.free(e.key_ptr.*);
                alloc.free(e.value_ptr.*);
            }
            self.clocks.clearRetainingCapacity();
        }

        fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.kind);
            alloc.free(self.id);
            if (self.del_hlc) |d| alloc.free(d);
            self.clearFieldsAndClocks(alloc);
            self.fields_json.deinit(alloc);
            self.clocks.deinit(alloc);
        }
    };

    const EdgeMockState = struct {
        mutex: std.Io.Mutex = .init,
        seq: u64 = 0,
        rows: std.ArrayList(StoredRegRow) = .empty,
        presence: std.StringHashMapUnmanaged(i64) = .empty,
        tails: std.StringHashMapUnmanaged([]u8) = .empty,
        invalid_ops: usize = 0,

        fn deinit(self: *@This(), alloc: Allocator) void {
            for (self.rows.items) |*r| r.deinit(alloc);
            self.rows.deinit(alloc);
            var pit = self.presence.iterator();
            while (pit.next()) |e| alloc.free(e.key_ptr.*);
            self.presence.deinit(alloc);
            var tit = self.tails.iterator();
            while (tit.next()) |e| {
                alloc.free(e.key_ptr.*);
                alloc.free(e.value_ptr.*);
            }
            self.tails.deinit(alloc);
        }

        fn findRow(self: *@This(), kind: []const u8, id: []const u8) ?*StoredRegRow {
            for (self.rows.items) |*r| {
                if (std.mem.eql(u8, r.kind, kind) and std.mem.eql(u8, r.id, id)) return r;
            }
            return null;
        }
    };

    var edge_state = EdgeMockState{};
    defer edge_state.deinit(gpa);

    const any_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var mock_srv = try any_addr.listen(io, .{ .reuse_address = true });
    defer mock_srv.deinit(io);
    const mock_port = mock_srv.socket.address.getPort();
    var stop_mock = std.atomic.Value(bool).init(false);

    const ServerWorker = struct {
        srv: *std.Io.net.Server,
        tio: std.Io,
        alloc: Allocator,
        stop: *std.atomic.Value(bool),
        state: *EdgeMockState,

        fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
            const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
            var it = std.mem.splitScalar(u8, target[qmark + 1 ..], '&');
            while (it.next()) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
            }
            return null;
        }

        fn handleConn(ctx: @This(), stream: *std.Io.net.Stream) void {
            var rbuf: [16384]u8 = undefined;
            var wbuf: [16384]u8 = undefined;
            var reader = stream.reader(ctx.tio, &rbuf);
            var writer = stream.writer(ctx.tio, &wbuf);

            while (!ctx.stop.load(.acquire)) {
                const req_line_raw = reader.interface.takeDelimiterInclusive('\n') catch return;
                const req_line = std.mem.trimEnd(u8, req_line_raw, "\r\n");
                if (req_line.len == 0) return;

                var parts_it = std.mem.splitScalar(u8, req_line, ' ');
                const method = parts_it.next() orelse return;
                const target = parts_it.next() orelse return;
                const path_only = if (std.mem.indexOfScalar(u8, target, '?')) |qi| target[0..qi] else target;

                var content_len: usize = 0;
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
                    if (trimmed.len == 0) break;
                    if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                        const val = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                        content_len = std.fmt.parseInt(usize, val, 10) catch 0;
                    }
                }
                const body_buf = ctx.alloc.alloc(u8, content_len) catch return;
                defer ctx.alloc.free(body_buf);
                if (content_len > 0) {
                    reader.interface.readSliceAll(body_buf) catch return;
                }

                var status: u16 = 200;
                var resp_body: []u8 = &.{};
                defer if (resp_body.len > 0) ctx.alloc.free(resp_body);

                ctx.state.mutex.lockUncancelable(ctx.tio);
                if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_only, "/registry/org_1/push")) {
                    var parsed = json.parseFromSlice(json.Value, ctx.alloc, body_buf, .{}) catch null;
                    defer if (parsed) |*p| p.deinit();
                    if (parsed == null or parsed.?.value != .object) {
                        status = 400;
                        resp_body = ctx.alloc.dupe(u8, "{\"error\":\"bad_push\"}") catch &.{};
                    } else {
                        const fo = parsed.?.value.object;
                        const batch = if (fo.get("batch")) |bv| (if (bv == .string) bv.string else "") else "";
                        const ops_v = fo.get("ops");
                        if (batch.len == 0 or ops_v == null or ops_v.? != .array or ops_v.?.array.items.len == 0) {
                            status = 400;
                            resp_body = ctx.alloc.dupe(u8, "{\"error\":\"bad_push\"}") catch &.{};
                        } else {
                            var batch_valid = true;
                            for (ops_v.?.array.items) |opv| {
                                if (opv != .object) {
                                    batch_valid = false;
                                    break;
                                }
                                const oo = opv.object;
                                const k = if (oo.get("kind")) |kv| (if (kv == .string) kv.string else "") else "";
                                const rid = if (oo.get("id")) |iv| (if (iv == .string) iv.string else "") else "";
                                const opk = if (oo.get("op")) |ov| (if (ov == .string) ov.string else "") else "";
                                const hlc = if (oo.get("hlc")) |hv| (if (hv == .string) hv.string else "") else "";
                                if (k.len == 0 or rid.len == 0 or !isEdgeHlcValid(hlc)) {
                                    batch_valid = false;
                                    break;
                                }
                                if (std.mem.eql(u8, opk, "delete")) {
                                    if (oo.get("set") != null or std.mem.eql(u8, k, "sidebarPins")) {
                                        batch_valid = false;
                                        break;
                                    }
                                } else if (std.mem.eql(u8, opk, "upsert") or std.mem.eql(u8, opk, "update")) {
                                    const sv = oo.get("set") orelse {
                                        batch_valid = false;
                                        break;
                                    };
                                    if (sv != .object) {
                                        batch_valid = false;
                                        break;
                                    }
                                    var sit = sv.object.iterator();
                                    while (sit.next()) |se| {
                                        if (!isEdgeFieldNameValid(se.key_ptr.*)) {
                                            batch_valid = false;
                                            break;
                                        }
                                    }
                                    if (!batch_valid) break;
                                } else {
                                    batch_valid = false;
                                    break;
                                }
                            }
                            if (!batch_valid) {
                                ctx.state.invalid_ops += 1;
                                status = 400;
                                resp_body = ctx.alloc.dupe(u8, "{\"error\":\"invalid_op\"}") catch &.{};
                            } else {
                                const next_seq = ctx.state.seq + 1;
                                var applied: u64 = 0;
                                for (ops_v.?.array.items) |opv| {
                                    const oo = opv.object;
                                    const k = oo.get("kind").?.string;
                                    const rid = oo.get("id").?.string;
                                    const opk = oo.get("op").?.string;
                                    const hlc = oo.get("hlc").?.string;
                                    if (std.mem.eql(u8, opk, "delete")) {
                                        if (ctx.state.findRow(k, rid)) |existing| {
                                            const cmp_clock = if (existing.deleted) existing.del_hlc else existing.maxClock();
                                            if (cmp_clock == null or std.mem.order(u8, hlc, cmp_clock.?) == .gt) {
                                                if (existing.del_hlc) |old_d| ctx.alloc.free(old_d);
                                                existing.del_hlc = ctx.alloc.dupe(u8, hlc) catch null;
                                                existing.deleted = true;
                                                existing.seq = next_seq;
                                                existing.clearFieldsAndClocks(ctx.alloc);
                                                applied += 1;
                                            }
                                        } else {
                                            ctx.state.rows.append(ctx.alloc, .{
                                                .kind = ctx.alloc.dupe(u8, k) catch continue,
                                                .id = ctx.alloc.dupe(u8, rid) catch continue,
                                                .seq = next_seq,
                                                .deleted = true,
                                                .del_hlc = ctx.alloc.dupe(u8, hlc) catch null,
                                            }) catch {};
                                            applied += 1;
                                        }
                                    } else {
                                        var row_ptr = ctx.state.findRow(k, rid);
                                        var row_changed = false;
                                        if (row_ptr == null) {
                                            if (std.mem.eql(u8, opk, "update")) continue;
                                            ctx.state.rows.append(ctx.alloc, .{
                                                .kind = ctx.alloc.dupe(u8, k) catch continue,
                                                .id = ctx.alloc.dupe(u8, rid) catch continue,
                                                .seq = next_seq,
                                                .deleted = false,
                                            }) catch continue;
                                            row_ptr = &ctx.state.rows.items[ctx.state.rows.items.len - 1];
                                            row_changed = true;
                                        } else if (row_ptr.?.deleted) {
                                            if (std.mem.eql(u8, opk, "update")) continue;
                                            if (row_ptr.?.del_hlc) |dh| {
                                                if (std.mem.order(u8, hlc, dh) != .gt) continue;
                                            }
                                            row_ptr.?.deleted = false;
                                            row_ptr.?.clearFieldsAndClocks(ctx.alloc);
                                            row_changed = true;
                                        }
                                        const rp = row_ptr.?;
                                        var sit = oo.get("set").?.object.iterator();
                                        while (sit.next()) |se| {
                                            const fname = se.key_ptr.*;
                                            if (rp.clocks.get(fname)) |prev_clk| {
                                                if (std.mem.order(u8, hlc, prev_clk) != .gt) continue;
                                            }
                                            if (se.value_ptr.* == .null) {
                                                if (rp.fields_json.fetchRemove(fname)) |rem| {
                                                    ctx.alloc.free(rem.key);
                                                    ctx.alloc.free(rem.value);
                                                }
                                            } else {
                                                const v_str = std.fmt.allocPrint(ctx.alloc, "{f}", .{json.fmt(se.value_ptr.*, .{})}) catch continue;
                                                const fgop = rp.fields_json.getOrPut(ctx.alloc, fname) catch {
                                                    ctx.alloc.free(v_str);
                                                    continue;
                                                };
                                                if (fgop.found_existing) {
                                                    ctx.alloc.free(fgop.value_ptr.*);
                                                } else {
                                                    fgop.key_ptr.* = ctx.alloc.dupe(u8, fname) catch {
                                                        _ = rp.fields_json.remove(fname);
                                                        ctx.alloc.free(v_str);
                                                        continue;
                                                    };
                                                }
                                                fgop.value_ptr.* = v_str;
                                            }
                                            const cgop = rp.clocks.getOrPut(ctx.alloc, fname) catch continue;
                                            if (cgop.found_existing) {
                                                ctx.alloc.free(cgop.value_ptr.*);
                                            } else {
                                                cgop.key_ptr.* = ctx.alloc.dupe(u8, fname) catch continue;
                                            }
                                            cgop.value_ptr.* = ctx.alloc.dupe(u8, hlc) catch continue;
                                            row_changed = true;
                                        }
                                        if (row_changed) {
                                            rp.seq = next_seq;
                                            applied += 1;
                                        }
                                    }
                                }
                                if (applied > 0) ctx.state.seq = next_seq;
                                resp_body = std.fmt.allocPrint(
                                    ctx.alloc,
                                    "{{\"batch\":{f},\"seq\":{d},\"applied\":{d}}}",
                                    .{ json.fmt(batch, .{}), ctx.state.seq, applied },
                                ) catch &.{};
                            }
                        }
                    }
                } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_only, "/registry/org_1/rows")) {
                    const since: u64 = if (queryParam(target, "since")) |s| (std.fmt.parseInt(u64, s, 10) catch 0) else 0;
                    if (queryParam(target, "device")) |dev| {
                        if (dev.len > 0 and std.mem.eql(u8, queryParam(target, "beat") orelse "", "1")) {
                            const now_ms: i64 = @intCast(std.Io.Clock.real.now(ctx.tio).toMilliseconds());
                            const pgop = ctx.state.presence.getOrPut(ctx.alloc, dev) catch null;
                            if (pgop) |g| {
                                if (!g.found_existing) {
                                    g.key_ptr.* = ctx.alloc.dupe(u8, dev) catch {
                                        _ = ctx.state.presence.remove(dev);
                                        ctx.state.mutex.unlock(ctx.tio);
                                        return;
                                    };
                                }
                                g.value_ptr.* = now_ms;
                            }
                        }
                    }
                    var aw: std.Io.Writer.Allocating = .init(ctx.alloc);
                    const w = &aw.writer;
                    const full = since > ctx.state.seq;
                    w.print("{{\"seq\":{d},\"full\":{},\"gcFloor\":0,\"rows\":[", .{ ctx.state.seq, full }) catch {};
                    var first_row = true;
                    for (ctx.state.rows.items) |r| {
                        if (!full and r.seq <= since) continue;
                        if (!first_row) w.writeByte(',') catch {};
                        first_row = false;
                        w.print("{{\"kind\":{f},\"id\":{f},\"seq\":{d},\"deleted\":{}", .{
                            json.fmt(r.kind, .{}),
                            json.fmt(r.id, .{}),
                            r.seq,
                            r.deleted,
                        }) catch {};
                        if (r.del_hlc) |dh| w.print(",\"delHlc\":{f}", .{json.fmt(dh, .{})}) catch {};
                        w.writeAll(",\"fields\":{") catch {};
                        var f_first = true;
                        var fit = r.fields_json.iterator();
                        while (fit.next()) |fe| {
                            if (!f_first) w.writeByte(',') catch {};
                            f_first = false;
                            w.print("{f}:{s}", .{ json.fmt(fe.key_ptr.*, .{}), fe.value_ptr.* }) catch {};
                        }
                        w.writeAll("},\"clocks\":{") catch {};
                        var c_first = true;
                        var cit = r.clocks.iterator();
                        while (cit.next()) |ce| {
                            if (!c_first) w.writeByte(',') catch {};
                            c_first = false;
                            w.print("{f}:{f}", .{ json.fmt(ce.key_ptr.*, .{}), json.fmt(ce.value_ptr.*, .{}) }) catch {};
                        }
                        w.writeAll("}}") catch {};
                    }
                    w.writeAll("],\"presence\":{") catch {};
                    var p_first = true;
                    var pit = ctx.state.presence.iterator();
                    while (pit.next()) |pe| {
                        if (!p_first) w.writeByte(',') catch {};
                        p_first = false;
                        w.print("{f}:{d}", .{ json.fmt(pe.key_ptr.*, .{}), pe.value_ptr.* }) catch {};
                    }
                    w.writeAll("}}") catch {};
                    resp_body = aw.toOwnedSlice() catch &.{};
                } else if (std.mem.startsWith(u8, path_only, "/chat2/") and std.mem.endsWith(u8, path_only, "/tail")) {
                    const cid = path_only["/chat2/".len .. path_only.len - "/tail".len];
                    if (std.mem.eql(u8, method, "PUT")) {
                        const copy = ctx.alloc.dupe(u8, body_buf) catch {
                            ctx.state.mutex.unlock(ctx.tio);
                            return;
                        };
                        const tgop = ctx.state.tails.getOrPut(ctx.alloc, cid) catch null;
                        if (tgop) |g| {
                            if (g.found_existing) {
                                ctx.alloc.free(g.value_ptr.*);
                            } else {
                                g.key_ptr.* = ctx.alloc.dupe(u8, cid) catch {
                                    _ = ctx.state.tails.remove(cid);
                                    ctx.alloc.free(copy);
                                    ctx.state.mutex.unlock(ctx.tio);
                                    return;
                                };
                            }
                            g.value_ptr.* = copy;
                        } else {
                            ctx.alloc.free(copy);
                        }
                        resp_body = std.fmt.allocPrint(ctx.alloc, "{{\"ok\":true,\"bytes\":{d}}}", .{body_buf.len}) catch &.{};
                    } else if (std.mem.eql(u8, method, "GET")) {
                        if (ctx.state.tails.get(cid)) |stored| {
                            resp_body = ctx.alloc.dupe(u8, stored) catch &.{};
                        } else {
                            status = 404;
                            resp_body = ctx.alloc.dupe(u8, "{\"error\":\"not_found\"}") catch &.{};
                        }
                    }
                } else {
                    status = 404;
                    resp_body = ctx.alloc.dupe(u8, "{\"error\":\"not_found\"}") catch &.{};
                }
                ctx.state.mutex.unlock(ctx.tio);

                const status_text = if (status == 200) "OK" else if (status == 400) "Bad Request" else "Not Found";
                writer.interface.print(
                    "HTTP/1.1 {d} {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: keep-alive\r\n\r\n{s}",
                    .{ status, status_text, resp_body.len, resp_body },
                ) catch return;
                writer.interface.flush() catch return;
            }
        }

        fn run(ctx: @This()) void {
            while (!ctx.stop.load(.acquire)) {
                var stream = ctx.srv.accept(ctx.tio) catch return;
                if (ctx.stop.load(.acquire)) {
                    stream.close(ctx.tio);
                    return;
                }
                ctx.handleConn(&stream);
                stream.close(ctx.tio);
            }
        }
    };

    const srv_thread = try std.Thread.spawn(.{}, ServerWorker.run, .{ServerWorker{
        .srv = &mock_srv,
        .tio = io,
        .alloc = gpa,
        .stop = &stop_mock,
        .state = &edge_state,
    }});
    defer {
        stop_mock.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", mock_port)) |wake_addr| {
            if (wake_addr.connect(io, .{ .mode = .stream })) |ws_wake| ws_wake.close(io) else |_| {}
        } else |_| {}
        srv_thread.join();
    }

    const edge_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{mock_port});
    defer gpa.free(edge_url);

    // Two independent EngineHost instances signed into the same org (`org_1`) on the HTTP Edge server:
    // - `host_zig`: standalone Zig desktop/iOS engine creating a session & running a turn.
    // - `host_peer`: peer client (GPUI desktop / iOS / another Mac) pulling from the same org.
    var host_zig = try engine_host.EngineHost.init(gpa, "dev-zig-mac", "Zig MacBook Pro");
    defer host_zig.deinit();
    host_zig.io = io;
    try host_zig.auth.configureCodegraff(edge_url, "cg_client_synth", "https://codegraff.example", null);
    try host_zig.auth.signInWithKey("tok-zig-synth");
    if (host_zig.auth.org_id) |old| gpa.free(old);
    host_zig.auth.org_id = try gpa.dupe(u8, "org_1");

    var host_peer = try engine_host.EngineHost.init(gpa, "dev-gpui-peer", "Peer Studio");
    defer host_peer.deinit();
    host_peer.io = io;
    try host_peer.auth.configureCodegraff(edge_url, "cg_client_synth", "https://codegraff.example", null);
    try host_peer.auth.signInWithKey("tok-peer-synth");
    if (host_peer.auth.org_id) |old| gpa.free(old);
    host_peer.auth.org_id = try gpa.dupe(u8, "org_1");

    // 1. `host_zig` creates a space + chat and executes a turn locally.
    try execRpc(&host_zig, 1, "Mutate", "{\"op\":\"createSpace\",\"spaceId\":\"sp-zig-sync\",\"path\":\"/work/nanoharness\",\"name\":\"nanoharness\"}");
    try execRpc(&host_zig, 2, "Mutate", "{\"op\":\"createChat\",\"chatId\":\"chat-zig-sync-1\",\"spaceId\":\"sp-zig-sync\",\"config\":{\"harness\":\"graff\",\"model\":\"claude-agent/claude-opus-5-5\",\"reasoning\":\"high\"}}");
    try execRpc(&host_zig, 3, "QueueCommand", "{\"chatId\":\"chat-zig-sync-1\",\"command\":{\"kind\":\"run\",\"messageId\":\"msg-zig-1\",\"request\":{\"prompt\":\"Sync this Zig session across all devices\"}}}");

    // 2. `host_zig` syncs with the HTTP Edge server, then `host_peer` syncs from the HTTP Edge server.
    _ = host_zig.syncFromEdgeRegistry(io);
    _ = host_peer.syncFromEdgeRegistry(io);

    // Zero ops rejected by `edge/src/registry-core.ts` validation!
    try testing.expectEqual(@as(usize, 0), edge_state.invalid_ops);

    // 3. `host_peer` MUST see `host_zig`'s device (with live presence), space, chat (title + preview), session status, AND transcript!
    try testing.expectEqual(@as(usize, 2), host_peer.devices.items.len);
    var saw_zig_dev = false;
    for (host_peer.devices.items) |d| {
        if (std.mem.eql(u8, d.id, "dev-zig-mac")) {
            saw_zig_dev = true;
            try testing.expectEqualStrings("Zig MacBook Pro", d.name);
            try testing.expect(d.last_seen_at_ms > 0);
        }
    }
    try testing.expect(saw_zig_dev);
    try testing.expectEqual(@as(usize, 1), host_peer.spaces.items.len);
    try testing.expectEqualStrings("sp-zig-sync", host_peer.spaces.items[0].id);
    try testing.expectEqual(@as(usize, 1), host_peer.chats.items.len);
    try testing.expectEqualStrings("chat-zig-sync-1", host_peer.chats.items[0].id);
    try testing.expectEqualStrings("dev-zig-mac", host_peer.chats.items[0].device_id);
    try testing.expectEqualStrings("Sync this Zig session across all devices", host_peer.chats.items[0].title.?);
    try testing.expect(host_peer.chats.items[0].preview != null);
    try testing.expectEqualStrings("idle", host_peer.chats.items[0].activity_status orelse "");

    // Verify `host_peer` opens `WatchDocMessages` and pulls `host_zig`'s published `/chat2/chat-zig-sync-1/tail` sidecar!
    var watch_p: json.Parsed(json.Value) = try json.parseFromSlice(json.Value, gpa, "{\"chatId\":\"chat-zig-sync-1\"}", .{});
    defer watch_p.deinit();
    var watch_msgs = try host_peer.handle("WatchDocMessages", watch_p.value);
    defer watch_msgs.stream_items_json.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, watch_msgs.stream_items_json.items[0], "Sync this Zig session across all devices") != null);
    try testing.expect(std.mem.indexOf(u8, watch_msgs.stream_items_json.items[0], "Ack from dev-zig-mac: Sync this Zig session across all devices") != null);

    // 4. Reverse direction: `host_peer` renames & archives the chat -> pushes to Edge -> `host_zig` pulls delta!
    try execRpc(&host_peer, 10, "Mutate", "{\"op\":\"renameChat\",\"chatId\":\"chat-zig-sync-1\",\"title\":\"Renamed on GPUI Peer\"}");
    try execRpc(&host_peer, 11, "Mutate", "{\"op\":\"setChatArchived\",\"chatId\":\"chat-zig-sync-1\",\"archived\":true}");
    _ = host_peer.syncFromEdgeRegistryUnlocked(io);
    _ = host_zig.syncFromEdgeRegistryUnlocked(io);

    try testing.expectEqual(@as(usize, 0), edge_state.invalid_ops);
    try testing.expectEqualStrings("Renamed on GPUI Peer", host_zig.chats.items[0].title.?);
    try testing.expect(host_zig.chats.items[0].archived);
}

