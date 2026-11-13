//! UI-only send feedback. Never insert speculative rows into the document:
//! its count and cursors belong to WatchDocMessages, not this window.
const std = @import("std");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const tr = @import("transcript.zig");

pub const Pending = struct {
    app: *App,
    chat: []u8,
    message: []u8,
    part: tr.Part,
    started_ms: i64,
    finished: bool = false,
    rejected: bool = false,
    /// A remote Run command is presentation only: it owns no local retry/draft.
    remote: bool = false,
    withdrawn: bool = false,
    delivery_pending: bool = false,
    waiting_for_attachments: bool = false,

    pub fn entry(p: *Pending) tr.Entry {
        return .{
            .id = p.message,
            .role = .user,
            .status = .complete,
            .parts = .fromOwnedSlice(@as([*]tr.Part, @ptrCast(&p.part))[0..1]),
        };
    }

    pub fn onReply(p: *Pending, id: u64, reply: rpc.Reply) void {
        switch (reply) {
            .ok, .done => p.finished = true,
            .err => {
                p.finished = true;
                p.rejected = true;
            },
            .item => {},
        }
        App.onNotice(p.app, id, reply);
        p.app.redraw();
    }

    fn destroy(p: *Pending) void {
        const gpa = p.app.gpa;
        gpa.free(p.chat);
        gpa.free(p.message);
        p.part.text.deinit(gpa);
        gpa.destroy(p);
    }
};

pub fn begin(a: *App, chat: []const u8, message: []const u8, prompt: []const u8) !*Pending {
    const p = try a.gpa.create(Pending);
    errdefer a.gpa.destroy(p);
    const owned_chat = try a.gpa.dupe(u8, chat);
    errdefer a.gpa.free(owned_chat);
    const owned_message = try a.gpa.dupe(u8, message);
    errdefer a.gpa.free(owned_message);
    var part: tr.Part = .{ .id = &.{}, .kind = .text };
    errdefer part.text.deinit(a.gpa);
    try part.text.appendSlice(a.gpa, prompt);
    p.* = .{ .app = a, .chat = owned_chat, .message = owned_message, .part = part, .started_ms = a.nowMs() };
    try a.pending_sends.append(a.gpa, p);
    return p;
}

pub fn echoed(p: *const Pending, t: *const tr.Transcript) bool {
    for (t.entries.items) |e| if (std.mem.eql(u8, e.id, p.message)) return true;
    return false;
}

pub fn visible(p: *const Pending, chat: []const u8, t: *const tr.Transcript) bool {
    return !p.rejected and !p.withdrawn and std.mem.eql(u8, p.chat, chat) and !echoed(p, t);
}

pub fn active(a: *const App, chat: []const u8, t: *const tr.Transcript) ?*Pending {
    for (a.pending_sends.items) |p| if (visible(p, chat, t)) return p;
    return null;
}

/// A full WatchQueue snapshot can arrive before WatchDocMessages on any device.
/// Keep its UI-only entries out of delivery acknowledgements and local draft recovery.
pub fn syncRemote(a: *App, chat: []const u8, value: std.json.Value) void {
    const list: []const std.json.Value = blk: {
        if (value != .object) break :blk &.{};
        const items = value.object.get("pendingPrompts") orelse break :blk &.{};
        if (items != .array) break :blk &.{};
        break :blk items.array.items;
    };
    for (a.pending_sends.items) |p| if (std.mem.eql(u8, p.chat, chat)) {
        p.delivery_pending = false;
        if (p.remote) p.withdrawn = true;
    };
    for (list) |item| {
        if (item != .object) continue;
        const id = item.object.get("messageId") orelse continue;
        const text = item.object.get("text") orelse continue;
        const issued = item.object.get("issuedAt") orelse continue;
        if (id != .string or id.string.len == 0 or text != .string or issued != .integer or issued.integer <= 0) continue;
        const millis = std.math.mul(i64, issued.integer, 1000) catch continue;
        const attached = item.object.get("waitingForAttachments");
        const waiting = if (attached) |v| (v == .bool and v.bool) else false;
        var found: ?*Pending = null;
        var i = a.pending_sends.items.len;
        while (i > 0) {
            i -= 1;
            const p = a.pending_sends.items[i];
            if (p.rejected or (!p.remote and p.withdrawn) or !std.mem.eql(u8, p.chat, chat) or !std.mem.eql(u8, p.message, id.string)) continue;
            if (!std.mem.eql(u8, p.part.text.items, text.string)) {
                // Keep the previous frame's borrowed text alive until reap().
                p.withdrawn = true;
                continue;
            }
            found = p;
            break;
        }
        const p = found orelse blk: {
            const made = begin(a, chat, id.string, text.string) catch continue;
            made.remote = true;
            made.finished = true;
            break :blk made;
        };
        p.started_ms = @min(p.started_ms, millis);
        p.withdrawn = false;
        p.delivery_pending = true;
        p.waiting_for_attachments = waiting;
    }
    a.redraw();
}

pub fn clearRemote(a: *App, chat: []const u8) void {
    for (a.pending_sends.items) |p| if (p.remote and std.mem.eql(u8, p.chat, chat)) {
        p.withdrawn = true;
    };
}

/// At a frame boundary only: the previous layout can still reference the
/// prompt, and a pending RPC handler must outlive even an early doc echo.
pub fn reap(a: *App) void {
    var i: usize = 0;
    while (i < a.pending_sends.items.len) {
        const p = a.pending_sends.items[i];
        const t = if (a.selected != null and std.mem.eql(u8, a.selected.?, p.chat)) &a.transcript else if (a.peer(p.chat)) |peer| &peer.transcript else null;
        if (p.finished and (p.rejected or p.withdrawn or (t != null and echoed(p, t.?)))) {
            // Restore failed sends only at this boundary, including immediate
            // errors delivered before send() has cleared the composer.
            if (p.rejected and !p.remote and !p.withdrawn) {
                if (a.selected != null and std.mem.eql(u8, a.selected.?, p.chat)) {
                    if (a.wizard != null or a.queue_edit != null) {
                        // A borrowed composer is an answer/leased queue row,
                        // not the prompt that failed. Recovery belongs behind
                        // it and must never replace even an empty answer.
                        if (a.draft_stash.items.len == 0) a.draft_stash.appendSlice(a.gpa, p.part.text.items) catch {};
                    } else if (a.composer.text().len == 0) a.composer.set(p.part.text.items);
                } else if (!a.drafts.contains(p.chat)) {
                    const key = a.gpa.dupe(u8, p.chat) catch break;
                    const value = a.gpa.dupe(u8, p.part.text.items) catch {
                        a.gpa.free(key);
                        break;
                    };
                    a.drafts.put(a.gpa, key, value) catch {
                        a.gpa.free(key);
                        a.gpa.free(value);
                        break;
                    };
                }
            }
            _ = a.pending_sends.orderedRemove(i);
            p.destroy();
        } else i += 1;
    }
}

pub fn deinit(a: *App) void {
    for (a.pending_sends.items) |p| p.destroy();
    a.pending_sends.deinit(a.gpa);
    // App.deinit also reaps its retired transcript rows after this point.
    a.pending_sends = .empty;
}
