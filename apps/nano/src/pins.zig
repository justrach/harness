//! Pinned sessions, as the GPUI app keeps them (crates/ui/src/shell/spaces.rs,
//! sidebar_pins): an ordered list of chat ids per profile, "local" here,
//! kept in ui-settings.json's `sidebarPinnedSessionIdsByProfile`. Only pins
//! have an order of their own; the other sessions follow activity. Pure:
//! ids in, ids out, each rule tested as the GPUI app tests it.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Id = []const u8;

fn indexOf(list: []const Id, id: Id) ?usize {
    for (list, 0..) |x, i| if (std.mem.eql(u8, x, id)) return i;
    return null;
}

/// Where a dragged session lands: among the pins at a visible index, or
/// back with the other sessions (`SidebarSessionDrop`).
pub const Target = union(enum) { pinned: usize, regular };

/// The visible pins in pin order, then the rest in their order
/// (`project_pinned_first`).
pub fn pinnedFirst(gpa: Allocator, order: []const Id, pins: []const Id) ![]Id {
    var out: std.ArrayList(Id) = .empty;
    errdefer out.deinit(gpa);
    for (pins) |p| if (indexOf(order, p) != null and indexOf(out.items, p) == null) try out.append(gpa, p);
    for (order) |o| if (indexOf(out.items, o) == null) try out.append(gpa, o);
    return out.toOwnedSlice(gpa);
}

/// The visible pin at `from` moved to where `to` is, every other pin
/// (hidden ones too) keeping its place (`reorder_visible_pins`).
pub fn reorderVisible(gpa: Allocator, pins: []const Id, visible: []const Id, from: usize, to: usize) ![]Id {
    const out = try gpa.dupe(Id, pins);
    if (from >= visible.len or to >= visible.len or from == to) return out;
    const moving = visible[from];
    const at = indexOf(out, moving) orelse return out;
    var list: std.ArrayList(Id) = .fromOwnedSlice(out);
    _ = list.orderedRemove(at);
    const anchor = indexOf(list.items, visible[to]) orelse {
        try list.insert(gpa, at, moving);
        return list.toOwnedSlice(gpa);
    };
    try list.insert(gpa, anchor + @intFromBool(from < to), moving);
    return list.toOwnedSlice(gpa);
}

/// The pins after a session is dropped on `target` (`sidebar_session_drop_pins`).
pub fn dropPins(gpa: Allocator, saved: []const Id, visible: []const Id, id: Id, target: Target) ![]Id {
    switch (target) {
        .regular => {
            var out: std.ArrayList(Id) = .empty;
            errdefer out.deinit(gpa);
            for (saved) |s| if (!std.mem.eql(u8, s, id)) try out.append(gpa, s);
            return out.toOwnedSlice(gpa);
        },
        .pinned => |i| {
            if (indexOf(visible, id)) |from| return reorderVisible(gpa, saved, visible, from, @min(i, visible.len - 1));
            // Pinned but not shown (another project's): left as it is.
            if (indexOf(saved, id) != null) return gpa.dupe(Id, saved);
            var out: std.ArrayList(Id) = try .initCapacity(gpa, saved.len + 1);
            errdefer out.deinit(gpa);
            out.appendSliceAssumeCapacity(saved);
            const at = if (i < visible.len)
                indexOf(saved, visible[i]) orelse saved.len
            else if (visible.len > 0)
                (if (indexOf(saved, visible[visible.len - 1])) |p| p + 1 else saved.len)
            else
                saved.len;
            out.insertAssumeCapacity(at, id);
            return out.toOwnedSlice(gpa);
        },
    }
}

/// The row a point `y` down a list of rows falls on, rows `gap` apart;
/// outside, none unless `clamp` (`row_drop_index`).
pub fn rowDropIndex(y: f32, heights: []const f32, gap: f32, clamp: bool) ?usize {
    if (heights.len == 0) return null;
    var total: f32 = 0;
    for (heights) |h| total += h;
    total += gap * @as(f32, @floatFromInt(heights.len - 1));
    if (!clamp and (y < 0 or y > total)) return null;
    var at: f32 = 0;
    for (heights, 0..) |h, i| {
        at += h + gap;
        if (y < at) return i;
    }
    return heights.len - 1;
}

/// How far row `ix` shifts, in slots, while the row at `from` is held
/// over `over` (`slide_offset`).
pub fn slideOffset(ix: usize, from: usize, over: usize) i8 {
    if (from < over and from < ix and ix <= over) return -1;
    if (over < from and over <= ix and ix < from) return 1;
    return 0;
}

/// Drops pins no longer known and repeats; whether any went
/// (`retain_known_pins`).
pub fn retainKnown(pins: *std.ArrayList(Id), known: []const Id) bool {
    var changed = false;
    var i: usize = 0;
    while (i < pins.items.len) {
        const p = pins.items[i];
        if (indexOf(known, p) == null or indexOf(pins.items[0..i], p) != null) {
            _ = pins.orderedRemove(i);
            changed = true;
        } else i += 1;
    }
    return changed;
}

const testing = std.testing;

fn expectIds(want: []const Id, got: []const Id) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "pins_lead_without_changing_unpinned_recency" {
    const got = try pinnedFirst(testing.allocator, &.{ "newest", "p2", "middle", "p1", "oldest" }, &.{ "p1", "p2" });
    defer testing.allocator.free(got);
    try expectIds(&.{ "p1", "p2", "newest", "middle", "oldest" }, got);
}

test "missing_duplicate_and_archived_pins_do_not_disturb_regular_rows" {
    const got = try pinnedFirst(testing.allocator, &.{ "b", "a", "c" }, &.{ "archived", "a", "a" });
    defer testing.allocator.free(got);
    try expectIds(&.{ "a", "b", "c" }, got);
}

test "filtered_pin_reorder_preserves_every_other_pins_relative_order" {
    const got = try reorderVisible(testing.allocator, &.{ "a1", "b1", "a2", "archived", "b2" }, &.{ "a1", "a2" }, 0, 1);
    defer testing.allocator.free(got);
    try expectIds(&.{ "b1", "a2", "a1", "archived", "b2" }, got);
}

test "pin_reorder_rejects_invalid_or_noop_moves" {
    const pins = [_]Id{ "a", "b" };
    const same = try reorderVisible(testing.allocator, &pins, &pins, 0, 0);
    defer testing.allocator.free(same);
    try expectIds(&pins, same);
    const out = try reorderVisible(testing.allocator, &pins, &pins, 8, 0);
    defer testing.allocator.free(out);
    try expectIds(&pins, out);
}

test "pin_cleanup_retains_archived_and_prunes_deleted" {
    var list: std.ArrayList(Id) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, &.{ "active", "archived", "deleted", "active" });
    try testing.expect(retainKnown(&list, &.{ "active", "archived" }));
    try expectIds(&.{ "active", "archived" }, list.items);
    try testing.expect(!retainKnown(&list, &.{ "active", "archived" }));
}

test "sidebar_hit_testing_uses_compact_and_mixed_row_heights" {
    try testing.expectEqual(@as(?usize, 1), rowDropIndex(31, &.{ 29, 29 }, 2, false));
    try testing.expectEqual(@as(?usize, null), rowDropIndex(61, &.{ 29, 29 }, 2, false));
    try testing.expectEqual(@as(?usize, 1), rowDropIndex(48, &.{ 45, 63 }, 2, false));
    try testing.expectEqual(@as(?usize, null), rowDropIndex(-1, &.{29}, 2, false));
    try testing.expectEqual(@as(?usize, 0), rowDropIndex(-1, &.{29}, 2, true));
    try testing.expectEqual(@as(?usize, 1), rowDropIndex(500, &.{ 29, 45 }, 2, true));
}

test "session_transfers_only_change_pin_membership_and_order" {
    const g = testing.allocator;
    const saved = [_]Id{ "hidden", "a", "b", "hidden-tail" };
    const visible = [_]Id{ "a", "b" };
    const cases = .{
        .{ "normal", Target.regular, &[_]Id{ "hidden", "a", "b", "hidden-tail" } },
        .{ "normal", Target{ .pinned = 1 }, &[_]Id{ "hidden", "a", "normal", "b", "hidden-tail" } },
        .{ "normal", Target{ .pinned = 2 }, &[_]Id{ "hidden", "a", "b", "normal", "hidden-tail" } },
        .{ "a", Target.regular, &[_]Id{ "hidden", "b", "hidden-tail" } },
        .{ "a", Target{ .pinned = 1 }, &[_]Id{ "hidden", "b", "a", "hidden-tail" } },
    };
    inline for (cases) |cs| {
        const got = try dropPins(g, &saved, &visible, cs[0], cs[1]);
        defer g.free(got);
        try expectIds(cs[2], got);
    }
    const first = try dropPins(g, &.{}, &.{}, "first", .{ .pinned = 0 });
    defer g.free(first);
    try expectIds(&.{"first"}, first);
    const none = try dropPins(g, &.{"only"}, &.{"only"}, "only", .regular);
    defer g.free(none);
    try expectIds(&.{}, none);
}

test "slide_offsets_shift_toward_the_gap" {
    try testing.expectEqual(@as(i8, -1), slideOffset(1, 0, 2));
    try testing.expectEqual(@as(i8, -1), slideOffset(2, 0, 2));
    try testing.expectEqual(@as(i8, 0), slideOffset(0, 0, 2));
    try testing.expectEqual(@as(i8, 0), slideOffset(3, 0, 2));
    try testing.expectEqual(@as(i8, 1), slideOffset(1, 3, 1));
    try testing.expectEqual(@as(i8, 1), slideOffset(2, 3, 1));
    try testing.expectEqual(@as(i8, 0), slideOffset(0, 3, 1));
    try testing.expectEqual(@as(i8, 0), slideOffset(3, 3, 1));
    for (0..4) |ix| try testing.expectEqual(@as(i8, 0), slideOffset(ix, 2, 2));
}
