//! Cached isolated Luau visual states for transcript rows (`MAX_CACHED = 8`).
const std = @import("std");
const vl = @import("visual_luau.zig");

pub const max_cached: usize = 8;

pub const Entry = struct {
    part_id: []u8,
    title: []u8,
    script_hash: u64,
    script_len: usize,
    visual: ?*vl.Visual = null,
    node: ?vl.Node = null,
    arena: ?std.heap.ArenaAllocator = null,
    err: ?[]u8 = null,
    busy: bool = false,
    revision: u64 = 0,
    last_used: u64 = 0,

    pub fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        if (e.visual) |v| v.deinit();
        if (e.arena) |*ar| ar.deinit();
        if (e.err) |err| gpa.free(err);
        gpa.free(e.part_id);
        gpa.free(e.title);
    }
};

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    tick: u64 = 0,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        for (c.entries.items) |*e| e.deinit(gpa);
        c.entries.deinit(gpa);
    }

    pub fn clear(c: *Cache, app: anytype) void {
        for (c.entries.items) |*e| {
            if (e.visual) |v| v.deinit();
            if (e.arena) |ar| app.retireArena(ar);
            if (e.err) |err| app.gpa.free(err);
            app.gpa.free(e.part_id);
            app.gpa.free(e.title);
        }
        c.entries.clearRetainingCapacity();
    }

    pub fn getOrInit(c: *Cache, app: anytype, part_id: []const u8, title: []const u8, script: []const u8) ?*Entry {
        c.tick +%= 1;
        const hash = std.hash.Wyhash.hash(0, script);
        for (c.entries.items) |*e| {
            if (std.mem.eql(u8, e.part_id, part_id)) {
                e.last_used = c.tick;
                if (e.script_hash != hash or e.script_len != script.len) {
                    reinitEntry(app, e, title, script, hash);
                }
                return e;
            }
        }

        if (c.entries.items.len >= max_cached) {
            var lru_idx: usize = 0;
            for (c.entries.items, 0..) |e, i| {
                if (e.last_used < c.entries.items[lru_idx].last_used) lru_idx = i;
            }
            const evicted = c.entries.swapRemove(lru_idx);
            if (evicted.visual) |v| v.deinit();
            if (evicted.arena) |ar| app.retireArena(ar);
            if (evicted.err) |err| app.gpa.free(err);
            app.gpa.free(evicted.part_id);
            app.gpa.free(evicted.title);
        }

        const dup_id = app.gpa.dupe(u8, part_id) catch return null;
        const dup_title = plain(app.gpa, title, 160) catch {
            app.gpa.free(dup_id);
            return null;
        };
        c.entries.append(app.gpa, .{
            .part_id = dup_id,
            .title = dup_title,
            .script_hash = hash,
            .script_len = script.len,
            .last_used = c.tick,
        }) catch {
            app.gpa.free(dup_id);
            app.gpa.free(dup_title);
            return null;
        };
        const e = &c.entries.items[c.entries.items.len - 1];
        initRuntime(app.gpa, e, script);
        return e;
    }

    pub fn dispatch(c: *Cache, app: anytype, part_id: []const u8, revision: u64, handler_id: u64, input: vl.Input) void {
        const e = c.find(part_id) orelse return;
        if (e.busy or e.revision != revision or e.err != null) return;
        const v = e.visual orelse return;
        e.busy = true;
        var next_arena = std.heap.ArenaAllocator.init(app.gpa);
        const res = v.call(next_arena.allocator(), handler_id, input);
        e.busy = false;
        e.revision +%= 1;
        switch (res) {
            .ok => |node| {
                if (e.arena) |old| app.retireArena(old);
                e.arena = next_arena;
                e.node = node;
                if (e.err) |old_err| {
                    app.gpa.free(old_err);
                    e.err = null;
                }
            },
            .err => |raw_err| {
                defer app.gpa.free(raw_err);
                next_arena.deinit();
                if (e.arena) |old| {
                    app.retireArena(old);
                    e.arena = null;
                }
                e.node = null;
                if (e.err) |old_err| app.gpa.free(old_err);
                e.err = plain(app.gpa, raw_err, 360) catch null;
            },
        }
        app.redraw();
    }

    pub fn find(c: *Cache, part_id: []const u8) ?*Entry {
        for (c.entries.items) |*e| {
            if (std.mem.eql(u8, e.part_id, part_id)) return e;
        }
        return null;
    }
};

fn reinitEntry(app: anytype, e: *Entry, title: []const u8, script: []const u8, hash: u64) void {
    if (e.visual) |v| {
        v.deinit();
        e.visual = null;
    }
    if (e.arena) |old| {
        app.retireArena(old);
        e.arena = null;
    }
    e.node = null;
    if (e.err) |old_err| {
        app.gpa.free(old_err);
        e.err = null;
    }
    if (plain(app.gpa, title, 160)) |t| {
        app.gpa.free(e.title);
        e.title = t;
    } else |_| {}
    e.script_hash = hash;
    e.script_len = script.len;
    e.revision +%= 1;
    initRuntime(app.gpa, e, script);
}

fn initRuntime(gpa: std.mem.Allocator, e: *Entry, script: []const u8) void {
    switch (vl.Visual.init(gpa, script)) {
        .ok => |v| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            switch (v.render(arena.allocator())) {
                .ok => |node| {
                    e.visual = v;
                    e.arena = arena;
                    e.node = node;
                    e.err = null;
                },
                .err => |raw_err| {
                    defer gpa.free(raw_err);
                    arena.deinit();
                    v.deinit();
                    e.err = plain(gpa, raw_err, 360) catch null;
                },
            }
        },
        .err => |raw_err| {
            defer gpa.free(raw_err);
            e.err = plain(gpa, raw_err, 360) catch null;
        },
    }
}

pub fn plain(gpa: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var count: usize = 0;
    var truncated = false;
    var it = (std.unicode.Utf8View.init(text) catch {
        const cap = @min(text.len, limit);
        for (text[0..cap]) |b| {
            if ((b >= 0x20 and b != 0x7f) or b == '\n') try out.append(gpa, b);
        }
        if (text.len > limit) try out.appendSlice(gpa, "\xe2\x80\xa6");
        return out.toOwnedSlice(gpa);
    }).iterator();
    while (it.nextCodepointSlice()) |cp| {
        const val = std.unicode.utf8Decode(cp) catch continue;
        const is_ctrl = (val < 0x20 and val != '\n') or val == 0x7f or (val >= 0x80 and val <= 0x9f);
        if (is_ctrl) continue;
        if (count >= limit) {
            truncated = true;
            break;
        }
        try out.appendSlice(gpa, cp);
        count += 1;
    }
    if (truncated) try out.appendSlice(gpa, "\xe2\x80\xa6");
    return out.toOwnedSlice(gpa);
}
