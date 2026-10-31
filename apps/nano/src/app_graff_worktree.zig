//! The session footer's Graff worktree actions (pickers.rs
//! `run_graff_worktree_action`): one at a time, the chat it runs for
//! marked busy, then Graff's verdict kept under the chat's id.
const std = @import("std");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const graff_worktree = @import("graff_worktree.zig");
const App = @import("app.zig").App;

/// `GraffWorktreeOutcome`.
pub const Outcome = enum { done, kept, failed };

/// `GraffWorktreeStatus`: Graff's last word on a chat's tree.
pub const Status = struct {
    chat_id: []u8,
    outcome: Outcome,
    /// Graff said the tree holds work found nowhere else: "Discard anyway".
    can_discard: bool,
    message: []u8,
};

pub const State = struct {
    /// The chat an action runs for, and its tree's path (owned).
    busy: ?[]u8 = null,
    busy_tree: []u8 = &.{},
    status: ?Status = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.clearBusy(gpa);
        s.clearStatus(gpa);
    }

    fn clearBusy(s: *State, gpa: std.mem.Allocator) void {
        if (s.busy) |b| gpa.free(b);
        gpa.free(s.busy_tree);
        s.busy = null;
        s.busy_tree = &.{};
    }

    fn clearStatus(s: *State, gpa: std.mem.Allocator) void {
        if (s.status) |st| {
            gpa.free(st.chat_id);
            gpa.free(st.message);
        }
        s.status = null;
    }

    /// The verdict shown for `chat_id`, if it's that chat's.
    pub fn statusFor(s: *const State, chat_id: []const u8) ?Status {
        const st = s.status orelse return null;
        return if (std.mem.eql(u8, st.chat_id, chat_id)) st else null;
    }
};

/// Asks the engine to `action` the chat's tree, on the chat's computer.
pub fn run(a: *App, chat_id: []const u8, action: []const u8) void {
    const s = &a.graff_worktree;
    if (s.busy != null) return;
    const chat = a.findChat(chat_id) orelse return;
    const local = a.device_id orelse "";
    const host: ?[]const u8 = if (chat.device_id) |d| (if (std.mem.eql(u8, d, local)) null else d) else null;
    s.clearStatus(a.gpa);
    s.busy = a.gpa.dupe(u8, chat_id) catch return;
    s.busy_tree = a.gpa.dupe(u8, chat.cwd orelse "") catch &.{};
    a.request(requests.graffWorktreeAction(chat_id, action, host), .of(App, a, onReply));
    a.redraw();
}

fn onReply(a: *App, _: u64, reply: rpc.Reply) void {
    const s = &a.graff_worktree;
    const chat_id = s.busy orelse return;
    var outcome: Outcome = .failed;
    var message: []const u8 = "";
    switch (reply) {
        .ok => |v| if (v == .object) {
            const o = v.object;
            if (o.get("outcome")) |x| if (x == .string) {
                if (std.mem.eql(u8, x.string, "done")) outcome = .done else if (std.mem.eql(u8, x.string, "kept")) outcome = .kept;
            };
            if (o.get("message")) |x| if (x == .string) {
                message = x.string;
            };
        },
        .err => |e| message = e,
        else => return,
    }
    apply(a, chat_id, outcome, message);
}

/// Records Graff's verdict for the busy chat's tree and ends the wait.
pub fn apply(a: *App, chat_id: []const u8, outcome: Outcome, message: []const u8) void {
    const s = &a.graff_worktree;
    var buf: [400]u8 = undefined;
    const line = graff_worktree.statusLine(&buf, message, s.busy_tree);
    const id = a.gpa.dupe(u8, chat_id) catch return;
    const text = a.gpa.dupe(u8, line) catch {
        a.gpa.free(id);
        return;
    };
    s.clearBusy(a.gpa);
    s.clearStatus(a.gpa);
    s.status = .{
        .chat_id = id,
        .outcome = outcome,
        .can_discard = outcome != .done and (std.mem.indexOf(u8, message, "--discard") != null or std.mem.indexOf(u8, message, "ONLY on this branch") != null),
        .message = text,
    };
    a.redraw();
}
