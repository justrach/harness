//! The file explorer's calls (crates/ui/src/files/*): the chat's checkout
//! listed a folder at a time as folders open (`ListWorkspaceDirectory`,
//! gitignored files left out unless "show all" is on), git's view of each
//! file for its colour (`WatchWorkspaceGitStatus`), and an opened file read
//! into a tab (`ReadWorkspaceFile`).
const std = @import("std");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const panels = @import("app_panels.zig");
const App = @import("app.zig").App;

fn host(a: *const App) ?[]const u8 {
    const id = a.selected orelse return null;
    const dev = (a.findChat(id) orelse return null).device_id orelse return null;
    if (a.device_id) |mine| if (std.mem.eql(u8, mine, dev)) return null;
    return dev;
}

pub fn toggle(a: *App) void {
    a.panels.files_open = !a.panels.files_open;
    if (a.panels.files_open) open(a);
    a.redraw();
}

/// Lists the root and watches git, unless they are already.
pub fn open(a: *App) void {
    const p = &a.panels;
    if (!p.listings.contains("")) list(a, "");
    if (p.w_git == null) {
        const chat = a.findChat(a.selected orelse return) orelse return;
        if (chat.space_id) |sid| if (chat.cwd) |dir| {
            p.w_git = a.send_(requests.watchGit(sid, dir, host(a)), .of(App, a, onGit));
        };
    }
}

/// Opens or shuts a folder; its entries are listed the first time.
pub fn toggleDir(a: *App, path: []const u8) void {
    const p = &a.panels;
    p.selected = (p.arena.allocator().dupe(u8, path) catch return);
    if (p.expanded.remove(path)) return a.redraw();
    const key = p.arena.allocator().dupe(u8, path) catch return;
    p.expanded.put(p.gpa, key, {}) catch return;
    if (!p.listings.contains(path)) list(a, key);
    a.redraw();
}

/// "Show all files (even hidden)": lists everything again.
pub fn setShowAll(a: *App, on: bool) void {
    const p = &a.panels;
    p.show_all = on;
    p.listings.clearRetainingCapacity();
    list(a, "");
    var it = p.expanded.keyIterator();
    while (it.next()) |k| list(a, k.*);
    a.redraw();
}

const Pending = struct { a: *App, dir: []const u8 };

fn list(a: *App, dir: []const u8) void {
    const p = &a.panels;
    const chat = a.selected orelse return;
    const key = p.arena.allocator().dupe(u8, dir) catch return;
    p.listings.put(p.gpa, key, .{}) catch return;
    const id = a.send_(requests.listDirectory(chat, dir, p.show_all, host(a)), .of(App, a, onListed)) orelse return;
    p.pending_lists.put(p.gpa, id, key) catch {};
}

fn onListed(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.panels;
    const dir = (p.pending_lists.fetchRemove(id) orelse return).value;
    const ar = p.arena.allocator();
    var listing: panels.Listing = .{ .loading = false };
    switch (r) {
        .ok => |v| {
            const entries = if (v == .object) v.object.get("entries") else null;
            var out: std.ArrayList(panels.Entry) = .empty;
            if (entries) |e| if (e == .array) for (e.array.items) |x| if (x == .object) {
                const o = x.object;
                const path = str(o, "path") orelse continue;
                out.append(ar, .{
                    .path = ar.dupe(u8, path) catch continue,
                    .name = ar.dupe(u8, str(o, "name") orelse std.fs.path.basename(path)) catch continue,
                    .dir = std.mem.eql(u8, str(o, "kind") orelse "", "directory"),
                    .ignored = if (o.get("ignored")) |g| g == .bool and g.bool else false,
                }) catch {};
            };
            listing.entries = out.items;
        },
        .err => |e| listing.err = ar.dupe(u8, e) catch "Couldn't list this folder",
        else => return,
    }
    p.listings.put(p.gpa, dir, listing) catch {};
    a.redraw();
}

fn onGit(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.panels;
    if (p.w_git != id) return;
    switch (r) {
        .item => |v| {
            p.git.clearRetainingCapacity();
            const st = if (v == .object) v.object.get("status") else null;
            const fs = if (st) |s| (if (s == .object) s.object.get("files") else null) else null;
            if (fs) |f| if (f == .array) for (f.array.items) |x| if (x == .object) {
                const path = str(x.object, "path") orelse continue;
                const kind = gitKind(str(x.object, "worktree") orelse "", str(x.object, "index") orelse "") orelse continue;
                const key = p.arena.allocator().dupe(u8, path) catch continue;
                p.git.put(p.gpa, key, kind) catch {};
            };
        },
        .done, .err => p.w_git = null,
        .ok => {},
    }
    a.redraw();
}

/// Git's colour for a file (`git_status.rs`): added and untracked green,
/// modified amber, renamed accent, deleted and conflicted red.
pub fn gitKind(worktree: []const u8, index: []const u8) ?panels.GitKind {
    const eq = std.mem.eql;
    for ([_][]const u8{ worktree, index }) |s| {
        if (eq(u8, s, "deleted") or eq(u8, s, "unmerged")) return .deleted;
    }
    for ([_][]const u8{ worktree, index }) |s| {
        if (eq(u8, s, "modified") or eq(u8, s, "typeChanged")) return .modified;
        if (eq(u8, s, "renamed") or eq(u8, s, "copied")) return .renamed;
        if (eq(u8, s, "added") or eq(u8, s, "untracked")) return .added;
    }
    return null;
}

/// A folder's colour: the most severe of what changed inside it.
pub fn dirKind(a: *const App, dir: []const u8) ?panels.GitKind {
    var worst: ?panels.GitKind = null;
    var it = a.panels.git.iterator();
    while (it.next()) |e| {
        const path = e.key_ptr.*;
        if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') continue;
        const k = e.value_ptr.*;
        if (worst == null or @intFromEnum(k) > @intFromEnum(worst.?)) worst = k;
    }
    return worst;
}

/// Searches the checkout's file names for what the search box holds.
pub fn search(a: *App) void {
    const p = &a.panels;
    const chat = a.selected orelse return;
    const q = std.mem.trim(u8, p.search.text(), " ");
    if (q.len == 0) {
        p.searching = false;
        p.results = &.{};
        return a.redraw();
    }
    p.searching = true;
    p.search_id = a.send_(requests.searchFiles(chat, q, p.show_all, host(a)), .of(App, a, onSearched));
}

fn onSearched(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.panels;
    if (p.search_id != id) return;
    p.searching = false;
    const ar = p.arena.allocator();
    var out: std.ArrayList(panels.Entry) = .empty;
    switch (r) {
        .ok => |v| if (v == .array) for (v.array.items) |x| if (x == .object) {
            const o = x.object;
            const path = str(o, "path") orelse continue;
            out.append(ar, .{
                .path = ar.dupe(u8, path) catch continue,
                .name = ar.dupe(u8, str(o, "name") orelse std.fs.path.basename(path)) catch continue,
                .dir = std.mem.eql(u8, str(o, "kind") orelse "", "directory"),
                .ignored = false,
            }) catch {};
        },
        else => {},
    }
    p.results = out.items;
    a.redraw();
}

/// Opens `path` in a file tab (or the tab already showing it).
pub fn openFile(a: *App, path: []const u8) void {
    const p = &a.panels;
    p.selected = p.arena.allocator().dupe(u8, path) catch null;
    for (p.tabs.items, 0..) |t, i| if (t.kind == .file and std.mem.eql(u8, t.path, path)) {
        p.host_open = true;
        return panels.showTab(a, i);
    };
    const copy = p.gpa.dupe(u8, path) catch return;
    p.tabs.append(p.gpa, .{ .kind = .file, .path = copy }) catch return p.gpa.free(copy);
    p.host_open = true;
    panels.showTab(a, p.tabs.items.len - 1);
}

pub fn read(a: *App, path: []const u8) void {
    const chat = a.selected orelse return;
    a.panels.file = .{};
    a.request(requests.readFile(chat, path, host(a)), .of(App, a, onRead));
}

fn onRead(a: *App, _: u64, r: rpc.Reply) void {
    const p = &a.panels;
    const ar = p.arena.allocator();
    p.file = .{ .loading = false };
    switch (r) {
        .ok => |v| if (v == .object) {
            const o = v.object;
            if (str(o, "text")) |t| p.file.text = ar.dupe(u8, t) catch null;
            if (p.file.text == null) p.file.reason = switch (reasonOf(str(o, "readOnlyReason") orelse str(o, "encoding") orelse "")) {
                .binary => "Binary files cannot be previewed.",
                .large => "This file is too large to preview.",
                .other => "This file can't be shown.",
            };
        },
        .err => |e| p.file.reason = ar.dupe(u8, e) catch "Couldn't read this file",
        else => {},
    }
    a.redraw();
}

fn reasonOf(s: []const u8) enum { binary, large, other } {
    if (std.mem.eql(u8, s, "binary")) return .binary;
    if (std.mem.eql(u8, s, "tooLarge")) return .large;
    return .other;
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

test "git colours, most severe first" {
    try std.testing.expectEqual(panels.GitKind.added, gitKind("untracked", "unchanged").?);
    try std.testing.expectEqual(panels.GitKind.modified, gitKind("modified", "added").?);
    try std.testing.expectEqual(panels.GitKind.deleted, gitKind("unchanged", "unmerged").?);
    try std.testing.expect(gitKind("unchanged", "unchanged") == null);
}
