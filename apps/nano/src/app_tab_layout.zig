//! Nano's tab/split layout beside the shared `openTabs`.
//!
//! A flat chat list cannot say which panes shared one tab, how wide they
//! were, or which panel tab was active. This versioned record does. It is a
//! Nano-only key so the desktop's richer `workspaceWindows` stays untouched.
const std = @import("std");
const tabs = @import("tabs.zig");
const App = @import("app.zig").App;

pub const version: u16 = 1;

const SavedPanelTab = struct { chat: ?[]const u8 = null };
const SavedPane = struct {
    active: usize = 0,
    chat: ?[]const u8 = null,
    tabs: []const SavedPanelTab = &.{},
};
const SavedSplit = struct {
    vertical: bool = false,
    focus: usize = 0,
    zoomed: bool = false,
    shares: []const f32 = &.{},
    panes: []const SavedPane = &.{},
};
const SavedTab = struct {
    chat: ?[]const u8 = null,
    split: ?SavedSplit = null,
};
const SavedLayout = struct {
    version: u16 = version,
    active: usize = 0,
    tabs: []const SavedTab = &.{},
};

/// Publishes the current top-level tabs and every split under them.
pub fn remember(a: *App) void {
    if (rememberInMemory(a)) a.settings.flushOpenTabsAndLayout();
}

pub fn rememberInMemory(a: *App) bool {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var saved: std.ArrayList(SavedTab) = .empty;
    saved.ensureTotalCapacity(alloc, a.tabs.items.items.len) catch return false;

    for (a.tabs.items.items, 0..) |active, ix| {
        var tab: SavedTab = .{ .chat = active };
        if (ix < a.tabs.splits.items.len) if (a.tabs.splits.items[ix]) |s| {
            const count = @min(s.panes.items.len, tabs.max_panes);
            var panes: std.ArrayList(SavedPane) = .empty;
            var shares: std.ArrayList(f32) = .empty;
            panes.ensureTotalCapacity(alloc, count) catch return false;
            shares.ensureTotalCapacity(alloc, count) catch return false;
            for (0..count) |pane_ix| {
                var rows: std.ArrayList(SavedPanelTab) = .empty;
                const group = &s.groups[pane_ix];
                rows.ensureTotalCapacity(alloc, group.items.items.len) catch return false;
                for (group.items.items) |row| rows.appendAssumeCapacity(.{ .chat = row.chat });
                panes.appendAssumeCapacity(.{
                    .active = group.active,
                    .chat = if (pane_ix == s.focus) active else s.panes.items[pane_ix],
                    .tabs = rows.items,
                });
                if (pane_ix < s.shares.items.len) shares.appendAssumeCapacity(s.shares.items[pane_ix]);
            }
            if (panes.items.len == count and shares.items.len != count) {
                shares.clearRetainingCapacity();
                const even = 1 / @as(f32, @floatFromInt(count));
                for (0..count) |_| shares.appendAssumeCapacity(even);
            }
            tab.split = .{
                .vertical = s.axis == .vertical,
                .focus = s.focus,
                .zoomed = s.zoomed,
                .shares = shares.items,
                .panes = panes.items,
            };
        };
        saved.appendAssumeCapacity(tab);
    }
    const body = std.json.Stringify.valueAlloc(alloc, SavedLayout{
        .active = a.tabs.active,
        .tabs = saved.items,
    }, .{}) catch return false;
    return a.settings.updateTabLayout(body);
}

/// Replaces the live Tabs with the saved arrangement. False when there is no
/// usable Nano layout, leaving the caller's `openTabs` fallback untouched.
pub fn restore(a: *App) bool {
    const body = a.settings.tabLayout() orelse return false;
    var parsed = std.json.parseFromSlice(SavedLayout, a.gpa, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return false;
    defer parsed.deinit();
    const saved = parsed.value;
    if (saved.version != version or saved.tabs.len == 0) return false;

    var next = tabs.Tabs.init(a.gpa);
    var transferred = false;
    defer if (!transferred) next.deinit();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a.gpa);
    for (saved.tabs, 0..) |tab, ix| {
        if (ix > 0) next.appendTab();
        if (ix >= next.items.items.len) return false;
        next.items.items[ix] = duplicateChat(a, tab.chat, &seen);
        if (tab.split) |split| {
            next.splits.items[ix] = buildSplit(a, split, &seen) catch |err| switch (err) {
                // A corrupt split must not throw away a valid saved chat.
                error.InvalidLayout => null,
                else => return false,
            };
        }
    }
    next.active = @min(saved.active, next.items.items.len - 1);

    var previous = a.tabs;
    a.tabs = next;
    transferred = true;
    previous.deinit();
    a.tabs.clearShown();
    a.tabs_ready = true;
    a.select(a.tabs.current(), null);
    return true;
}

fn buildSplit(a: *App, saved: SavedSplit, seen: *std.StringHashMapUnmanaged(void)) !tabs.Split {
    const count = saved.panes.len;
    if (count == 0 or count > tabs.max_panes or saved.focus >= count or saved.shares.len != count) return error.InvalidLayout;
    // Normalizing in f32 can overflow even when every stored weight is
    // finite. Reject ratios that round down to an invisible f32 pane.
    var total: f64 = 0;
    for (saved.shares) |share| {
        if (!std.math.isFinite(share) or share <= 0) return error.InvalidLayout;
        total += share;
    }
    var shares: [tabs.max_panes]f32 = undefined;
    for (saved.shares, 0..) |share, ix| {
        shares[ix] = @floatCast(@as(f64, share) / total);
        if (shares[ix] <= 0) return error.InvalidLayout;
    }
    var out: tabs.Split = .{ .axis = if (saved.vertical) .vertical else .horizontal };
    errdefer out.deinit(a.gpa);
    const focus = saved.focus;
    for (0..count) |ix| {
        const pane = saved.panes[ix];
        try out.panes.append(a.gpa, if (ix == focus) null else duplicateChat(a, pane.chat, seen));
        try out.shares.append(a.gpa, shares[ix]);
        try out.drafts.append(a.gpa, null);
        out.groups[ix] = try buildGroup(a, pane, seen);
    }
    out.focus = focus;
    out.zoomed = saved.zoomed;
    return out;
}

fn buildGroup(a: *App, saved: SavedPane, seen: *std.StringHashMapUnmanaged(void)) !tabs.PanelTabs {
    var group: tabs.PanelTabs = .{};
    errdefer group.deinit(a.gpa);
    const active = if (saved.tabs.len > 0) @min(saved.active, saved.tabs.len - 1) else 0;
    for (saved.tabs, 0..) |row, ix| {
        var tab: tabs.PanelTab = .{};
        // The active slot borrows its pane's live chat; only parked tabs
        // own another identity, including in malformed older records.
        tab.chat = if (ix == active) null else duplicateChat(a, row.chat, seen);
        try group.items.append(a.gpa, tab);
    }
    if (group.items.items.len > 0) group.active = @min(saved.active, group.items.items.len - 1);
    return group;
}

fn duplicateChat(a: *App, id: ?[]const u8, seen: *std.StringHashMapUnmanaged(void)) ?[]u8 {
    const chat = id orelse return null;
    _ = a.findChat(chat) orelse return null;
    const got = seen.getOrPut(a.gpa, chat) catch return null;
    if (got.found_existing) return null;
    // Archive state is not view identity. A saved reference is restored
    // without any Unarchive mutation; only a real send/restore can do that.
    return a.gpa.dupe(u8, chat) catch null;
}
