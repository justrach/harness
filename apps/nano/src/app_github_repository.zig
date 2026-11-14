//! Explicit, read-only repository GitHub requests. No poller, local gh
//! process, token store or provider-supplied executable links in the view.
const std = @import("std");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
pub const Kind = requests.GitHubKind;
pub const Filter = requests.GitHubFilter;
pub const Repository = struct { key: []const u8, host: []const u8, owner: []const u8, name: []const u8, url: []const u8 };
pub const Item = struct { number: u64, title: []const u8, url: []const u8, state: []const u8, isDraft: bool = false, author: []const u8, updatedAt: []const u8 };
pub const Detail = struct {
    number: u64,
    title: []const u8,
    url: []const u8,
    state: []const u8,
    body: []const u8,
    author: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    isDraft: bool = false,
    baseRef: ?[]const u8 = null,
    headRef: ?[]const u8 = null,
    additions: ?u64 = null,
    deletions: ?u64 = null,
    changedFiles: ?u64 = null,
};
pub const File = struct {
    filename: []const u8,
    status: []const u8,
    additions: u64,
    deletions: u64,
    patch: ?[]const u8 = null,
    previousFilename: ?[]const u8 = null,
    patchTruncated: bool = false,
};
pub const Event = struct { id: []const u8, event: []const u8, author: []const u8, createdAt: []const u8, body: ?[]const u8 = null, commitSha: ?[]const u8 = null };
pub const Page = struct {
    repository: Repository,
    kind: Kind,
    items: []const Item = &.{},
    detail: ?Detail = null,
    files: []const File = &.{},
    events: []const Event = &.{},
    page: usize = 1,
    hasNextPage: bool = false,
    truncated: bool = false,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    page: Page,
    pub fn parse(gpa: std.mem.Allocator, value: std.json.Value) !Snapshot {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const page = try std.json.parseFromValueLeaky(Page, arena.allocator(), value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (page.page == 0 or page.items.len > 30 or page.files.len > 30 or page.events.len > 30 or
            !std.mem.eql(u8, page.repository.host, "github.com") or page.repository.key.len == 0 or
            !validPart(page.repository.owner) or !validPart(page.repository.name)) return error.InvalidGitHubPage;
        return .{ .arena = arena, .page = page };
    }
};
fn validPart(part: []const u8) bool {
    if (part.len == 0 or part.len > 100 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}
const Target = struct { arena: std.heap.ArenaAllocator, chat: []const u8, cwd: []const u8, device: []const u8, branch: []const u8 };
const Linked = struct { arena: std.heap.ArenaAllocator, repository: Repository };
pub const State = struct {
    images: @import("github_images.zig").Cache = .{},
    /// Surface identity is the opening chat, never whichever split has focus.
    owner: ?[]u8 = null,
    open: bool = false,
    target: ?Target = null,
    linked: ?Linked = null,
    after_detail: ?Kind = null,
    list: ?Snapshot = null,
    details: ?Snapshot = null,
    content: ?Snapshot = null,
    pending: ?u64 = null,
    kind: Kind = .pulls,
    list_kind: Kind = .pulls,
    selected_kind: Kind = .pull,
    filter: Filter = .open,
    number: ?u64 = null,
    requested_page: usize = 1,
    expanded_file: ?usize = null,
    error_text: ?[]u8 = null,
    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.images.deinit();
        if (s.owner) |id| gpa.free(id);
        if (s.target) |*t| t.arena.deinit();
        if (s.linked) |*link| link.arena.deinit();
        if (s.list) |*p| p.arena.deinit();
        if (s.details) |*p| p.arena.deinit();
        if (s.content) |*p| p.arena.deinit();
        if (s.error_text) |e| gpa.free(e);
    }
    pub fn repository(s: *const State) ?Repository {
        if (s.linked) |link| return link.repository;
        if (s.list) |l| return l.page.repository;
        return if (s.details) |d| d.page.repository else null;
    }
    pub fn current(s: *const State) ?Page {
        return switch (s.kind) {
            .pulls, .issues => if (s.list) |l| (if (l.page.kind == s.kind) l.page else null) else null,
            .pull, .issue => if (s.details) |d| d.page else null,
            .files, .activity => if (s.content) |p| (if (p.page.kind == s.kind) p.page else null) else null,
        };
    }
};
fn clearError(a: *App) void {
    const s = &a.panels.github_repository;
    if (s.error_text) |e| a.retireSlice(e);
    s.error_text = null;
}
fn fail(a: *App, text: []const u8) void {
    clearError(a);
    a.panels.github_repository.error_text = a.gpa.dupe(u8, text) catch null;
    a.redraw();
}
fn clearSnapshots(a: *App) void {
    const s = &a.panels.github_repository;
    s.images.reset();
    if (s.list) |p| a.retireArena(p.arena);
    if (s.details) |p| a.retireArena(p.arena);
    if (s.content) |p| a.retireArena(p.arena);
    s.list = null;
    s.details = null;
    s.content = null;
    s.number = null;
    s.after_detail = null;
    s.expanded_file = null;
}
pub fn reset(a: *App) void {
    const s = &a.panels.github_repository;
    if (s.pending) |id| a.engine.cancel(id);
    clearSnapshots(a);
    clearError(a);
    if (s.target) |t| a.retireArena(t.arena);
    if (s.owner) |id| a.retireSlice(id);
    if (s.linked) |link| a.retireArena(link.arena);
    const images = s.images;
    s.* = .{ .images = images };
}
pub fn reconcile(a: *App) void {
    const s = &a.panels.github_repository;
    const t = s.target orelse return;
    const ch = if (s.owner) |id| a.findChat(id) else null;
    if (ch) |chat| if (std.mem.eql(u8, t.chat, chat.id) and std.mem.eql(u8, t.cwd, chat.cwd orelse "") and
        std.mem.eql(u8, t.device, chat.device_id orelse "") and std.mem.eql(u8, t.branch, chat.branch orelse "")) return;
    const was_open = s.open;
    const owner = if (s.owner) |id| a.gpa.dupe(u8, id) catch null else null;
    reset(a);
    s.owner = owner;
    if (was_open and ch != null and a.panels.host_open) show(a);
}
/// Called pre-tree after the transcript link's conversation owner is revalidated.
/// Opens a specific item directly: it need not appear on the first open-PR page.
pub fn openLinked(a: *App, target: @import("github_link.zig").Target) void {
    if (!validPart(target.owner) or !validPart(target.name) or target.number == 0 or target.number > std.math.maxInt(i64)) return;
    const link = makeLinked(a.gpa, target) catch return;
    reset(a);
    @import("app_git.zig").open(a, .github);
    a.view.strip.focused = .host;
    a.view.strip.expanded = null;
    const s = &a.panels.github_repository;
    s.linked = link;
    s.open = true;
    s.list_kind = if (target.kind == .pull) .pulls else .issues;
    s.selected_kind = if (target.kind == .pull) .pull else .issue;
    s.kind = s.selected_kind;
    s.number = target.number;
    s.filter = .all;
    s.after_detail = switch (target.section) {
        .summary => null,
        .code => .files,
        .activity => .activity,
    };
    load(a, s.selected_kind, 1);
}

fn makeLinked(gpa: std.mem.Allocator, target: @import("github_link.zig").Target) !Linked {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const owner = try alloc.dupe(u8, target.owner);
    const name = try alloc.dupe(u8, target.name);
    const raw_key = try std.fmt.allocPrint(alloc, "github.com/{s}/{s}", .{ owner, name });
    const key = try std.ascii.allocLowerString(alloc, raw_key);
    const url = try std.fmt.allocPrint(alloc, "https://github.com/{s}/{s}", .{ owner, name });
    return .{ .arena = arena, .repository = .{ .key = key, .host = "github.com", .owner = owner, .name = name, .url = url } };
}

/// Explicit opening may reparent the one GitHub surface. Ordinary focus,
/// hide/reopen and repository navigation must not.
pub fn bind(a: *App) void {
    const id = a.selected orelse return;
    const s = &a.panels.github_repository;
    if (s.owner) |owner| if (std.mem.eql(u8, owner, id)) return;
    const owned = a.gpa.dupe(u8, id) catch return;
    reset(a);
    s.owner = owned;
}

pub fn surface(a: *const App) bool {
    const t = a.panels.activeTab() orelse return false;
    return t.kind == .github;
}

/// Only attach to a visible instance of the owning chat. A different global
/// workspace, parked panel tab or zoomed neighbor must not inherit its child.
pub fn parentPane(a: *const App) ?usize {
    const id = a.panels.github_repository.owner orelse return null;
    if (a.tabs.layout()) |s| {
        for (s.panes.items, 0..) |parked, ix| {
            if (s.zoomed and ix != s.focus) continue;
            const chat = (if (ix == s.focus) a.selected else parked) orelse continue;
            if (std.mem.eql(u8, chat, id)) return ix;
        }
        return null;
    }
    return if (a.selected != null and std.mem.eql(u8, a.selected.?, id)) 0 else null;
}

pub fn ownerTitle(a: *const App) []const u8 {
    const id = a.panels.github_repository.owner orelse return "Conversation";
    const chat = a.findChat(id) orelse return "Conversation";
    return @import("view_sidebar.zig").chatLabel(chat);
}

pub fn show(a: *App) void {
    const s = &a.panels.github_repository;
    s.open = true;
    // Re-showing a child after split focus must not turn a linked detail
    // into a list request just because that list was never loaded.
    if (s.current() == null and s.pending == null) load(a, s.kind, 1);
    a.redraw();
}
pub fn hide(a: *App) void {
    const s = &a.panels.github_repository;
    // Sessions belong to the current checkout, not an explicitly linked repo.
    if (s.linked != null) {
        const owner = if (s.owner) |id| a.gpa.dupe(u8, id) catch null else null;
        reset(a);
        s.owner = owner;
        return a.redraw();
    }
    if (s.pending) |id| a.engine.cancel(id);
    s.pending = null;
    s.open = false;
    // An interrupted detail request must not leave an unpopulated detail view.
    s.kind = s.list_kind;
    a.redraw();
}
pub fn refresh(a: *App) void {
    const s = &a.panels.github_repository;
    if (s.pending != null) return;
    if (s.linked != null and s.number != null and s.kind != .pulls and s.kind != .issues) {
        const number = s.number;
        const after_detail = s.after_detail orelse if (s.kind == .files or s.kind == .activity) s.kind else null;
        clearSnapshots(a);
        s.number = number;
        s.after_detail = after_detail;
        return load(a, s.selected_kind, 1);
    }
    clearSnapshots(a);
    load(a, s.list_kind, 1);
}
pub fn list(a: *App, kind: Kind, filter: Filter) void {
    std.debug.assert(kind == .pulls or kind == .issues);
    const s = &a.panels.github_repository;
    if (s.pending != null) return;
    s.list_kind = kind;
    s.filter = filter;
    load(a, kind, 1);
}
pub fn openItem(a: *App, number: u64) void {
    const s = &a.panels.github_repository;
    if (s.pending != null or number == 0 or s.error_text != null) return;
    const page = if (s.list) |l| l.page else return;
    for (page.items) |item| if (item.number == number) {
        s.images.reset();
        s.number = number;
        s.selected_kind = if (s.list_kind == .pulls) .pull else .issue;
        s.expanded_file = null;
        if (s.details) |old| a.retireArena(old.arena);
        if (s.content) |old| a.retireArena(old.arena);
        s.details = null;
        s.content = null;
        return load(a, s.selected_kind, 1);
    };
}
pub fn back(a: *App) void {
    const s = &a.panels.github_repository;
    if (s.pending != null) return;
    s.kind = s.list_kind;
    s.number = null;
    s.after_detail = null;
    s.expanded_file = null;
    if (s.list == null) return load(a, s.list_kind, 1);
    a.redraw();
}
pub fn section(a: *App, kind: Kind) void {
    const s = &a.panels.github_repository;
    if (s.pending != null or s.details == null or s.error_text != null) return;
    if (kind == .files and s.selected_kind != .pull) return;
    if (kind == .pull or kind == .issue) {
        s.kind = s.selected_kind;
        return a.redraw();
    }
    if (kind == .files or kind == .activity) load(a, kind, 1);
}
pub fn turnPage(a: *App, next: bool) void {
    const s = &a.panels.github_repository;
    if (s.pending != null or s.error_text != null) return;
    const p = s.current() orelse return;
    if (next) {
        if (p.hasNextPage) load(a, s.kind, p.page + 1);
    } else if (p.page > 1) load(a, s.kind, p.page - 1);
}
pub fn load(a: *App, kind: Kind, index: usize) void {
    const s = &a.panels.github_repository;
    if (s.pending != null) return;
    const id = s.owner orelse a.selected orelse return fail(a, "Open a repository session to browse GitHub.");
    const chat = a.findChat(id) orelse return;
    const cwd = chat.cwd orelse return fail(a, "This session has no repository checkout.");
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
        const device = alloc.dupe(u8, chat.device_id orelse "") catch {
            arena.deinit();
            return;
        };
        const branch = alloc.dupe(u8, chat.branch orelse "") catch {
            arena.deinit();
            return;
        };
        s.target = .{ .arena = arena, .chat = chat_copy, .cwd = cwd_copy, .device = device, .branch = branch };
    }
    clearError(a);
    s.kind = kind;
    s.requested_page = index;
    s.expanded_file = null;
    if (!a.engine.up()) return fail(a, "Connect to the checkout's host, then refresh GitHub.");
    const target = s.target.?;
    const host = if (target.device.len == 0 or (a.device_id != null and std.mem.eql(u8, target.device, a.device_id.?))) null else target.device;
    s.pending = a.send_(requests.githubBrowse(.{
        .chatId = target.chat,
        .kind = kind,
        .state = if (kind == .pulls or kind == .issues) s.filter else null,
        .number = if (kind == .pulls or kind == .issues) null else s.number,
        .page = index,
        .expectedRepository = if (s.repository()) |repo| repo.key else null,
        .targetDeviceId = host,
        .linkedRepository = if (s.linked) |link| .{ .owner = link.repository.owner, .name = link.repository.name } else null,
    }), .of(App, a, onReply));
    if (s.pending == null) fail(a, "GitHub request could not be sent. Refresh to retry.");
    a.redraw();
}
fn onReply(a: *App, id: u64, reply: rpc.Reply) void {
    const s = &a.panels.github_repository;
    if (s.pending != id or reply == .item) return;
    s.pending = null;
    switch (reply) {
        .ok => |value| {
            var next = Snapshot.parse(a.gpa, value) catch return fail(a, "The host returned an invalid GitHub page. Refresh to retry.");
            if (next.page.kind != s.kind or next.page.page != s.requested_page or
                (s.repository() != null and !std.mem.eql(u8, s.repository().?.key, next.page.repository.key)))
            {
                next.arena.deinit();
                return fail(a, "Repository context changed. Refresh before continuing.");
            }
            switch (s.kind) {
                .pulls, .issues => {
                    if (s.list) |old| a.retireArena(old.arena);
                    s.list = next;
                },
                .pull, .issue => {
                    if (next.page.detail == null or next.page.detail.?.number != s.number) {
                        next.arena.deinit();
                        return fail(a, "The host returned an invalid GitHub item. Refresh to retry.");
                    }
                    if (s.details) |old| a.retireArena(old.arena);
                    s.details = next;
                    if (s.after_detail) |kind| {
                        s.after_detail = null;
                        return load(a, kind, 1);
                    }
                },
                .files, .activity => {
                    if (s.content) |old| a.retireArena(old.arena);
                    s.content = next;
                },
            }
        },
        .err => return fail(a, "GitHub is unavailable on this session's host. Check gh installation, sign-in and repository permissions, then Refresh. Provider output is hidden for safety."),
        .done => return fail(a, "GitHub request ended without a page. Refresh to retry."),
        .item => unreachable,
    }
    a.redraw();
}
/// Never open provider-controlled URLs or remote assets. Construct a canonical
/// page only from the validated repository and the currently selected number.
pub fn itemUrl(allocator: std.mem.Allocator, repo: Repository, number: u64, pull: bool) ![]u8 {
    if (!std.mem.eql(u8, repo.host, "github.com") or !validPart(repo.owner) or !validPart(repo.name) or number == 0) return error.InvalidGitHubURL;
    return std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/{s}/{d}", .{ repo.owner, repo.name, if (pull) "pull" else "issues", number });
}
