//! Closed-context restoration. The history owns its data, never a whole-window snapshot.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const App = @import("app.zig").App;
const tabs = @import("tabs.zig");
const drafts = @import("app_drafts.zig");

/// An existing tab/pane reference is not an instruction to recreate a
/// deleted conversation. Before initial metadata is authoritative, keep it;
/// direct selection of a newly-created chat does not use this validation.
pub fn validateCurrent(a: *App) void {
    if (!a.chats_synced) return;
    const id = a.tabs.current() orelse return;
    if (a.findChat(id) != null) return; // archived references are valid
    a.retireSlice(a.tabs.items.items[a.tabs.active].?);
    a.tabs.items.items[a.tabs.active] = null;
    if (a.tabs.drafts.items[a.tabs.active]) |*draft| draft.deinit(a.gpa);
    a.tabs.drafts.items[a.tabs.active] = null;
    if (a.tabs.layout()) |split| {
        if (split.drafts.items[split.focus]) |*draft| draft.deinit(a.gpa);
        split.drafts.items[split.focus] = null;
    }
}

pub fn parkActive(a: *App) void {
    const d = drafts.canvas(a) catch return;
    const pane = if (a.tabs.layout()) |s| s.focus else null;
    if (pane != null) if (a.tabs.unpark(a.tabs.active, null)) |old| {
        var stale = old;
        stale.deinit(a.gpa);
    };
    a.tabs.park(a.tabs.active, pane, d);
}

fn cleanChat(a: *App, id: *?[]u8, allow_archived: bool, seen: *bool) bool {
    const chat = id.* orelse return false;
    seen.* = true;
    const valid = if (a.findChat(chat)) |ch| (!ch.archived or allow_archived) and a.tabs.find(chat) == null else false;
    if (valid) return true;
    a.gpa.free(chat);
    id.* = null;
    return false;
}
fn hasPrompt(d: ?tabs.Draft) bool {
    return if (d) |v| v.text.len > 0 else false;
}
fn cleanGroup(a: *App, group: *tabs.PanelTabs, seen: *bool) bool {
    var useful = false;
    var ix = group.items.items.len;
    while (ix > 0) {
        ix -= 1;
        const slot = &group.items.items[ix];
        const had_chat = slot.chat != null;
        const valid = cleanChat(a, &slot.chat, false, seen);
        if (had_chat and !valid) {
            if (slot.draft) |*d| d.deinit(a.gpa);
            _ = group.items.orderedRemove(ix);
            if (group.active > ix) group.active -= 1;
            continue;
        }
        useful = valid or hasPrompt(slot.draft) or useful;
    }
    return useful;
}
fn cleanEntry(a: *App, e: *tabs.ClosedEntry) bool {
    var seen = false;
    const had_chat = e.chat != null;
    const valid_primary = cleanChat(a, &e.chat, e.auto_archived, &seen);
    if (had_chat and !valid_primary) {
        if (e.draft) |*d| d.deinit(a.gpa);
        e.draft = null;
        if (e.split) |*s| {
            if (s.drafts.items[s.focus]) |*d| d.deinit(a.gpa);
            s.drafts.items[s.focus] = null;
        }
    }
    var useful = valid_primary or hasPrompt(e.draft);
    useful = cleanGroup(a, &e.group, &seen) or useful;
    if (e.split) |*s| {
        for (s.panes.items, 0..) |*id, ix| {
            const had_pane_chat = id.* != null;
            const valid = cleanChat(a, id, false, &seen);
            if (had_pane_chat and !valid) {
                if (s.drafts.items[ix]) |*d| d.deinit(a.gpa);
                s.drafts.items[ix] = null;
            }
            useful = valid or hasPrompt(s.drafts.items[ix]) or useful;
            useful = cleanGroup(a, &s.groups[ix], &seen) or useful;
        }
    }
    // An intentionally empty pane is still a closable context. Missing,
    // archived or already-open chats alone must not manufacture blank tabs.
    return useful or !seen;
}

pub fn reopen(a: *App) void {
    while (a.tabs.popClosedEntry()) |value| {
        var e = value;
        defer e.deinit(a.gpa);
        if (!cleanEntry(a, &e)) continue;
        parkActive(a);
        // A genuine empty placeholder may be reused; a composer with work or
        // attachments must never be consumed by a reopen operation.
        e.reuse_placeholder = a.tabs.items.items.len == 1 and a.tabs.current() == null and a.tabs.layout() == null and a.composer.text().len == 0 and @import("app_attachments.zig").count(a) == 0;
        // On success this chat allocation transfers into Tabs and remains
        // alive through the unarchive request; no fallible duplicate is needed.
        const undo_archive = if (e.auto_archived) e.chat else null;
        a.tabs.restoreClosed(&e) catch {
            a.tabs.pushClosed(e);
            e = .{};
            return;
        };
        if (undo_archive) |id| a.setArchived(id, false);
        a.view.split_reveal = null;
        a.view.strip.expanded = null;
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        const pane = if (a.tabs.layout()) |s| s.focus else null;
        a.view.strip.focused = .{ .chat = pane orelse 0 };
        const back = a.tabs.unpark(a.tabs.active, pane) orelse a.tabs.unpark(a.tabs.active, null);
        a.select(a.tabs.current(), null);
        if (back) |d| drafts.adopt(a, d);
        a.rememberTabs();
        a.redraw();
        return;
    }
}

fn archivedFixture(h: *Harness) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"a","title":"Alpha","archived":true},{"id":"b","title":"Beta","archived":false}]
    , .{});
    defer parsed.deinit();
    try h.a.chats.replace(parsed.value);
}

test "closed history restores the original top-tab position and multiple LIFO entries (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.openChat("b", null);
    h.a.newTab();
    h.a.composer.set("Unrelated current work");
    h.a.closeTab(0);
    h.a.closeTab(0);
    h.a.reopenClosedTab();
    try testing.expect(h.a.tabs.items.items[0] != null);
    try testing.expectEqualStrings("b", h.a.tabs.items.items[0].?);
    h.a.reopenClosedTab();
    try testing.expectEqualStrings("a", h.a.tabs.items.items[0].?);
    try testing.expectEqualStrings("b", h.a.tabs.items.items[1].?);
    h.a.showTab(2);
    try testing.expectEqualStrings("Unrelated current work", h.a.composer.text());
}

test "closed history restores a split draft and unequal layout without replacing surviving work (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.vertical);
    h.a.composer.set("Closed pane draft");
    h.a.tabs.resize(.down);
    const first = h.a.tabs.layout().?.shares.items[0];
    h.a.closeFocused();
    h.a.reopenClosedTab();
    const s = h.a.tabs.layout() orelse return error.MissingSplit;
    try testing.expectEqual(@as(usize, 2), s.panes.items.len);
    try testing.expectEqual(@import("tabs.zig").Axis.vertical, s.axis);
    try testing.expectApproxEqAbs(first, s.shares.items[0], 0.001);
    try testing.expectEqualStrings("Closed pane draft", h.a.composer.text());
    try testing.expectEqualStrings("a", s.panes.items[0].?);
}

test "closed history restores an inactive panel tab and its exact draft position (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.a.tabs.isolateWorkspace();
    h.a.addChatTab(true);
    h.a.composer.set("Middle draft");
    h.a.addChatTab(true);
    h.a.openChat("b", null);
    h.a.view.strip.pending = .{ .close_panel_tab = .{ .pane = 0, .tab = 1 } };
    @import("view_tab_strip.zig").settle(&h.a);
    h.a.reopenClosedTab();
    const s = h.a.tabs.layout() orelse return error.MissingPanelTabs;
    try testing.expectEqual(@as(usize, 3), s.groups[0].count());
    try testing.expectEqual(@as(usize, 1), s.groups[0].active);
    try testing.expectEqualStrings("Middle draft", h.a.composer.text());
    h.a.showPaneTab(2);
    try testing.expectEqualStrings("b", h.a.selected.?);
}

test "closed history skips deleted and already-open chats while preserving current drafts (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.closeFocused();
    h.a.newTab();
    h.a.openChat("a", null);
    const count = h.a.tabs.items.items.len;
    h.a.reopenClosedTab();
    try testing.expectEqual(count, h.a.tabs.items.items.len);
    h.a.closeFocused();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"b","title":"Beta","archived":false}]
    , .{});
    defer parsed.deinit();
    try h.a.chats.replace(parsed.value);
    h.a.composer.set("Keep current draft");
    h.a.reopenClosedTab();
    try testing.expect(h.a.selected == null);
    try testing.expectEqualStrings("Keep current draft", h.a.composer.text());
}

test "closed history merging a reopened pane preserves a new surviving pane draft (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.composer.set("Closed pane draft");
    h.a.closeFocused();
    h.a.replaceCurrent(null);
    h.a.composer.set("New surviving pane draft");
    h.a.reopenClosedTab();
    try testing.expectEqualStrings("Closed pane draft", h.a.composer.text());
    h.a.focusPane(0);
    try testing.expectEqualStrings("New surviving pane draft", h.a.composer.text());
}

test "closed history closing a background split workspace captures its newest focused draft (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.vertical);
    h.a.composer.set("Newest workspace draft");
    h.a.newWorkspaceSession();
    h.a.composer.set("Independent workspace draft");
    h.a.closeTab(0);
    h.a.reopenClosedTab();
    try testing.expectEqualStrings("Newest workspace draft", h.a.composer.text());
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    h.a.showTab(1);
    try testing.expectEqualStrings("Independent workspace draft", h.a.composer.text());
}

test "closed history never treats pre-existing archival as an undoable close side effect (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try archivedFixture(&h);
    h.a.closeArchiving(true);
    h.a.reopenClosedTab();
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.findChat("a").?.archived);
}

test "closed history only undoes its own autoarchive, not external archival (#455)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.closeArchiving(true);
    try archivedFixture(&h); // synthetic response to the close's archive request
    h.a.reopenClosedTab();
    try testing.expect(h.a.selected != null);
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.a.closeArchiving(false);
    h.a.setArchived("a", true);
    h.a.reopenClosedTab();
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.findChat("a").?.archived);
}
