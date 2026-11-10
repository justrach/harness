//! Per-field LWW Workspace Registry CRDT (`crates/doc/src/registry.rs`, `crates/sync/src/registry.rs`).
//!
//! Synchronizes workspace metadata (`devices`, `spaces`, `chats`, `sessions`,
//! `repos`, `sandboxes`, `change_requests`) over `reg1` frames using per-field
//! Last-Writer-Wins timestamps `(ts, device_id)` and row tombstones.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const reg1_magic = "reg1";

pub const Table = enum {
    devices,
    spaces,
    chats,
    sessions,
    repos,
    sandboxes,
    change_requests,
};

pub const Stamp = struct {
    ts: i64,
    device_id: []const u8,

    pub fn newerThan(self: Stamp, other: Stamp) bool {
        if (self.ts != other.ts) return self.ts > other.ts;
        return std.mem.order(u8, self.device_id, other.device_id) == .gt;
    }
};

pub const FieldCell = struct {
    value_json: []u8,
    ts: i64,
    device_id: []u8,

    pub fn deinit(self: *FieldCell, gpa: Allocator) void {
        gpa.free(self.value_json);
        gpa.free(self.device_id);
    }
};

pub const RowState = struct {
    table: Table,
    row_id: []u8,
    tombstone_ts: ?i64 = null,
    tombstone_device: ?[]u8 = null,
    fields: std.StringHashMapUnmanaged(FieldCell) = .empty,

    pub fn deinit(self: *RowState, gpa: Allocator) void {
        gpa.free(self.row_id);
        if (self.tombstone_device) |d| gpa.free(d);
        var it = self.fields.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        self.fields.deinit(gpa);
    }
};

/// Validate a chat ID (`chat_id_validation_error` in `crates/doc/src/registry.rs`).
/// Rejects empty IDs, IDs > 128 bytes, `:` separators, and control characters.
pub fn validateRowId(table: Table, row_id: []const u8) bool {
    if (row_id.len == 0 or row_id.len > 128) return false;
    for (row_id) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
        if (table == .chats and ch == ':') return false;
    }
    return true;
}

pub const RegistryDoc = struct {
    gpa: Allocator,
    device_id: []u8,
    rows: std.StringHashMapUnmanaged(RowState) = .empty,

    pub fn init(gpa: Allocator, device_id: []const u8) !RegistryDoc {
        return .{
            .gpa = gpa,
            .device_id = try gpa.dupe(u8, device_id),
        };
    }

    pub fn deinit(self: *RegistryDoc) void {
        self.gpa.free(self.device_id);
        var it = self.rows.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.rows.deinit(self.gpa);
    }

    fn compositeKey(self: *const RegistryDoc, table: Table, row_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ @tagName(table), row_id });
    }

    /// Apply a per-field LWW update. Returns `true` if the field won LWW tie-breaking.
    pub fn setField(
        self: *RegistryDoc,
        table: Table,
        row_id: []const u8,
        field: []const u8,
        value_json: []const u8,
        ts: i64,
        writer_device: []const u8,
    ) !bool {
        if (!validateRowId(table, row_id)) return error.InvalidRowId;
        const key = try self.compositeKey(table, row_id);
        defer self.gpa.free(key);

        const gop = try self.rows.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, key);
            gop.value_ptr.* = .{
                .table = table,
                .row_id = try self.gpa.dupe(u8, row_id),
            };
        }
        const row = gop.value_ptr;
        const incoming = Stamp{ .ts = ts, .device_id = writer_device };

        if (row.tombstone_ts) |t_ts| {
            const tomb = Stamp{ .ts = t_ts, .device_id = row.tombstone_device orelse "" };
            if (tomb.newerThan(incoming)) return false;
        }

        const fgop = try row.fields.getOrPut(self.gpa, field);
        if (fgop.found_existing) {
            const existing = Stamp{ .ts = fgop.value_ptr.ts, .device_id = fgop.value_ptr.device_id };
            if (!incoming.newerThan(existing)) return false;
            fgop.value_ptr.deinit(self.gpa);
        } else {
            fgop.key_ptr.* = try self.gpa.dupe(u8, field);
        }

        fgop.value_ptr.* = .{
            .value_json = try self.gpa.dupe(u8, value_json),
            .ts = ts,
            .device_id = try self.gpa.dupe(u8, writer_device),
        };
        return true;
    }

    pub fn getField(self: *const RegistryDoc, table: Table, row_id: []const u8, field: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ @tagName(table), row_id }) catch return null;
        const row = self.rows.get(key) orelse return null;
        if (row.tombstone_ts != null) return null;
        const cell = row.fields.get(field) orelse return null;
        return cell.value_json;
    }

    pub fn deleteRow(self: *RegistryDoc, table: Table, row_id: []const u8, ts: i64, writer_device: []const u8) !bool {
        if (!validateRowId(table, row_id)) return error.InvalidRowId;
        const key = try self.compositeKey(table, row_id);
        defer self.gpa.free(key);

        const gop = try self.rows.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, key);
            gop.value_ptr.* = .{
                .table = table,
                .row_id = try self.gpa.dupe(u8, row_id),
            };
        }
        const row = gop.value_ptr;
        const incoming = Stamp{ .ts = ts, .device_id = writer_device };
        if (row.tombstone_ts) |t_ts| {
            const existing = Stamp{ .ts = t_ts, .device_id = row.tombstone_device orelse "" };
            if (!incoming.newerThan(existing)) return false;
        }
        if (row.tombstone_device) |old| self.gpa.free(old);
        row.tombstone_ts = ts;
        row.tombstone_device = try self.gpa.dupe(u8, writer_device);
        return true;
    }
};

test "RegistryDoc per-field LWW tie-breaking, tombstones, and chat_id validation" {
    const gpa = testing.allocator;
    var reg = try RegistryDoc.init(gpa, "dev-a");
    defer reg.deinit();

    // Reject colon in chat IDs
    try testing.expectError(error.InvalidRowId, reg.setField(.chats, "bad:id", "title", "\"Hi\"", 10, "dev-a"));

    // Independent fields on the same chat row merge without clobbering
    try testing.expect(try reg.setField(.chats, "chat-1", "title", "\"First\"", 100, "dev-a"));
    try testing.expect(try reg.setField(.chats, "chat-1", "pinned", "true", 100, "dev-b"));

    // Older timestamp loses
    try testing.expect(!try reg.setField(.chats, "chat-1", "title", "\"Stale\"", 99, "dev-b"));
    // Equal timestamp tie-breaks by device_id ("dev-b" > "dev-a")
    try testing.expect(try reg.setField(.chats, "chat-1", "title", "\"TieWinner\"", 100, "dev-b"));
    try testing.expectEqualStrings("\"TieWinner\"", reg.getField(.chats, "chat-1", "title").?);
    try testing.expectEqualStrings("true", reg.getField(.chats, "chat-1", "pinned").?);

    // Tombstone hides row and blocks older field writes
    try testing.expect(try reg.deleteRow(.chats, "chat-1", 200, "dev-a"));
    try testing.expect(reg.getField(.chats, "chat-1", "title") == null);
    try testing.expect(!try reg.setField(.chats, "chat-1", "title", "\"TooLate\"", 150, "dev-b"));
}
