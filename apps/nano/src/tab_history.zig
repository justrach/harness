//! Owned, bounded close history. Entries describe only the removed context.
const std = @import("std");
const tabs = @import("tabs.zig");
const Allocator = std.mem.Allocator;
pub const limit = 32;
pub const Identity = struct { workspace: u64, pane: u64 };
pub const Kind = enum { workspace, pane, panel_tab };
pub const Entry = struct {
    kind: Kind = .workspace,
    workspace: u64 = 0,
    pane: u64 = 0,
    workspace_index: usize = 0,
    pane_index: usize = 0,
    tab_index: usize = 0,
    axis: tabs.Axis = .horizontal,
    shares: [tabs.max_panes]f32 = @splat(0),
    siblings: [tabs.max_panes]u64 = @splat(0),
    count: usize = 0,
    chat: ?[]u8 = null,
    draft: ?tabs.Draft = null,
    group: tabs.PanelTabs = .{},
    split: ?tabs.Split = null,
    /// Set only by the close operation which actually requested archival.
    auto_archived: bool = false,
    reuse_placeholder: bool = false,

    pub fn deinit(e: *Entry, gpa: Allocator) void {
        if (e.chat) |id| gpa.free(id);
        if (e.draft) |*d| d.deinit(gpa);
        e.group.deinit(gpa);
        if (e.split) |*s| s.deinit(gpa);
        e.* = .{};
    }
};

pub fn copyChat(gpa: Allocator, id: ?[]const u8) !?[]u8 {
    return if (id) |s| try gpa.dupe(u8, s) else null;
}
pub fn copyDraft(gpa: Allocator, d: ?tabs.Draft) !?tabs.Draft {
    return if (d) |v| try v.clone(gpa) else null;
}
pub fn copyGroup(gpa: Allocator, group: tabs.PanelTabs) !tabs.PanelTabs {
    var out: tabs.PanelTabs = .{ .active = group.active };
    errdefer out.deinit(gpa);
    try out.items.ensureTotalCapacity(gpa, group.items.items.len);
    for (group.items.items) |item| {
        var next: tabs.PanelTab = .{ .shown = item.shown };
        next.chat = try copyChat(gpa, item.chat);
        errdefer if (next.chat) |id| gpa.free(id);
        next.draft = try copyDraft(gpa, item.draft);
        out.items.appendAssumeCapacity(next);
    }
    return out;
}
pub fn copySplit(gpa: Allocator, s: tabs.Split) !tabs.Split {
    var out: tabs.Split = .{ .axis = s.axis, .focus = s.focus, .zoomed = s.zoomed, .identities = s.identities };
    errdefer out.deinit(gpa);
    try out.panes.ensureTotalCapacity(gpa, s.panes.items.len);
    try out.drafts.ensureTotalCapacity(gpa, s.drafts.items.len);
    for (s.panes.items) |id| out.panes.appendAssumeCapacity(try copyChat(gpa, id));
    for (s.drafts.items) |d| out.drafts.appendAssumeCapacity(try copyDraft(gpa, d));
    try out.shares.appendSlice(gpa, s.shares.items);
    for (s.groups, 0..) |g, i| out.groups[i] = try copyGroup(gpa, g);
    return out;
}

pub fn capture(t: *tabs.Tabs, kind: Kind, workspace_index: usize, pane_index: usize, tab_index: usize) void {
    t.ensurePaneIdentities();
    var e: Entry = .{ .kind = kind, .workspace_index = workspace_index, .pane_index = pane_index, .tab_index = tab_index };
    if (workspace_index >= t.items.items.len) return;
    const identity = t.identities.items[workspace_index];
    e.workspace = identity.workspace;
    e.pane = identity.pane;
    if (t.splits.items[workspace_index]) |s| {
        e.axis = s.axis;
        e.count = s.panes.items.len;
        @memcpy(e.shares[0..e.count], s.shares.items);
        e.siblings = s.identities;
        e.pane = s.identities[pane_index];
    }
    captureData(t, &e) catch {
        e.deinit(t.gpa);
        return;
    };
    t.pushClosed(e);
}
fn captureData(t: *tabs.Tabs, e: *Entry) !void {
    const i = e.workspace_index;
    if (e.kind == .workspace) {
        e.chat = try copyChat(t.gpa, t.items.items[i]);
        e.draft = try copyDraft(t.gpa, t.drafts.items[i]);
        if (t.splits.items[i]) |s| e.split = try copySplit(t.gpa, s);
        // showTab parks a workspace's live focused draft at top level. It
        // is newer than any previously parked per-pane value.
        if (e.split) |*s| if (e.draft) |d| {
            if (s.drafts.items[s.focus]) |*old| old.deinit(t.gpa);
            s.drafts.items[s.focus] = d;
            e.draft = null;
        };
        return;
    }
    const s = t.splits.items[i].?;
    if (e.kind == .panel_tab and e.tab_index != s.groups[e.pane_index].active) {
        const slot = s.groups[e.pane_index].items.items[e.tab_index];
        e.chat = try copyChat(t.gpa, slot.chat);
        e.draft = try copyDraft(t.gpa, slot.draft);
    } else {
        e.chat = try copyChat(t.gpa, if (e.pane_index == s.focus) t.items.items[i] else s.panes.items[e.pane_index]);
        e.draft = try copyDraft(t.gpa, s.drafts.items[e.pane_index]);
        if (e.kind == .pane) e.group = try copyGroup(t.gpa, s.groups[e.pane_index]);
    }
}

/// The caller parks its live draft before this operation. All potentially
/// failing allocations precede ownership transfer; failure leaves the entry usable.
pub fn restore(t: *tabs.Tabs, e: *Entry) !void {
    const previous_active = t.active;
    errdefer t.active = previous_active;
    var parent: ?usize = null;
    for (t.identities.items, 0..) |id, i| if (id.workspace == e.workspace) {
        parent = i;
        break;
    };
    if (e.kind == .workspace or parent == null) return restoreWorkspace(t, e);
    const i = parent.?;
    t.active = i;
    try t.isolateWorkspace();
    var s = t.layout().?;
    if (t.drafts.items[i]) |d| {
        if (s.drafts.items[s.focus]) |*old| old.deinit(t.gpa);
        s.drafts.items[s.focus] = d;
        t.drafts.items[i] = null;
    }
    if (e.kind == .panel_tab) {
        var pane: ?usize = null;
        for (s.identities[0..s.panes.items.len], 0..) |id, ix| if (id == e.pane) {
            pane = ix;
            break;
        };
        if (pane == null) return restoreWorkspace(t, e);
        const group = &s.groups[pane.?];
        try group.items.ensureUnusedCapacity(t.gpa, if (group.items.items.len == 0) 2 else 1);
        t.focusPane(pane.?);
        if (group.items.items.len == 0) group.items.appendAssumeCapacity(.{});
        // Park the current selection rather than replacing it with the old snapshot.
        group.items.items[group.active] = .{ .chat = t.items.items[i], .draft = s.drafts.items[s.focus], .shown = t.bumpShown() };
        t.items.items[i] = null;
        s.drafts.items[s.focus] = null;
        const at = @min(e.tab_index, group.items.items.len);
        group.items.insertAssumeCapacity(at, .{});
        group.active = at;
        t.items.items[i] = e.chat;
        s.drafts.items[s.focus] = e.draft;
        e.chat = null;
        e.draft = null;
    } else {
        if (s.panes.items.len >= tabs.max_panes or (s.panes.items.len > 1 and s.axis != e.axis)) return restoreWorkspace(t, e);
        try s.panes.ensureUnusedCapacity(t.gpa, 1);
        try s.drafts.ensureUnusedCapacity(t.gpa, 1);
        try s.shares.ensureUnusedCapacity(t.gpa, 1);
        const at = @min(e.pane_index, s.panes.items.len);
        const exact = survivingLayoutUnchanged(s.*, e);
        s.panes.items[s.focus] = t.items.items[i];
        t.items.items[i] = null;
        var ix = s.panes.items.len;
        while (ix > at) : (ix -= 1) {
            s.groups[ix] = s.groups[ix - 1];
            s.identities[ix] = s.identities[ix - 1];
        }
        s.groups[at] = e.group;
        e.group = .{};
        s.identities[at] = e.pane;
        s.panes.insertAssumeCapacity(at, null);
        s.drafts.insertAssumeCapacity(at, e.draft);
        e.draft = null;
        s.shares.insertAssumeCapacity(at, 0);
        s.focus = at;
        s.axis = e.axis;
        t.items.items[i] = e.chat;
        e.chat = null;
        // Exact undo when untouched; otherwise retain the surviving panes'
        // edited proportions instead of rolling their layout back.
        if (exact) @memcpy(s.shares.items, e.shares[0..e.count]) else {
            const share = if (e.pane_index < e.count and e.shares[e.pane_index] > 0 and e.shares[e.pane_index] < 1) e.shares[e.pane_index] else 1 / @as(f32, @floatFromInt(s.panes.items.len));
            for (s.shares.items, 0..) |*v, k| v.* = if (k == at) share else v.* * (1 - share);
        }
    }
    s.zoomed = false;
    t.noteShown();
}
fn survivingLayoutUnchanged(s: tabs.Split, e: *const Entry) bool {
    if (e.count < 2 or s.panes.items.len + 1 != e.count or e.pane_index >= e.count) return false;
    const even_share = 1 / @as(f32, @floatFromInt(e.count));
    var even = true;
    for (e.shares[0..e.count]) |share| if (@abs(share - even_share) >= 1e-3) {
        even = false;
    };
    const neighbor = @min(e.pane_index -| 1, s.panes.items.len - 1);
    for (s.shares.items, 0..) |share, ix| {
        const original = if (ix < e.pane_index) ix else ix + 1;
        if (s.identities[ix] != e.siblings[original]) return false;
        const expected = if (even) 1 / @as(f32, @floatFromInt(s.panes.items.len)) else e.shares[original] + (if (ix == neighbor) e.shares[e.pane_index] else 0);
        if (@abs(share - expected) >= 1e-3) return false;
    }
    return true;
}

fn restoreWorkspace(t: *tabs.Tabs, e: *Entry) !void {
    // Allocate the fallback panel before adding a workspace, so OOM cannot
    // leave a half-restored blank workspace in front of the user's work.
    var standalone: ?tabs.Split = null;
    defer if (standalone) |*s| s.deinit(t.gpa);
    if (e.kind == .pane) {
        standalone = .{ .axis = e.axis };
        const s = &standalone.?;
        try s.panes.append(t.gpa, null);
        try s.shares.append(t.gpa, 1);
        try s.drafts.append(t.gpa, null);
        s.identities[0] = e.pane;
    }
    const reuse = e.reuse_placeholder and t.items.items.len == 1 and t.items.items[0] == null and t.splits.items[0] == null;
    const at = if (reuse) 0 else @min(e.workspace_index, t.items.items.len);
    if (reuse) {
        if (t.drafts.items[0]) |*d| d.deinit(t.gpa);
        t.drafts.items[0] = null;
    } else try t.insertEmpty(at);
    t.active = at;
    if (e.kind == .pane) {
        // A vanished parent cannot be resurrected over the current workspace.
        // Preserve the removed panel (including its tabs) as a new workspace.
        t.splits.items[at] = standalone;
        standalone = null;
        const s = t.layout().?;
        s.groups[0] = e.group;
        e.group = .{};
        s.axis = e.axis;
        s.identities[0] = e.pane;
        s.drafts.items[0] = e.draft;
        e.draft = null;
    } else {
        t.splits.items[at] = e.split;
        e.split = null;
        t.drafts.items[at] = e.draft;
        e.draft = null;
    }
    t.items.items[at] = e.chat;
    e.chat = null;
    if (e.kind == .workspace and e.workspace != 0) t.identities.items[at] = .{ .workspace = e.workspace, .pane = e.pane };
    t.noteShown();
}

const testing = std.testing;
fn draft(text: []const u8) !tabs.Draft {
    const value: tabs.Draft = .{ .text = @constCast(text), .harness = @constCast("test"), .model = @constCast("model"), .ref = @constCast("branch"), .checkout_local = true };
    return value.clone(testing.allocator);
}

test "closed history is bounded LIFO and owns IDs independently (#455)" {
    var t: tabs.Tabs = .init(testing.allocator);
    defer t.deinit();
    for (0..limit + 9) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "chat-{d}", .{i});
        t.rememberClosed(id);
    }
    try testing.expectEqual(limit, t.closed.items.len);
    var i: usize = limit + 9;
    while (i > 9) {
        i -= 1;
        const id = t.popClosed().?;
        defer testing.allocator.free(id);
        var buf: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "chat-{d}", .{i}), id);
    }
    try testing.expect(t.popClosed() == null);
}

test "closed history restores pane tab selection and deep owned drafts (#455)" {
    var t: tabs.Tabs = .init(testing.allocator);
    defer t.deinit();
    t.setCurrent("a");
    try testing.expect(try t.split(.horizontal));
    try t.newPaneTab(try draft("First parked prompt"));
    t.setCurrent("b");
    try t.newPaneTab(try draft("Second parked prompt"));
    t.park(t.active, t.layout().?.focus, try draft("Focused closed prompt"));
    const key = t.layout().?.identities[1];
    try testing.expect(t.closePane());
    var e = t.popClosedEntry().?;
    defer e.deinit(testing.allocator);
    try t.restoreClosed(&e);
    const s = t.layout().?;
    try testing.expectEqual(@as(usize, 1), s.focus);
    try testing.expectEqual(key, s.identities[s.focus]);
    const group = s.groups[1];
    try testing.expectEqual(@as(usize, 3), group.count());
    try testing.expectEqual(@as(usize, 2), group.active);
    try testing.expectEqualStrings("First parked prompt", group.items.items[0].draft.?.text);
    try testing.expectEqualStrings("Second parked prompt", group.items.items[1].draft.?.text);
    try testing.expectEqualStrings("b", group.items.items[1].chat.?);
    const d = s.drafts.items[1].?;
    try testing.expectEqualStrings("Focused closed prompt", d.text);
    try testing.expect(d.checkout_local);
    try testing.expectEqualStrings("branch", d.ref.?);
}

test "closed history merges a pane without undoing divider edits made since close (#455)" {
    var t: tabs.Tabs = .init(testing.allocator);
    defer t.deinit();
    t.setCurrent("a");
    try testing.expect(try t.split(.horizontal));
    t.setCurrent("b");
    try testing.expect(try t.split(.horizontal));
    t.setCurrent("c");
    try testing.expect(t.closePane());
    t.layout().?.shares.items[0] = 0.7;
    t.layout().?.shares.items[1] = 0.3;
    var e = t.popClosedEntry().?;
    defer e.deinit(testing.allocator);
    try t.restoreClosed(&e);
    const s = t.layout().?;
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), s.shares.items[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 7.0 / 3.0), s.shares.items[0] / s.shares.items[1], 0.001);
    try testing.expectEqualStrings("a", s.panes.items[0].?);
    try testing.expectEqualStrings("b", s.panes.items[1].?);
}

test "closed history identifies the parent workspace after tab insertion rather than by index (#455)" {
    var t: tabs.Tabs = .init(testing.allocator);
    defer t.deinit();
    t.setCurrent("a");
    try testing.expect(try t.split(.vertical));
    t.setCurrent("b");
    try testing.expect(t.closePane());
    var e = t.popClosedEntry().?;
    defer e.deinit(testing.allocator);
    try t.insertEmpty(0);
    t.active = 0;
    t.setCurrent("unrelated");
    try t.restoreClosed(&e);
    try testing.expectEqual(@as(usize, 1), t.active);
    try testing.expectEqualStrings("unrelated", t.items.items[0].?);
    try testing.expectEqualStrings("a", t.layout().?.panes.items[0].?);
    try testing.expectEqualStrings("b", t.current().?);
}

test "closed history missing parent falls back without replacing another workspace (#455)" {
    var t: tabs.Tabs = .init(testing.allocator);
    defer t.deinit();
    t.setCurrent("a");
    try testing.expect(try t.split(.vertical));
    t.setCurrent("b");
    try testing.expect(t.closePane());
    var e = t.popClosedEntry().?;
    defer e.deinit(testing.allocator);
    t.close(0);
    t.setCurrent("unrelated");
    t.park(t.active, null, try draft("Keep this new work"));
    try t.restoreClosed(&e);
    try testing.expectEqual(@as(usize, 2), t.items.items.len);
    try testing.expectEqualStrings("b", t.current().?);
    try testing.expectEqualStrings("unrelated", t.items.items[1].?);
    try testing.expectEqualStrings("Keep this new work", t.drafts.items[1].?.text);
}

fn cloneFailureCase(gpa: Allocator) !void {
    const source: tabs.Draft = .{ .text = @constCast("An unsent prompt"), .harness = @constCast("test"), .model = @constCast("model"), .reasoning = @constCast("high"), .space = @constCast("project"), .device = @constCast("device"), .ref = @constCast("branch"), .checkout_local = true, .no_project = true };
    var cloned = try source.clone(gpa);
    defer cloned.deinit(gpa);
    try testing.expectEqualStrings(source.text, cloned.text);
    try testing.expect(cloned.checkout_local and cloned.no_project);
    try testing.expectEqualStrings("branch", cloned.ref.?);
}
test "closed history draft cloning cleans up every allocation failure (#455)" {
    try testing.checkAllAllocationFailures(testing.allocator, cloneFailureCase, .{});
}

fn splitCloneFailureCase(gpa: Allocator, source: tabs.Split) !void {
    var cloned = try copySplit(gpa, source);
    defer cloned.deinit(gpa);
    try testing.expectEqualStrings("Neighbor draft", cloned.drafts.items[0].?.text);
    try testing.expectEqualStrings("Inactive draft", cloned.groups[1].items.items[0].draft.?.text);
    try testing.expectEqualStrings("inactive", cloned.groups[1].items.items[0].chat.?);
    try testing.expectEqualStrings("Selected draft", cloned.drafts.items[1].?.text);
}
test "closed history split cloning cleans up partial chats groups and drafts on every allocation failure (#455)" {
    var t: tabs.Tabs = .init(testing.allocator);
    defer t.deinit();
    t.setCurrent("neighbor");
    try testing.expect(try t.split(.vertical));
    t.park(t.active, 0, try draft("Neighbor draft"));
    t.setCurrent("inactive");
    try t.newPaneTab(try draft("Inactive draft"));
    t.park(t.active, 1, try draft("Selected draft"));
    try testing.checkAllAllocationFailures(testing.allocator, splitCloneFailureCase, .{t.layout().?.*});
}
