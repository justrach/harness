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
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var saved: std.ArrayList(SavedTab) = .empty;
    saved.ensureTotalCapacity(alloc, a.tabs.items.items.len) catch return;

    for (a.tabs.items.items, 0..) |active, ix| {
        var tab: SavedTab = .{ .chat = active };
        if (ix < a.tabs.splits.items.len) if (a.tabs.splits.items[ix]) |s| {
            const count = @min(s.panes.items.len, tabs.max_panes);
            var panes: std.ArrayList(SavedPane) = .empty;
            var shares: std.ArrayList(f32) = .empty;
            panes.ensureTotalCapacity(alloc, count) catch return;
            shares.ensureTotalCapacity(alloc, count) catch return;
            for (0..count) |pane_ix| {
                var rows: std.ArrayList(SavedPanelTab) = .empty;
                const group = &s.groups[pane_ix];
                rows.ensureTotalCapacity(alloc, group.items.items.len) catch return;
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
    }, .{}) catch return;
    a.settings.setTabLayout(body);
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
    errdefer next.deinit();
    for (saved.tabs, 0..) |tab, ix| {
        if (ix > 0) next.appendTab();
        if (ix >= next.items.items.len) return false;
        next.items.items[ix] = duplicateChat(a, tab.chat);
        if (tab.split) |split| {
            next.splits.items[ix] = buildSplit(a, split) catch return false;
        }
    }
    next.active = @min(saved.active, next.items.items.len - 1);

    var previous = a.tabs;
    a.tabs = next;
    previous.deinit();
    a.tabs_ready = true;
    a.select(a.tabs.current(), null);
    return true;
}

fn buildSplit(a: *App, saved: SavedSplit) !tabs.Split {
    const count = @min(saved.panes.len, tabs.max_panes);
    if (count == 0) return error.EmptyLayout;
    var out: tabs.Split = .{ .axis = if (saved.vertical) .vertical else .horizontal };
    errdefer out.deinit(a.gpa);
    const focus = @min(saved.focus, count - 1);
    const even = 1 / @as(f32, @floatFromInt(count));
    for (0..count) |ix| {
        const pane = saved.panes[ix];
        try out.panes.append(a.gpa, if (ix == focus) null else duplicateChat(a, pane.chat));
        const share = if (ix < saved.shares.len and std.math.isFinite(saved.shares[ix]) and saved.shares[ix] > 0)
            saved.shares[ix]
        else
            even;
        try out.shares.append(a.gpa, share);
        try out.drafts.append(a.gpa, null);
        out.groups[ix] = try buildGroup(a, pane);
    }
    out.focus = focus;
    out.zoomed = saved.zoomed;
    return out;
}

fn buildGroup(a: *App, saved: SavedPane) !tabs.PanelTabs {
    var group: tabs.PanelTabs = .{};
    errdefer group.deinit(a.gpa);
    for (saved.tabs) |row| {
        var tab: tabs.PanelTab = .{};
        tab.chat = duplicateChat(a, row.chat);
        try group.items.append(a.gpa, tab);
    }
    if (group.items.items.len > 0) group.active = @min(saved.active, group.items.items.len - 1);
    return group;
}

fn duplicateChat(a: *App, id: ?[]const u8) ?[]u8 {
    const chat = id orelse return null;
    if (a.findChat(chat) == null) return null;
    return a.gpa.dupe(u8, chat) catch null;
}
