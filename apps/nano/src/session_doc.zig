//! Pure-Zig CRDT session document (`SessionDoc`), mirroring `crates/doc/src/schema.rs`,
//! `crates/doc/src/constants.rs`, `crates/doc/src/queue.rs`, and `crates/doc/src/transcript_delta.rs`.
//!
//! Container layout:
//! - `meta`:     `{ chatId, schemaVersion }`
//! - `messages`: ordered list of `MessageEntry` with O(1) tail/index lookup & RLE delta appends
//! - `commands`: ordered command log (`run`, `steer`, `interrupt`, `respondInput`, `dismissInput`)
//! - `queue`:    movable list of `QueuedItem` with fail-closed host-authoritative edit leases
//! - `vv`:       causal version vector (`device_id -> seq`) for `chat2` frontier checks
//!
//! Snapshots and updates serialize in a single pre-sized pass as compact `HZD1` envelopes
//! (or accept legacy Rust `"loro"` magic headers via `isRustLoroBlob`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const transcript = @import("transcript.zig");
const loro_ffi = @import("loro_ffi.zig");

// 1:1 constants from `crates/doc/src/constants.rs` and `crates/engine/src/doc_host.rs`
// (Lean `HarnessProofs.PerformanceAndQueueParity`).
pub const schema_version: u32 = 1;
pub const msg_inline_max: usize = 256 * 1024;
pub const retain_days: u32 = 3;
pub const compact_log_bytes: usize = 8 * 1024 * 1024;
pub const soft_ceiling_bytes: usize = 25 * 1024 * 1024;
pub const stream_commit_ms: u64 = 120;
pub const do_flush_ms: u64 = 5_000;
pub const doc_lru_byte_budget: usize = 80 * 1024 * 1024;
pub const tail_message_count: usize = 64;
pub const terminal_output_batch_ms: u64 = 12;
pub const command_default_ttl_ms: i64 = 24 * 60 * 60 * 1000;
pub const queue_edit_lease_ms: i64 = 60_000;

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
    extra_fields_json: ?[]u8 = null,
    is_error: bool = false,
    resolved: bool = false,

    pub fn byteWeight(self: PartItem) usize {
        const c_len = if (self.call_json) |c| c.len else 0;
        const o_len = if (self.output) |o| o.len else 0;
        const ef_len = if (self.extra_fields_json) |ef| ef.len else 0;
        return self.id.len + self.kind.len + self.text.items.len + c_len + o_len + ef_len + 32;
    }

    pub fn deinit(self: *PartItem, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.kind);
        self.text.deinit(gpa);
        if (self.call_json) |c| gpa.free(c);
        if (self.output) |o| gpa.free(o);
        if (self.extra_fields_json) |ef| gpa.free(ef);
    }
};

pub const MessageEntry = struct {
    id: []u8,
    role: []u8, // "user", "assistant", "system"
    created_at: i64,
    device_id: []u8,
    status: ?[]u8 = null, // "streaming", "complete", "aborted"
    duration_ms: ?i64 = null,
    parts: std.ArrayList(PartItem) = .empty,

    pub fn headerByteWeight(self: MessageEntry) usize {
        const st_len = if (self.status) |st| st.len else 0;
        return self.id.len + self.role.len + self.device_id.len + st_len + 64;
    }

    pub fn totalByteWeight(self: MessageEntry) usize {
        var total = self.headerByteWeight();
        for (self.parts.items) |p| total += p.byteWeight();
        return total;
    }

    pub fn isStreaming(self: MessageEntry) bool {
        if (self.status) |st| return std.mem.eql(u8, st, "streaming");
        return false;
    }

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

    pub fn byteWeight(self: CommandEntry) usize {
        return self.id.len + self.kind.len + self.payload_json.len + self.status.len + 48;
    }

    pub fn deinit(self: *CommandEntry, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.kind);
        gpa.free(self.payload_json);
        gpa.free(self.issued_by);
        gpa.free(self.status);
    }
};

/// `QueueDeliveryGate` from `crates/doc/src/queue.rs`:
/// expired `editing` leases fail closed into `review_required` (never `none`!).
pub const QueueGateKind = enum {
    none,
    editing,
    review_required,
};

pub const QueuedItem = struct {
    id: []u8,
    text: []u8,
    issued_by: []u8,
    issued_at: i64,
    hold_for_turn_end: bool = true,
    gate_kind: QueueGateKind = .none,
    lease_id: ?[]u8 = null,
    editor_device_id: ?[]u8 = null,
    editor_instance_id: ?[]u8 = null,
    acquired_at_ms: i64 = 0,
    expires_at_ms: i64 = 0,

    pub fn byteWeight(self: QueuedItem) usize {
        return self.id.len + self.text.len + self.issued_by.len + 48;
    }

    /// Lean Theorem `expired_edit_fails_closed_never_auto_delivers`:
    /// any `editing` or `review_required` barrier blocks automatic delivery.
    pub fn isAutoDeliverable(self: QueuedItem, turn_running: bool) bool {
        if (self.gate_kind != .none) return false;
        return !(turn_running and self.hold_for_turn_end);
    }

    pub fn clearGate(self: *QueuedItem, gpa: Allocator) void {
        if (self.lease_id) |l| gpa.free(l);
        if (self.editor_device_id) |d| gpa.free(d);
        if (self.editor_instance_id) |inst| gpa.free(inst);
        self.lease_id = null;
        self.editor_device_id = null;
        self.editor_instance_id = null;
        self.gate_kind = .none;
        self.acquired_at_ms = 0;
        self.expires_at_ms = 0;
    }

    pub fn deinit(self: *QueuedItem, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.text);
        gpa.free(self.issued_by);
        self.clearGate(gpa);
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

/// Rule 2 from `crates/doc/src/commands.rs` (`can_composer_cancel`).
pub fn canComposerCancel(status: CommandStatus, issued_by: []const u8, caller_device: []const u8) bool {
    return status == .pending and std.mem.eql(u8, issued_by, caller_device);
}

/// Rule 3 from `crates/doc/src/commands.rs` (`evaluate_command`).
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
    last_access_seq: u64 = 0,
    /// O(1) incremental byte & pin counters (Lean `HarnessProofs.PerformanceAndQueueParity`).
    live_payload_bytes: usize = 0,
    streaming_msg_count: usize = 0,
    pending_cmd_count: usize = 0,
    /// O(1) `msg_id -> index in messages` map (keys borrow `MessageEntry.id`).
    msg_index: std.StringHashMapUnmanaged(usize) = .empty,
    vv: std.StringHashMapUnmanaged(u64) = .empty,
    messages: std.ArrayList(MessageEntry) = .empty,
    commands: std.ArrayList(CommandEntry) = .empty,
    queue: std.ArrayList(QueuedItem) = .empty,
    /// Lazy Loro 1.13 CRDT backing document for byte-exact `chat2` interop with Rust peers.
    loro_handle: ?*loro_ffi.LoroSession = null,

    /// O(1) active-work check (streaming message or pending command).
    pub fn hasActiveWork(self: *const SessionDoc) bool {
        return self.streaming_msg_count > 0 or self.pending_cmd_count > 0;
    }

    /// O(1) resident payload byte query, maintained incrementally on every mutation.
    pub fn approxPayloadBytes(self: *const SessionDoc) usize {
        return self.live_payload_bytes;
    }

    /// Reference O(M*P + C + Q) linear fold used to verify incremental byte parity in tests.
    pub fn computePayloadBytesLinear(self: *const SessionDoc) usize {
        var total: usize = self.chat_id.len + self.device_id.len;
        for (self.messages.items) |m| total += m.totalByteWeight();
        for (self.commands.items) |c| total += c.byteWeight();
        for (self.queue.items) |q| total += q.byteWeight();
        return total;
    }

    /// O(1) message index lookup: checks the live tail entry first (0 hash overhead
    /// during streaming turns), then falls back to `self.msg_index`.
    pub fn findMessageIdx(self: *const SessionDoc, msg_id: []const u8) ?usize {
        const items = self.messages.items;
        if (items.len > 0 and std.mem.eql(u8, items[items.len - 1].id, msg_id)) {
            return items.len - 1;
        }
        return self.msg_index.get(msg_id);
    }

    pub fn init(gpa: Allocator, chat_id: []const u8, device_id: []const u8) !SessionDoc {
        const cid = try gpa.dupe(u8, chat_id);
        errdefer gpa.free(cid);
        const did = try gpa.dupe(u8, device_id);
        return .{
            .gpa = gpa,
            .chat_id = cid,
            .device_id = did,
            .live_payload_bytes = cid.len + did.len,
        };
    }

    pub fn deinit(self: *SessionDoc) void {
        if (self.loro_handle) |lh| {
            loro_ffi.destroySession(lh);
            self.loro_handle = null;
        }
        self.msg_index.deinit(self.gpa);
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

    fn appendIndexedMessage(self: *SessionDoc, msg: MessageEntry) !void {
        const new_idx = self.messages.items.len;
        try self.messages.ensureUnusedCapacity(self.gpa, 1);
        try self.msg_index.put(self.gpa, msg.id, new_idx);
        self.messages.appendAssumeCapacity(msg);
        self.live_payload_bytes += msg.totalByteWeight();
        if (msg.isStreaming()) self.streaming_msg_count += 1;
    }

    pub fn appendUserMessage(self: *SessionDoc, msg_id: []const u8, part_id: []const u8, text: []const u8, now_ms: i64) !void {
        if (self.findMessageIdx(msg_id) != null) return;
        try self.bumpClock();
        const mid = try self.gpa.dupe(u8, msg_id);
        var transferred = false;
        errdefer if (!transferred) self.gpa.free(mid);
        const mrole = try self.gpa.dupe(u8, "user");
        errdefer if (!transferred) self.gpa.free(mrole);
        const mdev = try self.gpa.dupe(u8, self.device_id);
        errdefer if (!transferred) self.gpa.free(mdev);
        const mstatus = try self.gpa.dupe(u8, "complete");
        errdefer if (!transferred) self.gpa.free(mstatus);

        const pid = try self.gpa.dupe(u8, part_id);
        errdefer if (!transferred) self.gpa.free(pid);
        const pkind = try self.gpa.dupe(u8, "text");
        errdefer if (!transferred) self.gpa.free(pkind);
        var ptext: std.ArrayList(u8) = .empty;
        errdefer if (!transferred) ptext.deinit(self.gpa);
        try ptext.appendSlice(self.gpa, text);

        var parts: std.ArrayList(PartItem) = .empty;
        errdefer if (!transferred) parts.deinit(self.gpa);
        try parts.append(self.gpa, .{
            .id = pid,
            .kind = pkind,
            .text = ptext,
        });

        var msg = MessageEntry{
            .id = mid,
            .role = mrole,
            .created_at = now_ms,
            .device_id = mdev,
            .status = mstatus,
            .parts = parts,
        };
        transferred = true;
        errdefer msg.deinit(self.gpa);
        try self.appendIndexedMessage(msg);
    }

    pub fn beginAssistantMessage(self: *SessionDoc, msg_id: []const u8, now_ms: i64) !void {
        if (self.findMessageIdx(msg_id) != null) return;
        try self.bumpClock();
        const mid = try self.gpa.dupe(u8, msg_id);
        var transferred = false;
        errdefer if (!transferred) self.gpa.free(mid);
        const mrole = try self.gpa.dupe(u8, "assistant");
        errdefer if (!transferred) self.gpa.free(mrole);
        const mdev = try self.gpa.dupe(u8, self.device_id);
        errdefer if (!transferred) self.gpa.free(mdev);
        const mstatus = try self.gpa.dupe(u8, "streaming");
        errdefer if (!transferred) self.gpa.free(mstatus);

        var msg = MessageEntry{
            .id = mid,
            .role = mrole,
            .created_at = now_ms,
            .device_id = mdev,
            .status = mstatus,
        };
        transferred = true;
        errdefer msg.deinit(self.gpa);
        try self.appendIndexedMessage(msg);
    }

    /// O(1) tail/hash-indexed RLE streaming delta append on a text or reasoning part.
    /// Returns the new total byte length of the part's text for `WatchDocMessages` `append` frames.
    pub fn appendPartDelta(self: *SessionDoc, msg_id: []const u8, part_id: []const u8, kind: []const u8, delta: []const u8) !usize {
        const msg_idx = self.findMessageIdx(msg_id) orelse return error.MessageNotFound;
        try self.bumpClock();
        const m = &self.messages.items[msg_idx];
        // Reverse scan on `m.parts`: the active streaming part is almost always the tail part.
        var pi = m.parts.items.len;
        while (pi > 0) {
            pi -= 1;
            const p = &m.parts.items[pi];
            if (std.mem.eql(u8, p.id, part_id)) {
                try p.text.appendSlice(self.gpa, delta);
                self.live_payload_bytes += delta.len;
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
        const w = part.byteWeight();
        try m.parts.append(self.gpa, part);
        self.live_payload_bytes += w;
        return new_len;
    }

    /// Upsert a structured tool call part (`kind = "tool"`) with `ToolCall` JSON, output,
    /// `resolved`, and `isError` so `transcript.zig` folds tool chips 1:1 with Rust.
    pub fn upsertToolPart(
        self: *SessionDoc,
        msg_id: []const u8,
        part_id: []const u8,
        call_json: []const u8,
        output: ?[]const u8,
        resolved: bool,
        is_error: bool,
    ) !void {
        const msg_idx = self.findMessageIdx(msg_id) orelse return error.MessageNotFound;
        try self.bumpClock();
        const m = &self.messages.items[msg_idx];
        for (m.parts.items) |*p| {
            if (std.mem.eql(u8, p.id, part_id)) {
                const old_w = p.byteWeight();
                if (call_json.len > 0) {
                    const c_copy = try self.gpa.dupe(u8, call_json);
                    if (p.call_json) |old_c| self.gpa.free(old_c);
                    p.call_json = c_copy;
                }
                if (output) |out_s| {
                    const o_copy = try self.gpa.dupe(u8, out_s);
                    if (p.output) |old_o| self.gpa.free(old_o);
                    p.output = o_copy;
                }
                p.resolved = resolved;
                p.is_error = is_error;
                self.live_payload_bytes = self.live_payload_bytes - old_w + p.byteWeight();
                return;
            }
        }
        var part = PartItem{
            .id = try self.gpa.dupe(u8, part_id),
            .kind = try self.gpa.dupe(u8, "tool"),
            .resolved = resolved,
            .is_error = is_error,
        };
        errdefer part.deinit(self.gpa);
        part.call_json = try self.gpa.dupe(u8, if (call_json.len > 0) call_json else "{\"kind\":\"unknown\",\"name\":\"Tool\"}");
        if (output) |out_s| part.output = try self.gpa.dupe(u8, out_s);
        const w = part.byteWeight();
        try m.parts.append(self.gpa, part);
        self.live_payload_bytes += w;
    }

    pub fn setMessageStatus(self: *SessionDoc, msg_id: []const u8, status: []const u8) !void {
        const msg_idx = self.findMessageIdx(msg_id) orelse return;
        try self.bumpClock();
        const m = &self.messages.items[msg_idx];
        const was_streaming = m.isStreaming();
        const old_len: usize = if (m.status) |old| old.len else 0;
        const copy = try self.gpa.dupe(u8, status);
        if (m.status) |old| self.gpa.free(old);
        m.status = copy;
        self.live_payload_bytes = self.live_payload_bytes - old_len + copy.len;
        const now_streaming = std.mem.eql(u8, copy, "streaming");
        if (was_streaming and !now_streaming) {
            self.streaming_msg_count -|= 1;
        } else if (!was_streaming and now_streaming) {
            self.streaming_msg_count += 1;
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
        const item = QueuedItem{
            .id = qid,
            .text = qtext,
            .issued_by = qby,
            .issued_at = now_ms,
            .hold_for_turn_end = hold,
        };
        const w = item.byteWeight();
        try self.queue.append(self.gpa, item);
        self.live_payload_bytes += w;
    }

    /// Retype a queued message (`UpdateQueuedMessage`); empty/whitespace text deletes it (`crates/doc/src/queue.rs` line 169).
    pub fn updateQueuedText(self: *SessionDoc, row_id: []const u8, new_text: []const u8) !bool {
        if (std.mem.trim(u8, new_text, " \t\r\n").len == 0) {
            return self.removeQueued(row_id);
        }
        for (self.queue.items) |*q| {
            if (std.mem.eql(u8, q.id, row_id)) {
                if (std.mem.eql(u8, q.text, new_text)) return false;
                try self.bumpClock();
                const copy = try self.gpa.dupe(u8, new_text);
                self.live_payload_bytes = self.live_payload_bytes - q.text.len + copy.len;
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
                self.live_payload_bytes -|= q.byteWeight();
                q.deinit(self.gpa);
                _ = self.queue.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Pop a queued row and return its owned `text` slice (`SendQueuedMessageNow` / `SteerQueuedMessageNow`).
    pub fn takeQueuedText(self: *SessionDoc, row_id: []const u8) ?[]u8 {
        for (self.queue.items, 0..) |*q, idx| {
            if (std.mem.eql(u8, q.id, row_id)) {
                self.live_payload_bytes -|= q.byteWeight();
                const owned_text = q.text;
                self.gpa.free(q.id);
                self.gpa.free(q.issued_by);
                q.clearGate(self.gpa);
                _ = self.queue.orderedRemove(idx);
                return owned_text;
            }
        }
        return null;
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

    /// Fail-closed lease sweep (`crates/doc/src/queue.rs` & Lean `expired_edit_fails_closed_never_auto_delivers`):
    /// any active `editing` gate with `now_ms >= expires_at_ms` transitions to `review_required`.
    pub fn expireQueueLeases(self: *SessionDoc, now_ms: i64) bool {
        var changed = false;
        for (self.queue.items) |*q| {
            if (q.gate_kind == .editing and q.expires_at_ms > 0 and now_ms >= q.expires_at_ms) {
                q.gate_kind = .review_required;
                q.acquired_at_ms = now_ms;
                changed = true;
            }
        }
        return changed;
    }

    /// Host-authoritative queue edit lease (`BeginQueuedMessageEdit`) with full metadata & `QUEUE_EDIT_LEASE_MS`.
    pub fn beginEditQueuedAt(
        self: *SessionDoc,
        row_id: []const u8,
        lease_id: []const u8,
        editor_device_id: []const u8,
        editor_instance_id: []const u8,
        now_ms: i64,
    ) !bool {
        _ = self.expireQueueLeases(now_ms);
        for (self.queue.items) |*q| {
            if (!std.mem.eql(u8, q.id, row_id)) continue;
            switch (q.gate_kind) {
                .none => {},
                .editing => {
                    if (q.lease_id) |cur| {
                        if (!std.mem.eql(u8, cur, lease_id)) return false;
                    }
                },
                .review_required => {
                    if (q.editor_device_id) |prev_dev| {
                        if (!std.mem.eql(u8, prev_dev, editor_device_id)) return false;
                    }
                },
            }
            try self.bumpClock();
            const l_copy = try self.gpa.dupe(u8, lease_id);
            errdefer self.gpa.free(l_copy);
            const d_copy = try self.gpa.dupe(u8, editor_device_id);
            errdefer self.gpa.free(d_copy);
            const i_copy = try self.gpa.dupe(u8, editor_instance_id);
            q.clearGate(self.gpa);
            q.gate_kind = .editing;
            q.lease_id = l_copy;
            q.editor_device_id = d_copy;
            q.editor_instance_id = i_copy;
            q.acquired_at_ms = now_ms;
            q.expires_at_ms = now_ms + queue_edit_lease_ms;
            return true;
        }
        return false;
    }

    pub fn beginEditQueued(self: *SessionDoc, row_id: []const u8, lease_id: []const u8, editor_device_id: []const u8) !bool {
        return self.beginEditQueuedAt(row_id, lease_id, editor_device_id, "inst-default", 1000);
    }

    /// Renew an active edit lease (`RenewQueuedMessageEdit`), extending expiry by `QUEUE_EDIT_LEASE_MS = 60_000`.
    pub fn renewEditQueued(self: *SessionDoc, row_id: []const u8, lease_id: []const u8, now_ms: i64) !bool {
        _ = self.expireQueueLeases(now_ms);
        for (self.queue.items) |*q| {
            if (!std.mem.eql(u8, q.id, row_id)) continue;
            if (q.gate_kind != .editing) return false;
            const cur = q.lease_id orelse return false;
            if (!std.mem.eql(u8, cur, lease_id)) return false;
            try self.bumpClock();
            q.expires_at_ms = now_ms + queue_edit_lease_ms;
            return true;
        }
        return false;
    }

    /// Complete or cancel a host-authoritative queue edit lease (`FinishQueuedMessageEdit`).
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
                    self.live_payload_bytes -|= q.byteWeight();
                    q.deinit(self.gpa);
                    _ = self.queue.orderedRemove(idx);
                    return true;
                },
                .commit => {
                    if (new_text) |txt| {
                        if (std.mem.trim(u8, txt, " \t\r\n").len == 0) {
                            // Committing empty text deletes the row (`crates/doc/src/queue.rs` & Lean `commit_empty_text_deletes_row`).
                            self.live_payload_bytes -|= q.byteWeight();
                            q.deinit(self.gpa);
                            _ = self.queue.orderedRemove(idx);
                            return true;
                        }
                        const copy = try self.gpa.dupe(u8, txt);
                        self.live_payload_bytes = self.live_payload_bytes - q.text.len + copy.len;
                        self.gpa.free(q.text);
                        q.text = copy;
                    }
                    q.clearGate(self.gpa);
                    return true;
                },
                .cancel, .release_unchanged => {
                    q.clearGate(self.gpa);
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
        const entry = CommandEntry{
            .id = cid,
            .kind = k_copy,
            .payload_json = p_copy,
            .issued_by = by_copy,
            .issued_at = now_ms,
            .status = st_copy,
        };
        const w = entry.byteWeight();
        const is_pending = std.mem.eql(u8, st_copy, "pending");
        try self.commands.append(self.gpa, entry);
        self.live_payload_bytes += w;
        if (is_pending) self.pending_cmd_count += 1;
    }

    pub fn abortStreamingMessages(self: *SessionDoc) !void {
        for (self.messages.items) |*m| {
            if (m.status) |st| {
                if (std.mem.eql(u8, st, "streaming")) {
                    const aborted = try self.gpa.dupe(u8, "aborted");
                    self.live_payload_bytes = self.live_payload_bytes - st.len + aborted.len;
                    self.gpa.free(st);
                    m.status = aborted;
                    self.streaming_msg_count -|= 1;
                }
            }
        }
    }

    fn writeEntryJson(w: *std.Io.Writer, m: MessageEntry) !void {
        try w.writeAll("{\"id\":");
        try json.Stringify.encodeJsonString(m.id, .{}, w);
        try w.writeAll(",\"role\":");
        try json.Stringify.encodeJsonString(m.role, .{}, w);
        try w.print(",\"createdAt\":{d},\"deviceId\":", .{m.created_at});
        try json.Stringify.encodeJsonString(m.device_id, .{}, w);
        if (m.status) |st| {
            try w.writeAll(",\"status\":");
            try json.Stringify.encodeJsonString(st, .{}, w);
        }
        if (m.duration_ms) |dms| {
            try w.print(",\"durationMs\":{d}", .{dms});
        }
        try w.writeAll(",\"parts\":[");
        for (m.parts.items, 0..) |p, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try json.Stringify.encodeJsonString(p.id, .{}, w);
            try w.writeAll(",\"kind\":");
            try json.Stringify.encodeJsonString(p.kind, .{}, w);
            if (std.mem.eql(u8, p.kind, "reasoning")) {
                try w.writeAll(",\"text\":");
                try json.Stringify.encodeJsonString(p.text.items, .{}, w);
                try w.writeAll(",\"reasoning\":");
                try json.Stringify.encodeJsonString(p.text.items, .{}, w);
            } else if (std.mem.eql(u8, p.kind, "tool")) {
                try w.writeAll(",\"call\":");
                if (p.call_json) |cj| {
                    try w.writeAll(cj);
                } else {
                    try w.writeAll("{\"kind\":\"unknown\",\"name\":");
                    try json.Stringify.encodeJsonString(p.text.items, .{}, w);
                    try w.writeByte('}');
                }
                try w.print(",\"resolved\":{},\"isError\":{}", .{ p.resolved, p.is_error });
                if (p.output) |out_s| {
                    try w.writeAll(",\"output\":");
                    try json.Stringify.encodeJsonString(out_s, .{}, w);
                }
            } else if (std.mem.eql(u8, p.kind, "error")) {
                try w.writeAll(",\"message\":");
                try json.Stringify.encodeJsonString(p.text.items, .{}, w);
            } else {
                try w.writeAll(",\"text\":");
                try json.Stringify.encodeJsonString(p.text.items, .{}, w);
            }
            if (p.extra_fields_json) |ef| {
                try w.writeAll(ef);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }

    fn writeResetFrame(self: *const SessionDoc, w: *std.Io.Writer) !void {
        try w.writeAll("{\"historyPending\":false,\"reset\":[");
        for (self.messages.items, 0..) |m, mi| {
            if (mi > 0) try w.writeByte(',');
            try writeEntryJson(w, m);
        }
        try w.writeAll("]}");
    }

    fn writeFrontier(self: *const SessionDoc, w: *std.Io.Writer) !void {
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
    }

    fn writeQueueFrame(self: *const SessionDoc, w: *std.Io.Writer) !void {
        try w.writeAll("{\"items\":[");
        for (self.queue.items, 0..) |q, qi| {
            if (qi > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try json.Stringify.encodeJsonString(q.id, .{}, w);
            try w.writeAll(",\"text\":");
            try json.Stringify.encodeJsonString(q.text, .{}, w);
            try w.print(",\"holdForTurnEnd\":{},\"issuedBy\":", .{q.hold_for_turn_end});
            try json.Stringify.encodeJsonString(q.issued_by, .{}, w);
            try w.print(",\"issuedAt\":{d}", .{q.issued_at});
            switch (q.gate_kind) {
                .none => {},
                .editing => {
                    try w.writeAll(",\"deliveryGate\":{\"kind\":\"editing\",\"leaseId\":");
                    try json.Stringify.encodeJsonString(q.lease_id orelse "", .{}, w);
                    try w.writeAll(",\"ownerDeviceId\":");
                    try json.Stringify.encodeJsonString(q.editor_device_id orelse "", .{}, w);
                    try w.writeAll(",\"ownerInstanceId\":");
                    try json.Stringify.encodeJsonString(q.editor_instance_id orelse "", .{}, w);
                    try w.print(",\"acquiredAtMs\":{d},\"expiresAtMs\":{d}}}", .{ q.acquired_at_ms, q.expires_at_ms });
                },
                .review_required => {
                    try w.writeAll(",\"deliveryGate\":{\"kind\":\"reviewRequired\",\"previousLeaseId\":");
                    try json.Stringify.encodeJsonString(q.lease_id orelse "", .{}, w);
                    try w.writeAll(",\"ownerDeviceId\":");
                    try json.Stringify.encodeJsonString(q.editor_device_id orelse "", .{}, w);
                    try w.print(",\"sinceMs\":{d}}}", .{q.acquired_at_ms});
                },
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }

    /// Build a `WatchDocMessages` `reset` JSON frame that `transcript.zig` applies.
    pub fn toResetFrameJson(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, self.live_payload_bytes + 128);
        errdefer aw.deinit();
        try self.writeResetFrame(&aw.writer);
        return aw.toOwnedSlice();
    }

    /// Build a `SessionTail` JSON sidecar (`PUT /chat2/{chatId}/tail`, `crates/doc/src/schema.rs:1525`):
    /// `{"chatId":"...","schemaVersion":1,"messages":[...last max_tail...],"totalMessages":N,"updatedAt":ms}`.
    pub fn toTailSidecarJson(self: *const SessionDoc, gpa: Allocator, updated_at_ms: i64, max_tail: usize) ![]u8 {
        const total = self.messages.items.len;
        const start = total -| max_tail;
        var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, @min(self.live_payload_bytes, 256 * 1024) + 192);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"chatId\":");
        try json.Stringify.encodeJsonString(self.chat_id, .{}, w);
        try w.print(",\"schemaVersion\":{d},\"messages\":[", .{schema_version});
        for (self.messages.items[start..], 0..) |m, mi| {
            if (mi > 0) try w.writeByte(',');
            try writeEntryJson(w, m);
        }
        try w.print("],\"totalMessages\":{d},\"updatedAt\":{d}}}", .{ total, updated_at_ms });
        return aw.toOwnedSlice();
    }

    /// Serialize the last `max_tail` messages as a bare JSON array (`[...]`) for `remote_tails` caching.
    pub fn toTailMessagesArrayJson(self: *const SessionDoc, gpa: Allocator, max_tail: usize) ![]u8 {
        const total = self.messages.items.len;
        const start = total -| max_tail;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeByte('[');
        for (self.messages.items[start..], 0..) |m, mi| {
            if (mi > 0) try w.writeByte(',');
            try writeEntryJson(w, m);
        }
        try w.writeByte(']');
        return aw.toOwnedSlice();
    }

    /// Return a trimmed single-line slice (up to `max_len` UTF-8-safe bytes) from the newest non-empty text part.
    pub fn latestTextPreview(self: *const SessionDoc, max_len: usize) ?[]const u8 {
        var mi = self.messages.items.len;
        while (mi > 0) {
            mi -= 1;
            const m = self.messages.items[mi];
            var pi = m.parts.items.len;
            while (pi > 0) {
                pi -= 1;
                const p = m.parts.items[pi];
                if (!std.mem.eql(u8, p.kind, "text")) continue;
                const trimmed = std.mem.trim(u8, p.text.items, " \t\r\n");
                if (trimmed.len == 0) continue;
                const nl = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
                const line = std.mem.trim(u8, trimmed[0..nl], " \t");
                if (line.len == 0) continue;
                return utf8PrefixSlice(line, max_len);
            }
        }
        return null;
    }

    fn utf8PrefixSlice(s: []const u8, max_bytes: usize) []const u8 {
        if (s.len <= max_bytes) return s;
        var end = max_bytes;
        while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
        return s[0..end];
    }

    /// Build an incremental `WatchDocMessages` `upsert` delta frame (`{"upsert":[{"after":...,"entry":{...}}],"count":N}`).
    pub fn toUpsertEntryFrameJson(self: *const SessionDoc, gpa: Allocator, msg_id: []const u8) ![]u8 {
        const idx = self.findMessageIdx(msg_id) orelse return error.MessageNotFound;

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
        try self.writeQueueFrame(&aw.writer);
        return aw.toOwnedSlice();
    }

    /// Export causal frontier (`vv`) as compact JSON bytes for `chat2` checkpoint frontier checks.
    pub fn exportFrontier(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try self.writeFrontier(&aw.writer);
        return aw.toOwnedSlice();
    }

    /// Ensure the backing `LoroSession` exists for `chat2` CRDT import/export.
    pub fn ensureLoroHandle(self: *SessionDoc) !*loro_ffi.LoroSession {
        if (self.loro_handle) |lh| return lh;
        const lh = try loro_ffi.createSession();
        self.loro_handle = lh;
        return lh;
    }

    /// Import a raw Loro 1.13 binary snapshot or row delta (`GET /checkpoint`, `GET /rows`),
    /// materialize its joined `messages` into `self.messages`, and return the causal status.
    pub fn importLoroBytes(self: *SessionDoc, bytes: []const u8) !loro_ffi.ImportOutcome {
        if (bytes.len == 0) return .applied;
        const lh = try self.ensureLoroHandle();
        const outcome = try loro_ffi.importBytes(lh, bytes);
        if (outcome == .applied) {
            const msgs_json = try loro_ffi.readMessagesJson(lh, self.gpa);
            defer self.gpa.free(msgs_json);
            _ = try self.mergeMessagesArrayJson(msgs_json);
        }
        return outcome;
    }

    /// Sync one `msg_id` (or all messages when `msg_id == null` or `loro_handle == null`)
    /// into the backing `LoroDoc` and return the incremental `ExportMode::updates(&before)`
    /// binary delta for `POST /chat2/{chatId}/rows`.
    pub fn syncEntryToLoroDelta(self: *SessionDoc, gpa: Allocator, msg_id: ?[]const u8) ![]u8 {
        const had_handle = self.loro_handle != null;
        const lh = try self.ensureLoroHandle();
        if (had_handle) {
            if (msg_id) |mid| {
                const idx = self.findMessageIdx(mid) orelse return gpa.alloc(u8, 0);
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                try writeEntryJson(&aw.writer, self.messages.items[idx]);
                return loro_ffi.syncMessagesJson(lh, self.chat_id, aw.written(), gpa);
            }
        }
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try aw.writer.writeByte('[');
        for (self.messages.items, 0..) |m, mi| {
            if (mi > 0) try aw.writer.writeByte(',');
            try writeEntryJson(&aw.writer, m);
        }
        try aw.writer.writeByte(']');
        return loro_ffi.syncMessagesJson(lh, self.chat_id, aw.written(), gpa);
    }

    /// Export full `ExportMode::Snapshot` Loro binary bytes for `POST /chat2/{chatId}/checkpoint`.
    pub fn exportLoroSnapshot(self: *SessionDoc, gpa: Allocator) ![]u8 {
        const delta = try self.syncEntryToLoroDelta(gpa, null);
        gpa.free(delta);
        return loro_ffi.exportSnapshot(self.loro_handle.?, gpa);
    }

    /// Export `oplog_vv().encode()` binary frontier bytes for `x-chat2-frontier`.
    pub fn exportLoroFrontier(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        if (self.loro_handle) |lh| return loro_ffi.exportFrontier(lh, gpa);
        return gpa.alloc(u8, 0);
    }

    /// Build a `<earlier-conversation>` seeded prompt matching `crates/engine/src/external_history/mod.rs`
    /// (`SEED_CONVERSATION_BYTES = 60_000`) when continuing a synced conversation in a fresh `graff` session.
    /// Returns `null` when there are no prior messages to seed.
    pub fn buildEarlierConversationSeedAlloc(
        self: *const SessionDoc,
        gpa: Allocator,
        exclude_msg_id: ?[]const u8,
        prompt: []const u8,
        checkout_changed: bool,
    ) !?[]u8 {
        const seed_max_bytes: usize = 60_000;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var lines: std.ArrayList([]const u8) = .empty;
        for (self.messages.items) |m| {
            if (exclude_msg_id) |ex| {
                if (std.mem.eql(u8, m.id, ex)) continue;
            }
            const role_label: []const u8 = if (std.mem.eql(u8, m.role, "user"))
                "User"
            else if (std.mem.eql(u8, m.role, "assistant"))
                "Assistant"
            else
                continue;

            for (m.parts.items) |p| {
                if (std.mem.eql(u8, p.kind, "text")) {
                    const trimmed = std.mem.trim(u8, p.text.items, " \t\r\n");
                    if (trimmed.len > 0) {
                        try lines.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ role_label, trimmed }));
                    }
                } else if (std.mem.eql(u8, p.kind, "tool")) {
                    var tool_kind: []const u8 = "call";
                    if (p.call_json) |cj| {
                        if (json.parseFromSliceLeaky(json.Value, a, cj, .{})) |cv| {
                            if (cv == .object) {
                                if (cv.object.get("kind")) |kv| {
                                    if (kv == .string and kv.string.len > 0) tool_kind = kv.string;
                                }
                            }
                        } else |_| {}
                    }
                    var result_line: []const u8 = "…";
                    if (p.output) |out_s| {
                        const trimmed = std.mem.trim(u8, out_s, " \t\r\n");
                        if (trimmed.len > 0) {
                            const nl = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
                            const single = std.mem.trim(u8, trimmed[0..nl], " \t");
                            if (single.len > 0) result_line = utf8PrefixSlice(single, 120);
                        }
                    }
                    try lines.append(a, try std.fmt.allocPrint(a, "Tool: {s} — {s}", .{ tool_kind, result_line }));
                }
            }
        }

        if (lines.items.len == 0) return null;

        var kept_start: usize = lines.items.len;
        var total_bytes: usize = 0;
        while (kept_start > 0) {
            const candidate = lines.items[kept_start - 1];
            if (total_bytes + candidate.len > seed_max_bytes and kept_start < lines.items.len) break;
            total_bytes += candidate.len;
            kept_start -= 1;
        }
        const omitted = kept_start;
        const intro = if (checkout_changed)
            "This conversation is continuing in a different checkout. Earlier messages are read-only context, not evidence that their files or uncommitted edits exist here. Inspect this checkout before continuing; don't redo finished work."
        else
            "This conversation started in an earlier session and continues here in graff. The earlier conversation is below as read-only context; don't redo work it shows as finished.";

        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll(intro);
        try w.writeAll("\n\n<earlier-conversation>\n");
        if (omitted > 0) {
            try w.print("[{d} earlier messages omitted]\n", .{omitted});
        }
        for (lines.items[kept_start..], 0..) |line, li| {
            if (li > 0) try w.writeByte('\n');
            try w.writeAll(line);
        }
        try w.writeAll("\n</earlier-conversation>\n\n");
        try w.writeAll(prompt);
        return try aw.toOwnedSlice();
    }

    fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }

    fn partItemEqual(a: PartItem, b: PartItem) bool {
        if (!std.mem.eql(u8, a.id, b.id)) return false;
        if (!std.mem.eql(u8, a.kind, b.kind)) return false;
        if (!std.mem.eql(u8, a.text.items, b.text.items)) return false;
        if (!optStrEql(a.call_json, b.call_json)) return false;
        if (!optStrEql(a.output, b.output)) return false;
        if (!optStrEql(a.extra_fields_json, b.extra_fields_json)) return false;
        return a.is_error == b.is_error and a.resolved == b.resolved;
    }

    fn messageEntryEqual(a: MessageEntry, b: MessageEntry) bool {
        if (!std.mem.eql(u8, a.id, b.id)) return false;
        if (!std.mem.eql(u8, a.role, b.role)) return false;
        if (a.created_at != b.created_at) return false;
        if (!std.mem.eql(u8, a.device_id, b.device_id)) return false;
        if (!optStrEql(a.status, b.status)) return false;
        if (a.duration_ms != b.duration_ms) return false;
        if (a.parts.items.len != b.parts.items.len) return false;
        for (a.parts.items, b.parts.items) |pa, pb| {
            if (!partItemEqual(pa, pb)) return false;
        }
        return true;
    }

    fn isCorePartField(k: []const u8) bool {
        const core = [_][]const u8{
            "id", "kind", "text", "reasoning", "call", "resolved", "isError", "output", "message",
        };
        for (core) |ck| {
            if (std.mem.eql(u8, k, ck)) return true;
        }
        return false;
    }

    fn parseMessageEntryFromJsonObject(self: *const SessionDoc, mo: json.ObjectMap) !?MessageEntry {
        const id_s = if (mo.get("id")) |v| (if (v == .string and v.string.len > 0) v.string else return null) else return null;
        const role_s = if (mo.get("role")) |v| (if (v == .string) v.string else "assistant") else "assistant";
        const created_at: i64 = if (mo.get("createdAt")) |v| (if (v == .integer) v.integer else 0) else 0;
        const dev_s = if (mo.get("deviceId")) |v| (if (v == .string) v.string else self.device_id) else self.device_id;
        const status_s: ?[]const u8 = if (mo.get("status")) |v| (if (v == .string) v.string else null) else null;
        const duration_ms: ?i64 = if (mo.get("durationMs")) |v| (if (v == .integer) v.integer else null) else null;

        const mid = try self.gpa.dupe(u8, id_s);
        var msg_transferred = false;
        errdefer if (!msg_transferred) self.gpa.free(mid);
        const mrole = try self.gpa.dupe(u8, role_s);
        errdefer if (!msg_transferred) self.gpa.free(mrole);
        const mdev = try self.gpa.dupe(u8, dev_s);
        errdefer if (!msg_transferred) self.gpa.free(mdev);
        const mstatus = if (status_s) |st| try self.gpa.dupe(u8, st) else null;
        errdefer if (!msg_transferred) if (mstatus) |st| self.gpa.free(st);

        var msg = MessageEntry{
            .id = mid,
            .role = mrole,
            .created_at = created_at,
            .device_id = mdev,
            .status = mstatus,
            .duration_ms = duration_ms,
        };
        msg_transferred = true;
        errdefer msg.deinit(self.gpa);

        if (mo.get("parts")) |parts_arr| if (parts_arr == .array) {
            for (parts_arr.array.items) |p_val| {
                if (p_val != .object) continue;
                const po = p_val.object;
                const pid = if (po.get("id")) |v| (if (v == .string) v.string else "p") else "p";
                const pkind = if (po.get("kind")) |v| (if (v == .string) v.string else "text") else "text";
                const ptext = if (po.get("text")) |v|
                    (if (v == .string) v.string else "")
                else if (po.get("reasoning")) |v|
                    (if (v == .string) v.string else "")
                else if (po.get("message")) |v|
                    (if (v == .string) v.string else "")
                else
                    "";

                const has_is_err = if (po.get("isError")) |ev| ev == .bool else false;
                const is_err_val = if (po.get("isError")) |ev| (ev == .bool and ev.bool) else false;
                const resolved_val = if (po.get("resolved")) |rv|
                    (rv == .bool and rv.bool)
                else
                    has_is_err;

                var part = PartItem{
                    .id = try self.gpa.dupe(u8, pid),
                    .kind = try self.gpa.dupe(u8, pkind),
                    .resolved = resolved_val,
                    .is_error = is_err_val,
                };
                errdefer part.deinit(self.gpa);
                if (ptext.len > 0) try part.text.appendSlice(self.gpa, ptext);
                if (po.get("call")) |call_v| {
                    if (call_v == .object) {
                        part.call_json = try json.Stringify.valueAlloc(self.gpa, call_v, .{});
                    }
                }
                if (po.get("output")) |out_v| if (out_v == .string) {
                    part.output = try self.gpa.dupe(u8, out_v.string);
                };

                var extra_aw: std.Io.Writer.Allocating = .init(self.gpa);
                errdefer extra_aw.deinit();
                var has_extra = false;
                var pit = po.iterator();
                while (pit.next()) |pe| {
                    if (pe.value_ptr.* == .null) continue;
                    if (isCorePartField(pe.key_ptr.*)) continue;
                    has_extra = true;
                    try extra_aw.writer.writeByte(',');
                    try json.Stringify.encodeJsonString(pe.key_ptr.*, .{}, &extra_aw.writer);
                    try extra_aw.writer.writeByte(':');
                    const encoded_v = try json.Stringify.valueAlloc(self.gpa, pe.value_ptr.*, .{});
                    defer self.gpa.free(encoded_v);
                    try extra_aw.writer.writeAll(encoded_v);
                }
                if (has_extra) {
                    part.extra_fields_json = try extra_aw.toOwnedSlice();
                } else {
                    extra_aw.deinit();
                }

                try msg.parts.append(self.gpa, part);
            }
        };
        return msg;
    }

    /// Upsert or update a `MessageEntry` parsed from JSON, maintaining exact `live_payload_bytes`,
    /// `streaming_msg_count`, `msg_index`, and chronological order on historical backfills.
    pub fn upsertMessageFromJsonObject(self: *SessionDoc, mo: json.ObjectMap) !bool {
        var new_msg = (try self.parseMessageEntryFromJsonObject(mo)) orelse return false;
        errdefer new_msg.deinit(self.gpa);

        if (self.findMessageIdx(new_msg.id)) |existing_idx| {
            var old_msg = self.messages.items[existing_idx];
            if (messageEntryEqual(old_msg, new_msg)) {
                new_msg.deinit(self.gpa);
                return false;
            }
            // Never regress an actively locally-streaming message with a shorter stale tail.
            if (old_msg.isStreaming() and std.mem.eql(u8, old_msg.device_id, self.device_id) and
                new_msg.isStreaming() and new_msg.totalByteWeight() < old_msg.totalByteWeight())
            {
                new_msg.deinit(self.gpa);
                return false;
            }
            const old_w = old_msg.totalByteWeight();
            const new_w = new_msg.totalByteWeight();
            const was_streaming = old_msg.isStreaming();
            const now_streaming = new_msg.isStreaming();

            try self.msg_index.ensureUnusedCapacity(self.gpa, 1);
            _ = self.msg_index.remove(old_msg.id);
            self.msg_index.putAssumeCapacity(new_msg.id, existing_idx);
            old_msg.deinit(self.gpa);
            self.messages.items[existing_idx] = new_msg;
            self.live_payload_bytes = self.live_payload_bytes - old_w + new_w;
            if (was_streaming and !now_streaming) {
                self.streaming_msg_count -|= 1;
            } else if (!was_streaming and now_streaming) {
                self.streaming_msg_count += 1;
            }
            return true;
        }

        // Fast path: empty list or chronological append at tail.
        if (self.messages.items.len == 0 or new_msg.created_at == 0 or
            self.messages.items[self.messages.items.len - 1].created_at <= new_msg.created_at)
        {
            try self.appendIndexedMessage(new_msg);
            return true;
        }

        // Historical backfill arrived after a newer local message: insert in chronological order
        // and refresh `msg_index` from `ins_idx` onward.
        var ins_idx: usize = 0;
        while (ins_idx < self.messages.items.len) : (ins_idx += 1) {
            const cur_ts = self.messages.items[ins_idx].created_at;
            if (cur_ts > 0 and cur_ts > new_msg.created_at) break;
        }
        try self.messages.ensureUnusedCapacity(self.gpa, 1);
        try self.msg_index.ensureUnusedCapacity(self.gpa, 1);
        const w = new_msg.totalByteWeight();
        const is_str = new_msg.isStreaming();
        self.messages.insertAssumeCapacity(ins_idx, new_msg);
        for (self.messages.items[ins_idx..], ins_idx..) |m, idx| {
            try self.msg_index.put(self.gpa, m.id, idx);
        }
        self.live_payload_bytes += w;
        if (is_str) self.streaming_msg_count += 1;
        return true;
    }

    /// Merge a JSON array `[...]` of `SessionMessageEntry` objects (or a `SessionTail` `{ "messages": [...] }`)
    /// into `self`, returning `true` if any entry was inserted or updated.
    pub fn mergeMessagesArrayJson(self: *SessionDoc, raw_json: []const u8) !bool {
        if (raw_json.len == 0) return false;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const parsed = try json.parseFromSliceLeaky(json.Value, arena.allocator(), raw_json, .{});
        const items: []const json.Value = switch (parsed) {
            .array => |arr| arr.items,
            .object => |obj| blk: {
                if (obj.get("messages")) |mv| if (mv == .array) break :blk mv.array.items;
                if (obj.get("reset")) |rv| if (rv == .array) break :blk rv.array.items;
                return false;
            },
            else => return false,
        };
        var changed = false;
        for (items) |m_val| {
            if (m_val != .object) continue;
            if (try self.upsertMessageFromJsonObject(m_val.object)) {
                changed = true;
            }
        }
        return changed;
    }

    /// True if `frontier_bytes` is contained in this document's causal history.
    /// Per `crates/engine/src/chat2_host.rs:194-227`, an empty or undecodable frontier on a
    /// present checkpoint returns `false` so the caller fetches the checkpoint safely.
    pub fn frontierContained(self: *const SessionDoc, gpa: Allocator, frontier_bytes: []const u8) bool {
        if (frontier_bytes.len == 0) return false;
        if (frontier_bytes[0] != '{') {
            if (self.loro_handle) |lh| {
                return loro_ffi.containsFrontier(lh, frontier_bytes);
            }
            return false;
        }
        var parsed = json.parseFromSlice(json.Value, gpa, frontier_bytes, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        if (parsed.value.object.count() == 0) return false;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .integer) return false;
            const need: u64 = @intCast(@max(0, e.value_ptr.integer));
            const have = self.vv.get(e.key_ptr.*) orelse 0;
            if (have < need) return false;
        }
        return true;
    }

    /// Single-pass pre-sized snapshot export (`HZD1` header + JSON state, plus embedded Loro
    /// binary snapshot when `loro_handle` is active so causal oplog history survives restarts).
    pub fn exportSnapshot(self: *const SessionDoc, gpa: Allocator) ![]u8 {
        var loro_b64: ?[]u8 = null;
        defer if (loro_b64) |b| gpa.free(b);
        if (self.loro_handle) |lh| {
            if (loro_ffi.exportSnapshot(lh, gpa)) |loro_raw| {
                defer gpa.free(loro_raw);
                if (loro_raw.len > 0) {
                    const enc_len = std.base64.standard.Encoder.calcSize(loro_raw.len);
                    const buf = try gpa.alloc(u8, enc_len);
                    _ = std.base64.standard.Encoder.encode(buf, loro_raw);
                    loro_b64 = buf;
                }
            } else |_| {}
        }

        const extra_loro = if (loro_b64) |b| b.len + 16 else 0;
        const est_cap = self.live_payload_bytes + self.vv.count() * 48 + extra_loro + 256;
        var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, est_cap);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll(zig_doc_magic);
        try w.print("{{\"schemaVersion\":{d},\"chatId\":", .{schema_version});
        try json.Stringify.encodeJsonString(self.chat_id, .{}, w);
        try w.writeAll(",\"vv\":");
        try self.writeFrontier(w);
        try w.writeAll(",\"transcript\":");
        try self.writeResetFrame(w);
        try w.writeAll(",\"queue\":");
        try self.writeQueueFrame(w);
        if (loro_b64) |b| {
            try w.writeAll(",\"loro\":");
            try json.Stringify.encodeJsonString(b, .{}, w);
        }
        try w.writeByte('}');
        return aw.toOwnedSlice();
    }

    /// Import a snapshot or CRDT update (`loro` binary blob OR `HZD1` envelope) into `self`,
    /// merging Loro causal history, version vector entries, messages, tool calls, and queue items.
    pub fn importSnapshot(self: *SessionDoc, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (isRustLoroBlob(bytes)) {
            _ = try self.importLoroBytes(bytes);
            return;
        }
        const payload = if (std.mem.startsWith(u8, bytes, zig_doc_magic))
            bytes[zig_doc_magic.len..]
        else
            bytes;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const parsed = json.parseFromSliceLeaky(json.Value, arena.allocator(), payload, .{}) catch |err| {
            // Non-JSON binary Loro delta that didn't start with `"loro"` snapshot magic.
            if (bytes.len > 0 and bytes[0] != '{' and !std.mem.startsWith(u8, bytes, zig_doc_magic)) {
                _ = try self.importLoroBytes(bytes);
                return;
            }
            return err;
        };
        if (parsed != .object) return error.InvalidSnapshot;
        const root = parsed.object;

        if (root.get("loro")) |loro_v| if (loro_v == .string and loro_v.string.len > 0) {
            const dec = std.base64.standard.Decoder;
            if (dec.calcSizeForSlice(loro_v.string)) |dec_len| {
                const raw = try arena.allocator().alloc(u8, dec_len);
                if (dec.decode(raw, loro_v.string)) |_| {
                    _ = self.importLoroBytes(raw) catch {};
                } else |_| {}
            } else |_| {}
        };

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
                    _ = try self.upsertMessageFromJsonObject(m_val.object);
                }
            };
        };

        if (root.get("queue")) |q_root| if (q_root == .object) {
            if (q_root.object.get("items")) |items_val| if (items_val == .array) {
                for (items_val.array.items) |q_val| {
                    if (q_val != .object) continue;
                    const qo = q_val.object;
                    const qid_s = if (qo.get("id")) |v| (if (v == .string) v.string else continue) else continue;
                    const qtxt_s = if (qo.get("text")) |v| (if (v == .string) v.string else continue) else continue;

                    var q_exists = false;
                    for (self.queue.items) |existing| {
                        if (std.mem.eql(u8, existing.id, qid_s)) {
                            q_exists = true;
                            break;
                        }
                    }
                    if (q_exists) continue;

                    const hold = if (qo.get("holdForTurnEnd")) |hv| (if (hv == .bool) hv.bool else true) else true;
                    const issued_by = if (qo.get("issuedBy")) |bv| (if (bv == .string) bv.string else self.device_id) else self.device_id;
                    const issued_at: i64 = if (qo.get("issuedAt")) |av| (if (av == .integer) av.integer else 0) else 0;

                    var item = QueuedItem{
                        .id = try self.gpa.dupe(u8, qid_s),
                        .text = try self.gpa.dupe(u8, qtxt_s),
                        .issued_by = try self.gpa.dupe(u8, issued_by),
                        .issued_at = issued_at,
                        .hold_for_turn_end = hold,
                    };
                    errdefer item.deinit(self.gpa);

                    if (qo.get("deliveryGate")) |gv| if (gv == .object) {
                        const go = gv.object;
                        const gkind = if (go.get("kind")) |kv| (if (kv == .string) kv.string else "") else "";
                        if (std.mem.eql(u8, gkind, "editing")) {
                            item.gate_kind = .editing;
                            if (go.get("leaseId")) |lv| if (lv == .string) {
                                item.lease_id = try self.gpa.dupe(u8, lv.string);
                            };
                            if (go.get("ownerDeviceId")) |dv| if (dv == .string) {
                                item.editor_device_id = try self.gpa.dupe(u8, dv.string);
                            };
                            if (go.get("ownerInstanceId")) |iv| if (iv == .string) {
                                item.editor_instance_id = try self.gpa.dupe(u8, iv.string);
                            };
                            if (go.get("acquiredAtMs")) |am| if (am == .integer) {
                                item.acquired_at_ms = am.integer;
                            };
                            if (go.get("expiresAtMs")) |em| if (em == .integer) {
                                item.expires_at_ms = em.integer;
                            };
                        } else if (std.mem.eql(u8, gkind, "reviewRequired")) {
                            item.gate_kind = .review_required;
                            if (go.get("previousLeaseId")) |lv| if (lv == .string) {
                                item.lease_id = try self.gpa.dupe(u8, lv.string);
                            };
                            if (go.get("ownerDeviceId")) |dv| if (dv == .string) {
                                item.editor_device_id = try self.gpa.dupe(u8, dv.string);
                            };
                            if (go.get("sinceMs")) |sm| if (sm == .integer) {
                                item.acquired_at_ms = sm.integer;
                            };
                        }
                    };

                    const w = item.byteWeight();
                    try self.queue.append(self.gpa, item);
                    self.live_payload_bytes += w;
                }
            };
        };
    }
};

test "SessionDoc RLE streaming delta, tool calls, fail-closed queue lease, and lossless queue+transcript snapshot roundtrip" {
    const gpa = testing.allocator;
    var doc = try SessionDoc.init(gpa, "chat-1", "dev-local");
    defer doc.deinit();

    try doc.appendUserMessage("msg-1", "p-1", "Port the engine to Zig", 1000);
    try doc.beginAssistantMessage("msg-2", 1005);
    try testing.expect(doc.hasActiveWork());
    const len1 = try doc.appendPartDelta("msg-2", "p-2", "text", "Working on ");
    try testing.expectEqual(@as(usize, 11), len1);

    // Structured tool call part round-trips into Transcript!
    try doc.upsertToolPart("msg-2", "tc-1", "{\"kind\":\"readFile\",\"path\":\"crates/doc/src/queue.rs\"}", "read ok", true, false);

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
    try testing.expectEqual(@as(usize, 2), tr.entries.items[1].parts.items.len);
    try testing.expectEqual(transcript.ToolKind.readFile, tr.entries.items[1].parts.items[1].tool);
    try testing.expect(tr.entries.items[1].parts.items[1].resolved);

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
    try testing.expect(!doc.hasActiveWork());
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

    // 2. Test queue reorder + fail-closed edit lease expiry + renewal
    try doc.enqueueMessage("q-1", "First item", true, 2000);
    try doc.enqueueMessage("q-2", "Second item", true, 2001);
    try testing.expect(try doc.moveQueued("q-2", 0));
    try testing.expectEqualStrings("q-2", doc.queue.items[0].id);
    try testing.expect(try doc.beginEditQueuedAt("q-2", "lease-1", "dev-local", "inst-1", 5_000));
    try testing.expect(!doc.queue.items[0].isAutoDeliverable(false));
    // Wrong lease rejected on renew
    try testing.expect(!try doc.renewEditQueued("q-2", "wrong-lease", 20_000));
    // Valid renew extends deadline to 20_000 + 60_000 = 80_000
    try testing.expect(try doc.renewEditQueued("q-2", "lease-1", 20_000));
    try testing.expectEqual(@as(i64, 80_000), doc.queue.items[0].expires_at_ms);
    // Expiry at 80_000 fails closed into review_required (NEVER auto-deliverable!)
    try testing.expect(doc.expireQueueLeases(80_000));
    try testing.expectEqual(QueueGateKind.review_required, doc.queue.items[0].gate_kind);
    try testing.expect(!doc.queue.items[0].isAutoDeliverable(false));

    // Verify incremental O(1) payload bytes matches full linear fold!
    try testing.expectEqual(doc.computePayloadBytesLinear(), doc.approxPayloadBytes());

    // 3. Test single-pass exportSnapshot -> importSnapshot lossless roundtrip (messages + tool call + queue + reviewRequired gate!)
    const snap = try doc.exportSnapshot(gpa);
    defer gpa.free(snap);

    var doc2 = try SessionDoc.init(gpa, "chat-1", "dev-peer");
    defer doc2.deinit();
    try doc2.importSnapshot(snap);
    try testing.expectEqual(@as(usize, 2), doc2.messages.items.len);
    try testing.expectEqual(@as(usize, 2), doc2.queue.items.len);
    try testing.expectEqual(QueueGateKind.review_required, doc2.queue.items[0].gate_kind);
    try testing.expectEqual(doc2.computePayloadBytesLinear(), doc2.approxPayloadBytes());
    const frontier = try doc.exportFrontier(gpa);
    defer gpa.free(frontier);
    try testing.expect(doc2.frontierContained(gpa, frontier));
}

test "Performance shape: O(1) indexed SessionDoc streaming + resident accounting >= 5x faster than linear O(M) baseline" {
    const gpa = testing.allocator;
    var doc = try SessionDoc.init(gpa, "chat-bench", "dev-bench");
    defer doc.deinit();

    // Seed 400 messages with multi-part history so linear O(M*P) scans feel realchat depth.
    var id_buf: [64]u8 = undefined;
    for (0..400) |i| {
        const mid = try std.fmt.bufPrint(&id_buf, "hist-msg-{d}", .{i});
        try doc.appendUserMessage(mid, "p-u", "Synthetic benchmark history line with realistic payload bytes.", @intCast(i));
    }
    try doc.beginAssistantMessage("live-tail", 5000);
    _ = try doc.appendPartDelta("live-tail", "p-live", "text", "init ");

    const iterations: usize = 2_000;

    // Slow baseline: linear message scan + linear full-doc byte & active-work scan on every streaming chunk
    const t0 = std.Io.Clock.Timestamp.now(testing.io, .awake);
    var sink_slow: usize = 0;
    for (0..iterations) |_| {
        // Simulate naive linear message lookup from index 0 + full resident byte scan
        for (doc.messages.items) |m| {
            if (std.mem.eql(u8, m.id, "live-tail")) {
                sink_slow +%= m.parts.items.len;
                break;
            }
        }
        sink_slow +%= doc.computePayloadBytesLinear();
    }
    const slow_ns: u64 = @intCast(@max(1, t0.untilNow(testing.io).raw.nanoseconds));

    // Fast path: O(1) tail/hash `findMessageIdx` + O(1) `approxPayloadBytes` + O(1) `hasActiveWork`
    const t1 = std.Io.Clock.Timestamp.now(testing.io, .awake);
    var sink_fast: usize = 0;
    for (0..iterations) |_| {
        if (doc.findMessageIdx("live-tail")) |idx| {
            sink_fast +%= doc.messages.items[idx].parts.items.len;
        }
        sink_fast +%= doc.approxPayloadBytes();
        if (doc.hasActiveWork()) sink_fast +%= 0;
    }
    const fast_ns: u64 = @intCast(@max(1, t1.untilNow(testing.io).raw.nanoseconds));

    try testing.expectEqual(sink_slow, sink_fast);
    // AGENTS.md shape test: O(1) path must be at least 5x faster than the O(M*P) scan!
    try testing.expect(fast_ns * 5 <= slow_ns);
}

test "SessionDoc Loro 1.13 binary CRDT snapshot + incremental RLE delta + earlier-conversation seed parity" {
    const gpa = testing.allocator;

    // 1. Desktop peer writes Turn 1 (user + reasoning + unresolved tool -> resolved tool + assistant text)
    var desktop_doc = try SessionDoc.init(gpa, "chat-loro-1", "dev-desktop");
    defer desktop_doc.deinit();

    // Empty or undecodable frontier on a present checkpoint must return false (fetch checkpoint).
    try testing.expect(!desktop_doc.frontierContained(gpa, ""));

    try desktop_doc.appendUserMessage("m-u1", "p-u1", "How does ranking work in dark mode?", 1_000);
    try desktop_doc.beginAssistantMessage("m-a1", 1_005);
    _ = try desktop_doc.appendPartDelta("m-a1", "p-r1", "reasoning", "Checking ranking weights...");
    try desktop_doc.upsertToolPart("m-a1", "tc-1", "{\"kind\":\"readFile\",\"path\":\"src/rank.rs\"}", null, false, false);

    const delta_1 = try desktop_doc.syncEntryToLoroDelta(gpa, null);
    defer gpa.free(delta_1);
    try testing.expect(delta_1.len > 0);

    // 2. Nano peer imports binary Loro delta_1: sees user message, reasoning, and unresolved tool part!
    var nano_doc = try SessionDoc.init(gpa, "chat-loro-1", "dev-nano");
    defer nano_doc.deinit();

    const out1 = try nano_doc.importLoroBytes(delta_1);
    try testing.expectEqual(loro_ffi.ImportOutcome.applied, out1);
    try testing.expectEqual(@as(usize, 2), nano_doc.messages.items.len);
    try testing.expectEqualStrings("dev-desktop", nano_doc.messages.items[0].device_id);
    try testing.expectEqualStrings("Checking ranking weights...", nano_doc.messages.items[1].parts.items[0].text.items);
    try testing.expect(!nano_doc.messages.items[1].parts.items[1].resolved);
    try testing.expectEqual(nano_doc.computePayloadBytesLinear(), nano_doc.approxPayloadBytes());

    // 3. Desktop peer resolves tool, streams assistant reply, and marks complete -> exports incremental delta_2
    try desktop_doc.upsertToolPart("m-a1", "tc-1", "{\"kind\":\"readFile\",\"path\":\"src/rank.rs\"}", "fn score() -> f64 { 0.8 }", true, false);
    _ = try desktop_doc.appendPartDelta("m-a1", "p-t1", "text", "Ranking uses BM25 ");
    _ = try desktop_doc.appendPartDelta("m-a1", "p-t1", "text", "plus recency decay.");
    try desktop_doc.setMessageStatus("m-a1", "complete");

    const delta_2 = try desktop_doc.syncEntryToLoroDelta(gpa, "m-a1");
    defer gpa.free(delta_2);
    try testing.expect(delta_2.len > 0);

    // Nano applies delta_2 in place without losing m-u1 or m-a1!
    const out2 = try nano_doc.importLoroBytes(delta_2);
    try testing.expectEqual(loro_ffi.ImportOutcome.applied, out2);
    try testing.expectEqual(@as(usize, 2), nano_doc.messages.items.len);
    try testing.expectEqualStrings("complete", nano_doc.messages.items[1].status.?);
    try testing.expect(nano_doc.messages.items[1].parts.items[1].resolved);
    try testing.expect(!nano_doc.messages.items[1].parts.items[1].is_error);
    try testing.expectEqualStrings("Ranking uses BM25 plus recency decay.", nano_doc.messages.items[1].parts.items[2].text.items);
    try testing.expectEqual(nano_doc.computePayloadBytesLinear(), nano_doc.approxPayloadBytes());

    // Frontier from desktop is now contained in nano_doc!
    const desktop_frontier = try desktop_doc.exportLoroFrontier(gpa);
    defer gpa.free(desktop_frontier);
    try testing.expect(nano_doc.frontierContained(gpa, desktop_frontier));

    // 4. Nano appends Turn 2 follow-up: builds `<earlier-conversation>` seed AND exports delta_3 back to Desktop!
    try nano_doc.appendUserMessage("m-u2", "p-u2", "Compare ranking strategies using the synthetic sample dataset.", 2_000);
    const seeded = (try nano_doc.buildEarlierConversationSeedAlloc(
        gpa,
        "m-u2",
        "Compare ranking strategies using the synthetic sample dataset.",
        false,
    )).?;
    defer gpa.free(seeded);
    try testing.expect(std.mem.indexOf(u8, seeded, "<earlier-conversation>") != null);
    try testing.expect(std.mem.indexOf(u8, seeded, "User: How does ranking work in dark mode?") != null);
    try testing.expect(std.mem.indexOf(u8, seeded, "Tool: readFile — fn score() -> f64 { 0.8 }") != null);
    try testing.expect(std.mem.indexOf(u8, seeded, "Assistant: Ranking uses BM25 plus recency decay.") != null);

    const delta_3 = try nano_doc.syncEntryToLoroDelta(gpa, "m-u2");
    defer gpa.free(delta_3);
    try testing.expect(delta_3.len > 0);

    // Desktop imports delta_3 and sees all 3 messages!
    const out3 = try desktop_doc.importLoroBytes(delta_3);
    try testing.expectEqual(loro_ffi.ImportOutcome.applied, out3);
    try testing.expectEqual(@as(usize, 3), desktop_doc.messages.items.len);
    try testing.expectEqualStrings("Compare ranking strategies using the synthetic sample dataset.", desktop_doc.messages.items[2].parts.items[0].text.items);
    try testing.expectEqualStrings("dev-nano", desktop_doc.messages.items[2].device_id);
    try testing.expectEqual(desktop_doc.computePayloadBytesLinear(), desktop_doc.approxPayloadBytes());

    // 5. HZD1 snapshot preserves embedded Loro oplog state across engine restarts!
    const hzd_snap = try nano_doc.exportSnapshot(gpa);
    defer gpa.free(hzd_snap);
    var restarted_nano = try SessionDoc.init(gpa, "chat-loro-1", "dev-nano");
    defer restarted_nano.deinit();
    try restarted_nano.importSnapshot(hzd_snap);
    try testing.expect(restarted_nano.frontierContained(gpa, desktop_frontier));
    try testing.expectEqual(@as(usize, 3), restarted_nano.messages.items.len);
    try testing.expectEqual(restarted_nano.computePayloadBytesLinear(), restarted_nano.approxPayloadBytes());
}
