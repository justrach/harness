//! Pure-Zig CRDT session document (`SessionDoc`), mirroring `crates/doc/src/schema.rs`
//! and `crates/doc/src/transcript_delta.rs`.
//!
//! Container layout:
//! - `meta`:     `{ chatId, schemaVersion }`
//! - `messages`: ordered list of `MessageEntry` with RLE text/reasoning delta appends
//! - `commands`: ordered command log (`run`, `interrupt`, `respondInput`, `dismissInput`)
//! - `queue`:    movable list of `QueuedItem` with host-authoritative edit leases
//! - `vv`:       causal version vector (`device_id -> seq`) for `chat2` frontier checks
//!
//! Snapshots and updates serialize as compact `HZD1` envelopes (or accept legacy Rust
//! `"loro"` magic headers via `isRustLoroBlob`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const transcript = @import("transcript.zig");

pub const schema_version: u32 = 2;
pub const rust_loro_magic = "loro";
pub const zig_doc_magic = "HZD1";

pub fn isRustLoroBlob(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, rust_loro_magic);
}

pub const PartItem = struct {
    id: []u8,
    kind: []u8, // "text", "reasoning", "tool", "input", "error", "image", "visual"
    text: std.ArrayList(u8) = .empty,
    call_json: ?[]u8 = null,
    output: ?[]u8 = null,
    is_error: bool = false,
    resolved: bool = false,

    pub fn deinit(self: *PartItem, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.kind);
        self.text.deinit(gpa);
        if (self.call_json) |c| gpa.free(c);
        if (self.output) |o| gpa.free(o);
    }
};

pub const MessageEntry = struct {
    id: []u8,
    role: []u8, // "user", "assistant", "system"
    created_at: i64,
    device_id: []u8,
    status: ?[]u8 = null, // "streaming", "complete", "aborted"
    parts: std.ArrayList(PartItem) = .empty,

    pub fn deinit(self: *MessageEntry, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.role);
        gpa.free(self.device_id);
        if (self.status) |s| gpa.free(s);
        for (self.parts.items) |*p| p.deinit(gpa);
        self.parts.deinit(gpa);
    }
};

pub const CommandEntry = struct {
    id: []u8,
    kind: []u8,
    payload_json: []u8,
    issued_by: []u8,
    issued_at: i64,
    status: []u8, // "pending", "running", "completed", "failed"

    pub fn deinit(self: *CommandEntry, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.kind);
        gpa.free(self.payload_json);
        gpa.free(self.issued_by);
        gpa.free(self.status);
    }
};

pub const QueuedItem = struct {
    id: []u8,
    text: []u8,
    issued_by: []u8,
    issued_at: i64,
    hold_for_turn_end: bool = true,
    lease_id: ?[]u8 = null,
    editor_device_id: ?[]u8 = null,

    pub fn deinit(self: *QueuedItem, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.text);
        gpa.free(self.issued_by);
        if (self.lease_id) |l| gpa.free(l);
        if (self.editor_device_id) |d| gpa.free(d);
    }
};

pub const EditAction = enum { commit, cancel, discard, release_unchanged };

/// All 5 `SessionCommandKind` variants from `crates/doc/src/commands.rs`.
pub const CommandKind = enum {
    run,
    steer,
    interrupt,
    respond_input,
    dismiss_input,
};

pub const CommandStatus = enum {
    pending,
    running,
    completed,
    failed,
};

pub const CommandDisposition = enum {
    skip,
    supersede,
    execute,
};

/// Rule 2 from `crates/doc/src/commands.rs` (`can_composer_cancel`), proven in Lean 4
/// (`HarnessProofs.RustCodebaseParity.composer_cancel_only_own_pending`).
pub fn canComposerCancel(status: CommandStatus, issued_by: []const u8, caller_device: []const u8) bool {
    return status == .pending and std.mem.eql(u8, issued_by, caller_device);
}

/// Rule 3 from `crates/doc/src/commands.rs` (`evaluate_command`), proven in Lean 4
/// (`HarnessProofs.RustCodebaseParity.steer_and_run_never_superseded` and
/// `stale_interrupt_superseded_while_fresh_executes`).
pub fn evaluateCommand(
    status: CommandStatus,
    already_processed: bool,
    kind: CommandKind,
    issued_at: i64,
    latest_run_issued_at: ?i64,
    active_run: bool,
) CommandDisposition {
    if (status != .pending or already_processed) return .skip;
    switch (kind) {
        .interrupt => {
            if (latest_run_issued_at) |run_at| {
                if (issued_at < run_at) return .supersede;
            }
            return if (active_run) .execute else .supersede;
        },
        .respond_input, .dismiss_input => {
            return if (active_run) .execute else .supersede;
        },
        .run, .steer => return .execute,
    }
}

pub const SessionDoc = struct {
    gpa: Allocator,
    chat_id: []u8,
    device_id: []u8,
    local_seq: u64 = 0,
    vv: std.StringHashMapUnmanaged(u64) = .empty,
    messages: std.ArrayList(MessageEntry) = .empty,
    commands: std.ArrayList(CommandEntry) = .empty,
    queue: std.ArrayList(QueuedItem) = .empty,

    pub fn init(gpa: Allocator, chat_id: []const u8, device_id: []const u8) !SessionDoc {
        const cid = try gpa.dupe(u8, chat_id);
        errdefer gpa.free(cid);
        const did = try gpa.dupe(u8, device_id);
        return .{
            .gpa = gpa,
            .chat_id = cid,
            .device_id = did,
        };
    }

    pub fn deinit(self: *SessionDoc) void {
        self.gpa.free(self.chat_id);
        self.gpa.free(self.device_id);
        var it = self.vv.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.vv.deinit(self.gpa);
        for (self.messages.items) |*m| m.deinit(self.gpa);
        self.messages.deinit(self.gpa);
        for (self.commands.items) |*c| c.deinit(self.gpa);
        self.commands.deinit(self.gpa);
        for (self.queue.items) |*q| q.deinit(self.gpa);
        self.queue.deinit(self.gpa);
    }

    fn bumpClock(self: *SessionDoc) !void {
        self.local_seq += 1;
        const gop = try self.vv.getOrPut(self.gpa, self.device_id);
        if (!gop.found_existing) {
            errdefer _ = self.vv.remove(self.device_id);
            gop.key_ptr.* = try self.gpa.dupe(u8, self.device_id);
        }
        gop.value_ptr.* = self.local_seq;
    }

    pub fn appendUserMessage(self: *SessionDoc, msg_id: []const u8, part_id: []const u8, text: []const u8, now_ms: i64) !void {
        try self.bumpClock();
        const mid = try self.gpa.dupe(u8, msg_id);
        errdefer self.gpa.free(mid);
        const mrole = try self.gpa.dupe(u8, "user");
        errdefer self.gpa.free(mrole);
        const mdev = try self.gpa.dupe(u8, self.device_id);
        errdefer self.gpa.free(mdev);
        const mstatus = try self.gpa.dupe(u8, "complete");
        errdefer self.gpa.free(mstatus);

        const pid = try self.gpa.dupe(u8, part_id);
        errdefer self.gpa.free(pid);
        const pkind = try self.gpa.dupe(u8, "text");
        errdefer self.gpa.free(pkind);
        var ptext: std.ArrayList(u8) = .empty;
        errdefer ptext.deinit(self.gpa);
        try ptext.appendSlice(self.gpa, text);

        var parts: std.ArrayList(PartItem) = .empty;
        errdefer parts.deinit(self.gpa);
        try parts.append(self.gpa, .{
            .id = pid,
            .kind = pkind,
            .text = ptext,
        });

        try self.messages.append(self.gpa, .{
            .id = mid,
            .role = mrole,
            .created_at = now_ms,
            .device_id = mdev,
            .status = mstatus,
            .parts = parts,
        });
    }

    pub fn beginAssistantMessage(self: *SessionDoc, msg_id: []const u8, now_ms: i64) !void {
        try self.bumpClock();
        const mid = try self.gpa.dupe(u8, msg_id);
        errdefer self.gpa.free(mid);
        const mrole = try self.gpa.dupe(u8, "assistant");
        errdefer self.gpa.free(mrole);
        const mdev = try self.gpa.dupe(u8, self.device_id);
        errdefer self.gpa.free(mdev);
        const mstatus = try self.gpa.dupe(u8, "streaming");
        errdefer self.gpa.free(mstatus);

        try self.messages.append(self.gpa, .{
            .id = mid,
            .role = mrole,
            .created_at = now_ms,
            .device_id = mdev,
            .status = mstatus,
        });
    }

    /// RLE-coalesced streaming delta append on a text or reasoning part.
    /// Returns the new total byte length of the part's text for `WatchDocMessages` `append` frames.
    pub fn appendPartDelta(self: *SessionDoc, msg_id: []const u8, part_id: []const u8, kind: []const u8, delta: []const u8) !usize {
        try self.bumpClock();
        for (self.messages.items) |*m| {
            if (!std.mem.eql(u8, m.id, msg_id)) continue;
            for (m.parts.items) |*p| {
                if (std.mem.eql(u8, p.id, part_id)) {
                    try p.text.appendSlice(self.gpa, delta);
                    return p.text.items.len;
                }
            }
            var part = PartItem{
                .id = try self.gpa.dupe(u8, part_id),
                .kind = try self.gpa.dupe(u8, kind),
            };
            errdefer part.deinit(self.gpa);
            try part.text.appendSlice(self.gpa, delta);
            const new_len = part.text.items.len;
            try m.parts.append(self.gpa, part);
            return new_len;
        }
        return error.MessageNotFound;
    }

    pub fn setMessageStatus(self: *SessionDoc, msg_id: []const u8, status: []const u8) !void {
        try self.bumpClock();
        for (self.messages.items) |*m| {
            if (!std.mem.eql(u8, m.id, msg_id)) continue;
            const copy = try self.gpa.dupe(u8, status);
            if (m.status) |old| self.gpa.free(old);
            m.status = copy;
            return;
        }
    }

    pub fn enqueueMessage(self: *SessionDoc, row_id: []const u8, text: []const u8, hold: bool, now_ms: i64) !void {
        try self.bumpClock();
        const qid = try self.gpa.dupe(u8, row_id);
        errdefer self.gpa.free(qid);
        const qtext = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(qtext);
        const qby = try self.gpa.dupe(u8, self.device_id);
        errdefer self.gpa.free(qby);
        try self.queue.append(self.gpa, .{
            .id = qid,
            .text = qtext,
            .issued_by = qby,
            .issued_at = now_ms,
            .hold_for_turn_end = hold,
        });
    }

    /// Retype a queued message (`UpdateQueuedMessage`); empty text deletes it (`crates/rpc/src/lib.rs`).
    pub fn updateQueuedText(self: *SessionDoc, row_id: []const u8, new_text: []const u8) !bool {
        if (new_text.len == 0) {
            return self.removeQueued(row_id);
        }
        for (self.queue.items) |*q| {
            if (std.mem.eql(u8, q.id, row_id)) {
                try self.bumpClock();
                const copy = try self.gpa.dupe(u8, new_text);
                self.gpa.free(q.text);
                q.text = copy;
                return true;
            }
        }
        return false;
    }

    pub fn removeQueued(self: *SessionDoc, row_id: []const u8) bool {
        for (self.queue.items, 0..) |*q, idx| {
            if (std.mem.eql(u8, q.id, row_id)) {
                q.deinit(self.gpa);
                _ = self.queue.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Reorder a queued item to `to_index` (movable list semantics).
    pub fn moveQueued(self: *SessionDoc, row_id: []const u8, to_index: usize) !bool {
        if (self.queue.items.len == 0) return false;
        const from_idx = for (self.queue.items, 0..) |q, idx| {
            if (std.mem.eql(u8, q.id, row_id)) break idx;
        } else return false;
        try self.bumpClock();
        const clamped = @min(to_index, self.queue.items.len - 1);
        if (from_idx == clamped) return true;
        const item = self.queue.orderedRemove(from_idx);
        self.queue.insertAssumeCapacity(clamped, item);
        return true;
    }

    /// Host-authoritative queue edit lease (`BeginEditQueuedMessage`).
    pub fn beginEditQueued(self: *SessionDoc, row_id: []const u8, lease_id: []const u8, editor_device_id: []const u8) !bool {
        for (self.queue.items) |*q| {
            if (!std.mem.eql(u8, q.id, row_id)) continue;
            if (q.lease_id != null and !std.mem.eql(u8, q.lease_id.?, lease_id)) return false;
            try self.bumpClock();
            const l_copy = try self.gpa.dupe(u8, lease_id);
            errdefer self.gpa.free(l_copy);
            const d_copy = try self.gpa.dupe(u8, editor_device_id);
            if (q.lease_id) |old| self.gpa.free(old);
            if (q.editor_device_id) |old| self.gpa.free(old);
            q.lease_id = l_copy;
            q.editor_device_id = d_copy;
            return true;
        }
        return false;
    }

    /// Complete or cancel a host-authoritative queue edit lease (`FinishEditQueuedMessage`).
    pub fn finishEditQueued(
        self: *SessionDoc,
        row_id: []const u8,
        lease_id: []const u8,
        action: EditAction,
        new_text: ?[]const u8,
    ) !bool {
        for (self.queue.items, 0..) |*q, idx| {
            if (!std.mem.eql(u8, q.id, row_id)) continue;
            if (q.lease_id) |cur| {
                if (!std.mem.eql(u8, cur, lease_id)) return false;
            }
            try self.bumpClock();
            switch (action) {
                .discard => {
                    q.deinit(self.gpa);
                    _ = self.queue.orderedRemove(idx);
                    return true;
                },
                .commit => {
                    if (new_text) |txt| {
                        const copy = try self.gpa.dupe(u8, txt);
                        self.gpa.free(q.text);
                        q.text = copy;
                    }
                    if (q.lease_id) |l| self.gpa.free(l);
                    if (q.editor_device_id) |d| self.gpa.free(d);
                    q.lease_id = null;
                    q.editor_device_id = null;
                    return true;
                },
                .cancel, .release_unchanged => {
                    if (q.lease_id) |l| self.gpa.free(l);
                    if (q.editor_device_id) |d| self.gpa.free(d);
                    q.lease_id = null;
                    q.editor_device_id = null;
                    return true;
                },
            }
        }
        return false;
    }

    pub fn enqueueCommand(
        self: *SessionDoc,
        cmd_id: []const u8,
        kind: []const u8,
        payload_json: []const u8,
        status: []const u8,
        now_ms: i64,
    ) !void {
        try self.bumpClock();
        const cid = try self.gpa.dupe(u8, cmd_id);
        errdefer self.gpa.free(cid);
        const k_copy = try self.gpa.dupe(u8, kind);
        errdefer self.gpa.free(k_copy);
        const p_copy = try self.gpa.dupe(u8, payload_json);
        errdefer self.gpa.free(p_copy);
        const by_copy = try self.gpa.dupe(u8, self.device_id);
        errdefer self.gpa.free(by_copy);
        const st_copy = try self.gpa.dupe(u8, status);
        errdefer self.gpa.free(st_copy);
        try self.commands.append(self.gpa, .{
            .id = cid,
            .kind = k_copy,
            .payload_json = p_copy,
            .issued_by = by_copy,
            .issued_at = now_ms,
            .status = st_copy,
        });
    }

    pub fn abortStreamingMessages(self: *SessionDoc) !void {
        for (self.messages.items) |*m| {
            if (m.status) |st| {
                if (std.mem.eql(u8, st, "streaming")) {
                    const aborted = try self.gpa.dupe(u8, "aborted");
                    self.gpa.free(st);
                    m.status = aborted;
                }
            }
        }
    }

    fn writeEntryJson(w: *std.Io.Writer, m: MessageEntry) !void {
        try w.writeAll("{\"id\":");
        try json.Stringify.encodeJsonString(m.id, .{}, w);
        try w.writeAll(",\"role\":");
        try json.Stringify.encodeJsonString(m.role, .{}, w);
        try w.print(",\"createdAt\":{d}", .{m.created_at});
        if (m.status) |st| {
            try w.writeAll(",\"status\":");
            try json.Stringify.encodeJsonString(st, .{}, w);
        }
        try w.writeAll(",\"parts\":[");
        for (m.parts.items, 0..) |p, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try json.Stringify.encodeJsonString(p.id, .{}, w);
            try w.writeAll(",\"kind\":");
            try json.Stringify.encodeJsonString(p.kind, .{}, w);
            if (std.mem.eql(u8, p.kind, "reasoning")) {
                try w.writeAll(",\"reasoning\":");
                try json.Stringify.encodeJsonString(p.text.items, .{}, w);
            } else {
                try w.writeAll(",\"text\":");
                try json.Stringify.encodeJsonString(p.text.items, .{}, w);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }

    /// Build a `WatchDocMessages` `reset` JSON frame that `transcript.zig` applies.
    pub fn toResetFrameJson(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"historyPending\":false,\"reset\":[");
        for (self.messages.items, 0..) |m, mi| {
            if (mi > 0) try w.writeByte(',');
            try writeEntryJson(w, m);
        }
        try w.writeAll("]}");
        return aw.toOwnedSlice();
    }

    /// Build an incremental `WatchDocMessages` `upsert` delta frame (`{"upsert":[{"after":...,"entry":{...}}],"count":N}`).
    pub fn toUpsertEntryFrameJson(self: *const SessionDoc, gpa: Allocator, msg_id: []const u8) ![]u8 {
        const idx = for (self.messages.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.id, msg_id)) break i;
        } else return error.MessageNotFound;

        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"upsert\":[{\"after\":");
        if (idx > 0) {
            try json.Stringify.encodeJsonString(self.messages.items[idx - 1].id, .{}, w);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"entry\":");
        try writeEntryJson(w, self.messages.items[idx]);
        try w.print("}}],\"count\":{d}}}", .{self.messages.items.len});
        return aw.toOwnedSlice();
    }

    /// Build an incremental `WatchDocMessages` `append` delta frame (`{"append":[{"entry":...,"part":...,"text":...,"len":L}],"count":N}`).
    pub fn toAppendDeltaFrameJson(
        self: *const SessionDoc,
        gpa: Allocator,
        msg_id: []const u8,
        part_id: []const u8,
        delta: []const u8,
        total_len: usize,
    ) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"append\":[{\"entry\":");
        try json.Stringify.encodeJsonString(msg_id, .{}, w);
        try w.writeAll(",\"part\":");
        try json.Stringify.encodeJsonString(part_id, .{}, w);
        try w.writeAll(",\"text\":");
        try json.Stringify.encodeJsonString(delta, .{}, w);
        try w.print(",\"len\":{d}}}],\"count\":{d}}}", .{ total_len, self.messages.items.len });
        return aw.toOwnedSlice();
    }

    /// Build an incremental `WatchDocMessages` `remove` delta frame (`{"remove":[...],"count":N}`).
    pub fn toRemoveEntriesFrameJson(self: *const SessionDoc, gpa: Allocator, ids: []const []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"remove\":[");
        for (ids, 0..) |id, i| {
            if (i > 0) try w.writeByte(',');
            try json.Stringify.encodeJsonString(id, .{}, w);
        }
        try w.print("],\"count\":{d}}}", .{self.messages.items.len});
        return aw.toOwnedSlice();
    }

    /// Build a `WatchQueue` JSON frame (`{"items":[...]}`).
    pub fn toQueueFrameJson(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"items\":[");
        for (self.queue.items, 0..) |q, qi| {
            if (qi > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try json.Stringify.encodeJsonString(q.id, .{}, w);
            try w.writeAll(",\"text\":");
            try json.Stringify.encodeJsonString(q.text, .{}, w);
            if (q.editor_device_id) |ed| {
                try w.writeAll(",\"deliveryGate\":{\"kind\":\"editing\",\"ownerDeviceId\":");
                try json.Stringify.encodeJsonString(ed, .{}, w);
                try w.writeByte('}');
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return aw.toOwnedSlice();
    }

    /// Export causal frontier (`vv`) as compact JSON bytes for `chat2` checkpoint frontier checks.
    pub fn exportFrontier(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeByte('{');
        var it = self.vv.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try w.writeByte(',');
            first = false;
            try json.Stringify.encodeJsonString(e.key_ptr.*, .{}, w);
            try w.print(":{d}", .{e.value_ptr.*});
        }
        try w.writeByte('}');
        return aw.toOwnedSlice();
    }

    /// True if every `(peer, seq)` in `frontier_bytes` is `<= self.vv[peer]`.
    pub fn frontierContained(self: *const SessionDoc, gpa: Allocator, frontier_bytes: []const u8) bool {
        if (frontier_bytes.len == 0) return true;
        if (isRustLoroBlob(frontier_bytes)) return false;
        var parsed = json.parseFromSlice(json.Value, gpa, frontier_bytes, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .integer) return false;
            const need: u64 = @intCast(@max(0, e.value_ptr.integer));
            const have = self.vv.get(e.key_ptr.*) orelse 0;
            if (have < need) return false;
        }
        return true;
    }

    /// Export full snapshot (`HZD1` header + JSON state) for `DocsStore` and `chat2` checkpoints.
    pub fn exportSnapshot(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        const reset = try self.toResetFrameJson(gpa);
        defer gpa.free(reset);
        const frontier = try self.exportFrontier(gpa);
        defer gpa.free(frontier);
        const queue = try self.toQueueFrameJson(gpa);
        defer gpa.free(queue);
        return std.fmt.allocPrint(gpa, "{s}{{\"chatId\":{f},\"vv\":{s},\"transcript\":{s},\"queue\":{s}}}", .{
            zig_doc_magic,
            json.fmt(self.chat_id, .{}),
            frontier,
            reset,
            queue,
        });
    }

    /// Import a snapshot or CRDT update (`HZD1` envelope) into `self`, merging
    /// version vector entries and hydrating missing messages/queue items.
    pub fn importSnapshot(self: *SessionDoc, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (isRustLoroBlob(bytes)) return error.UnsupportedLegacyLoroBlob;
        const payload = if (std.mem.startsWith(u8, bytes, zig_doc_magic))
            bytes[zig_doc_magic.len..]
        else
            bytes;

        var parsed = try json.parseFromSlice(json.Value, self.gpa, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSnapshot;
        const root = parsed.value.object;

        if (root.get("vv")) |vv_val| if (vv_val == .object) {
            var it = vv_val.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .integer) continue;
                const seq: u64 = @intCast(@max(0, e.value_ptr.integer));
                const gop = try self.vv.getOrPut(self.gpa, e.key_ptr.*);
                if (!gop.found_existing) {
                    errdefer _ = self.vv.remove(e.key_ptr.*);
                    gop.key_ptr.* = try self.gpa.dupe(u8, e.key_ptr.*);
                    gop.value_ptr.* = seq;
                } else {
                    gop.value_ptr.* = @max(gop.value_ptr.*, seq);
                }
                if (std.mem.eql(u8, e.key_ptr.*, self.device_id)) {
                    self.local_seq = @max(self.local_seq, seq);
                }
            }
        };

        if (root.get("transcript")) |tr_val| if (tr_val == .object) {
            if (tr_val.object.get("reset")) |reset_arr| if (reset_arr == .array) {
                for (reset_arr.array.items) |m_val| {
                    if (m_val != .object) continue;
                    const mo = m_val.object;
                    const id_s = if (mo.get("id")) |v| (if (v == .string) v.string else continue) else continue;
                    // Skip if message ID already present
                    var exists = false;
                    for (self.messages.items) |existing| {
                        if (std.mem.eql(u8, existing.id, id_s)) {
                            exists = true;
                            break;
                        }
                    }
                    if (exists) continue;

                    const role_s = if (mo.get("role")) |v| (if (v == .string) v.string else "assistant") else "assistant";
                    const created_at: i64 = if (mo.get("createdAt")) |v| (if (v == .integer) v.integer else 0) else 0;
                    const status_s: ?[]const u8 = if (mo.get("status")) |v| (if (v == .string) v.string else null) else null;

                    const mid = try self.gpa.dupe(u8, id_s);
                    errdefer self.gpa.free(mid);
                    const mrole = try self.gpa.dupe(u8, role_s);
                    errdefer self.gpa.free(mrole);
                    const mdev = try self.gpa.dupe(u8, self.device_id);
                    errdefer self.gpa.free(mdev);
                    const mstatus = if (status_s) |st| try self.gpa.dupe(u8, st) else null;
                    errdefer if (mstatus) |st| self.gpa.free(st);

                    var msg = MessageEntry{
                        .id = mid,
                        .role = mrole,
                        .created_at = created_at,
                        .device_id = mdev,
                        .status = mstatus,
                    };
                    errdefer {
                        for (msg.parts.items) |*p| p.deinit(self.gpa);
                        msg.parts.deinit(self.gpa);
                    }

                    if (mo.get("parts")) |parts_arr| if (parts_arr == .array) {
                        for (parts_arr.array.items) |p_val| {
                            if (p_val != .object) continue;
                            const po = p_val.object;
                            const pid = if (po.get("id")) |v| (if (v == .string) v.string else "p") else "p";
                            const pkind = if (po.get("kind")) |v| (if (v == .string) v.string else "text") else "text";
                            const ptext = if (po.get("text")) |v| (if (v == .string) v.string else "") else if (po.get("reasoning")) |v| (if (v == .string) v.string else "") else "";

                            const pid_copy = try self.gpa.dupe(u8, pid);
                            var part_transferred = false;
                            errdefer if (!part_transferred) self.gpa.free(pid_copy);
                            const pkind_copy = try self.gpa.dupe(u8, pkind);
                            errdefer if (!part_transferred) self.gpa.free(pkind_copy);
                            var ptext_list: std.ArrayList(u8) = .empty;
                            errdefer if (!part_transferred) ptext_list.deinit(self.gpa);
                            try ptext_list.appendSlice(self.gpa, ptext);

                            try msg.parts.append(self.gpa, .{
                                .id = pid_copy,
                                .kind = pkind_copy,
                                .text = ptext_list,
                            });
                            part_transferred = true;
                        }
                    };
                    try self.messages.append(self.gpa, msg);
                }
            };
        };
    }
};

test "SessionDoc RLE streaming delta, incremental upsert/append frames, queue lease, and snapshot roundtrip" {
    const gpa = testing.allocator;
    var doc = try SessionDoc.init(gpa, "chat-1", "dev-local");
    defer doc.deinit();

    try doc.appendUserMessage("msg-1", "p-1", "Port the engine to Zig", 1000);
    try doc.beginAssistantMessage("msg-2", 1005);
    const len1 = try doc.appendPartDelta("msg-2", "p-2", "text", "Working on ");
    try testing.expectEqual(@as(usize, 11), len1);

    // 1. Test initial reset + incremental append on Transcript
    var tr: transcript.Transcript = .{ .gpa = gpa };
    defer tr.deinit();
    {
        const reset_json = try doc.toResetFrameJson(gpa);
        defer gpa.free(reset_json);
        var parsed = try json.parseFromSlice(json.Value, gpa, reset_json, .{});
        defer parsed.deinit();
        try tr.apply(parsed.value);
    }
    const len2 = try doc.appendPartDelta("msg-2", "p-2", "text", "chat2 wire.");
    try testing.expectEqual(@as(usize, 22), len2);
    {
        const append_json = try doc.toAppendDeltaFrameJson(gpa, "msg-2", "p-2", "chat2 wire.", len2);
        defer gpa.free(append_json);
        var parsed = try json.parseFromSlice(json.Value, gpa, append_json, .{});
        defer parsed.deinit();
        try tr.apply(parsed.value);
    }
    try doc.setMessageStatus("msg-2", "complete");
    {
        const upsert_json = try doc.toUpsertEntryFrameJson(gpa, "msg-2");
        defer gpa.free(upsert_json);
        var parsed = try json.parseFromSlice(json.Value, gpa, upsert_json, .{});
        defer parsed.deinit();
        try tr.apply(parsed.value);
    }
    try testing.expectEqual(@as(usize, 2), tr.entries.items.len);
    try testing.expectEqualStrings("Working on chat2 wire.", tr.entries.items[1].parts.items[0].text.items);
    try testing.expectEqual(transcript.EntryStatus.complete, tr.entries.items[1].status);

    // 2. Test queue reorder + edit lease
    try doc.enqueueMessage("q-1", "First item", true, 2000);
    try doc.enqueueMessage("q-2", "Second item", true, 2001);
    try testing.expect(try doc.moveQueued("q-2", 0));
    try testing.expectEqualStrings("q-2", doc.queue.items[0].id);
    try testing.expect(try doc.beginEditQueued("q-2", "lease-1", "dev-local"));
    try testing.expect(try doc.finishEditQueued("q-2", "lease-1", .commit, "Edited second item"));
    try testing.expectEqualStrings("Edited second item", doc.queue.items[0].text);

    // 3. Test exportSnapshot -> importSnapshot roundtrip
    const snap = try doc.exportSnapshot(gpa);
    defer gpa.free(snap);

    var doc2 = try SessionDoc.init(gpa, "chat-1", "dev-peer");
    defer doc2.deinit();
    try doc2.importSnapshot(snap);
    try testing.expectEqual(@as(usize, 2), doc2.messages.items.len);
    const frontier = try doc.exportFrontier(gpa);
    defer gpa.free(frontier);
    try testing.expect(doc2.frontierContained(gpa, frontier));
}
