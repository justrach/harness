//! Bounded, per-window tool motion and access-map selection. No global
//! state, wall-clock timers, transcript copies or personal data.
const std = @import("std");
const rows = @import("tool_rows.zig");
const Allocator = std.mem.Allocator;

pub const max_rows = 1024;
pub const max_folds = 256;

pub fn key(chat: ?[]const u8, entry: []const u8, part: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ chat orelse "", entry, part }) |s| {
        h.update(std.mem.asBytes(&s.len));
        h.update(s);
    }
    return h.final();
}

pub const Row = struct {
    /// Only a tool observed live gets an honest timer/reveal. History
    /// already resolved on first observation remains static on remount.
    started: ?f64 = null,
    reveal: ?f64 = null,
    settled_at: ?f64 = null,
    resolved: bool = false,
    touched: f64 = 0,

    pub fn elapsed(r: Row, now: f64) ?u64 {
        const start = r.started orelse return null;
        return @intFromFloat(@max(now - start, 0) * 1000);
    }

    pub fn wash(r: Row, now: f64, reduced: bool) f32 {
        const start = r.settled_at orelse return 1;
        return if (reduced) 1 else rows.easeOutQuint(@floatCast((now - start) / 0.240));
    }
};

pub const Fold = struct {
    open: bool = false,
    initialized: bool = false,
    from: f32 = 0,
    target: f32 = 0,
    started: f64 = 0,
    /// Measured natural content height, independent of the clipping box.
    natural: f32 = 0,
    touched: f64 = 0,

    pub fn height(f: *const Fold, now: f64, reduced: bool) f32 {
        if (reduced or now - f.started >= 0.140) return f.target;
        const t = rows.easeOutQuint(@floatCast((now - f.started) / 0.140));
        return f.from + (f.target - f.from) * t;
    }

    pub fn update(f: *Fold, open: bool, natural: f32, now: f64, reduced: bool) void {
        f.touched = now;
        if (natural > 0) f.natural = natural;
        const target: f32 = if (open) f.natural else 0;
        if (!f.initialized) {
            f.* = .{ .open = open, .initialized = true, .from = target, .target = target, .natural = f.natural, .started = now - 1, .touched = now };
        } else if (open != f.open or @abs(target - f.target) > 0.5) {
            f.from = f.height(now, reduced);
            f.target = target;
            f.open = open;
            f.started = now;
        }
    }

    pub fn animating(f: *const Fold, now: f64, reduced: bool) bool {
        return !reduced and now - f.started < 0.140 and @abs(f.target - f.from) > 0.5;
    }
};

pub const State = struct {
    rows: std.AutoHashMapUnmanaged(u64, Row) = .empty,
    folds: std.AutoHashMapUnmanaged(u64, Fold) = .empty,
    veils: @import("veil.zig").Store = .{},
    access_chat: ?[]u8 = null,
    selected_agent: usize = 0,
    selected_tool: ?@import("tool_access.zig").Family = null,
    selected_call: ?u64 = null,
    map_scroll: f32 = 0,
    agent_scroll: f32 = 0,
    maps: std.AutoHashMapUnmanaged(u64, @import("tool_access_cache.zig").Cache) = .empty,

    pub fn deinit(s: *State, a: Allocator) void {
        s.rows.deinit(a);
        s.folds.deinit(a);
        s.veils.deinit(a);
        var maps = s.maps.valueIterator();
        while (maps.next()) |map| map.deinit();
        s.maps.deinit(a);
        if (s.access_chat) |id| a.free(id);
    }

    pub fn accessMap(s: *State, a: Allocator, chat: []const u8, now: f64) ?*@import("tool_access_cache.zig").Cache {
        const id = key(chat, "tool-access", "snapshot");
        if (s.maps.getPtr(id)) |map| {
            map.touched = now;
            return map;
        }
        if (s.maps.count() == 8) {
            var oldest: ?u64 = null;
            var touched = std.math.inf(f64);
            var it = s.maps.iterator();
            while (it.next()) |item| if (item.value_ptr.touched < touched) {
                oldest = item.key_ptr.*;
                touched = item.value_ptr.touched;
            };
            if (oldest) |old| if (s.maps.fetchRemove(old)) |removed| {
                var cache = removed.value;
                cache.deinit();
            };
        }
        s.maps.put(a, id, .{ .touched = now }) catch return null;
        return s.maps.getPtr(id);
    }

    pub fn observe(s: *State, a: Allocator, id: u64, resolved: bool, live: bool, now: f64, delay: f64) Row {
        if (s.rows.getPtr(id)) |r| {
            if (resolved and !r.resolved and r.started != null) r.settled_at = now;
            r.resolved = resolved;
            r.touched = now;
            return r.*;
        }
        // Settled history does not need a clock slot. Under capacity
        // pressure never evict a row touched this frame: that would replay
        // arrivals forever in a large transcript.
        if (resolved or !evict(Row, &s.rows, max_rows, now)) return .{ .resolved = resolved, .touched = now };
        const r: Row = .{ .started = if (live and !resolved) now else null, .reveal = if (live) now + delay else null, .resolved = resolved, .touched = now };
        s.rows.put(a, id, r) catch {};
        return r;
    }

    pub fn fold(s: *State, a: Allocator, id: u64, open: bool, natural: f32, now: f64, reduced: bool) Fold {
        if (s.folds.getPtr(id)) |f| {
            f.update(open, natural, now, reduced);
            return f.*;
        }
        var f: Fold = .{ .initialized = true, .started = now - 1 };
        f.update(open, natural, now, reduced);
        if (!open or !evict(Fold, &s.folds, max_folds, now)) return f;
        s.folds.put(a, id, f) catch {};
        return f;
    }

    pub fn openAccess(s: *State, a: Allocator, chat: []const u8) void {
        if (s.access_chat) |old| {
            if (std.mem.eql(u8, old, chat)) return;
        }
        const owned = a.dupe(u8, chat) catch return;
        if (s.access_chat) |old| a.free(old);
        s.access_chat = owned;
        s.selected_agent = 0;
        s.selected_tool = null;
        s.selected_call = null;
        s.map_scroll = 0;
        s.agent_scroll = 0;
    }
};

fn evict(comptime T: type, map: *std.AutoHashMapUnmanaged(u64, T), cap: usize, now: f64) bool {
    if (map.count() < cap) return true;
    var oldest: ?u64 = null;
    var at: f64 = std.math.inf(f64);
    var it = map.iterator();
    while (it.next()) |e| if (e.value_ptr.touched < at) {
        at = e.value_ptr.touched;
        oldest = e.key_ptr.*;
    };
    if (at >= now - 1) return false;
    if (oldest) |id| return map.remove(id);
    return false;
}

test "history is static, live timers survive remount and motion state is bounded" {
    const t = std.testing;
    var s: State = .{};
    defer s.deinit(t.allocator);
    const history = s.observe(t.allocator, 1, true, false, 1, 0);
    try t.expectEqual(@as(?f64, null), history.started);
    try t.expectEqual(@as(?f64, null), history.reveal);
    _ = s.observe(t.allocator, 2, false, true, 2, 0);
    const remount = s.observe(t.allocator, 2, false, true, 5, 0);
    try t.expectEqual(@as(?u64, 3000), remount.elapsed(5));
    const settled = s.observe(t.allocator, 2, true, false, 6, 0);
    try t.expectEqual(@as(f32, 1), settled.wash(6, true));
    for (3..max_rows + 20) |i| _ = s.observe(t.allocator, @intCast(i), false, true, 10, 0);
    const retained = s.rows.get(3).?.reveal;
    for (3..max_rows + 20) |i| _ = s.observe(t.allocator, @intCast(i), false, true, 10.1, 0);
    try t.expectEqual(retained, s.rows.get(3).?.reveal);
    try t.expect(s.rows.count() <= max_rows);
    try t.expect(s.rows.get(1) == null);
}

test "fold keeps content mounted through closing and snaps for reduced motion" {
    var f: Fold = .{};
    f.update(true, 120, 0, false);
    f.update(false, 120, 1, false);
    try std.testing.expect(f.animating(1.05, false));
    try std.testing.expect(f.height(1.05, false) > 0);
    try std.testing.expectEqual(@as(f32, 0), f.height(1.05, true));
    try std.testing.expectEqual(@as(f32, 0), f.height(1.2, false));
    try std.testing.expect(!f.animating(2, false));
}
