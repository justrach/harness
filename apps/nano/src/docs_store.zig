//! `DocsStore` — local persistence for doc snapshots, chat2 room cursors,
//! the processed-command ledger, and the durable chat outbox (`crates/sync/src/store.rs`).
//!
//! Backed by SQLite (`docs.sqlite`) with persistent cached prepared statements and WAL
//! when opened via `openSqlite`, or in-memory when initialized via `init`.
//! Enforces C2 (`docs/chat2-sync.md`): snapshot bytes and applied cursor update
//! atomically together, and commands are marked processed BEFORE execution.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

// -----------------------------------------------------------------------------
// SQLite3 C ABI bindings (system libsqlite3)
// -----------------------------------------------------------------------------
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;
pub const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

extern "c" fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern "c" fn sqlite3_close(db: *sqlite3) c_int;
extern "c" fn sqlite3_exec(
    db: *sqlite3,
    sql: [*:0]const u8,
    callback: ?*const anyopaque,
    arg: ?*anyopaque,
    errmsg: ?*[*:0]u8,
) c_int;
extern "c" fn sqlite3_prepare_v2(
    db: *sqlite3,
    zSql: [*]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*[*]const u8,
) c_int;
extern "c" fn sqlite3_bind_text(
    stmt: *sqlite3_stmt,
    idx: c_int,
    val: [*]const u8,
    len: c_int,
    destructor: ?*const anyopaque,
) c_int;
extern "c" fn sqlite3_bind_blob(
    stmt: *sqlite3_stmt,
    idx: c_int,
    val: ?*const anyopaque,
    len: c_int,
    destructor: ?*const anyopaque,
) c_int;
extern "c" fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, val: i64) c_int;
extern "c" fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_clear_bindings(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_column_blob(stmt: *sqlite3_stmt, iCol: c_int) ?[*]const u8;
extern "c" fn sqlite3_column_text(stmt: *sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern "c" fn sqlite3_column_bytes(stmt: *sqlite3_stmt, iCol: c_int) c_int;
extern "c" fn sqlite3_column_int64(stmt: *sqlite3_stmt, iCol: c_int) i64;
extern "c" fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;

pub const schema_migrations_sql: [:0]const u8 =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\CREATE TABLE IF NOT EXISTS snapshots (
    \\    doc_id TEXT PRIMARY KEY,
    \\    bytes BLOB NOT NULL,
    \\    saved_at INTEGER NOT NULL,
    \\    cursor INTEGER NOT NULL DEFAULT 0,
    \\    epoch INTEGER NOT NULL DEFAULT 2,
    \\    cursor_verified INTEGER NOT NULL DEFAULT 1
    \\);
    \\CREATE TABLE IF NOT EXISTS processed_commands (
    \\    command_id TEXT PRIMARY KEY,
    \\    processed_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS chat_outbox (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    doc_id TEXT NOT NULL,
    \\    batch_id TEXT NOT NULL UNIQUE,
    \\    bytes BLOB NOT NULL,
    \\    needs_checkpoint INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_chat_outbox_doc_id ON chat_outbox (doc_id);
    \\CREATE TABLE IF NOT EXISTS chat_outbox_initialized (
    \\    doc_id TEXT PRIMARY KEY
    \\);
    \\CREATE TABLE IF NOT EXISTS chat_sync_jobs (
    \\    doc_id TEXT NOT NULL,
    \\    kind TEXT NOT NULL,
    \\    enqueued_at INTEGER NOT NULL,
    \\    PRIMARY KEY (doc_id, kind)
    \\);
    \\CREATE TABLE IF NOT EXISTS sync_job_clock (
    \\    id INTEGER PRIMARY KEY CHECK (id = 1),
    \\    seq INTEGER NOT NULL
    \\);
;

const save_snap_sql =
    \\INSERT INTO snapshots (doc_id, bytes, saved_at, cursor, epoch, cursor_verified)
    \\VALUES (?1, ?2, ?3, ?4, ?5, 1)
    \\ON CONFLICT(doc_id) DO UPDATE SET
    \\  bytes = excluded.bytes,
    \\  saved_at = excluded.saved_at,
    \\  cursor = excluded.cursor,
    \\  epoch = excluded.epoch,
    \\  cursor_verified = 1
;
const mark_cmd_sql = "INSERT OR IGNORE INTO processed_commands (command_id, processed_at) VALUES (?1, ?2)";
const enq_outbox_sql = "INSERT OR IGNORE INTO chat_outbox (doc_id, batch_id, bytes, needs_checkpoint) VALUES (?1, ?2, ?3, 0)";
const ack_outbox_sql = "DELETE FROM chat_outbox WHERE doc_id = ?1 AND batch_id = ?2";

pub const SnapshotRecord = struct {
    bytes: []u8,
    saved_at: i64,
    cursor: u64 = 0,
    epoch: u32 = 2,
    cursor_verified: bool = true,

    pub fn deinit(self: *SnapshotRecord, gpa: Allocator) void {
        gpa.free(self.bytes);
    }
};

pub const OutboxItem = struct {
    doc_id: []u8,
    batch_id: []u8,
    bytes: []u8,
    needs_checkpoint: bool = false,

    pub fn deinit(self: *OutboxItem, gpa: Allocator) void {
        gpa.free(self.doc_id);
        gpa.free(self.batch_id);
        gpa.free(self.bytes);
    }
};

pub const DocsStore = struct {
    gpa: Allocator,
    db: ?*sqlite3 = null,
    /// Persistent cached SQLite prepared statements (Lean `cached_sqlite_and_indexed_outbox_strictly_faster`).
    stmt_save_snap: ?*sqlite3_stmt = null,
    stmt_mark_cmd: ?*sqlite3_stmt = null,
    stmt_enq_outbox: ?*sqlite3_stmt = null,
    stmt_ack_outbox: ?*sqlite3_stmt = null,
    snapshots: std.StringHashMapUnmanaged(SnapshotRecord) = .empty,
    processed_commands: std.StringHashMapUnmanaged(i64) = .empty,
    outbox: std.ArrayList(OutboxItem) = .empty,
    /// O(1) batch deduplication set (borrows `OutboxItem.batch_id`).
    outbox_batch_set: std.StringHashMapUnmanaged(void) = .empty,
    /// O(1) pending outbox count per `doc_id` (owns `doc_id` keys).
    pending_by_doc: std.StringHashMapUnmanaged(usize) = .empty,
    outbox_initialized: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: Allocator) DocsStore {
        return .{ .gpa = gpa };
    }

    fn prepareCached(db: *sqlite3, sql: []const u8) !*sqlite3_stmt {
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != SQLITE_OK or stmt == null) {
            return error.SqlitePrepareFailed;
        }
        return stmt.?;
    }

    /// Open a SQLite-backed `DocsStore` (`:memory:` or a file path), run all 6
    /// migrations from `crates/sync/src/store.rs`, prepare cached hot statements,
    /// and hydrate in-memory tables.
    pub fn openSqlite(gpa: Allocator, path_z: [*:0]const u8) !DocsStore {
        var raw_db: ?*sqlite3 = null;
        if (sqlite3_open(path_z, &raw_db) != SQLITE_OK or raw_db == null) {
            if (raw_db) |d| _ = sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        const db = raw_db.?;
        errdefer _ = sqlite3_close(db);

        if (sqlite3_exec(db, schema_migrations_sql.ptr, null, null, null) != SQLITE_OK) {
            return error.SqliteMigrateFailed;
        }

        var store = DocsStore{
            .gpa = gpa,
            .db = db,
        };
        errdefer store.deinit();
        store.stmt_save_snap = try prepareCached(db, save_snap_sql);
        store.stmt_mark_cmd = try prepareCached(db, mark_cmd_sql);
        store.stmt_enq_outbox = try prepareCached(db, enq_outbox_sql);
        store.stmt_ack_outbox = try prepareCached(db, ack_outbox_sql);
        try store.reloadFromSqlite();
        return store;
    }

    pub fn deinit(self: *DocsStore) void {
        if (self.stmt_save_snap) |s| {
            _ = sqlite3_finalize(s);
            self.stmt_save_snap = null;
        }
        if (self.stmt_mark_cmd) |s| {
            _ = sqlite3_finalize(s);
            self.stmt_mark_cmd = null;
        }
        if (self.stmt_enq_outbox) |s| {
            _ = sqlite3_finalize(s);
            self.stmt_enq_outbox = null;
        }
        if (self.stmt_ack_outbox) |s| {
            _ = sqlite3_finalize(s);
            self.stmt_ack_outbox = null;
        }
        if (self.db) |db| {
            _ = sqlite3_close(db);
            self.db = null;
        }
        var snap_it = self.snapshots.iterator();
        while (snap_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.snapshots.deinit(self.gpa);

        var cmd_it = self.processed_commands.iterator();
        while (cmd_it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.processed_commands.deinit(self.gpa);

        self.outbox_batch_set.deinit(self.gpa);
        var pend_it = self.pending_by_doc.iterator();
        while (pend_it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.pending_by_doc.deinit(self.gpa);

        for (self.outbox.items) |*item| item.deinit(self.gpa);
        self.outbox.deinit(self.gpa);

        var init_it = self.outbox_initialized.iterator();
        while (init_it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.outbox_initialized.deinit(self.gpa);
    }

    pub fn beginTransaction(self: *DocsStore) !void {
        if (self.db) |db| {
            if (sqlite3_exec(db, "BEGIN IMMEDIATE;", null, null, null) != SQLITE_OK) {
                return error.SqliteStepFailed;
            }
        }
    }

    pub fn commitTransaction(self: *DocsStore) !void {
        if (self.db) |db| {
            if (sqlite3_exec(db, "COMMIT;", null, null, null) != SQLITE_OK) {
                return error.SqliteStepFailed;
            }
        }
    }

    fn incPendingForDoc(self: *DocsStore, doc_id: []const u8) !void {
        const gop = try self.pending_by_doc.getOrPut(self.gpa, doc_id);
        if (!gop.found_existing) {
            errdefer _ = self.pending_by_doc.remove(doc_id);
            gop.key_ptr.* = try self.gpa.dupe(u8, doc_id);
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* += 1;
        }
    }

    fn decPendingForDoc(self: *DocsStore, doc_id: []const u8) void {
        if (self.pending_by_doc.getPtr(doc_id)) |cnt| {
            if (cnt.* <= 1) {
                if (self.pending_by_doc.fetchRemove(doc_id)) |kv| {
                    self.gpa.free(kv.key);
                }
            } else {
                cnt.* -= 1;
            }
        }
    }

    fn reloadFromSqlite(self: *DocsStore) !void {
        const db = self.db orelse return;
        // 1. Load snapshots
        {
            const sql = "SELECT doc_id, bytes, saved_at, cursor, epoch, cursor_verified FROM snapshots";
            var stmt: ?*sqlite3_stmt = null;
            if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) == SQLITE_OK and stmt != null) {
                defer _ = sqlite3_finalize(stmt.?);
                while (sqlite3_step(stmt.?) == SQLITE_ROW) {
                    const id_ptr = sqlite3_column_text(stmt.?, 0) orelse continue;
                    const id_len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 0)));
                    const doc_id = id_ptr[0..id_len];

                    const blob_len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 1)));
                    const blob_ptr = sqlite3_column_blob(stmt.?, 1);
                    const bytes = if (blob_ptr != null and blob_len > 0) blob_ptr.?[0..blob_len] else "";

                    const saved_at = sqlite3_column_int64(stmt.?, 2);
                    const cursor: u64 = @intCast(@max(0, sqlite3_column_int64(stmt.?, 3)));
                    const epoch: u32 = @intCast(@max(0, sqlite3_column_int64(stmt.?, 4)));
                    const verified = sqlite3_column_int64(stmt.?, 5) != 0;

                    const bytes_copy = try self.gpa.dupe(u8, bytes);
                    errdefer self.gpa.free(bytes_copy);
                    const key_copy = try self.gpa.dupe(u8, doc_id);
                    errdefer self.gpa.free(key_copy);
                    try self.snapshots.put(self.gpa, key_copy, .{
                        .bytes = bytes_copy,
                        .saved_at = saved_at,
                        .cursor = cursor,
                        .epoch = epoch,
                        .cursor_verified = verified,
                    });
                }
            }
        }
        // 2. Load processed_commands
        {
            const sql = "SELECT command_id, processed_at FROM processed_commands";
            var stmt: ?*sqlite3_stmt = null;
            if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) == SQLITE_OK and stmt != null) {
                defer _ = sqlite3_finalize(stmt.?);
                while (sqlite3_step(stmt.?) == SQLITE_ROW) {
                    const id_ptr = sqlite3_column_text(stmt.?, 0) orelse continue;
                    const id_len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 0)));
                    const cmd_id = try self.gpa.dupe(u8, id_ptr[0..id_len]);
                    errdefer self.gpa.free(cmd_id);
                    const ts = sqlite3_column_int64(stmt.?, 1);
                    try self.processed_commands.put(self.gpa, cmd_id, ts);
                }
            }
        }
        // 3. Load chat_outbox
        {
            const sql = "SELECT doc_id, batch_id, bytes, needs_checkpoint FROM chat_outbox ORDER BY id ASC";
            var stmt: ?*sqlite3_stmt = null;
            if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) == SQLITE_OK and stmt != null) {
                defer _ = sqlite3_finalize(stmt.?);
                while (sqlite3_step(stmt.?) == SQLITE_ROW) {
                    const doc_ptr = sqlite3_column_text(stmt.?, 0) orelse continue;
                    const doc_len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 0)));
                    const batch_ptr = sqlite3_column_text(stmt.?, 1) orelse continue;
                    const batch_len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 1)));
                    const blob_len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 2)));
                    const blob_ptr = sqlite3_column_blob(stmt.?, 2);
                    const bytes = if (blob_ptr != null and blob_len > 0) blob_ptr.?[0..blob_len] else "";
                    const needs_cp = sqlite3_column_int64(stmt.?, 3) != 0;

                    var item = OutboxItem{
                        .doc_id = try self.gpa.dupe(u8, doc_ptr[0..doc_len]),
                        .batch_id = try self.gpa.dupe(u8, batch_ptr[0..batch_len]),
                        .bytes = try self.gpa.dupe(u8, bytes),
                        .needs_checkpoint = needs_cp,
                    };
                    errdefer item.deinit(self.gpa);
                    try self.outbox.ensureUnusedCapacity(self.gpa, 1);
                    try self.outbox_batch_set.put(self.gpa, item.batch_id, {});
                    errdefer _ = self.outbox_batch_set.remove(item.batch_id);
                    try self.incPendingForDoc(item.doc_id);
                    self.outbox.appendAssumeCapacity(item);
                }
            }
        }
    }

    /// Save snapshot bytes + cursor + epoch atomically (C2 rule) using cached prepared statement.
    pub fn saveSnapshotWithCursor(
        self: *DocsStore,
        doc_id: []const u8,
        bytes: []const u8,
        cursor: u64,
        epoch: u32,
        now_ms: i64,
    ) !void {
        if (self.stmt_save_snap) |stmt| {
            defer {
                _ = sqlite3_reset(stmt);
                _ = sqlite3_clear_bindings(stmt);
            }
            _ = sqlite3_bind_text(stmt, 1, doc_id.ptr, @intCast(doc_id.len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_blob(stmt, 2, if (bytes.len > 0) bytes.ptr else null, @intCast(bytes.len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_int64(stmt, 3, now_ms);
            _ = sqlite3_bind_int64(stmt, 4, @intCast(cursor));
            _ = sqlite3_bind_int64(stmt, 5, @intCast(epoch));
            if (sqlite3_step(stmt) != SQLITE_DONE) return error.SqliteStepFailed;
        }

        const bytes_copy = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(bytes_copy);

        const gop = try self.snapshots.getOrPut(self.gpa, doc_id);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.gpa);
        } else {
            errdefer _ = self.snapshots.remove(doc_id);
            gop.key_ptr.* = try self.gpa.dupe(u8, doc_id);
        }
        gop.value_ptr.* = .{
            .bytes = bytes_copy,
            .saved_at = now_ms,
            .cursor = cursor,
            .epoch = epoch,
            .cursor_verified = true,
        };
    }

    pub fn saveSnapshot(self: *DocsStore, doc_id: []const u8, bytes: []const u8, now_ms: i64) !void {
        const prev_cursor = self.snapshotCursor(doc_id) orelse 0;
        const prev_epoch = self.snapshotEpoch(doc_id) orelse 2;
        try self.saveSnapshotWithCursor(doc_id, bytes, prev_cursor, prev_epoch, now_ms);
    }

    pub fn loadSnapshot(self: *const DocsStore, doc_id: []const u8) ?[]const u8 {
        const rec = self.snapshots.get(doc_id) orelse return null;
        return rec.bytes;
    }

    pub fn snapshotCursor(self: *const DocsStore, doc_id: []const u8) ?u64 {
        const rec = self.snapshots.get(doc_id) orelse return null;
        return if (rec.cursor_verified) rec.cursor else null;
    }

    pub fn snapshotEpoch(self: *const DocsStore, doc_id: []const u8) ?u32 {
        const rec = self.snapshots.get(doc_id) orelse return null;
        return rec.epoch;
    }

    /// Mark `command_id` processed BEFORE execution. Returns `true` if newly marked,
    /// `false` if already processed (idempotent duplicate).
    pub fn markCommandProcessed(self: *DocsStore, command_id: []const u8, now_ms: i64) !bool {
        if (self.processed_commands.contains(command_id)) return false;
        if (self.stmt_mark_cmd) |stmt| {
            defer {
                _ = sqlite3_reset(stmt);
                _ = sqlite3_clear_bindings(stmt);
            }
            _ = sqlite3_bind_text(stmt, 1, command_id.ptr, @intCast(command_id.len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_int64(stmt, 2, now_ms);
            if (sqlite3_step(stmt) != SQLITE_DONE) return error.SqliteStepFailed;
        }
        const key = try self.gpa.dupe(u8, command_id);
        errdefer self.gpa.free(key);
        try self.processed_commands.put(self.gpa, key, now_ms);
        return true;
    }

    pub fn isCommandProcessed(self: *const DocsStore, command_id: []const u8) bool {
        return self.processed_commands.contains(command_id);
    }

    /// Insert before sending. O(1) `outbox_batch_set` makes crash-after-ACK replay idempotent without scanning.
    pub fn enqueueChatUpdate(self: *DocsStore, doc_id: []const u8, batch_id: []const u8, bytes: []const u8) !void {
        if (self.outbox_batch_set.contains(batch_id)) return;
        if (self.stmt_enq_outbox) |stmt| {
            defer {
                _ = sqlite3_reset(stmt);
                _ = sqlite3_clear_bindings(stmt);
            }
            _ = sqlite3_bind_text(stmt, 1, doc_id.ptr, @intCast(doc_id.len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_text(stmt, 2, batch_id.ptr, @intCast(batch_id.len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_blob(stmt, 3, if (bytes.len > 0) bytes.ptr else null, @intCast(bytes.len), SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) return error.SqliteStepFailed;
        }
        var item = OutboxItem{
            .doc_id = try self.gpa.dupe(u8, doc_id),
            .batch_id = try self.gpa.dupe(u8, batch_id),
            .bytes = try self.gpa.dupe(u8, bytes),
        };
        errdefer item.deinit(self.gpa);
        try self.outbox.ensureUnusedCapacity(self.gpa, 1);
        try self.outbox_batch_set.put(self.gpa, item.batch_id, {});
        errdefer _ = self.outbox_batch_set.remove(item.batch_id);
        try self.incPendingForDoc(doc_id);
        self.outbox.appendAssumeCapacity(item);
    }

    /// O(1) pending outbox count for `doc_id` (Lean `indexedOutboxOps`).
    pub fn pendingOutboxCount(self: *const DocsStore, doc_id: []const u8) usize {
        return self.pending_by_doc.get(doc_id) orelse 0;
    }

    pub fn hasPendingChatUpdates(self: *const DocsStore, doc_id: []const u8) bool {
        return self.pendingOutboxCount(doc_id) > 0;
    }

    pub fn acknowledgeChatUpdate(self: *DocsStore, doc_id: []const u8, batch_id: []const u8) void {
        if (self.stmt_ack_outbox) |stmt| {
            defer {
                _ = sqlite3_reset(stmt);
                _ = sqlite3_clear_bindings(stmt);
            }
            _ = sqlite3_bind_text(stmt, 1, doc_id.ptr, @intCast(doc_id.len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_text(stmt, 2, batch_id.ptr, @intCast(batch_id.len), SQLITE_TRANSIENT);
            _ = sqlite3_step(stmt);
        }
        var i: usize = 0;
        while (i < self.outbox.items.len) {
            const item = &self.outbox.items[i];
            if (std.mem.eql(u8, item.doc_id, doc_id) and std.mem.eql(u8, item.batch_id, batch_id)) {
                _ = self.outbox_batch_set.remove(item.batch_id);
                self.decPendingForDoc(doc_id);
                item.deinit(self.gpa);
                _ = self.outbox.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn rejectChatUpdate(self: *DocsStore, doc_id: []const u8, batch_id: []const u8) void {
        if (self.db) |db| {
            const sql = "UPDATE chat_outbox SET needs_checkpoint = 1 WHERE doc_id = ?1 AND batch_id = ?2";
            var stmt: ?*sqlite3_stmt = null;
            if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) == SQLITE_OK and stmt != null) {
                defer _ = sqlite3_finalize(stmt.?);
                _ = sqlite3_bind_text(stmt.?, 1, doc_id.ptr, @intCast(doc_id.len), SQLITE_TRANSIENT);
                _ = sqlite3_bind_text(stmt.?, 2, batch_id.ptr, @intCast(batch_id.len), SQLITE_TRANSIENT);
                _ = sqlite3_step(stmt.?);
            }
        }
        for (self.outbox.items) |*item| {
            if (std.mem.eql(u8, item.doc_id, doc_id) and std.mem.eql(u8, item.batch_id, batch_id)) {
                item.needs_checkpoint = true;
            }
        }
    }

    /// Delete all persisted snapshots and outbox items for `doc_id` (`deleteChat`),
    /// preventing memory leaks and ghost chat resurrection on engine restart.
    pub fn deleteDoc(self: *DocsStore, doc_id: []const u8) void {
        if (self.db) |db| {
            const sql1 = "DELETE FROM snapshots WHERE doc_id = ?1";
            var stmt1: ?*sqlite3_stmt = null;
            if (sqlite3_prepare_v2(db, sql1.ptr, @intCast(sql1.len), &stmt1, null) == SQLITE_OK and stmt1 != null) {
                defer _ = sqlite3_finalize(stmt1.?);
                _ = sqlite3_bind_text(stmt1.?, 1, doc_id.ptr, @intCast(doc_id.len), SQLITE_TRANSIENT);
                _ = sqlite3_step(stmt1.?);
            }
            const sql2 = "DELETE FROM chat_outbox WHERE doc_id = ?1";
            var stmt2: ?*sqlite3_stmt = null;
            if (sqlite3_prepare_v2(db, sql2.ptr, @intCast(sql2.len), &stmt2, null) == SQLITE_OK and stmt2 != null) {
                defer _ = sqlite3_finalize(stmt2.?);
                _ = sqlite3_bind_text(stmt2.?, 1, doc_id.ptr, @intCast(doc_id.len), SQLITE_TRANSIENT);
                _ = sqlite3_step(stmt2.?);
            }
        }
        if (self.snapshots.fetchRemove(doc_id)) |kv| {
            self.gpa.free(kv.key);
            var rec = kv.value;
            rec.deinit(self.gpa);
        }
        if (self.outbox_initialized.fetchRemove(doc_id)) |kv| {
            self.gpa.free(kv.key);
        }
        if (self.pending_by_doc.fetchRemove(doc_id)) |kv| {
            self.gpa.free(kv.key);
        }
        var i: usize = 0;
        while (i < self.outbox.items.len) {
            if (std.mem.eql(u8, self.outbox.items[i].doc_id, doc_id)) {
                _ = self.outbox_batch_set.remove(self.outbox.items[i].batch_id);
                self.outbox.items[i].deinit(self.gpa);
                _ = self.outbox.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

test "DocsStore atomic snapshot+cursor C2 rule, command idempotence, and outbox (in-memory and SQLite)" {
    var store = try DocsStore.openSqlite(testing.allocator, ":memory:");
    defer store.deinit();

    try store.saveSnapshotWithCursor("chat-1", "HZD1{}", 42, 2, 1000);
    try testing.expectEqualStrings("HZD1{}", store.loadSnapshot("chat-1").?);
    try testing.expectEqual(@as(?u64, 42), store.snapshotCursor("chat-1"));
    try testing.expectEqual(@as(?u32, 2), store.snapshotEpoch("chat-1"));

    try testing.expect(try store.markCommandProcessed("cmd-1", 1001));
    try testing.expect(!try store.markCommandProcessed("cmd-1", 1002));
    try testing.expect(store.isCommandProcessed("cmd-1"));

    try store.enqueueChatUpdate("chat-1", "batch-1", &.{ 1, 2, 3 });
    try store.enqueueChatUpdate("chat-1", "batch-1", &.{ 1, 2, 3 }); // idempotent
    try testing.expectEqual(@as(usize, 1), store.pendingOutboxCount("chat-1"));
    try testing.expect(store.hasPendingChatUpdates("chat-1"));
    store.acknowledgeChatUpdate("chat-1", "batch-1");
    try testing.expectEqual(@as(usize, 0), store.pendingOutboxCount("chat-1"));
    try testing.expect(!store.hasPendingChatUpdates("chat-1"));
}

test "Performance shape: DocsStore cached SQLite statements + O(1) outbox index >= 5x faster than uncached prepare + O(C*B) scan" {
    const gpa = testing.allocator;
    var store = try DocsStore.openSqlite(gpa, ":memory:");
    defer store.deinit();

    const num_chats: usize = 400;
    const num_batches: usize = 1_600;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const chat_ids = try a.alloc([]const u8, num_chats);
    for (0..num_chats) |c| {
        chat_ids[c] = try std.fmt.allocPrint(a, "chat-{d}", .{c});
    }
    const batch_ids = try a.alloc([]const u8, num_batches);
    for (0..num_batches) |b| {
        batch_ids[b] = try std.fmt.allocPrint(a, "batch-{d}", .{b});
    }

    try store.beginTransaction();
    for (0..num_batches) |b| {
        try store.enqueueChatUpdate(chat_ids[b % num_chats], batch_ids[b], "HZD1-bench-payload");
    }
    try store.commitTransaction();

    // Fast path: cached SQLite prepared statement reuse + O(1) duplicate check + O(1) pendingOutboxCount
    const t_fast0 = std.Io.Clock.Timestamp.now(testing.io, .awake);
    var fast_sum: usize = 0;
    if (store.stmt_save_snap) |st| {
        try store.beginTransaction();
        for (0..num_chats) |c| {
            _ = sqlite3_reset(st);
            _ = sqlite3_clear_bindings(st);
            _ = sqlite3_bind_text(st, 1, chat_ids[c].ptr, @intCast(chat_ids[c].len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_blob(st, 2, "HZD1-snap".ptr, 9, SQLITE_TRANSIENT);
            _ = sqlite3_bind_int64(st, 3, 1_000);
            _ = sqlite3_step(st);
        }
        try store.commitTransaction();
    }
    for (0..num_batches) |b| {
        if (store.outbox_batch_set.contains(batch_ids[b])) fast_sum += 1;
    }
    for (0..25) |_| {
        for (chat_ids) |cid| {
            fast_sum += store.pendingOutboxCount(cid);
        }
    }
    const fast_ns: u64 = @intCast(@max(1, t_fast0.untilNow(testing.io).raw.nanoseconds));

    // Slow baseline (previous DocsStore shape): uncached sqlite3_prepare_v2 per write + O(B) duplicate scan + O(C*B) outbox scan
    var slow_db: ?*sqlite3 = null;
    _ = sqlite3_open(":memory:", &slow_db);
    defer if (slow_db) |d| {
        _ = sqlite3_close(d);
    };
    _ = sqlite3_exec(slow_db.?, schema_migrations_sql.ptr, null, null, null);

    const t_slow0 = std.Io.Clock.Timestamp.now(testing.io, .awake);
    var slow_sum: usize = 0;
    for (0..num_chats) |c| {
        var st: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(slow_db.?, save_snap_sql.ptr, @intCast(save_snap_sql.len), &st, null) == SQLITE_OK and st != null) {
            _ = sqlite3_bind_text(st.?, 1, chat_ids[c].ptr, @intCast(chat_ids[c].len), SQLITE_TRANSIENT);
            _ = sqlite3_bind_blob(st.?, 2, "HZD1-snap".ptr, 9, SQLITE_TRANSIENT);
            _ = sqlite3_bind_int64(st.?, 3, 1_000);
            _ = sqlite3_step(st.?);
            _ = sqlite3_finalize(st.?);
        }
    }
    for (0..num_batches) |b| {
        for (store.outbox.items) |ob| {
            if (std.mem.eql(u8, ob.batch_id, batch_ids[b])) {
                slow_sum += 1;
                break;
            }
        }
    }
    for (0..25) |_| {
        for (chat_ids) |cid| {
            for (store.outbox.items) |ob| {
                if (std.mem.eql(u8, ob.doc_id, cid)) slow_sum += 1;
            }
        }
    }
    const slow_ns: u64 = @intCast(@max(1, t_slow0.untilNow(testing.io).raw.nanoseconds));

    try testing.expectEqual(slow_sum, fast_sum);
    // AGENTS.md shape test: cached + indexed path must be at least 5x faster than uncached + O(C*B) scan!
    try testing.expect(fast_ns * 5 <= slow_ns);
}
