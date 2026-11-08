//! Host-path and starting-folder rules from v0.2.173 settings/project_folders.rs.
const std = @import("std");
const workspace = @import("workspace.zig");
const Allocator = std.mem.Allocator;

pub fn parent(path: []const u8) ?[]const u8 {
    const p = std.mem.trimEnd(u8, path, "/\\");
    if (p.len == 0 or (p.len == 2 and p[1] == ':')) return null;
    const at = std.mem.lastIndexOfAny(u8, p, "/\\") orelse return null;
    return p[0..if (at == 0) 1 else if (at == 2 and p[1] == ':') 3 else at];
}

pub fn valid(path: []const u8) bool {
    const p = std.mem.trim(u8, path, " \t\r\n");
    if (p.len == 0 or std.mem.indexOfAny(u8, p, "\r\n\x00") != null) return false;
    return p[0] == '/' or std.mem.eql(u8, p, "~") or std.mem.startsWith(u8, p, "~/") or
        std.mem.startsWith(u8, p, "~\\") or std.mem.startsWith(u8, p, "\\\\") or
        (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '/' or p[2] == '\\'));
}

pub fn resolve(gpa: Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) return gpa.dupe(u8, home);
    if (std.mem.startsWith(u8, path, "~/") or std.mem.startsWith(u8, path, "~\\")) return child(gpa, home, path[2..]);
    return gpa.dupe(u8, path);
}

pub fn child(gpa: Allocator, path: []const u8, name: []const u8) ![]const u8 {
    // Never std.fs.path: the selected computer may use a different OS.
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, path, "/\\"), name });
}

/// Upgrade seed and success history combine by max, not sum. Ties are lexical.
pub fn starting(gpa: Allocator, preferences: ?std.json.Value, device: []const u8, spaces: []const workspace.Space) !?[]const u8 {
    var pref: ?std.json.Value = null;
    if (preferences) |v| if (v == .object) {
        pref = v.object.get(device);
    };
    if (pref) |p| if (p == .object) if (p.object.get("overridePath")) |v| if (v == .string and valid(v.string)) return try gpa.dupe(u8, std.mem.trim(u8, v.string, " \t\r\n"));
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var counts: std.StringHashMapUnmanaged(u64) = .empty;
    for (spaces) |s| {
        if (!std.mem.eql(u8, s.device_id orelse continue, device)) continue;
        const p = parent(s.path) orelse continue;
        const normalized = try a.dupe(u8, p);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        const entry = try counts.getOrPut(a, normalized);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* +|= 1;
    }
    if (pref) |p| if (p == .object) if (p.object.get("parentCounts")) |v| if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .integer or e.value_ptr.integer <= 0 or !valid(e.key_ptr.*)) continue;
            const entry = try counts.getOrPut(a, e.key_ptr.*);
            const n: u64 = @intCast(e.value_ptr.integer);
            entry.value_ptr.* = if (entry.found_existing) @max(entry.value_ptr.*, n) else n;
        }
    };
    var best: ?[]const u8 = null;
    var score: u64 = 0;
    var it = counts.iterator();
    while (it.next()) |e| if (best == null or e.value_ptr.* > score or (e.value_ptr.* == score and std.mem.order(u8, e.key_ptr.*, best.?) == .lt)) {
        best = e.key_ptr.*;
        score = e.value_ptr.*;
    };
    return if (best) |p| try gpa.dupe(u8, p) else null;
}

test "project starting folder uses the host's path syntax and history, not the viewer's home" {
    const testing = std.testing;
    const spaces = [_]workspace.Space{
        .{ .id = "one", .device_id = "remote", .path = "/projects/one", .name = "one" },
        .{ .id = "two", .device_id = "remote", .path = "/projects/two", .name = "two" },
        .{ .id = "three", .device_id = "local", .path = "/viewer/three", .name = "three" },
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"remote":{"parentCounts":{"/projects":1,"/archive":2}},"local":{"overridePath":"/viewer"}}
    , .{});
    defer parsed.deinit();
    const start = (try starting(testing.allocator, parsed.value, "remote", &spaces)).?;
    defer testing.allocator.free(start);
    // max(history, current), not sum: tie picks /archive lexically.
    try testing.expectEqualStrings("/archive", start);
    const local = (try starting(testing.allocator, parsed.value, "local", &spaces)).?;
    defer testing.allocator.free(local);
    try testing.expectEqualStrings("/viewer", local);
    try testing.expectEqualStrings("C:\\projects", parent("C:\\projects\\notes").?);
    try testing.expectEqualStrings("C:/", parent("C:/projects").?);
    try testing.expect(parent("/") == null);
    try testing.expect(valid("C:\\projects"));
    try testing.expect(!valid("relative/path"));
    const resolved = try resolve(testing.allocator, "~/projects", "/remote/home");
    defer testing.allocator.free(resolved);
    try testing.expectEqualStrings("/remote/home/projects", resolved);
}
