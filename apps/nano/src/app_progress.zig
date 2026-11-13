//! Live-only progress belongs to the visible chat, never to transcript content.
const std = @import("std");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const tabs = @import("tabs.zig");
const retry_s: f64 = 2;

pub const State = struct {
    feeds: std.ArrayList(*Feed) = .empty,
};

const Feed = struct {
    app: *App,
    chat: []u8,
    watch: ?u64 = null,
    pending_watch: ?u64 = null,
    retry_at: f64 = 0,
    pending_retry_at: f64 = 0,
    since: ?i64 = null,

    fn progress(f: *Feed, id: u64, reply: rpc.Reply) void {
        if (f.watch != id) return;
        switch (reply) {
            .item => |value| f.since = buildWaitSince(value),
            .done, .err => {
                f.watch = null;
                f.since = null;
                f.retry_at = f.app.now + retry_s;
            },
            .ok => {},
        }
        f.app.redraw();
    }

    fn pending(f: *Feed, id: u64, reply: rpc.Reply) void {
        if (f.pending_watch != id) return;
        switch (reply) {
            .item => |value| @import("app_send_feedback.zig").syncRemote(f.app, f.chat, value),
            .done, .err => {
                f.pending_watch = null;
                f.pending_retry_at = f.app.now + retry_s;
            },
            .ok => {},
        }
        f.app.redraw();
    }

    fn cancel(f: *Feed) void {
        if (f.watch) |id| f.app.engine.cancel(id);
        if (f.pending_watch) |id| f.app.engine.cancel(id);
        f.watch = null;
        f.pending_watch = null;
        f.since = null;
    }
};

fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// The reserved record is the protocol's explicit signal, not a quiet-model heuristic.
pub fn buildWaitSince(value: std.json.Value) ?i64 {
    if (value != .object) return null;
    const list = value.object.get("items") orelse return null;
    if (list != .array) return null;
    var earliest: ?i64 = null;
    for (list.array.items) |item| {
        if (!std.mem.eql(u8, string(item, "toolId") orelse continue, "harness:build-wait")) continue;
        if (!std.mem.eql(u8, string(item, "state") orelse continue, "waiting")) continue;
        const raw = string(item, "output") orelse continue;
        if (raw.len == 0) continue;
        const digits = if (raw[0] == '+') raw[1..] else raw;
        if (digits.len == 0) continue;
        var valid = true;
        for (digits) |ch| if (!std.ascii.isDigit(ch)) {
            valid = false;
            break;
        };
        if (!valid) continue;
        const since = std.fmt.parseInt(i64, digits, 10) catch continue;
        if (since > 0) earliest = if (earliest) |old| @min(old, since) else since;
    }
    return earliest;
}

pub fn waitingSince(a: *const App, chat: []const u8) ?i64 {
    for (a.live_progress.feeds.items) |f| if (std.mem.eql(u8, f.chat, chat)) return f.since;
    return null;
}

fn wantedChats(a: *const App, out: *[tabs.max_panes]?[]const u8) usize {
    var n: usize = 0;
    if (a.view.settings_open) return 0;
    if (a.selected) |id| {
        out[n] = id;
        n += 1;
    }
    if (a.tabs.layout()) |split| if (!split.zoomed) {
        for (split.panes.items) |pane| if (pane) |id| {
            var duplicate = false;
            for (out[0..n]) |old| if (std.mem.eql(u8, old.?, id)) {
                duplicate = true;
                break;
            };
            if (!duplicate and n < out.len) {
                out[n] = id;
                n += 1;
            }
        };
    };
    return n;
}

pub fn tick(a: *App, now: f64) ?f64 {
    var ids: [tabs.max_panes]?[]const u8 = @splat(null);
    const count = wantedChats(a, &ids);
    var i: usize = 0;
    while (i < a.live_progress.feeds.items.len) {
        const f = a.live_progress.feeds.items[i];
        const keep = for (ids[0..count]) |id| {
            if (std.mem.eql(u8, f.chat, id.?)) break true;
        } else false;
        if (!keep) {
            f.cancel();
            @import("app_send_feedback.zig").clearRemote(a, f.chat);
            a.gpa.free(f.chat);
            a.gpa.destroy(f);
            _ = a.live_progress.feeds.swapRemove(i);
        } else i += 1;
    }
    for (ids[0..count]) |id| {
        const found = for (a.live_progress.feeds.items) |f| {
            if (std.mem.eql(u8, f.chat, id.?)) break true;
        } else false;
        if (found) continue;
        const f = a.gpa.create(Feed) catch continue;
        const chat = a.gpa.dupe(u8, id.?) catch {
            a.gpa.destroy(f);
            continue;
        };
        f.* = .{ .app = a, .chat = chat };
        a.live_progress.feeds.append(a.gpa, f) catch {
            a.gpa.free(chat);
            a.gpa.destroy(f);
        };
    }
    var next: ?f64 = null;
    for (a.live_progress.feeds.items) |f| {
        if (!a.engine.up()) {
            f.cancel();
            f.retry_at = 0;
            f.pending_retry_at = 0;
            continue;
        }
        if (f.watch == null) {
            if (now >= f.retry_at) {
                f.watch = a.send_(requests.watchToolProgress(f.chat), .of(Feed, f, Feed.progress));
                f.retry_at = now + retry_s;
            }
            if (f.watch == null) next = if (next) |old| @min(old, f.retry_at) else f.retry_at;
        }
        const selected = if (a.selected) |id| std.mem.eql(u8, id, f.chat) else false;
        if (selected) {
            if (f.pending_watch) |id| a.engine.cancel(id);
            f.pending_watch = null;
        } else if (f.pending_watch == null) {
            if (now >= f.pending_retry_at) {
                f.pending_watch = a.send_(requests.watchQueue(f.chat), .of(Feed, f, Feed.pending));
                f.pending_retry_at = now + retry_s;
            }
            if (f.pending_watch == null) next = if (next) |old| @min(old, f.pending_retry_at) else f.pending_retry_at;
        }
    }
    return next;
}

pub fn deinit(a: *App) void {
    for (a.live_progress.feeds.items) |f| {
        f.cancel();
        a.gpa.free(f.chat);
        a.gpa.destroy(f);
    }
    a.live_progress.feeds.deinit(a.gpa);
}

test "restore waiting protocol uses the same data vectors as the Rust host (#606)" {
    const testing = std.testing;
    const path = try std.fs.path.join(testing.allocator, &.{ @import("parity_options").protocol_dir, "build-wait.json" });
    defer testing.allocator.free(path);
    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("cases").?.array.items) |case| {
        const expected = case.object.get("expected").?;
        const since: ?i64 = if (expected == .integer) expected.integer else null;
        testing.expectEqual(since, buildWaitSince(case)) catch |err| {
            std.debug.print("build-wait vector: {s}\n", .{case.object.get("name").?.string});
            return err;
        };
    }
}
