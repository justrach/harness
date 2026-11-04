//! The open chat's message queue, driven as the desktop drives it
//! (crates/ui/src/queue.rs): a message typed while the agent works is
//! queued (`QueueMessage`, held for the turn's end) or, with ⌘↩, steers the
//! run; a row can be removed, sent now (which interrupts the turn), or
//! edited in the composer under a lease the host grants and the editor
//! renews every 20 seconds. The host-only calls name the chat's device when
//! it isn't this one.
const std = @import("std");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const App = @import("app.zig").App;

/// What the engine says it can do (`EngineInfo.capabilities`).
pub const Caps = struct {
    queue: bool = false,
    actions: bool = false,
    edit_lease: bool = false,
    dismiss_input: bool = false,
};

pub fn readCaps(list: []const std.json.Value) Caps {
    var c: Caps = .{};
    for (list) |v| if (v == .string) {
        const s = v.string;
        if (std.mem.eql(u8, s, "message-queue-v1")) c.queue = true;
        if (std.mem.eql(u8, s, "message-queue-actions-v1")) c.actions = true;
        if (std.mem.eql(u8, s, "message-queue-edit-lease-v1")) c.edit_lease = true;
        if (std.mem.eql(u8, s, "dismiss-input-v1")) c.dismiss_input = true;
    };
    return c;
}

/// A queued row being edited in the composer.
pub const Edit = struct {
    row: []u8,
    lease: []u8,
    base_hash: []u8,
    renew_at: f64,
    saving: bool = false,

    fn deinit(e: *Edit, gpa: std.mem.Allocator) void {
        gpa.free(e.row);
        gpa.free(e.lease);
        gpa.free(e.base_hash);
    }
};

const renew_s = 20.0;

/// The chat's device when the queue lives on another one.
fn host(a: *const App) ?[]const u8 {
    const id = a.selected orelse return null;
    const ch = a.findChat(id) orelse return null;
    return foreign(a, ch.device_id);
}

/// `device`, unless it's this one.
fn foreign(a: *const App, device: ?[]const u8) ?[]const u8 {
    const dev = device orelse return null;
    if (a.device_id) |mine| if (std.mem.eql(u8, mine, dev)) return null;
    return dev;
}

pub fn watch(a: *App) void {
    const chat = a.selected orelse return;
    if (a.w_queue.id) |id| a.engine.cancel(id);
    a.queue.replace(.{ .array = .init(a.gpa) }) catch {};
    a.w_queue = .{ .id = a.send_(requests.watchQueue(chat), .of(App, a, onQueue)) };
}

pub fn stop(a: *App) void {
    if (a.w_queue.id) |id| a.engine.cancel(id);
    a.w_queue = .{};
    a.queue.replace(.{ .array = .init(a.gpa) }) catch {};
    if (a.queue_edit) |*e| {
        e.deinit(a.gpa);
        a.queue_edit = null;
    }
}

/// Frees what the queue holds; no calls (the engine may be gone first).
pub fn deinit(a: *App) void {
    if (a.queue_edit) |*e| e.deinit(a.gpa);
    a.queue_edit = null;
    for (a.steers.items) |s| s.free();
    a.steers.deinit(a.gpa);
    a.queue.deinit();
    if (a.queue_begin) |b| a.gpa.free(b);
}

fn onQueue(a: *App, id: u64, r: rpc.Reply) void {
    if (a.w_queue.id != id) return;
    switch (r) {
        .item => |v| a.queue.replace(@import("queue.zig").items(v)) catch {},
        .done, .err => a.w_queue = .{ .retry_at = a.now + 2 },
        .ok => {},
    }
    a.redraw();
}

/// Whether a message sent now waits in the queue: the agent is working
/// (or waiting on a question) and the engine queues.
pub fn queues(a: *const App) bool {
    if (!a.caps.queue or a.selected == null) return false;
    const s = a.selectedStatus();
    return s == .working or s == .awaiting_input;
}

pub fn queueMessage(a: *App, text: []const u8) void {
    const chat = a.selected orelse return;
    a.request(requests.queueMessage(chat, text), .of(App, a, App.onNotice));
}

/// What a message does while a run is live (`FollowUpAction`).
pub const FollowUp = enum { queue, steer };

/// Why a message can't steer the run, in the desktop's words
/// (`steer_unavailable`, `steer_reason`).
pub fn steerBlocked(live: bool, has_text: bool, has_attachments: bool, actions: bool, steers: bool) ?[]const u8 {
    if (!live) return "Steer is available while a run is active";
    if (!has_text) return "Steer needs text in the composer";
    if (has_attachments) return "Steer only supports text; remove attachments or screenshots";
    if (!actions) return "Update Harness on this device and the chat host to use this action";
    if (!steers) return "This agent does not support steering during a turn";
    return null;
}

/// This device's catalog says the chat's agent steers mid-turn; another
/// device's agents aren't in it (`catalog_supports_chat_steering`).
fn chatSteers(a: *const App) bool {
    if (host(a) != null) return false;
    const id = a.selected orelse return false;
    const harness = (a.findChat(id) orelse return false).harness orelse return false;
    for (a.harnesses.items) |h| if (std.mem.eql(u8, h.id, harness)) return h.steers;
    return false;
}

fn steerBlock(a: *const App) ?[]const u8 {
    const has_text = std.mem.trim(u8, a.composer.text(), " \n\t").len > 0;
    return steerBlocked(a.queues(), has_text, @import("app_attachments.zig").count(a) > 0, a.caps.actions, chatSteers(a));
}

/// Settings › Shortcuts' follow-up behaviour, in the file both apps share.
fn behavior(a: *const App) FollowUp {
    const v = a.settings.text("followUpBehavior") orelse return .queue;
    return if (std.mem.eql(u8, v, "steer")) .steer else .queue;
}

/// What Enter does with a run live: the setting, or the queue where it
/// can't steer (`main_action`).
pub fn mainFollowUp(a: *const App) FollowUp {
    return if (behavior(a) == .steer and steerBlock(a) == null) .steer else .queue;
}

/// ⌘↩ with a run live: whichever the setting doesn't choose, so by default
/// it steers. Where it can't, the draft stays and the composer says why.
pub fn sendOpposite(a: *App) void {
    if (a.queue_edit != null) return;
    if (behavior(a) == .steer) return a.sendAs(.queue);
    if (steerBlock(a)) |why| {
        a.setNotice(why);
        return a.redraw();
    }
    a.sendAs(.steer);
}

/// A message on its way to steer a run: queued first for its row's id, then
/// promoted (`SteerQueuedMessageNow`), as the desktop's composer does.
pub const Steer = struct {
    app: *App,
    chat: []u8,
    text: []u8,

    fn free(s: *Steer) void {
        const gpa = s.app.gpa;
        gpa.free(s.chat);
        gpa.free(s.text);
        gpa.destroy(s);
    }

    fn finish(s: *Steer) void {
        const a = s.app;
        for (a.steers.items, 0..) |x, i| if (x == s) {
            _ = a.steers.swapRemove(i);
            break;
        };
        s.free();
        a.redraw();
    }

    fn onQueued(s: *Steer, _: u64, r: rpc.Reply) void {
        const a = s.app;
        const row: ?[]const u8 = switch (r) {
            .ok => |v| if (v == .object) str(v.object, "id") else null,
            .err, .done => null,
            .item => return,
        };
        if (row == null or row.?.len == 0) {
            // Nothing was queued: the prompt is still the user's draft.
            a.setNotice("Couldn't send that message");
            if (a.selected != null and std.mem.eql(u8, a.selected.?, s.chat) and a.composer.text().len == 0) a.composer.set(s.text);
            return s.finish();
        }
        const host_id: ?[]const u8 = if (a.selected != null and std.mem.eql(u8, a.selected.?, s.chat)) host(a) else if (a.findChat(s.chat)) |ch| foreign(a, ch.device_id) else null;
        // The reply can come before this returns: nothing touches `s` after.
        a.request(requests.steerQueuedNow(s.chat, row.?, host_id), .of(Steer, s, onSteered));
    }

    fn onSteered(s: *Steer, _: u64, r: rpc.Reply) void {
        switch (r) {
            .ok => |v| if (!acked(v, "sent")) s.app.setNotice("Message queued, but it couldn't steer the run. Check the queue."),
            .err, .done => s.app.setNotice("Message queued, but it couldn't steer the run. Check the queue."),
            .item => return,
        }
        s.finish();
    }
};

/// Sends `text` (it may be the composer's own) to steer the open chat's run,
/// and takes it out of the composer.
pub fn steer(a: *App, text: []const u8) void {
    const chat = a.selected orelse return;
    const s = newSteer(a, chat, text) catch return a.setNotice("Couldn't send that message");
    @import("app_attachments.zig").clear(a);
    a.composer.clear();
    a.view.stick_end = true;
    a.request(requests.queueMessage(s.chat, s.text), .of(Steer, s, Steer.onQueued));
}

fn newSteer(a: *App, chat: []const u8, text: []const u8) !*Steer {
    const s = try a.gpa.create(Steer);
    errdefer a.gpa.destroy(s);
    const owned_chat = try a.gpa.dupe(u8, chat);
    errdefer a.gpa.free(owned_chat);
    const owned_text = try a.gpa.dupe(u8, text);
    errdefer a.gpa.free(owned_text);
    s.* = .{ .app = a, .chat = owned_chat, .text = owned_text };
    try a.steers.append(a.gpa, s);
    return s;
}

pub fn remove(a: *App, row: []const u8) void {
    const chat = a.selected orelse return;
    a.request(requests.removeQueued(chat, row, host(a)), .of(App, a, onRemoved));
}

fn onRemoved(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| if (!acked(v, "removed")) a.setNotice("That message had already left the queue"),
        .err => a.setNotice("Couldn't remove the message"),
        else => {},
    }
    a.redraw();
}

/// "Send now": interrupts the turn and sends the row.
pub fn sendNow(a: *App, row: []const u8) void {
    const chat = a.selected orelse return;
    a.request(requests.sendQueuedNow(chat, row, host(a)), .of(App, a, onSent));
}

fn onSent(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| if (!acked(v, "sent")) a.setNotice("Couldn't send that message"),
        .err => a.setNotice("Couldn't send that message"),
        else => {},
    }
    a.redraw();
}

fn acked(v: std.json.Value, field: []const u8) bool {
    if (v != .object) return false;
    const f = v.object.get(field) orelse return false;
    return f == .bool and f.bool;
}

pub fn beginEdit(a: *App, row: []const u8) void {
    const chat = a.selected orelse return;
    if (!a.caps.edit_lease) return a.setNotice("Update the chat host to edit queued messages safely");
    if (a.queue_edit != null or a.queue_begin != null) return;
    a.queue_begin = a.gpa.dupe(u8, row) catch return;
    var buf: [36]u8 = undefined;
    const instance = a.instanceId(&buf);
    a.request(requests.beginEdit(chat, row, a.device_id orelse "", instance, host(a)), .of(App, a, onBegun));
    a.redraw();
}

fn onBegun(a: *App, _: u64, r: rpc.Reply) void {
    const row = a.queue_begin orelse return;
    defer {
        a.gpa.free(row);
        a.queue_begin = null;
    }
    const v = switch (r) {
        .ok => |v| v,
        .err => return a.setNotice("Connect to the chat host to edit this message"),
        else => return,
    };
    if (v != .object) return;
    const o = v.object;
    const outcome = str(o, "outcome") orelse "";
    if (std.mem.eql(u8, outcome, "locked")) return a.setNotice("That queued message is being edited on another device");
    if (!std.mem.eql(u8, outcome, "acquired")) return a.setNotice("That queued message is no longer available");
    const lease = str(o, "leaseId") orelse return;
    const hash = str(o, "baseTextHash") orelse return;
    const text = str(o, "text") orelse "";
    a.queue_edit = .{
        .row = a.gpa.dupe(u8, row) catch return,
        .lease = a.gpa.dupe(u8, lease) catch return,
        .base_hash = a.gpa.dupe(u8, hash) catch return,
        .renew_at = a.now + renew_s,
    };
    a.draft_stash.clearRetainingCapacity();
    a.draft_stash.appendSlice(a.gpa, a.composer.text()) catch {};
    a.composer.set(text);
    a.redraw();
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

pub const Finish = enum { commit, cancel, discard };

/// Ends the edit: saves the composer's text (or, emptied, removes the
/// row), or leaves the row as it was.
pub fn finishEdit(a: *App, action: Finish) void {
    const chat = a.selected orelse return;
    const e = if (a.queue_edit) |*e| e else return;
    const attachments = @import("app_attachments.zig");
    const body = std.mem.trim(u8, a.composer.text(), " \n\t");
    const attached = if (action == .commit) attachments.prompt(a, body) catch {
        a.setNotice("Wait for the attachments to finish before saving this edit.");
        return;
    } else null;
    defer if (attached) |text| a.gpa.free(text);
    const text = attached orelse body;
    const act: Finish = if (action == .commit and text.len == 0) .discard else action;
    e.saving = true;
    a.request(requests.finishEdit(chat, e.row, e.lease, @tagName(act), if (act == .commit) text else null, if (act == .commit) e.base_hash else null, host(a)), .of(App, a, onFinished));
}

fn onFinished(a: *App, _: u64, r: rpc.Reply) void {
    const outcome: []const u8 = switch (r) {
        .ok => |v| if (v == .object) (str(v.object, "outcome") orelse "") else "",
        .err => {
            if (a.queue_edit) |*e| e.saving = false;
            return a.setNotice("Couldn't reach the chat host; your edit is still in the editor");
        },
        else => return,
    };
    const done = std.mem.eql(u8, outcome, "committed") or std.mem.eql(u8, outcome, "cancelled") or
        std.mem.eql(u8, outcome, "discarded") or std.mem.eql(u8, outcome, "released");
    if (!done) {
        if (a.queue_edit) |*e| e.saving = false;
        return a.setNotice(if (std.mem.eql(u8, outcome, "conflict"))
            "This message changed on another device; your edit was kept locally"
        else if (std.mem.eql(u8, outcome, "missing"))
            "The queued message was removed; your edit was kept locally"
        else
            "The edit lease changed; your text is still in the editor");
    }
    @import("app_attachments.zig").clear(a);
    if (a.queue_edit) |*e| e.deinit(a.gpa);
    a.queue_edit = null;
    a.composer.set(a.draft_stash.items);
    a.draft_stash.clearRetainingCapacity();
    a.redraw();
}

/// Renews the edit's lease when it is due; from `tick`. When next due.
pub fn tick(a: *App, now: f64) ?f64 {
    const e = if (a.queue_edit) |*e| e else return null;
    if (now < e.renew_at) return e.renew_at;
    e.renew_at = now + renew_s;
    const chat = a.selected orelse return null;
    a.request(requests.renewEdit(chat, e.row, e.lease, host(a)), .of(App, a, onRenewed));
    return e.renew_at;
}

fn onRenewed(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| if (v == .object) {
            const o = str(v.object, "outcome") orelse "";
            if (!std.mem.eql(u8, o, "renewed")) a.setNotice("Edit protection expired; review this message before sending");
        },
        .err => a.setNotice("Edit protection expired; review this message before sending"),
        else => {},
    }
}

test "steering: a live run, text alone, a host and an agent that can" {
    try std.testing.expect(steerBlocked(true, true, false, true, true) == null);
    try std.testing.expectEqualStrings("Steer is available while a run is active", steerBlocked(false, true, false, true, true).?);
    try std.testing.expectEqualStrings("Steer needs text in the composer", steerBlocked(true, false, false, true, true).?);
    try std.testing.expectEqualStrings("Steer only supports text; remove attachments or screenshots", steerBlocked(true, true, true, true, true).?);
    try std.testing.expectEqualStrings("Update Harness on this device and the chat host to use this action", steerBlocked(true, true, false, false, true).?);
    try std.testing.expectEqualStrings("This agent does not support steering during a turn", steerBlocked(true, true, false, true, false).?);
}

test "capabilities are read by name" {
    const list = [_]std.json.Value{ .{ .string = "message-queue-v1" }, .{ .string = "message-queue-edit-lease-v1" } };
    const c = readCaps(&list);
    try std.testing.expect(c.queue and c.edit_lease and !c.actions);
}
