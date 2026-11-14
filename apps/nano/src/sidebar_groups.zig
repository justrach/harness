//! Frame-local grouping: one pass over chats, never one scan per group.
//! UI and keyboard navigation share membership and presentation ordering.
const std = @import("std");
const workspace = @import("workspace.zig");

pub const Group = struct {
    key: []const u8,
    count: usize = 0,
    height: f32 = 0,
    first: usize,
    last: usize,
};

pub const Index = struct {
    groups: std.ArrayList(Group) = .empty,
    next: []?usize,

    /// All allocations belong to the caller's frame arena. Input order within
    /// each group is preserved, independently of later group reordering.
    pub fn build(alloc: std.mem.Allocator, chats: []const workspace.Chat, items: anytype) !Index {
        var out: Index = .{ .next = try alloc.alloc(?usize, chats.len) };
        @memset(out.next, null);
        var lookup: std.StringHashMapUnmanaged(usize) = .empty;
        for (chats, items, 0..) |ch, item, i| {
            if (!item.listed or ch.archived or item.pinned) continue;
            const entry = try lookup.getOrPut(alloc, item.group_key);
            if (!entry.found_existing) {
                entry.value_ptr.* = out.groups.items.len;
                try out.groups.append(alloc, .{ .key = item.group_key, .first = i, .last = i });
            } else out.next[out.groups.items[entry.value_ptr.*].last] = i;
            const group = &out.groups.items[entry.value_ptr.*];
            group.last = i;
            group.count += 1;
            group.height += item.row_h + 2;
        }
        return out;
    }

    pub fn order(self: *Index, organization: @import("settings.zig").Organization, device: ?[]const u8) void {
        if (organization == .by_status) std.mem.sort(Group, self.groups.items, {}, struct {
            fn lt(_: void, x: Group, y: Group) bool {
                return @backingInt(workspace.StatusGroup.fromKey(x.key).?) < @backingInt(workspace.StatusGroup.fromKey(y.key).?);
            }
        }.lt);
        if (organization == .by_device) if (device) |me| self.promote(me);
        self.promote("needs");
    }

    fn promote(self: *Index, key: []const u8) void {
        for (self.groups.items, 0..) |group, i| if (std.mem.eql(u8, group.key, key)) {
            std.mem.copyBackwards(Group, self.groups.items[1 .. i + 1], self.groups.items[0..i]);
            self.groups.items[0] = group;
            break;
        };
    }
};

test "sidebar group index preserves member order counts heights and attention priority" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const chat: workspace.Chat = .{ .id = "synthetic", .title = null, .space_id = null, .archived = false, .preview = null, .harness = null, .model = null, .cwd = null };
    var chats: [7]workspace.Chat = undefined;
    @memset(&chats, chat);
    chats[4].archived = true;
    const Item = struct { listed: bool = true, pinned: bool = false, row_h: f32 = 38, group_key: []const u8 };
    const items = [_]Item{
        .{ .group_key = "remote" },                .{ .group_key = "local", .row_h = 30 }, .{ .group_key = "remote" },
        .{ .group_key = "local", .pinned = true }, .{ .group_key = "remote" },             .{ .group_key = "hidden", .listed = false },
        .{ .group_key = "needs" },
    };
    var index = try Index.build(arena.allocator(), &chats, &items);
    try testing.expectEqual(@as(usize, 3), index.groups.items.len);
    try testing.expectEqual(@as(usize, 2), index.groups.items[0].count);
    try testing.expectEqual(@as(f32, 80), index.groups.items[0].height);
    try testing.expectEqual(@as(?usize, 2), index.next[0]);
    try testing.expectEqual(@as(?usize, null), index.next[2]);
    index.order(.by_device, "local");
    try testing.expectEqualStrings("needs", index.groups.items[0].key);
    try testing.expectEqualStrings("local", index.groups.items[1].key);
    try testing.expectEqualStrings("remote", index.groups.items[2].key);
    try testing.expectEqual(@as(usize, 0), index.groups.items[2].first);
    try testing.expectEqual(@as(?usize, 2), index.next[index.groups.items[2].first]);
}
