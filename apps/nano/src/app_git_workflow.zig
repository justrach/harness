//! Explicit checkout mutations. Every action uses the last host snapshot's
//! checkout/checksum fences; a failed or cancelled call is never retried.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");

pub const File = struct {
    path: []const u8,
    indexStatus: []const u8,
    worktreeStatus: []const u8,
    pub fn staged(f: File) bool {
        return changed(f.indexStatus) and !std.mem.eql(u8, f.indexStatus, "?");
    }
    pub fn unstaged(f: File) bool {
        return changed(f.worktreeStatus) or std.mem.eql(u8, f.indexStatus, "?");
    }
};
fn changed(status: []const u8) bool {
    return status.len > 0 and !std.mem.eql(u8, status, " ");
}
pub const Page = struct {
    checkoutId: []const u8,
    checksum: []const u8,
    branch: ?[]const u8 = null,
    headSha: ?[]const u8 = null,
    files: []const File,
    upstream: ?struct { remote: []const u8, branch: []const u8 } = null,
    blockedReason: ?[]const u8 = null,
    pub fn stagedCount(p: Page) usize {
        var count: usize = 0;
        for (p.files) |f| {
            if (f.staged()) count += 1;
        }
        return count;
    }
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    page: Page,
    pub fn parse(gpa: std.mem.Allocator, value: std.json.Value) !Snapshot {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const page = try std.json.parseFromValueLeaky(Page, arena.allocator(), value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (page.files.len > 2000 or page.checkoutId.len == 0 or page.checksum.len == 0) return error.InvalidGitState;
        return .{ .arena = arena, .page = page };
    }
};
const Target = struct { arena: std.heap.ArenaAllocator, chat: []const u8, cwd: []const u8, device: []const u8, branch: []const u8 };
pub const Confirm = enum { commit, push };
pub const State = struct {
    open: bool = false,
    target: ?Target = null,
    snapshot: ?Snapshot = null,
    pending: ?u64 = null,
    action_kind: ?requests.GitActionKind = null,
    confirm: ?Confirm = null,
    message: ui.TextBuffer = .{},
    error_text: ?[]u8 = null,
    notice: ?[]const u8 = null,
    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.target) |*t| t.arena.deinit();
        if (s.snapshot) |*p| p.arena.deinit();
        if (s.error_text) |e| gpa.free(e);
        @import("text_buffer.zig").deinit(&s.message);
    }
};

pub fn reset(a: *App) void {
    const s = &a.panels.git_workflow;
    if (s.pending) |id| a.engine.cancel(id);
    if (s.target) |t| a.retireArena(t.arena);
    if (s.snapshot) |p| a.retireArena(p.arena);
    if (s.error_text) |e| a.retireSlice(e);
    @import("text_buffer.zig").deinit(&s.message);
    s.* = .{};
}
pub fn reconcile(a: *App) void {
    const s = &a.panels.git_workflow;
    const t = s.target orelse return;
    const ch = if (a.selected) |id| a.findChat(id) else null;
    if (ch) |chat| if (std.mem.eql(u8, t.chat, chat.id) and std.mem.eql(u8, t.cwd, chat.cwd orelse "") and
        std.mem.eql(u8, t.device, chat.device_id orelse "") and std.mem.eql(u8, t.branch, chat.branch orelse "")) return;
    const was_open = s.open;
    reset(a);
    s.open = was_open;
    if (was_open and a.panels.host_open) load(a);
}
pub fn show(a: *App) void {
    a.panels.git_workflow.open = true;
    load(a);
    a.redraw();
}
pub fn load(a: *App) void {
    const s = &a.panels.git_workflow;
    if (s.pending != null) return;
    const id = a.selected orelse return;
    const ch = a.findChat(id) orelse return;
    const cwd = ch.cwd orelse return;
    if (s.target == null) {
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        const alloc = arena.allocator();
        const chat_copy = alloc.dupe(u8, id) catch {
            arena.deinit();
            return;
        };
        const cwd_copy = alloc.dupe(u8, cwd) catch {
            arena.deinit();
            return;
        };
        const device = alloc.dupe(u8, ch.device_id orelse "") catch {
            arena.deinit();
            return;
        };
        const branch = alloc.dupe(u8, ch.branch orelse "") catch {
            arena.deinit();
            return;
        };
        s.target = .{ .arena = arena, .chat = chat_copy, .cwd = cwd_copy, .device = device, .branch = branch };
    }
    clearError(a);
    s.confirm = null;
    s.notice = null;
    s.action_kind = null;
    if (!a.engine.up()) return fail(a, "Connect to the checkout's host, then refresh Git changes.");
    s.pending = a.send_(requests.gitState(id, host(a)), .of(App, a, onReply));
    if (s.pending == null) fail(a, "Could not load Git changes. Refresh to retry.");
    a.redraw();
}
fn host(a: *App) ?[]const u8 {
    const t = a.panels.git_workflow.target orelse return null;
    return if (t.device.len == 0 or (a.device_id != null and std.mem.eql(u8, t.device, a.device_id.?))) null else t.device;
}
pub fn canAct(a: *const App) bool {
    const s = &a.panels.git_workflow;
    const snap = s.snapshot orelse return false;
    return s.pending == null and s.error_text == null and snap.page.blockedReason == null and a.engine.up();
}
pub fn canCommit(a: *const App) bool {
    if (!canAct(a)) return false;
    const s = &a.panels.git_workflow;
    const message = std.mem.trim(u8, s.message.text(), " \t\r\n");
    return s.snapshot.?.page.stagedCount() > 0 and message.len > 0 and s.message.text().len <= 4096;
}
pub fn canPush(a: *const App) bool {
    if (!canAct(a)) return false;
    const p = a.panels.git_workflow.snapshot.?.page;
    return p.upstream != null and p.headSha != null and p.branch != null;
}
pub fn arm(a: *App, kind: Confirm) void {
    if (if (kind == .commit) canCommit(a) else canPush(a)) a.panels.git_workflow.confirm = kind;
    a.redraw();
}
pub fn cancel(a: *App) void {
    a.panels.git_workflow.confirm = null;
    a.redraw();
}
pub fn confirm(a: *App) void {
    const kind = a.panels.git_workflow.confirm orelse return;
    if (kind == .commit) {
        if (canCommit(a)) apply(a, .{ .kind = .commit, .message = a.panels.git_workflow.message.text() });
    } else if (canPush(a)) apply(a, .{ .kind = .push });
}
pub fn fileAction(a: *App, path: []const u8, stage: bool) void {
    const s = &a.panels.git_workflow;
    if (s.confirm != null or !canAct(a)) return;
    for (s.snapshot.?.page.files) |f| if (std.mem.eql(u8, path, f.path) and (if (stage) f.unstaged() else f.staged())) {
        return apply(a, .{ .kind = if (stage) .stage else .unstage, .path = path });
    };
}
fn apply(a: *App, action: requests.GitAction) void {
    const s = &a.panels.git_workflow;
    const t = s.target orelse return;
    const p = s.snapshot.?.page;
    s.confirm = null;
    s.notice = null;
    s.action_kind = action.kind;
    s.pending = a.send_(requests.gitAction(t.chat, p.checkoutId, p.checksum, action, host(a)), .of(App, a, onReply));
    if (s.pending == null) fail(a, "The Git action was not sent. Refresh before retrying.");
    a.redraw();
}
fn clearError(a: *App) void {
    const s = &a.panels.git_workflow;
    if (s.error_text) |e| a.retireSlice(e);
    s.error_text = null;
}
fn fail(a: *App, text: []const u8) void {
    clearError(a);
    a.panels.git_workflow.error_text = a.gpa.dupe(u8, text) catch null;
    a.redraw();
}
/// Only fixed host-owned errors are safe to display. Never pass through a
/// provider/transport/hook string, even if it resembles a recognized prefix.
pub fn friendlyError(message: []const u8, mutation: bool) []const u8 {
    const safe = [_][]const u8{
        "An agent is active in this working tree",
        "Chat checkout changed; refresh and retry",
        "Checkout changed while reading; refresh and retry",
        "Checkout changed; refresh and retry",
        "Git action failed; inspect hooks, identity, authentication or remote state in a terminal, then refresh",
        "Git timed out; refresh state before retrying",
        "No single existing upstream is configured; set one in a terminal first",
        "Push is unavailable for mirror remotes; use a terminal",
        "Resolve merge conflicts in a terminal first",
        "Finish the in-progress Git operation in a terminal first",
        "Detached HEAD: switch to a branch in a terminal first",
        "Large or special file blocks the native Git workflow",
        "Symlink or unreadable path blocks the native Git workflow",
        "Changed content exceeds the native Git workflow limit",
        "Too many changed files for the native Git workflow",
        "Git state exceeds the native workflow limit",
        "Git state contains unsupported non-UTF-8 paths",
        "Native Git mutations require safe descriptor-relative filesystem access on this host",
        "Stage changes before committing",
    };
    for (safe) |known| if (std.mem.eql(u8, message, known)) return known;
    return if (mutation) "Git action did not complete successfully. Refresh to check the actual state before retrying. The checkout may have changed, an agent may be active, or Git may need attention in a terminal." else "Git changes are unavailable. Check the checkout and its host, then refresh.";
}
fn onReply(a: *App, id: u64, reply: rpc.Reply) void {
    const s = &a.panels.git_workflow;
    if (s.pending != id) return;
    if (reply == .item) return;
    s.pending = null;
    const action = s.action_kind;
    s.action_kind = null;
    switch (reply) {
        .ok => |v| {
            const next = Snapshot.parse(a.gpa, v) catch return fail(a, "The host returned invalid Git state. Refresh before continuing.");
            if (s.snapshot) |old| a.retireArena(old.arena);
            s.snapshot = next;
            if (action) |kind| {
                s.notice = switch (kind) {
                    .stage => "File staged.",
                    .unstage => "File unstaged; working file kept.",
                    .commit => "Staged changes committed.",
                    .push => "Push completed.",
                };
                if (kind == .commit) s.message.set("");
                // History and diff have independent snapshots. History reloads
                // when revisited; the existing checkout-diff watch updates diffs.
                if (a.panels.history.snapshot) |old| a.retireArena(old.arena);
                a.panels.history.snapshot = null;
            }
        },
        .err => |message| return fail(a, friendlyError(message, action != null)),
        .done => return fail(a, "Git reply ended without a result. Refresh to check the actual state; no action will be retried automatically."),
        .item => unreachable,
    }
    a.redraw();
}
