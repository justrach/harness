//! The account's Codegraff cloud sandboxes, kept on the app for every view
//! that shows them (state/cloud_sandboxes.rs): the "Cloud sandbox running"
//! strip in the sidebar's foot, its chip while the sidebar is closed, and
//! Settings › Accounts' card. A sandbox started from Harness keeps running,
//! billed, until it is turned off, so the list is read when the engine
//! attaches, after a Codegraff sign-in, after a create or turn-off, and every
//! 60 seconds while anything runs. A failed read keeps the last answer.
const std = @import("std");
const json = std.json;
const rpc = @import("rpc.zig");
const sandboxes = @import("sandboxes.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

/// How often a running sandbox's state is read again (`REFRESH_EVERY`).
pub const refresh_s: f64 = 60;

pub const State = struct {
    /// The engine's last answer: null before the first, while signed out of
    /// Codegraff, or from an engine that doesn't know the call.
    list: ?sandboxes.List = null,
    arena: ?std.heap.ArenaAllocator = null,
    /// Bumped on every answer, changed or not.
    revision: u64 = 0,
    /// The read under way, and when the next one is due (none while nothing
    /// runs).
    call: ?u64 = null,
    next_read: ?f64 = null,
    /// The strip's Turn off: the pauses it waits for, and whether one failed.
    turning_off: usize = 0,
    turn_off_failed: bool = false,

    pub fn deinit(s: *State) void {
        if (s.arena) |*ar| ar.deinit();
        s.* = .{};
    }
};

fn engineUp(a: *App) bool {
    return a.engine.up();
}

/// The list, when there is one to show (signed in, and offered here).
pub fn shown(a: *const App) ?sandboxes.List {
    const l = a.cloud_sandboxes.list orelse return null;
    return if (l.enabled) l else null;
}

/// Read the list now (`refresh_cloud_sandboxes`), dropping any read under
/// way. Without an engine, nothing.
pub fn refresh(a: *App) void {
    if (!engineUp(a)) return;
    const s = &a.cloud_sandboxes;
    s.next_read = null;
    s.call = a.engine.call("CodegraffSandboxes", rpc.empty, .of(App, a, onList));
}

fn onList(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.cloud_sandboxes;
    if (id != 0 and s.call != id) return;
    s.call = null;
    switch (r) {
        .ok => |v| apply(a, v),
        // A failed read keeps the last answer, and tries again on the timer.
        else => schedule(a),
    }
    a.redraw();
}

/// Take an answer (`apply_cloud_sandboxes_value`): the engine's, or the
/// same call's read elsewhere. One that doesn't parse keeps the last.
pub fn apply(a: *App, v: json.Value) void {
    const s = &a.cloud_sandboxes;
    var ar: std.heap.ArenaAllocator = .init(a.gpa);
    const got = sandboxes.parse(ar.allocator(), v) catch {
        ar.deinit();
        return schedule(a);
    };
    if (s.arena) |*old| old.deinit();
    s.arena = ar;
    s.list = got;
    s.revision +%= 1;
    schedule(a);
    a.redraw();
}

/// One timer while anything runs; none otherwise.
fn schedule(a: *App) void {
    const s = &a.cloud_sandboxes;
    const l = s.list orelse {
        s.next_read = null;
        return;
    };
    s.next_read = if (sandboxes.needsRefresh(l)) a.now + refresh_s else null;
}

/// From the app's tick: read again when it's time. When next.
pub fn tick(a: *App, now: f64) ?f64 {
    const t = a.cloud_sandboxes.next_read orelse return null;
    if (now < t) return t;
    // The timer is spent either way; with no engine there is none after.
    a.cloud_sandboxes.next_read = null;
    refresh(a);
    return a.cloud_sandboxes.next_read;
}

/// Pause every one of `ids` (memory and files are kept; billing stops),
/// then read the list again so the strip and the card catch up at once.
pub fn turnOff(a: *App, ids: []const []const u8) void {
    const s = &a.cloud_sandboxes;
    if (s.turning_off > 0 or ids.len == 0 or !engineUp(a)) return;
    s.turning_off = ids.len;
    s.turn_off_failed = false;
    for (ids) |id| a.call("CodegraffSandboxAction", .{ .id = id, .action = "stop" }, .of(App, a, onTurnedOff));
}

fn onTurnedOff(a: *App, _: u64, r: rpc.Reply) void {
    const s = &a.cloud_sandboxes;
    if (r == .err and !s.turn_off_failed) {
        // The first failure is the one said.
        s.turn_off_failed = true;
        var buf: [256]u8 = undefined;
        const why = if (std.mem.eql(u8, r.err, "not connected")) "Engine not connected" else r.err;
        a.setNotice(std.fmt.bufPrint(&buf, "Couldn't turn off the cloud sandbox: {s}", .{why}) catch "Couldn't turn off the cloud sandbox");
    }
    s.turning_off -|= 1;
    if (s.turning_off == 0) refresh(a);
    a.redraw();
}

const testing = std.testing;

fn applyText(a: *App, text: []const u8) !void {
    const p = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer p.deinit();
    apply(a, p.value);
}

fn one(comptime state: []const u8) []const u8 {
    return "{\"enabled\": true, \"sandboxes\": [{\"id\": \"cnd_1\", \"provider\": \"fleet\", \"state\": \"" ++ state ++ "\"}]}";
}

test "a timer runs only while something runs" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try applyText(&a, one("running"));
    try testing.expect(a.cloud_sandboxes.next_read != null);
    try applyText(&a, one("paused"));
    try testing.expect(a.cloud_sandboxes.next_read == null);
    try applyText(&a, one("stopping"));
    try testing.expect(a.cloud_sandboxes.next_read != null);
    try applyText(&a, "null");
    try testing.expect(a.cloud_sandboxes.next_read == null);
    try testing.expect(a.cloud_sandboxes.list == null);
    try testing.expectEqual(@as(u64, 4), a.cloud_sandboxes.revision);
}

test "an answer that doesn't parse keeps the last; with no engine the timer ends and nothing is sent" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try applyText(&a, one("running"));
    try applyText(&a, "[1, 2]");
    try testing.expectEqualStrings("running", shown(&a).?.sandboxes[0].state);
    try testing.expectEqual(@as(u64, 1), a.cloud_sandboxes.revision);
    const due = a.cloud_sandboxes.next_read.?;
    try testing.expectEqual(due, tick(&a, due - 1).?);
    try testing.expect(tick(&a, due) == null);
    try testing.expect(a.cloud_sandboxes.call == null);
    turnOff(&a, &.{"cnd_1"});
    try testing.expectEqual(@as(usize, 0), a.cloud_sandboxes.turning_off);
}
