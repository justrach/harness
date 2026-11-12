//! Zig bindings to `apps/nano/loro-bridge` (`loro` 1.13 C-ABI staticlib) for
//! byte-exact `chat2` CRDT snapshot/row/frontier interoperability with Rust
//! Desktop & iOS `Harness.app`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LoroSession = opaque {};

extern "c" fn loro_session_new() ?*LoroSession;
extern "c" fn loro_session_free(session: ?*LoroSession) void;
extern "c" fn loro_bytes_free(ptr: ?[*]u8, len: usize) void;
extern "c" fn loro_session_import(session: *LoroSession, bytes_ptr: ?[*]const u8, bytes_len: usize) c_int;
extern "c" fn loro_session_contains_frontier(session: *const LoroSession, frontier_ptr: ?[*]const u8, frontier_len: usize) c_int;
extern "c" fn loro_session_export_snapshot(session: *const LoroSession, out_ptr: *?[*]u8, out_len: *usize) c_int;
extern "c" fn loro_session_export_frontier(session: *const LoroSession, out_ptr: *?[*]u8, out_len: *usize) c_int;
extern "c" fn loro_session_read_messages_json(session: *const LoroSession, out_ptr: *?[*]u8, out_len: *usize) c_int;
extern "c" fn loro_session_sync_messages_json(
    session: *LoroSession,
    chat_id_ptr: ?[*]const u8,
    chat_id_len: usize,
    entries_json_ptr: ?[*]const u8,
    entries_json_len: usize,
    out_update_ptr: *?[*]u8,
    out_update_len: *usize,
) c_int;

pub const ImportOutcome = enum {
    applied,
    pending_dependencies,
};

pub fn createSession() !*LoroSession {
    return loro_session_new() orelse error.OutOfMemory;
}

pub fn destroySession(session: *LoroSession) void {
    loro_session_free(session);
}

fn takeRustBytes(gpa: Allocator, raw_ptr: ?[*]u8, raw_len: usize) ![]u8 {
    defer if (raw_ptr != null and raw_len > 0) loro_bytes_free(raw_ptr, raw_len);
    if (raw_ptr == null or raw_len == 0) return gpa.alloc(u8, 0);
    return gpa.dupe(u8, raw_ptr.?[0..raw_len]);
}

pub fn importBytes(session: *LoroSession, bytes: []const u8) !ImportOutcome {
    if (bytes.len == 0) return .applied;
    const rc = loro_session_import(session, bytes.ptr, bytes.len);
    if (rc == 0) return .applied;
    if (rc == 1) return .pending_dependencies;
    return error.InvalidLoroBlob;
}

pub fn containsFrontier(session: *const LoroSession, frontier: []const u8) bool {
    if (frontier.len == 0) return false;
    return loro_session_contains_frontier(session, frontier.ptr, frontier.len) == 1;
}

pub fn exportSnapshot(session: *const LoroSession, gpa: Allocator) ![]u8 {
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    if (loro_session_export_snapshot(session, &ptr, &len) != 0) return error.LoroExportFailed;
    return takeRustBytes(gpa, ptr, len);
}

pub fn exportFrontier(session: *const LoroSession, gpa: Allocator) ![]u8 {
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    if (loro_session_export_frontier(session, &ptr, &len) != 0) return error.LoroExportFailed;
    return takeRustBytes(gpa, ptr, len);
}

pub fn readMessagesJson(session: *const LoroSession, gpa: Allocator) ![]u8 {
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    if (loro_session_read_messages_json(session, &ptr, &len) != 0) return error.LoroReadFailed;
    return takeRustBytes(gpa, ptr, len);
}

pub fn syncMessagesJson(
    session: *LoroSession,
    chat_id: []const u8,
    entries_json: []const u8,
    gpa: Allocator,
) ![]u8 {
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    const rc = loro_session_sync_messages_json(
        session,
        if (chat_id.len > 0) chat_id.ptr else null,
        chat_id.len,
        if (entries_json.len > 0) entries_json.ptr else null,
        entries_json.len,
        &ptr,
        &len,
    );
    if (rc != 0) return error.LoroSyncFailed;
    return takeRustBytes(gpa, ptr, len);
}
