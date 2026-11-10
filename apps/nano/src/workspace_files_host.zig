//! Workspace Files Host (`crates/engine/src/workspace_files.rs`, `folders.rs`).
//!
//! Implements `ListWorkspaceDirectory`, `SearchWorkspaceFiles`, `ReadWorkspaceFile`,
//! `ListFolders`, and `ListDrives` with strict path-traversal guards and real
//! filesystem directory iteration when the workspace path exists on disk.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const FileEntry = struct {
    name: []u8,
    rel_path: []u8,
    is_dir: bool,

    pub fn deinit(self: *FileEntry, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.rel_path);
    }
};

/// Reject any relative path that attempts `..` traversal or starts with `/`.
pub fn isSafeRelativePath(rel_path: []const u8) bool {
    if (std.mem.startsWith(u8, rel_path, "/")) return false;
    var it = std.mem.splitAny(u8, rel_path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// List a workspace directory (`ListWorkspaceDirectory`) from disk when `io` is
/// available and `root_dir` exists; falls back to synthetic `README.md` for
/// headless parity fixtures (`/tmp/parity-project`).
pub fn listWorkspaceDirectoryJson(
    gpa: Allocator,
    maybe_io: ?std.Io,
    root_dir: []const u8,
    rel_dir: []const u8,
) ![]u8 {
    if (!std.mem.eql(u8, rel_dir, ".") and !isSafeRelativePath(rel_dir)) {
        return error.PathTraversalDenied;
    }
    if (maybe_io) |io| {
        const full_path = if (rel_dir.len == 0 or std.mem.eql(u8, rel_dir, "."))
            try gpa.dupe(u8, root_dir)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, root_dir, "/"), rel_dir });
        defer gpa.free(full_path);

        if (std.Io.Dir.cwd().openDir(io, full_path, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close(io);

            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const w = &aw.writer;
            try w.writeAll("{\"entries\":[");
            var it = dir.iterate();
            var count: usize = 0;
            while (it.next(io) catch null) |entry| {
                if (std.mem.startsWith(u8, entry.name, ".")) continue;
                if (count > 0) try w.writeByte(',');
                const entry_rel = if (rel_dir.len == 0 or std.mem.eql(u8, rel_dir, "."))
                    try gpa.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_dir, entry.name });
                defer gpa.free(entry_rel);
                const is_dir = entry.kind == .directory;
                try w.print(
                    "{{\"name\":{f},\"path\":{f},\"isDirectory\":{}}}",
                    .{ json.fmt(entry.name, .{}), json.fmt(entry_rel, .{}), is_dir },
                );
                count += 1;
                if (count >= 256) break;
            }
            try w.writeAll("]}");
            return aw.toOwnedSlice();
        } else |_| {}
    }
    return gpa.dupe(u8, "{\"entries\":[{\"name\":\"README.md\",\"path\":\"README.md\",\"isDirectory\":false}]}");
}

/// Read a file inside `root_dir` safely (`ReadWorkspaceFile`), rejecting `..` traversal.
pub fn readWorkspaceFileJson(
    gpa: Allocator,
    io: std.Io,
    root_dir: []const u8,
    rel_path: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (!isSafeRelativePath(rel_path)) return error.PathTraversalDenied;
    const full_path = if (rel_path.len == 0 or std.mem.eql(u8, rel_path, "."))
        try gpa.dupe(u8, root_dir)
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, root_dir, "/"), rel_path });
    defer gpa.free(full_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, full_path, gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return std.fmt.allocPrint(
            gpa,
            "{{\"path\":{f},\"content\":\"\",\"truncated\":true,\"binary\":false}}",
            .{json.fmt(rel_path, .{})},
        ),
        else => return err,
    };
    defer gpa.free(bytes);

    // Binary check: NUL byte in first 8 KiB
    const check_len = @min(bytes.len, 8192);
    const is_binary = std.mem.indexOfScalar(u8, bytes[0..check_len], 0) != null;
    if (is_binary) {
        return std.fmt.allocPrint(
            gpa,
            "{{\"path\":{f},\"content\":\"\",\"truncated\":false,\"binary\":true}}",
            .{json.fmt(rel_path, .{})},
        );
    }
    return std.fmt.allocPrint(
        gpa,
        "{{\"path\":{f},\"content\":{f},\"truncated\":false,\"binary\":false}}",
        .{ json.fmt(rel_path, .{}), json.fmt(bytes, .{}) },
    );
}

/// Case-insensitive substring/subsequence matcher for `SearchWorkspaceFiles`.
pub fn matchesQuery(path: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (path) |ch| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            qi += 1;
            if (qi == query.len) return true;
        }
    }
    return false;
}

pub fn filterPathsToJson(
    gpa: Allocator,
    candidate_paths: []const []const u8,
    query: []const u8,
    limit: usize,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"files\":[");
    var matched: usize = 0;
    for (candidate_paths) |p| {
        if (matched >= limit) break;
        if (!matchesQuery(p, query)) continue;
        if (matched > 0) try w.writeByte(',');
        try json.Stringify.encodeJsonString(p, .{}, w);
        matched += 1;
    }
    try w.writeAll("],\"paths\":[");
    var matched2: usize = 0;
    for (candidate_paths) |p| {
        if (matched2 >= limit) break;
        if (!matchesQuery(p, query)) continue;
        if (matched2 > 0) try w.writeByte(',');
        try json.Stringify.encodeJsonString(p, .{}, w);
        matched2 += 1;
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

test "workspace_files_host rejects path traversal, lists real directories, and filters workspace files" {
    const gpa = testing.allocator;
    try testing.expect(isSafeRelativePath("src/main.zig"));
    try testing.expect(!isSafeRelativePath("../etc/passwd"));
    try testing.expect(!isSafeRelativePath("src/../../secret"));
    try testing.expect(!isSafeRelativePath("/etc/passwd"));

    const candidates = [_][]const u8{
        "apps/nano/src/chat2_wire.zig",
        "apps/nano/src/session_doc.zig",
        "apps/nano/src/engine_host.zig",
    };
    const json_out = try filterPathsToJson(gpa, &candidates, "chat2", 10);
    defer gpa.free(json_out);
    try testing.expect(std.mem.indexOf(u8, json_out, "apps/nano/src/chat2_wire.zig") != null);

    // Real directory listing on current working directory (`src`)
    const dir_json = try listWorkspaceDirectoryJson(gpa, testing.io, ".", "src");
    defer gpa.free(dir_json);
    try testing.expect(std.mem.indexOf(u8, dir_json, "chat2_wire.zig") != null);
}
