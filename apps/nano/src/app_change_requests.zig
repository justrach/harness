//! The app's pull requests, watched as the GPUI app watches them
//! (crates/ui/src/state.rs `reconcile_change_request_watches`,
//! `spawn_change_request_watch`): one `WatchCheckoutChangeRequest` per
//! active chat's checkout and branch, opened on connect and whenever chats,
//! spaces or devices change, again once this device is known, and 2 s after
//! a stream ends; an engine that doesn't know the method marks its device
//! unsupported until it reports another version. And the session footer's
//! merge (pickers.rs `run_change_request_merge`): Merge, "Merge #N?", then
//! the host's answer kept under the chat's id.
const std = @import("std");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const cr = @import("change_requests.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

/// Seconds before an ended watch opens again (`RETRY_DELAY`).
const retry_s = 2.0;

/// One watch: its target (owned), its stream while open.
const Watch = struct {
    arena: std.heap.ArenaAllocator,
    key: cr.WatchKey,
    id: ?u64 = null,
    retry_at: ?f64 = null,
};

/// `ChangeRequestMergeStatus`: the host's last answer for a chat.
pub const MergeStatus = struct { chat_id: []u8, merged: bool, message: []u8 };

pub const State = struct {
    gpa: Allocator,
    client: cr.ClientState,
    watches: std.ArrayList(Watch) = .empty,
    /// `change_request_merge_armed`: the chat asked "Merge #N?".
    armed: ?struct { chat_id: []u8, number: u64 } = null,
    /// `change_request_merge_busy`: the chat a merge runs for.
    busy: ?[]u8 = null,
    status: ?MergeStatus = null,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa, .client = .init(gpa) };
    }

    pub fn deinit(s: *State) void {
        for (s.watches.items) |*w| w.arena.deinit();
        s.watches.deinit(s.gpa);
        s.client.deinit();
        s.disarm();
        if (s.busy) |b| s.gpa.free(b);
        s.clearStatus();
    }

    pub fn disarm(s: *State) void {
        if (s.armed) |x| s.gpa.free(x.chat_id);
        s.armed = null;
    }

    fn clearStatus(s: *State) void {
        if (s.status) |st| {
            s.gpa.free(st.chat_id);
            s.gpa.free(st.message);
        }
        s.status = null;
    }

    pub fn isArmed(s: *const State, chat_id: []const u8, number: u64) bool {
        const x = s.armed orelse return false;
        return x.number == number and std.mem.eql(u8, x.chat_id, chat_id);
    }

    pub fn isBusy(s: *const State, chat_id: []const u8) bool {
        return if (s.busy) |b| std.mem.eql(u8, b, chat_id) else false;
    }

    pub fn statusFor(s: *const State, chat_id: []const u8) ?MergeStatus {
        const st = s.status orelse return null;
        return if (std.mem.eql(u8, st.chat_id, chat_id)) st else null;
    }
};

/// The PR `chat` shows, and whether it's the chat's own (`change_request_for_chat`,
/// `change_request_provenance`).
pub fn forChat(a: *const App, chat: workspace.Chat) ?struct { cr.Summary, cr.Provenance } {
    const pr = a.change_requests.client.forChat(chat) orelse return null;
    return .{ pr, cr.provenance(chat, a.chats.items, a.spaces.items) };
}

/// Opens the watches the chats want and closes those they don't
/// (`reconcile_change_request_watches`). Without a connection they wait.
pub fn reconcile(a: *App) void {
    const s = &a.change_requests;
    const targets = cr.desiredTargets(a.gpa, a.chats.items, &s.client) catch return;
    defer a.gpa.free(targets);
    var i: usize = 0;
    while (i < s.watches.items.len) {
        const w = &s.watches.items[i];
        const keep = for (targets) |t| {
            if (t.eql(w.key)) break true;
        } else false;
        if (keep) {
            i += 1;
            continue;
        }
        if (w.id) |id| a.engine.cancel(id);
        w.arena.deinit();
        _ = s.watches.orderedRemove(i);
    }
    s.client.retainTargets(targets);
    for (targets) |t| {
        const have = for (s.watches.items) |w| {
            if (w.key.eql(t)) break true;
        } else false;
        if (have) continue;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        const key = t.dupe(arena.allocator()) catch {
            arena.deinit();
            continue;
        };
        s.watches.append(a.gpa, .{ .arena = arena, .key = key }) catch {
            arena.deinit();
            continue;
        };
    }
    if (a.engine.state != .connected) return;
    for (s.watches.items) |*w| if (w.id == null and w.retry_at == null) open(a, w);
}

/// This device is known now: watches opened before were routed through
/// `targetDeviceId`; open them again routed as they should be.
pub fn restart(a: *App) void {
    for (a.change_requests.watches.items) |*w| {
        if (w.id) |id| a.engine.cancel(id);
        w.id = null;
        w.retry_at = null;
    }
    reconcile(a);
}

/// The connection dropped: every stream ended with it. The snapshots stay
/// (a transport gap keeps the last good one) and the watches open on connect.
pub fn disconnected(a: *App) void {
    for (a.change_requests.watches.items) |*w| {
        w.id = null;
        w.retry_at = null;
    }
}

/// A devices item: a device on another engine version is asked again
/// (`clear_unsupported_on_version_change`), then the watches reconciled.
pub fn devicesArrived(a: *App) void {
    for (a.devices.items) |d| _ = a.change_requests.client.clearUnsupportedOnVersionChange(d.id, d.version);
    reconcile(a);
}

/// Watches whose retry is due open again; the time of the next one.
pub fn tick(a: *App, now: f64) ?f64 {
    var next: ?f64 = null;
    for (a.change_requests.watches.items) |*w| if (w.retry_at) |t| {
        if (now >= t) {
            w.retry_at = null;
            if (a.engine.state == .connected) open(a, w);
        } else next = if (next) |n| @min(n, t) else t;
    };
    return next;
}

fn open(a: *App, w: *Watch) void {
    const params = cr.watchParams(w.key, a.device_id);
    w.id = a.send_(requests.watchChangeRequest(params), rpc.Handler.of(App, a, onFrame).checkedStream());
    if (w.id == null and a.engine.state == .connected) w.retry_at = a.now + retry_s;
}

fn watchOf(a: *App, id: u64) ?*Watch {
    for (a.change_requests.watches.items) |*w| if (w.id == id) return w;
    return null;
}

fn onFrame(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.change_requests;
    const w = watchOf(a, id) orelse return;
    switch (r) {
        // The engine says the stream started.
        .ok => return,
        .item => |v| {
            var arena: std.heap.ArenaAllocator = .init(a.gpa);
            defer arena.deinit();
            // A malformed frame is dropped; the stream goes on.
            const status = cr.parseStatus(arena.allocator(), v) orelse return;
            s.client.store(w.key, status) catch return;
        },
        .err => |e| if (std.mem.startsWith(u8, e, "unknown method")) {
            // This engine doesn't serve it: not asked again until the
            // device reports another version.
            var version: ?[]const u8 = null;
            for (a.devices.items) |d| if (std.mem.eql(u8, d.id, w.key.device_id)) {
                version = d.version;
            };
            w.id = null;
            s.client.markUnsupported(w.key.device_id, version);
            reconcile(a);
        } else ended(a, w),
        .done => ended(a, w),
    }
    a.redraw();
}

fn ended(a: *App, w: *Watch) void {
    w.id = null;
    if (a.engine.state == .connected) w.retry_at = a.now + retry_s;
}

// ── merge ────────────────────────────────────────────────────────────

/// "Merge": asks "Merge #N?" in its place.
pub fn arm(a: *App, chat_id: []const u8, number: u64) void {
    const s = &a.change_requests;
    s.disarm();
    s.armed = .{ .chat_id = a.gpa.dupe(u8, chat_id) catch return, .number = number };
    s.clearStatus();
    a.redraw();
}

pub fn cancel(a: *App) void {
    a.change_requests.disarm();
    a.redraw();
}

/// "Merge #N?": merges the chat's PR on the checkout's host, one at a time.
pub fn merge(a: *App, chat_id: []const u8, number: u64) void {
    const s = &a.change_requests;
    if (s.busy != null) return;
    const chat = a.findChat(chat_id) orelse return;
    const params = cr.mergeParams(chat, number, a.device_id) orelse return;
    s.disarm();
    s.busy = a.gpa.dupe(u8, chat_id) catch return;
    s.clearStatus();
    a.request(requests.mergeChangeRequest(params), .of(App, a, onMerged));
    a.redraw();
}

fn onMerged(a: *App, _: u64, r: rpc.Reply) void {
    const result: cr.MergeResult = switch (r) {
        .ok => |v| cr.parseMergeResult(v),
        .err => |e| .{ .merged = false, .message = e },
        else => return,
    };
    applyMerge(a, result);
}

/// The host's answer to the running merge.
pub fn applyMerge(a: *App, result: cr.MergeResult) void {
    const s = &a.change_requests;
    const chat_id = s.busy orelse return;
    s.busy = null;
    s.clearStatus();
    const message = a.gpa.dupe(u8, result.message) catch return a.gpa.free(chat_id);
    s.status = .{ .chat_id = chat_id, .merged = result.merged, .message = message };
    a.redraw();
}
