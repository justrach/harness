//! Paged, host-routed repository history. Git stays in the engine; the UI
//! never spawns git or gh, mutates an index, or adds its own polling loop.
const std = @import("std");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");

pub const page_size = 50;
pub const Ref = struct { kind: []const u8, label: []const u8 };
pub const Commit = struct {
    sha: []const u8,
    subject: []const u8,
    authorName: []const u8,
    authoredAt: []const u8,
    parentShas: []const []const u8 = &.{},
    refs: []const Ref = &.{},
};
pub const Page = struct {
    commits: []const Commit,
    headSha: ?[]const u8 = null,
    nextCursor: ?usize = null,
    totalCount: ?usize = null,
    comparison: ?struct { base: []const u8, ahead: usize, behind: usize } = null,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    page: Page,

    pub fn parse(gpa: std.mem.Allocator, value: std.json.Value) !Snapshot {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const page = try std.json.parseFromValueLeaky(Page, arena.allocator(), value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (page.commits.len > page_size) return error.OversizedHistoryPage;
        return .{ .arena = arena, .page = page };
    }
};
const Target = struct {
    arena: std.heap.ArenaAllocator,
    chat: []const u8,
    cwd: []const u8,
    device: []const u8,
    branch: []const u8,
};
pub const State = struct {
    target: ?Target = null,
    snapshot: ?Snapshot = null,
    pending: ?u64 = null,
    cursor: usize = 0,
    requested_cursor: usize = 0,
    error_text: ?[]u8 = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.target) |*t| t.arena.deinit();
        if (s.snapshot) |*p| p.arena.deinit();
        if (s.error_text) |e| gpa.free(e);
        s.* = .{};
    }
};

pub fn open(a: *App, kind: @import("app_panels.zig").TabKind) void {
    std.debug.assert(kind == .git or kind == .github);
    const p = &a.panels;
    for (p.tabs.items, 0..) |tab, i| if (tab.kind == kind) {
        p.host_open = true;
        return @import("app_panels.zig").showTab(a, i);
    };
    p.tabs.append(a.gpa, .{ .kind = kind }) catch return;
    p.host_open = true;
    a.view.strip.focused = .host;
    @import("app_panels.zig").showTab(a, p.tabs.items.len - 1);
}

pub fn reset(a: *App) void {
    const s = &a.panels.history;
    if (s.pending) |id| a.engine.cancel(id);
    if (s.target) |t| a.retireArena(t.arena);
    if (s.snapshot) |p| a.retireArena(p.arena);
    if (s.error_text) |e| a.retireSlice(e);
    s.* = .{};
}

/// A chat can change checkout or branch without changing its ID. Cancel the
/// old host request before its delayed reply can populate the new context.
pub fn reconcile(a: *App) void {
    const t = a.panels.history.target orelse return;
    const chat = if (a.selected) |id| a.findChat(id) else null;
    if (chat) |ch| if (std.mem.eql(u8, t.chat, ch.id) and std.mem.eql(u8, t.cwd, ch.cwd orelse "") and
        std.mem.eql(u8, t.device, ch.device_id orelse "") and std.mem.eql(u8, t.branch, ch.branch orelse "")) return;
    reset(a);
    if (a.panels.host_open) if (a.panels.activeTab()) |tab| if (tab.kind == .git) load(a, 0);
}

pub fn load(a: *App, cursor: usize) void {
    const s = &a.panels.history;
    if (s.pending != null) return;
    const id = a.selected orelse return;
    const chat = a.findChat(id) orelse return;
    const cwd = chat.cwd orelse return;
    if (s.target == null) {
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        const alloc = arena.allocator();
        const target: Target = .{
            .arena = arena,
            .chat = alloc.dupe(u8, id) catch {
                arena.deinit();
                return;
            },
            .cwd = alloc.dupe(u8, cwd) catch {
                arena.deinit();
                return;
            },
            .device = alloc.dupe(u8, chat.device_id orelse "") catch {
                arena.deinit();
                return;
            },
            .branch = alloc.dupe(u8, chat.branch orelse "") catch {
                arena.deinit();
                return;
            },
        };
        // Keep the arena's final state, not its pre-allocation copy.
        s.target = target;
        s.target.?.arena = arena;
    }
    if (s.error_text) |e| a.retireSlice(e);
    s.error_text = null;
    if (!a.engine.up()) {
        s.error_text = a.gpa.dupe(u8, "Connect to the checkout's host to load Git history.") catch null;
        return;
    }
    const host = if (chat.device_id) |d| (if (a.device_id != null and std.mem.eql(u8, d, a.device_id.?)) null else d) else null;
    s.requested_cursor = cursor;
    s.pending = a.send_(requests.gitHistory(cwd, cursor, host), .of(App, a, onPage));
    if (s.pending == null) s.error_text = a.gpa.dupe(u8, "Could not request Git history. Refresh to retry.") catch null;
    a.redraw();
}

fn onPage(a: *App, id: u64, reply: rpc.Reply) void {
    const s = &a.panels.history;
    if (s.pending != id) return;
    switch (reply) {
        .ok => |v| {
            s.pending = null;
            const next = Snapshot.parse(a.gpa, v) catch {
                s.error_text = a.gpa.dupe(u8, "The host returned an invalid Git history page.") catch null;
                return a.redraw();
            };
            if (s.snapshot) |old| a.retireArena(old.arena);
            s.snapshot = next;
            s.cursor = s.requested_cursor;
        },
        .err => {
            s.pending = null;
            // Keep process output out of the UI: it can contain credentials
            // from remote URLs. The existing diff panel has detailed errors.
            s.error_text = a.gpa.dupe(u8, "Git history is unavailable. Check that this checkout is a Git repository and its host is online.") catch null;
        },
        .done => s.pending = null,
        .item => return,
    }
    a.redraw();
}

pub fn previousCursor(cursor: usize) usize {
    return cursor -| page_size;
}
