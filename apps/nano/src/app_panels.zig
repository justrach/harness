//! The panels beside a chat (crates/ui/src/shell.rs, changes.rs,
//! files/*): the surface pane's tabs (a checkout's diff, an open file) and
//! the file explorer, with the engine calls that fill them. The diff of
//! the working tree comes from `WatchCheckoutDiffs` and is fetched again
//! with `GetCheckoutDiff` when its checksum moves; branch and turn scopes
//! are fetched on demand.
const std = @import("std");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const diff = @import("diff.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Scope = enum {
    workingTree,
    branch,
    turn,

    pub fn label(s: Scope) []const u8 {
        return switch (s) {
            .workingTree => "Working tree",
            .branch => "Branch changes",
            .turn => "Latest turn",
        };
    }
};

pub const TabKind = enum { diffs, file, subagent, browser };

pub const Tab = struct {
    kind: TabKind,
    /// A file tab's path in the chat's checkout (owned).
    path: []u8 = &.{},
    agent: ?*@import("app_subagents.zig").Agent = null,
    browser: ?*@import("app_browser.zig").Browser = null,
};

/// A diff as last fetched: its files (into `arena`) and totals.
pub const Diff = struct {
    arena: std.heap.ArenaAllocator,
    files: []diff.File = &.{},
    additions: u32 = 0,
    deletions: u32 = 0,
    truncated: bool = false,
    checkout_id: []const u8 = "",
    checksum: []const u8 = "",
};

/// An entry of a listed folder.
pub const Entry = struct { path: []const u8, name: []const u8, dir: bool, ignored: bool };

/// A folder's listing, as `ListWorkspaceDirectory` gave it.
pub const Listing = struct { entries: []Entry = &.{}, loading: bool = true, err: ?[]const u8 = null };

/// An open file's text, as `ReadWorkspaceFile` gave it.
pub const FileText = struct { text: ?[]const u8 = null, reason: ?[]const u8 = null, loading: bool = true };

pub const Panels = struct {
    gpa: Allocator,
    host_open: bool = false,
    files_open: bool = false,
    tabs: std.ArrayList(Tab) = .empty,
    /// Closed surfaces remain alive until the frame using their labels ends.
    retired: std.ArrayList(Tab) = .empty,
    pending_agent: ?*@import("app_subagents.zig").Agent = null,
    pending_browser: ?*@import("app_browser.zig").Browser = null,
    active: usize = 0,
    scope: Scope = .workingTree,
    scope_menu: bool = false,
    scope_anchor: ?@import("nanoui").ui.Rect = null,
    /// The explorer's search: its text, and what matched.
    search: @import("nanoui").ui.TextBuffer = .{},
    searching: bool = false,
    results: []Entry = &.{},
    search_id: ?u64 = null,
    base_ref: []const u8 = "main",
    /// Folded files in the diff, by path.
    folded: std.StringHashMapUnmanaged(void) = .empty,
    diff: ?Diff = null,
    diff_loading: bool = false,
    diff_error: ?[]u8 = null,
    w_diffs: ?u64 = null,
    /// The explorer: listings by folder ("" the root), the folders open,
    /// the row selected, whether ignored files show, and git colours.
    arena: std.heap.ArenaAllocator,
    listings: std.StringHashMapUnmanaged(Listing) = .empty,
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    selected: ?[]const u8 = null,
    show_all: bool = false,
    git: std.StringHashMapUnmanaged(GitKind) = .empty,
    w_git: ?u64 = null,
    file: FileText = .{},
    /// Folder listings asked for, by call id.
    pending_lists: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    /// The chat these are for: a change clears them.
    chat: ?[]u8 = null,
    discard_confirm: bool = false,

    pub fn init(gpa: Allocator) Panels {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(p: *Panels) void {
        if (p.pending_agent) |s| s.destroy();
        if (p.pending_browser) |b| b.destroy();
        for (p.tabs.items) |t| destroyTab(p, t);
        for (p.retired.items) |t| destroyTab(p, t);
        p.tabs.deinit(p.gpa);
        p.retired.deinit(p.gpa);
        p.folded.deinit(p.gpa);
        if (p.diff) |*d| d.arena.deinit();
        if (p.diff_error) |e| p.gpa.free(e);
        p.listings.deinit(p.gpa);
        p.pending_lists.deinit(p.gpa);
        p.expanded.deinit(p.gpa);
        p.git.deinit(p.gpa);
        p.arena.deinit();
        if (p.chat) |c| p.gpa.free(c);
    }

    pub fn activeTab(p: *const Panels) ?Tab {
        const t = if (p.active < p.tabs.items.len) p.tabs.items[p.active] else return null;
        if (t.agent) |s| if (!s.belongsTo(p.chat)) return null;
        if (t.browser) |b| if (!b.belongsTo(p.chat)) return null;
        return t;
    }
};

pub fn destroyTab(p: *Panels, t: Tab) void {
    p.gpa.free(t.path);
    if (t.agent) |s| s.destroy();
    if (t.browser) |b| b.destroy();
}

pub const GitKind = enum { added, modified, renamed, deleted };

/// The chat's checkout folder, and its device when it isn't this one.
fn cwd(a: *const App) ?[]const u8 {
    const id = a.selected orelse return null;
    return (a.findChat(id) orelse return null).cwd;
}

fn host(a: *const App) ?[]const u8 {
    const id = a.selected orelse return null;
    const dev = (a.findChat(id) orelse return null).device_id orelse return null;
    if (a.device_id) |mine| if (std.mem.eql(u8, mine, dev)) return null;
    return dev;
}

/// A new chat was opened: what the panels showed was the last one's.
pub fn chatChanged(a: *App) void {
    const p = &a.panels;
    if (p.w_diffs) |id| a.engine.cancel(id);
    if (p.w_git) |id| a.engine.cancel(id);
    p.w_diffs = null;
    p.w_git = null;
    if (p.diff) |*d| d.arena.deinit();
    p.diff = null;
    p.listings.clearRetainingCapacity();
    p.pending_lists.clearRetainingCapacity();
    p.expanded.clearRetainingCapacity();
    p.git.clearRetainingCapacity();
    p.folded.clearRetainingCapacity();
    p.selected = null;
    _ = p.arena.reset(.retain_capacity);
    p.file = .{};
    if (p.chat) |c| p.gpa.free(c);
    p.chat = if (a.selected) |s| p.gpa.dupe(u8, s) catch null else null;
    if (a.selected == null) return;
    @import("app_actions.zig").refresh(a);
    if (p.host_open) showTab(a, p.active);
    if (p.files_open) openFiles(a);
}

/// The chat list came: a panel opened before the chat's folder was known
/// can fetch now.
pub fn chatsArrived(a: *App) void {
    const p = &a.panels;
    if (a.selected == null) return;
    @import("app_actions.zig").refresh(a);
    if (p.host_open and p.diff == null and !p.diff_loading) {
        if (p.activeTab()) |t| if (t.kind == .diffs) openDiffs(a);
    }
    if (p.files_open and p.w_git == null) openFiles(a);
}

// ── the surface pane ─────────────────────────────────────────────────

pub fn toggleHost(a: *App) void {
    a.panels.host_open = !a.panels.host_open;
    if (a.panels.host_open) showTab(a, a.panels.active);
    a.redraw();
}

/// A tab showing the checkout's diff.
pub fn addDiffsTab(a: *App) void {
    const p = &a.panels;
    p.tabs.append(p.gpa, .{ .kind = .diffs }) catch return;
    p.active = p.tabs.items.len - 1;
    p.host_open = true;
    openDiffs(a);
    a.redraw();
}

pub fn closeTab(a: *App, i: usize) void {
    const p = &a.panels;
    if (i >= p.tabs.items.len) return;
    p.retired.ensureUnusedCapacity(p.gpa, 1) catch return;
    const t = p.tabs.orderedRemove(i);
    if (t.agent) |s| s.stop();
    if (comptime @import("builtin").os.tag == .macos) if (t.browser) |b| if (b.native) |n| n.show(false);
    p.retired.appendAssumeCapacity(t);
    if (i < p.active) p.active -= 1;
    if (p.active >= p.tabs.items.len) p.active = p.tabs.items.len -| 1;
    showTab(a, p.active);
}

pub fn showTab(a: *App, i: usize) void {
    const p = &a.panels;
    if (i >= p.tabs.items.len) return a.redraw();
    p.active = i;
    const t = p.tabs.items[i];
    switch (t.kind) {
        .diffs => openDiffs(a),
        .file => readFile(a, t.path),
        .subagent, .browser => {},
    }
    a.redraw();
}

fn openDiffs(a: *App) void {
    const p = &a.panels;
    if (p.scope == .workingTree and p.w_diffs == null) {
        p.w_diffs = a.send_(requests.watchDiffs(host(a)), .of(App, a, onDiffs));
    }
    fetchDiff(a);
}

pub fn setScope(a: *App, s: Scope) void {
    a.panels.scope = s;
    a.panels.scope_menu = false;
    fetchDiff(a);
}

fn onDiffs(a: *App, id: u64, r: rpc.Reply) void {
    if (a.panels.w_diffs != id) return;
    switch (r) {
        // A change on the device: fetch this chat's diff again if it moved.
        .item => |v| if (changedFor(a, v)) fetchDiff(a),
        .done, .err => a.panels.w_diffs = null,
        .ok => {},
    }
}

fn changedFor(a: *const App, v: std.json.Value) bool {
    const dir = cwd(a) orelse return false;
    const list = if (v == .array) v.array.items else &.{v};
    // By the checkout's id once one is known: a folder can be named two
    // ways (/tmp and /private/tmp on macOS).
    const known = if (a.panels.diff) |x| x.checkout_id else "";
    for (list) |d| if (d == .object) {
        const id = strOf(d.object, "checkoutId") orelse "";
        const c = strOf(d.object, "cwd") orelse "";
        const same = if (known.len > 0) std.mem.eql(u8, id, known) else std.mem.eql(u8, c, dir);
        if (!same) continue;
        const sum = d.object.get("checksum") orelse return true;
        const have = if (a.panels.diff) |x| x.checksum else "";
        return sum != .string or !std.mem.eql(u8, sum.string, have);
    };
    return false;
}

pub fn fetchDiff(a: *App) void {
    const p = &a.panels;
    const dir = cwd(a) orelse return;
    p.diff_loading = true;
    a.request(requests.getDiff(dir, @tagName(p.scope), if (p.scope == .branch) p.base_ref else null, if (p.scope == .turn) a.selected else null, host(a)), .of(App, a, onDiff));
}

fn onDiff(a: *App, _: u64, r: rpc.Reply) void {
    const p = &a.panels;
    p.diff_loading = false;
    if (p.diff_error) |e| p.gpa.free(e);
    p.diff_error = null;
    switch (r) {
        .ok => |v| {
            if (v != .object) return;
            var next: Diff = .{ .arena = .init(p.gpa) };
            const ar = next.arena.allocator();
            const o = v.object;
            const patch = ar.dupe(u8, strOf(o, "patch") orelse "") catch return next.arena.deinit();
            next.files = diff.parse(ar, patch) catch &.{};
            next.additions = intOf(o, "additions");
            next.deletions = intOf(o, "deletions");
            next.truncated = if (o.get("truncated")) |t| t == .bool and t.bool else false;
            next.checkout_id = ar.dupe(u8, strOf(o, "checkoutId") orelse "") catch "";
            next.checksum = ar.dupe(u8, strOf(o, "checksum") orelse "") catch "";
            if (p.diff) |*old| old.arena.deinit();
            p.diff = next;
        },
        .err => |e| p.diff_error = p.gpa.dupe(u8, e) catch null,
        else => {},
    }
    a.redraw();
}

/// "Discard working tree changes?" answered yes.
pub fn discard(a: *App) void {
    const p = &a.panels;
    p.discard_confirm = false;
    const d = p.diff orelse return;
    const chat = a.selected orelse return;
    a.request(requests.discard(chat, d.checkout_id, d.checksum, host(a)), .of(App, a, onDiscarded));
}

fn onDiscarded(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .err => |e| a.setNotice(e),
        else => fetchDiff(a),
    }
}

pub fn toggleFold(a: *App, path: []const u8) void {
    const p = &a.panels;
    if (p.folded.remove(path)) return a.redraw();
    const key = p.arena.allocator().dupe(u8, path) catch return;
    p.folded.put(p.gpa, key, {}) catch {};
    a.redraw();
}

fn strOf(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn intOf(o: std.json.ObjectMap, k: []const u8) u32 {
    const v = o.get(k) orelse return 0;
    return if (v == .integer) std.math.cast(u32, v.integer) orelse 0 else 0;
}

// ── the file explorer ────────────────────────────────────────────────

pub const files = @import("app_files.zig");
pub const toggleFiles = files.toggle;
pub const openFiles = files.open;
pub const readFile = files.read;
