//! The open chat's message queue, driven as the desktop drives it
//! (crates/ui/src/queue.rs): a message typed while the agent works is
//! queued (`QueueMessage`, held for the turn's end); a row can be removed,
//! sent now (which interrupts the turn), or edited in the composer under a
//! lease the host grants and the editor renews every 20 seconds. The
//! host-only calls name the chat's device when it isn't this one.
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
    finish_call: ?u64 = null,
    renew_call: ?u64 = null,

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
    const dev = ch.device_id orelse return null;
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
    if (a.queue_begin_call) |id| a.engine.cancel(id);
    a.queue_begin_call = null;
    if (a.queue_begin) |row| a.gpa.free(row);
    a.queue_begin = null;
    a.queue.replace(.{ .array = .init(a.gpa) }) catch {};
    if (a.queue_edit) |*e| {
        // Replies still in flight belong to this editor, never the next
        // chat's editor. Release the host lease without a global notice.
        if (e.finish_call) |id| a.engine.cancel(id);
        if (e.renew_call) |id| a.engine.cancel(id);
        if (a.selected) |chat| a.request(requests.finishEdit(chat, e.row, e.lease, "cancel", null, null, host(a)), .of(App, a, onReleased));
        @import("app_attachments.zig").clear(a);
        e.deinit(a.gpa);
        a.queue_edit = null;
    }
}

/// Frees what the queue holds; no calls (the engine may be gone first).
pub fn deinit(a: *App) void {
    if (a.queue_edit) |*e| e.deinit(a.gpa);
    a.queue_edit = null;
    for (a.steers.items) |*s| s.deinit(a.gpa);
    a.steers.deinit(a.gpa);
    a.queue.deinit();
    if (a.queue_begin) |b| a.gpa.free(b);
}

fn onQueue(a: *App, id: u64, r: rpc.Reply) void {
    if (a.w_queue.id != id) return;
    switch (r) {
        .item => |v| {
            a.queue.replace(@import("queue.zig").items(v)) catch {};
            if (a.selected) |chat| @import("app_send_feedback.zig").syncRemote(a, chat, v);
        },
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

// Messages while the agent is working (crates/ui/src/composer/follow_up.rs):
// queued for the turn's end, or steered into the turn at its next step.

/// Settings › Shortcuts' choice (`FollowUpBehavior`, `followUpBehavior`).
pub const FollowUp = enum { queue, steer };

/// True when `model` is a GPT-6.0+ model (`gpt-6*`, `gpt-6.0`, `gpt-6.1-sol`,
/// `gpt-6-astra`, `chatgpt-new/gpt-6.1-sol`, `codex/gpt-6-sol`, `gpt-7*`, …).
pub fn isGpt6PlusModel(model: ?[]const u8) bool {
    const raw = model orelse return false;
    var bare = raw;
    if (std.mem.lastIndexOfAny(u8, raw, "/:")) |sep| bare = raw[sep + 1 ..];
    const rest = if (bare.len >= 4 and std.ascii.eqlIgnoreCase(bare[0..4], "gpt-"))
        bare[4..]
    else if (bare.len >= 3 and std.ascii.eqlIgnoreCase(bare[0..3], "gpt"))
        bare[3..]
    else
        return false;
    var i: usize = 0;
    var major: u32 = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
        major = major *| 10 +| (rest[i] - '0');
    }
    if (i == 0 or major < 6) return false;
    if (i == rest.len) return true;
    return switch (rest[i]) {
        '.', '-', '_', ':', ' ' => true,
        else => false,
    };
}

/// Codex and GPT-6.0+ models steer mid-turn by default; other models queue.
pub fn defaultFollowUpFor(harness: []const u8, model: ?[]const u8) FollowUp {
    if (isGpt6PlusModel(model)) return .steer;
    if (model == null and std.mem.eql(u8, harness, "codex")) return .steer;
    return .queue;
}

pub fn activeModelId(a: *const App) ?[]const u8 {
    const t = a.target();
    if (t.model) |m| return m;
    if (std.mem.eql(u8, a.models_for, t.harness) and a.models.items.len > 0) return a.models.items[0].id;
    if (a.view.model_picker.catalogs.get(t.harness)) |cat| {
        if (cat.models.items.len > 0) return cat.models.items[0].id;
    }
    return null;
}

pub fn defaultFollowUp(a: *const App) FollowUp {
    const t = a.target();
    return defaultFollowUpFor(t.harness, activeModelId(a));
}

pub fn followUpBehavior(a: *const App) FollowUp {
    const v = a.settings.text("followUpBehavior") orelse return defaultFollowUp(a);
    if (std.mem.eql(u8, v, "steer")) return .steer;
    if (std.mem.eql(u8, v, "queue")) return .queue;
    return defaultFollowUp(a);
}

pub fn setFollowUpBehavior(a: *App, f: FollowUp) void {
    a.settings.setText("followUpBehavior", @tagName(f));
    a.redraw();
}

pub fn toggleFollowUp(a: *App) void {
    setFollowUpBehavior(a, opposite(followUpBehavior(a)));
}

pub fn opposite(f: FollowUp) FollowUp {
    return if (f == .queue) .steer else .queue;
}

/// Why a steer can't be sent now (`steer_unavailable`), as `steer_reason`
/// words it; null when it can.
pub fn steerUnavailable(live: bool, has_text: bool, has_attachments: bool, queue_actions: bool, step_boundary: bool) ?[]const u8 {
    if (!live) return "Steer is available while a run is active";
    if (!has_text) return "Steer needs text in the composer";
    if (has_attachments) return "Steer only supports text; remove attachments or screenshots";
    if (!queue_actions) return "Update Harness on this device and the chat host to use this action";
    if (!step_boundary) return "This agent does not support steering during a turn";
    return null;
}

/// What a send during a run does (`main_action`): a steer only when it can
/// be one, else the queue.
pub fn followUpAction(behavior: FollowUp, unavailable: ?[]const u8) FollowUp {
    return if (behavior == .steer and unavailable == null) .steer else .queue;
}

test "follow-ups steer only when they can, as follow_up.rs decides" {
    const t = std.testing;
    try t.expectEqual(FollowUp.queue, followUpAction(.queue, null));
    try t.expectEqual(FollowUp.steer, followUpAction(.steer, null));
    try t.expectEqual(FollowUp.queue, followUpAction(.steer, "x"));
    try t.expectEqual(FollowUp.steer, opposite(.queue));
    try t.expectEqualStrings("Steer only supports text; remove attachments or screenshots", steerUnavailable(true, true, true, true, true).?);
    try t.expectEqualStrings("Update Harness on this device and the chat host to use this action", steerUnavailable(true, true, false, false, true).?);
    try t.expectEqualStrings("This agent does not support steering during a turn", steerUnavailable(true, true, false, true, false).?);
    try t.expect(steerUnavailable(true, true, false, true, true) == null);
}

test "Codex and GPT-6.0+ models default to Steer; older and non-GPT models default to Queue" {
    const t = std.testing;
    try t.expect(isGpt6PlusModel("gpt-6"));
    try t.expect(isGpt6PlusModel("gpt-6.0"));
    try t.expect(isGpt6PlusModel("gpt-6.1-sol"));
    try t.expect(isGpt6PlusModel("gpt-6-astra"));
    try t.expect(isGpt6PlusModel("gpt-6-sol"));
    try t.expect(isGpt6PlusModel("chatgpt-new/gpt-6.1-sol"));
    try t.expect(isGpt6PlusModel("codex/gpt-6-sol"));
    try t.expect(isGpt6PlusModel("openai:gpt-6.2"));
    try t.expect(isGpt6PlusModel("gpt-7"));
    try t.expect(!isGpt6PlusModel(null));
    try t.expect(!isGpt6PlusModel(""));
    try t.expect(!isGpt6PlusModel("gpt-5.6-sol"));
    try t.expect(!isGpt6PlusModel("gpt-5.4"));
    try t.expect(!isGpt6PlusModel("gpt-4o"));
    try t.expect(!isGpt6PlusModel("claude-opus-5"));
    try t.expect(!isGpt6PlusModel("grok-4.7"));

    try t.expectEqual(FollowUp.steer, defaultFollowUpFor("graff", "gpt-6.1-sol"));
    try t.expectEqual(FollowUp.steer, defaultFollowUpFor("graff", "chatgpt-new/gpt-6.1-sol"));
    try t.expectEqual(FollowUp.steer, defaultFollowUpFor("codex", "gpt-6-sol"));
    try t.expectEqual(FollowUp.steer, defaultFollowUpFor("codex", null));
    try t.expectEqual(FollowUp.queue, defaultFollowUpFor("graff", "gpt-5.6-sol"));
    try t.expectEqual(FollowUp.queue, defaultFollowUpFor("graff", "claude-opus-5"));
    try t.expectEqual(FollowUp.queue, defaultFollowUpFor("graff", null));
    try t.expectEqual(FollowUp.queue, defaultFollowUpFor("codex", "gpt-5.6-sol"));

    var a: App = .init(t.allocator, t.io, 1);
    defer a.deinit();
    a.new_model = try t.allocator.dupe(u8, "gpt-6.1-sol");
    try t.expectEqual(FollowUp.steer, followUpBehavior(&a));
    toggleFollowUp(&a);
    try t.expectEqual(FollowUp.queue, followUpBehavior(&a));
    toggleFollowUp(&a);
    try t.expectEqual(FollowUp.steer, followUpBehavior(&a));
}

/// "With text: …" under the Queue | Steer switch (`follow_up_hint`).
pub fn followUpHint(on_enter: bool, mac: bool) []const u8 {
    if (on_enter) return if (mac)
        "With text: Cmd+Enter uses the opposite behaviour; Cmd+Option+Enter is an alias. Empty: Cmd+Enter sends the newest queued message; the alias does nothing."
    else
        "With text: Ctrl+Enter uses the opposite behaviour; Ctrl+Alt+Enter is an alias. Empty: Ctrl+Enter sends the newest queued message; the alias does nothing.";
    return if (mac) "With text: Cmd+Option+Enter uses the opposite behaviour. Empty composer: no action." else "With text: Ctrl+Alt+Enter uses the opposite behaviour. Empty composer: no action.";
}

test "the follow-up hint tracks the send profile (follow_up_hint_tracks_the_composer_send_profile)" {
    try std.testing.expectEqualStrings("With text: Cmd+Option+Enter uses the opposite behaviour. Empty composer: no action.", followUpHint(false, true));
    try std.testing.expectEqualStrings("With text: Ctrl+Alt+Enter uses the opposite behaviour. Empty composer: no action.", followUpHint(false, false));
}

pub fn harnessSteersMidTurn(a: *const App, harness: []const u8) bool {
    for (a.harnesses.items) |x| {
        if (std.mem.eql(u8, x.id, harness)) return x.steers_mid_turn;
    }
    if (a.harnesses.items.len > 0) return false;
    return std.mem.eql(u8, harness, "graff") or
        std.mem.eql(u8, harness, "codex") or
        std.mem.eql(u8, harness, "claude-code") or
        std.mem.eql(u8, harness, "pi");
}

pub fn targetSteersMidTurn(a: *const App) bool {
    if (a.device_id != null and host(a) != null) return false;
    return harnessSteersMidTurn(a, a.target().harness);
}

pub fn rowCanSteer(a: *const App, r: @import("queue.zig").Row) bool {
    return a.caps.actions and host(a) == null and r.gate == .none and a.queue_edit == null and r.attachments == 0 and targetSteersMidTurn(a);
}

/// Steers an already-queued row into the active turn without interrupting.
pub fn steerRowNow(a: *App, row: []const u8) void {
    const chat = a.selected orelse return;
    a.request(requests.steerQueuedNow(chat, row, host(a)), .of(App, a, onSteered));
}

/// Whether the open chat's run would take a steer now, and if not, why.
pub fn steerBlocker(a: *const App, has_text: bool, has_attachments: bool) ?[]const u8 {
    const chat_id = a.selected orelse return steerUnavailable(false, has_text, has_attachments, false, false);
    const ch = a.findChat(chat_id);
    // The agent list is this device's: it speaks for a chat hosted here.
    const local = if (ch) |c| (if (c.device_id) |d| (if (a.device_id) |mine| std.mem.eql(u8, d, mine) else false) else true) else false;
    const harness = if (ch) |c| (c.harness orelse "graff") else null;
    const steps = local and if (harness) |h| harnessSteersMidTurn(a, h) else false;
    return steerUnavailable(queues(a), has_text, has_attachments, a.caps.actions and host(a) == null, steps);
}

pub const PendingSteer = struct {
    req: u64,
    chat: []u8,
    host: ?[]u8,

    pub fn deinit(s: *PendingSteer, gpa: std.mem.Allocator) void {
        gpa.free(s.chat);
        if (s.host) |h| gpa.free(h);
    }
};

/// A steer: queued like any follow-up, then promoted into the live turn
/// by its row's id (`STEER_QUEUED_MESSAGE_NOW`).
pub fn steer(a: *App, text: []const u8) void {
    const chat = a.selected orelse return;
    const id = a.send_(requests.queueMessage(chat, text), .of(App, a, onQueuedSteer)) orelse return a.setNotice("Send failed: not connected");
    const owned = a.gpa.dupe(u8, chat) catch return;
    const h = if (host(a)) |d| a.gpa.dupe(u8, d) catch null else null;
    a.steers.append(a.gpa, .{ .req = id, .chat = owned, .host = h }) catch {
        a.gpa.free(owned);
        if (h) |x| a.gpa.free(x);
    };
}

fn onQueuedSteer(a: *App, id: u64, r: rpc.Reply) void {
    const at = for (a.steers.items, 0..) |s, i| {
        if (s.req == id) break i;
    } else return;
    var s = a.steers.orderedRemove(at);
    defer s.deinit(a.gpa);
    switch (r) {
        .ok => |v| {
            const row = if (v == .object) (if (v.object.get("id")) |x| (if (x == .string and x.string.len > 0) x.string else null) else null) else null;
            const rid = row orelse return a.setNotice("Send failed: queue did not return an id");
            a.request(requests.steerQueuedNow(s.chat, rid, s.host), .of(App, a, onSteered));
        },
        .err => |e| {
            var buf: [160]u8 = undefined;
            a.setNotice(std.fmt.bufPrint(&buf, "Send failed: {s}", .{e}) catch "Send failed");
        },
        else => {},
    }
    a.redraw();
}

fn onSteered(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| if (!acked(v, "sent")) a.setNotice("Message queued, but the follow-up action was not accepted. Check the queue or transcript."),
        .err => a.setNotice("Message queued, but the follow-up action failed. Check the queue or transcript."),
        else => {},
    }
    a.redraw();
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
    // Keyboard shortcuts and stale row callbacks share the same authority
    // checks as the tray. Never skip a held newest row for an older one.
    if (!a.caps.actions) return;
    const queued = for (a.queue.items) |item| {
        if (std.mem.eql(u8, item.id, row)) break item;
    } else return;
    if (queued.gate != .none) return;
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

fn peerRow(a: *const App, row: []const u8) bool {
    for (a.queue.items) |queued| {
        if (std.mem.eql(u8, queued.id, row)) return !@import("peer_message.zig").editable(queued.text, queued.agent);
    }
    return false;
}

pub fn beginEdit(a: *App, row: []const u8) void {
    const chat = a.selected orelse return;
    // Defend stale click handlers too, not only the current row's hidden
    // Edit affordance. No draft/question/attachment state is touched.
    if (peerRow(a, row)) return a.setNotice("Agent messages stay in the queue, not your composer");
    if (!a.caps.edit_lease) return a.setNotice("Update the chat host to edit queued messages safely");
    if (a.queue_edit != null or a.queue_begin != null) return;
    a.queue_begin = a.gpa.dupe(u8, row) catch return;
    var buf: [36]u8 = undefined;
    const instance = a.instanceId(&buf);
    a.queue_begin_call = a.send_(requests.beginEdit(chat, row, a.device_id orelse "", instance, host(a)), .of(App, a, onBegun));
    a.redraw();
}

fn onBegun(a: *App, _: u64, r: rpc.Reply) void {
    const row = a.queue_begin orelse return;
    defer {
        a.gpa.free(row);
        a.queue_begin = null;
        a.queue_begin_call = null;
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
    const typed_peer = if (str(o, "turnOrigin")) |origin| !std.mem.eql(u8, origin, "human") else false;
    // Acquired text is authoritative and the row may have changed while
    // the request was in flight. Release its lease before suspending the
    // question or stashing/replacing a person's draft.
    if (peerRow(a, row) or !@import("peer_message.zig").editable(text, typed_peer)) {
        if (a.selected) |chat| a.request(requests.finishEdit(chat, row, lease, "cancel", null, null, host(a)), .of(App, a, App.onNotice));
        a.setNotice("Agent messages stay in the queue, not your composer");
        return;
    }
    // The question's page and answer stay parked under its request while
    // the lease editor exclusively owns the composer.
    @import("app_question.zig").suspendQuestion(a);
    a.draft_stash.clearRetainingCapacity();
    a.draft_stash.appendSlice(a.gpa, a.prompt_nav.draftOf(a.composer.text())) catch {};
    a.prompt_nav.retire(a);
    a.queue_edit = .{
        .row = a.gpa.dupe(u8, row) catch return,
        .lease = a.gpa.dupe(u8, lease) catch return,
        .base_hash = a.gpa.dupe(u8, hash) catch return,
        .renew_at = a.now + renew_s,
    };
    // The acquired lease text is authoritative; metadata may also carry
    // refs for rows queued by another client. Never reupload committed refs.
    const paths = for (a.queue.items) |queued| {
        if (std.mem.eql(u8, queued.id, row)) break queued.paths;
    } else &.{};
    @import("app_attachments.zig").restore(a, text, paths) catch {
        a.composer.set(text);
        a.setNotice("Couldn't restore the attachments; the original message is still in the editor.");
    };
    a.redraw();
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn onReleased(_: *App, _: u64, _: rpc.Reply) void {}

pub const Finish = enum { commit, cancel, discard };

/// Ends the edit: saves the composer's text (or, emptied, removes the
/// row), or leaves the row as it was.
pub fn finishEdit(a: *App, action: Finish) void {
    const chat = a.selected orelse return;
    const e = if (a.queue_edit) |*e| e else return;
    if (e.saving) return;
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
    e.finish_call = 0; // synchronous not-connected callback
    const id = a.send_(requests.finishEdit(chat, e.row, e.lease, @tagName(act), if (act == .commit) text else null, if (act == .commit) e.base_hash else null, host(a)), .of(App, a, onFinished));
    if (a.queue_edit) |*live| live.finish_call = id;
}

fn onFinished(a: *App, id: u64, r: rpc.Reply) void {
    const edit = if (a.queue_edit) |*e| e else return;
    if (edit.finish_call != id) return;
    edit.finish_call = null;
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
    if (edit.renew_call) |call| a.engine.cancel(call);
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
    if (e.renew_call) |id| a.engine.cancel(id);
    e.renew_call = 0;
    e.renew_call = a.send_(requests.renewEdit(chat, e.row, e.lease, host(a)), .of(App, a, onRenewed));
    return e.renew_at;
}

fn onRenewed(a: *App, id: u64, r: rpc.Reply) void {
    const e = if (a.queue_edit) |*edit| edit else return;
    if (e.renew_call != id) return;
    e.renew_call = null;
    switch (r) {
        .ok => |v| if (v == .object) {
            const o = str(v.object, "outcome") orelse "";
            if (!std.mem.eql(u8, o, "renewed")) a.setNotice("Edit protection expired; review this message before sending");
        },
        .err => a.setNotice("Edit protection expired; review this message before sending"),
        else => {},
    }
}

test "capabilities are read by name" {
    const list = [_]std.json.Value{ .{ .string = "message-queue-v1" }, .{ .string = "message-queue-edit-lease-v1" } };
    const c = readCaps(&list);
    try std.testing.expect(c.queue and c.edit_lease and !c.actions);
}
