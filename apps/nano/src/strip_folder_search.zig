//! release/v0.2.172 MenuSearch: ranked folder results, persistent actions,
//! seven visible 32px rows, and a safe keyboard selection for no matches.
const std = @import("std");
const workspace = @import("workspace.zig");
const rules = @import("rules.zig");

pub const list_height: f32 = 224;
pub const menu_width: f32 = 234;

pub fn indices(gpa: std.mem.Allocator, spaces: []const workspace.Space, device: ?[]const u8, query: []const u8) ![]usize {
    var result: std.ArrayList(usize) = .empty;
    defer result.deinit(gpa);
    // matchRank is Nano's existing port of popover::match_rank. Iterate the
    // five ranks in order to retain input order among equally ranked names.
    for (0..5) |rank| for (spaces, 0..) |space, ix| {
        if (device) |id| {
            const host = space.device_id orelse continue;
            if (!std.mem.eql(u8, id, host)) continue;
        }
        if (rules.matchRank(query, space.name)) |score| {
            if (score == rank) try result.append(gpa, ix);
        }
    };
    return result.toOwnedSlice(gpa);
}

pub fn afterEdit(matched: usize) usize {
    // New project is the last action. Never silently select projectless
    // when the user's search didn't find the folder they meant.
    return if (matched == 0) 1 else 0;
}

pub fn height(matched: usize) f32 {
    return @min(@as(f32, @floatFromInt(matched)) * 32, list_height) + 2 * 32 + 60;
}

test "release folder search ranks names on the panel's computer and retains stable order" {
    const spaces = [_]workspace.Space{
        .{ .id = "a", .device_id = "local", .path = "/synthetic/alpha", .name = "alpha" },
        .{ .id = "b", .device_id = "remote", .path = "/synthetic/beta", .name = "beta-remote" },
        .{ .id = "c", .device_id = "local", .path = "/synthetic/work-beta", .name = "work-beta" },
        .{ .id = "d", .device_id = "local", .path = "/synthetic/beta", .name = "beta" },
    };
    const found = try indices(std.testing.allocator, &spaces, "local", "BET");
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualSlices(usize, &.{ 3, 2 }, found);
    const all = try indices(std.testing.allocator, &spaces, "local", "");
    defer std.testing.allocator.free(all);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, all);
    const none = try indices(std.testing.allocator, &spaces, "local", "not a folder");
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expectEqual(@as(usize, 1), afterEdit(none.len));
    try std.testing.expectEqual(@as(usize, 0), afterEdit(found.len));
    try std.testing.expectEqual(@as(f32, 348), height(30));
}
