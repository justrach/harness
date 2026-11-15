//! Exercise saved custom chords through production dispatch, not just Settings.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const shortcuts = @import("shortcuts.zig");
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const custom: ui.Shortcut = .{ .key = 'y', .cmd = true, .alt = true };
const strip = @import("view_tab_strip.zig");

fn setBinding(h: *Harness, key: []const u8, combo: []const u8) !void {
    for (shortcuts.all) |entry| if (entry.slot == null and std.mem.eql(u8, entry.key, key)) {
        h.a.settings.setCombo(entry, combo);
        return;
    };
    return error.ShortcutNotFound;
}

// Start with real mounted folder-search focus: shortcuts must not depend on
// the composer being the active field.
fn folderSearch(h: *Harness) void {
    strip.open(&h.a, .folder, strip.active(&h.a), .{ .x = 400, .y = 5, .w = 140, .h = 32 });
    h.t.settle(1);
    h.t.typeText("field");
    h.t.settle(0.1);
}

test "deep shortcuts rebound new and split defaults stay replaced inside folder search" {
    for ([_][]const u8{ "newSession", "splitTerminal", "splitTerminalDown" }) |key| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try rebind(&h, key);
        folderSearch(&h);
        const before = h.a.tabs.items.items.len;
        const old: ui.Shortcut = if (std.mem.eql(u8, key, "newSession")) .{ .key = 't', .cmd = true } else .{ .key = 'd', .cmd = true, .shift = std.mem.eql(u8, key, "splitTerminalDown") };
        h.press(old);
        try testing.expectEqual(before, h.a.tabs.items.items.len);
        try testing.expect(h.a.tabs.layout() == null);
        try testing.expect(h.a.view.strip.menu == .folder);
        try testing.expectEqualStrings("field", h.a.view.strip.query.text());
        h.press(custom);
        if (std.mem.eql(u8, key, "newSession")) {
            try testing.expect(h.a.view.open_chooser.open);
            try testing.expectEqual(before, h.a.tabs.items.items.len);
            try testing.expectEqual(@import("app_open_chooser.zig").Intent.new_workspace_tab, h.a.view.open_chooser.intent);
            @import("app_open_chooser.zig").choose(&h.a, "local-project");
            try testing.expectEqual(before + 1, h.a.tabs.items.items.len);
            try testing.expect(h.a.tabs.find("a") != null);
        } else try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    }
}

test "deep shortcuts folder search yields to saved cycling close-only and reopen chords" {
    for ([_][]const u8{ "nextSession", "prevSession", "closeTabWithoutArchiving", "reopenClosedTab" }) |key| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.newTab();
        h.a.openChat("b", null);
        if (std.mem.eql(u8, key, "reopenClosedTab")) h.a.closeArchiving(false) else h.a.showTab(0);
        try rebind(&h, key);
        folderSearch(&h);
        h.press(custom);
        try testing.expect(h.a.view.strip.menu == null);
        try testing.expectEqualStrings("b", h.a.selected.?);
        try testing.expect(!h.a.findChat("a").?.archived);
        try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
        h.t.typeText("Typed after navigation");
        try testing.expectEqualStrings("Typed after navigation", h.a.composer.text());
        try testing.expectEqualStrings("field", h.a.view.strip.query.text());
    }
}

test "deep shortcuts modal palette and model picker block underlying workspace navigation" {
    for ([_]bool{ false, true }) |model| {
        for ([_]ui.Shortcut{
            .{ .key = 'p', .cmd = true, .shift = true },
            .{ .key = ui.Shortcut.tab, .ctrl = true },
            .{ .key = ']', .cmd = true },
            .{ .key = '1', .cmd = true },
        }) |key| {
            var h: Harness = undefined;
            try h.init(true);
            defer h.deinit();
            h.a.newTab();
            h.a.openChat("b", null);
            h.a.showTab(0);
            h.t.settle(1);
            h.press(if (model) .{ .key = '/', .cmd = true } else .{ .key = 'k', .cmd = true });
            h.press(key);
            try testing.expectEqualStrings("a", h.a.selected.?);
            try testing.expect(h.a.view.strip.menu == null);
            try testing.expect(if (model) h.a.picker != .none else h.a.view.palette.open);
        }
    }
}

test "deep shortcuts folder Shift Down targets the first pinned action and Up returns to projects" {
    for ([_]bool{ false, true }) |footer| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        folderSearch(&h);
        h.a.view.strip.footer_folder = footer;
        h.t.settle(1);
        const projects = h.a.view.strip.rows - 2;
        try testing.expect(projects > 0);
        h.press(.{ .key = ui.Shortcut.down, .shift = true });
        try testing.expectEqual(projects, h.a.view.strip.cursor);
        h.press(.{ .key = ui.Shortcut.up });
        try testing.expectEqual(projects - 1, h.a.view.strip.cursor);
        h.press(.{ .key = ui.Shortcut.down, .shift = true });
        h.t.key(.enter);
        h.t.settle(1);
        if (footer) {
            try testing.expect(h.a.view.open_chooser.open);
        } else try testing.expect(h.a.new_no_project);
    }
}

test "deep shortcuts numbered session jump leaves Settings without replacing the source tab" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.setText("sidebarLastActivity", "all");
    h.t.settle(1);
    const visible = @import("view_sidebar.zig").visibleSessionIds(&h.t.ctx, &h.a);
    var slot: ?usize = null;
    for (visible, 0..) |id, ix| if (std.mem.eql(u8, id, "b")) {
        slot = ix;
        break;
    };
    try testing.expect(slot != null and slot.? < 9);
    h.press(.{ .key = ',', .cmd = true });
    try testing.expect(h.a.view.settings_open);
    h.press((ui.Shortcut{ .key = @as(u21, '1') + @as(u21, @intCast(slot.?)), .cmd = true }).native());
    try testing.expect(!h.a.view.settings_open);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.tabs.find("a") != null);
}

test "deep shortcuts persisted named space chord dispatches rather than requiring a literal space" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try setBinding(&h, "toggleSidebar", "mod-alt-space");
    h.press(.{ .key = ' ', .cmd = true, .alt = true });
    try testing.expect(!h.a.view.sidebar_open);
}

fn expectOneFolderHighlight(h: *Harness) !void {
    const selected = @import("theme.zig").colors(true).selected;
    var count: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.x < 400 or node.rect.y <= 42 or node.rect.h != 32) continue;
        if (node.style.background) |bg| if (std.meta.eql(bg, selected)) {
            count += 1;
        };
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "deep shortcut integration folder mouse hover and Enter share one cursor (#699)" {
    for ([_]bool{ false, true }) |footer| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        folderSearch(&h);
        h.a.view.strip.footer_folder = footer;
        h.t.settle(0.2);
        h.press(.{ .key = ui.Shortcut.down });
        try testing.expectEqual(@as(usize, 1), h.a.view.strip.cursor);
        var row: ?ui.Rect = null;
        for (h.t.ctx.nodes.items) |node| {
            if (node.content == .text and node.rect.x >= 400 and node.rect.y > 42 and std.mem.eql(u8, node.content.text.str, "fieldnotes")) {
                row = node.rect;
                break;
            }
        }
        const target = row orelse return error.MissingSyntheticFolderRow;
        h.t.moveTo(target.x + target.w / 2, target.y + target.h / 2);
        try testing.expectEqual(@as(usize, 0), h.a.view.strip.cursor);
        try expectOneFolderHighlight(&h);
        // A keyboard choice must win over the now-stationary pointer.
        h.press(.{ .key = ui.Shortcut.down });
        try testing.expectEqual(@as(usize, 1), h.a.view.strip.cursor);
        try expectOneFolderHighlight(&h);
        h.t.moveTo(target.x + target.w / 2, target.y + target.h / 2);
        try testing.expectEqual(@as(usize, 0), h.a.view.strip.cursor);
        try expectOneFolderHighlight(&h);
        h.press(.{ .key = ui.Shortcut.enter });
        try testing.expect(h.a.view.strip.menu == null);
        try testing.expect(!h.a.new_no_project);
    }
}

test "deep shortcut integration archive-on-close protects queued sends before navigation clears the queue (#50)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var rows = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"queued-synthetic","text":"A queued synthetic prompt"}]
    , .{});
    defer rows.deinit();
    try h.a.queue.replace(rows.value);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"Mutate\":{}}", .{});
    h.a.engine.state = .connected;
    h.a.settings.set(.archive_sessions_on_close, true);
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expect(h.a.selected == null);
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try testing.expect(!std.mem.eql(u8, parsed.value.object.get("method").?.string, "Mutate"));
    }
}

test "deep shortcut integration empty Cmd Enter respects newest queued row gate and host capabilities (#316)" {
    for ([_]bool{ false, true }) |capable| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
        h.a.engine.state = .connected;
        h.a.caps = .{ .queue = true, .actions = capable };
        var rows = try std.json.parseFromSlice(std.json.Value, testing.allocator, if (capable)
            \\[{"id":"older","text":"Synthetic earlier prompt"},{"id":"newest","text":"Synthetic held prompt","deliveryGate":{"kind":"reviewRequired"}}]
        else
            \\[{"id":"newest","text":"Synthetic prompt"}]
        , .{});
        defer rows.deinit();
        try h.a.queue.replace(rows.value);
        h.t.ctx.focus = 0; // The hint remains global after clicking a transcript.
        h.press(.{ .key = ui.Shortcut.enter, .cmd = true });
        for (h.a.engine.sent.items) |frame| {
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
            defer parsed.deinit();
            try testing.expect(!std.mem.eql(u8, parsed.value.object.get("method").?.string, "SendQueuedMessageNow"));
        }
    }
}

test "deep shortcut integration queue send permits only a current capable ungated row (#316)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    h.a.engine.state = .connected;
    h.a.caps = .{ .queue = true, .actions = true };
    var rows = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"newest","text":"Synthetic prompt"} ]
    , .{});
    defer rows.deinit();
    try h.a.queue.replace(rows.value);
    h.a.queueSendNow("stale-row");
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true });
    var sends: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.object.get("method").?.string, "SendQueuedMessageNow")) continue;
        sends += 1;
        try testing.expectEqualStrings("newest", parsed.value.object.get("params").?.object.get("id").?.string);
    }
    try testing.expectEqual(@as(usize, 1), sends);
}

test "deep shortcuts first close cancellation and saved choice survive reopening (#617)" {
    for ([_]bool{ false, true }) |archive| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.press(.{ .key = 'w', .cmd = true });
        try testing.expect(h.a.view.close_choice);
        h.press(.{ .key = ui.Shortcut.escape });
        try testing.expect(!h.a.view.close_choice);
        try testing.expect(!h.a.settings.get(.archive_on_close_chosen));
        try testing.expectEqualStrings("a", h.a.selected.?);
        h.press(.{ .key = 'w', .cmd = true });
        try h.t.clickText(if (archive) "Archive it" else "Just close it");
        h.t.settle(1);
        try testing.expect(h.a.selected == null);
        try testing.expect(h.a.settings.get(.archive_on_close_chosen));
        try testing.expectEqual(archive, h.a.settings.get(.archive_sessions_on_close));
        h.press(.{ .key = 't', .cmd = true, .shift = true });
        try testing.expectEqualStrings("a", h.a.selected.?);
        try testing.expect(!h.a.findChat("a").?.archived);
        h.press(.{ .key = 'w', .cmd = true });
        try testing.expect(!h.a.view.close_choice);
        try testing.expect(h.a.selected == null);
    }
}

test "deep shortcuts running close warning restarts its deadline and preserves a replacement notice (#723)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working"}]
    , .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    h.a.closeArchiving(true);
    h.t.advance(4.9);
    const ac = @import("archive_close.zig");
    try testing.expectEqualStrings(ac.running_notice, h.a.view.sidebar_notice[0..h.a.view.sidebar_notice_len]);
    try testing.expect(!h.a.findChat("a").?.archived);
    const first_deadline = h.a.view.sidebar_notice_until.?;
    h.a.archiveClosed("a", true);
    try testing.expect(h.a.view.sidebar_notice_until.? > first_deadline);
    h.t.advance(0.2);
    try testing.expect(h.a.view.sidebar_notice_len > 0);
    h.a.setSidebarNotice("Synthetic persistent error", null);
    h.t.advance(6);
    try testing.expectEqualStrings("Synthetic persistent error", h.a.view.sidebar_notice[0..h.a.view.sidebar_notice_len]);
    h.a.archiveClosed("a", true);
    h.t.advance(5.1);
    try testing.expectEqual(@as(usize, 0), h.a.view.sidebar_notice_len);
    try testing.expectEqual(@import("workspace.zig").Status.working, @import("workspace.zig").statusOf(h.a.sessions.items, "a"));
}

test "deep shortcuts child tabs stay between their workspace parent and the next workspace (#26)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("b", null);
    h.a.newTab();
    h.t.settle(1);
    var next_y: f32 = std.math.inf(f32);
    for (h.t.ctx.nodes.items) |node| {
        if (node.content == .text and node.rect.x < h.a.view.sidebar_width and std.mem.eql(u8, node.content.text.str, "New session")) next_y = @min(next_y, node.rect.y);
    }
    try testing.expect(std.math.isFinite(next_y));
    var parent_y: f32 = std.math.inf(f32);
    var child_y: f32 = 0;
    var alpha_y: f32 = 0;
    var beta_count: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (node.content != .text or node.rect.x >= h.a.view.sidebar_width or node.rect.y >= next_y) continue;
        if (std.mem.eql(u8, node.content.text.str, "Beta")) {
            parent_y = @min(parent_y, node.rect.y);
            child_y = @max(child_y, node.rect.y);
            beta_count += 1;
        }
        if (std.mem.eql(u8, node.content.text.str, "Alpha")) alpha_y = node.rect.y;
    }
    try testing.expectEqual(@as(usize, 2), beta_count);
    try testing.expect(parent_y < alpha_y and alpha_y < child_y and child_y < next_y);
}

test "deep shortcut integration project folder confirmation survives a click inside the palette (#178)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"path":"/synthetic/chosen","entries":[]}}
    , .{});
    h.a.engine.state = .connected;
    h.a.addFolder();
    h.t.settle(1);
    try h.t.clickText("Add folder…");
    for (0..3) |_| {
        _ = h.a.engine.pump();
        h.t.settle(0.2);
    }
    const flow = @import("app_project_setup.zig");
    try testing.expect(flow.ready(&h.a.view.project_setup) != null);
    try h.t.clickText("Add folder");
    h.t.settle(0.1);
    try testing.expect(h.a.view.project_setup.open and h.a.view.project_setup.step == .folders);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true });
    try testing.expect(h.a.view.project_setup.step == .details);
    const folder = h.a.view.project_setup.folder orelse return error.MissingConfirmedFolder;
    try testing.expectEqualStrings("/synthetic/chosen", folder.path);
    try testing.expectEqual(@as(usize, 2), h.a.spaces.items.len);
}

test "deep shortcuts destination sheet harmless title clicks stay inside the modal (#178)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    @import("app_open_chooser.zig").open(&h.a, .new_project);
    h.t.settle(1);
    try h.t.clickText("Pick a computer and the folder to work in.");
    h.t.settle(0.1);
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expectEqual(@import("app_open_chooser.zig").Intent.new_project, h.a.view.open_chooser.intent);
    // Outside remains a real dismissal, not a blanket no-op workaround.
    h.t.click(20, 300);
    h.t.settle(0.1);
    try testing.expect(!h.a.view.open_chooser.open);
}

test "deep shortcuts starting folder edit title clicks preserve confirmation mode (#178, #305)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"path":"/synthetic/chosen","entries":[]}}
    , .{});
    h.a.engine.state = .connected;
    const flow = @import("app_project_setup.zig");
    flow.openStartingFolder(&h.a);
    for (0..3) |_| {
        _ = h.a.engine.pump();
        h.t.settle(0.2);
    }
    try testing.expect(flow.ready(&h.a.view.project_setup) != null);
    try h.t.clickText("New project starting folder");
    h.t.settle(0.1);
    try testing.expect(h.a.view.project_setup.open);
    try testing.expect(h.a.settings.projectFolderOverride("local") == null);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true });
    try testing.expect(!h.a.view.project_setup.open);
    try testing.expectEqualStrings("/synthetic/chosen", h.a.settings.projectFolderOverride("local").?);
    try testing.expectEqual(@as(usize, 2), h.a.spaces.items.len);
}

fn dispatchSyntheticItem(h: *Harness, id: u64, value: anytype) !void {
    const frame = try std.json.Stringify.valueAlloc(testing.allocator, .{ .id = id, .item = value }, .{});
    defer testing.allocator.free(frame);
    try h.a.engine.mux.dispatch(frame);
}

test "deep shortcuts stopped inactive peer drops thinking trailer through real session callbacks (#312)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("b", null);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"WatchSessions":[{"chatId":"a","status":"working"}],"WatchDocMessages":{"reset":[{"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic peer prompt"}]},{"id":"reply","role":"assistant","status":"streaming","parts":[{"id":"p","kind":"text","text":"Synthetic peer partial reply"}]}]}}
    , .{});
    h.a.engine.state = .connected;
    // Retry goes through the normal sidebar-watch setup and its private
    // onSessions callback, without starting a network thread or an app.
    h.a.w_sessions.retry_at = h.a.now;
    _ = h.a.tick(h.a.now);
    const sessions_watch = h.a.w_sessions.id orelse return error.MissingSessionWatch;
    h.a.syncPeers();
    const peer_watch = h.a.peer("a").?.watch orelse return error.MissingPeerWatch;
    for (h.a.engine.queued.items) |*frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.*, .{});
        defer parsed.deinit();
        const id = @as(u64, @intCast(parsed.value.object.get("id").?.integer));
        if (id != peer_watch and id != sessions_watch) continue;
        const snapshot = parsed.value.object.get("ok") orelse continue;
        const live = try std.json.Stringify.valueAlloc(testing.allocator, .{ .id = id, .item = snapshot }, .{});
        testing.allocator.free(frame.*);
        frame.* = live;
    }
    _ = h.a.engine.pump();
    try testing.expectEqual(@as(usize, 2), h.a.peer("a").?.transcript.entries.items.len);
    // Session protocol timestamps are RFC3339 strings. Keep the synthetic
    // row fresh so this tests stop ownership, not the unrelated stale gate.
    try dispatchSyntheticItem(&h, sessions_watch, &.{.{ .chatId = "a", .status = "working", .startedAt = "2026-01-01T00:00:00Z", .updatedAt = "2099-01-01T00:00:00Z" }});
    h.t.settle(0.2);
    try testing.expect(h.t.containsText("Working out the next step"));
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
    try dispatchSyntheticItem(&h, sessions_watch, &.{.{ .chatId = "a", .status = "idle" }});
    h.t.settle(0.2);
    try testing.expect(!h.t.containsText("Working out the next step"));
    h.t.advance(2);
    try testing.expect(!h.t.containsText("Working out the next step"));
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
    // The stop notification, not focus or a rewritten final doc, ended it.
    try testing.expect(h.a.peer("a").?.transcript.entries.items[1].status == .streaming);
    // The other historical case is a completed trailing user entry. It must
    // show the real active run, but never imply liveness after session stop.
    const user_tail = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"later-user","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic pending peer prompt"}]}]}
    , .{});
    defer user_tail.deinit();
    try dispatchSyntheticItem(&h, peer_watch, user_tail.value);
    try dispatchSyntheticItem(&h, sessions_watch, &.{.{ .chatId = "a", .status = "working", .startedAt = "2026-01-01T00:00:00Z", .updatedAt = "2099-01-01T00:00:00Z" }});
    h.t.settle(0.2);
    try testing.expect(h.t.containsText("Working out the next step"));
    try dispatchSyntheticItem(&h, sessions_watch, &.{.{ .chatId = "a", .status = "idle" }});
    h.t.settle(0.2);
    try testing.expect(!h.t.containsText("Working out the next step"));
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.layout().?.focus);
}

test "file editor mounted editable file sends fenced save only after explicit Save" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ReadWorkspaceFile":{"checkoutId":"synthetic-checkout","path":"notes.txt","text":"original synthetic file","contentHash":"initial-hash","size":23,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"status":"written","file":{"path":"notes.txt","contentHash":"saved-hash","size":16}}}
    , .{});
    h.a.engine.state = .connected;
    @import("app_files.zig").openFile(&h.a, "notes.txt");
    h.t.settle(1);
    try h.t.clickText("original synthetic file");
    h.press(.{ .key = 'a', .cmd = true });
    h.t.typeText("SYNTHETIC_EDITED");
    h.t.settle(0.1);
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try testing.expect(!std.mem.eql(u8, parsed.value.object.get("method").?.string, "WriteWorkspaceFile"));
    }
    try h.t.clickText("Save file");
    h.t.settle(0.2);
    var writes: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.object.get("method").?.string, "WriteWorkspaceFile")) continue;
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("a", params.get("chatId").?.string);
        try testing.expectEqualStrings("notes.txt", params.get("path").?.string);
        try testing.expectEqualStrings("initial-hash", params.get("expectedContentHash").?.string);
        try testing.expectEqualStrings("synthetic-checkout", params.get("expectedCheckoutId").?.string);
        try testing.expectEqualStrings("SYNTHETIC_EDITED", params.get("text").?.string);
        writes += 1;
    }
    try testing.expectEqual(@as(usize, 1), writes);
}

// Exercise AppKit's real interpretation of shifted editing keys, not an
// artificial TextOp that would discard the modifier before reaching the field.
const NativeEditing = struct {
    const nanoui = @import("nanoui");
    const objc = nanoui.objc;
    runtime: nanoui.App,
    window: *nanoui.Window,

    fn init(n: *@This(), a: *@import("app.zig").App) !void {
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        n.runtime = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .options = .{ .quit_on_last_window_closed = false },
            .nsapp = nsapp,
            .delegate = nsapp,
            .flags = .{ .hidden = true },
        };
        a.view.focus_composer = true;
        n.window = try n.runtime.newWindow(.{
            .width = 1200,
            .height = 780,
            .visible = false,
            .content = .{ .view = .init(a, @import("view.zig").view) },
        });
    }
    fn deinit(n: *@This()) void {
        if (n.runtime.main_menu) |menu| {
            objc.msg(void, n.runtime.nsapp, "setMainMenu:", .{@as(?objc.Object, null)});
            menu.destroy();
            n.runtime.main_menu = null;
        }
        n.runtime.running = true;
        n.window.close();
        nanoui.runFor(0.1);
        n.runtime.running = false;
        n.runtime.windows.deinit(testing.allocator);
    }
    fn key(n: *@This(), chars: []const u8, code: u16, flags: objc.NSUInteger) void {
        const surface = n.window.surface.?;
        surface.ctx.frame = 0; // One synchronous frame for a never-shown fixture.
        const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
            @as(objc.NSUInteger, 10),                                         objc.CGPoint{},          flags,                @as(f64, 0),
            objc.msg(objc.NSInteger, n.window.nswindow, "windowNumber", .{}), @as(?objc.Object, null), objc.nsString(chars), objc.nsString(chars),
            objc.NO,                                                          code,
        });
        objc.msg(void, surface.nsview, "keyDown:", .{event});
    }
};

test "deep shortcuts native Cmd W on a fresh chat preserves its hidden window and running sessions (#55)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const objc = @import("nanoui").objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.closeArchiving(false); // Leave just the sole fresh-chat canvas.
    var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working","updatedAt":1}]
    , .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    var n: NativeEditing = undefined;
    try n.init(&h.a);
    defer n.deinit();
    try @import("native_menu.zig").install(&n.runtime, &h.a);
    const sent = h.a.engine.sent.items.len;
    const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10),                                         objc.CGPoint{},          @as(objc.NSUInteger, 1 << 20), @as(f64, 0),
        objc.msg(objc.NSInteger, n.window.nswindow, "windowNumber", .{}), @as(?objc.Object, null), objc.nsString("w"),            objc.nsString("w"),
        objc.NO,                                                          @as(u16, 13),
    });
    try testing.expect(objc.msg(objc.BOOL, n.runtime.main_menu.?.ns, "performKeyEquivalent:", .{event}));
    try testing.expectEqual(@as(usize, 1), n.runtime.windows.items.len);
    try testing.expect(n.window.surface != null and !n.runtime.stopping);
    try testing.expect(h.a.selected == null);
    try testing.expectEqual(sent, h.a.engine.sent.items.len);
    try testing.expectEqual(@import("workspace.zig").Status.working, @import("workspace.zig").statusOf(h.a.sessions.items, "a"));
}

test "deep shortcuts native shifted Backspace and Delete edit both composer and palette (#339)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const pool = @import("nanoui").objc.Pool.push();
    defer pool.pop();
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var n: NativeEditing = undefined;
    try n.init(&h.a);
    defer n.deinit();
    for ([_]bool{ false, true }) |palette| {
        if (palette) n.key("k", 40, 1 << 20);
        n.key("abcd", 0, 0);
        const buffer = if (palette) &h.a.view.palette.query else &h.a.composer;
        try testing.expectEqualStrings("abcd", buffer.text());
        n.key("\u{7f}", 51, 1 << 17);
        try testing.expectEqualStrings("abc", buffer.text());
        n.key("\u{f702}", 123, 1 << 20); // Cmd+Left: start of line.
        n.key("\u{f728}", 117, 1 << 17);
        try testing.expectEqualStrings("bc", buffer.text());
    }
}

fn rebind(h: *Harness, key: []const u8) !void {
    for (shortcuts.all) |entry| if (entry.slot == null and std.mem.eql(u8, entry.key, key)) {
        h.a.settings.setCombo(entry, "mod-alt-y");
        return;
    };
    return error.ShortcutNotFound;
}

test "retention custom sidebar chord replaces rather than supplements its default (#793)" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try rebind(&h, "toggleSidebar");
    h.press(.{ .key = 'b', .cmd = true });
    try testing.expect(h.a.view.sidebar_open);
    h.press(custom);
    try testing.expect(!h.a.view.sidebar_open);
    h.press(custom);
    try testing.expect(h.a.view.sidebar_open);
}

test "retention custom new chat and project chords dispatch their saved bindings (#792, #793)" {
    for ([_][]const u8{ "newSession", "newProject", "openProjectPicker", "openModelPicker" }) |key| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try rebind(&h, key);
        const before = h.a.tabs.items.items.len;
        h.press(custom);
        if (std.mem.eql(u8, key, "newSession")) {
            try testing.expect(h.a.view.open_chooser.open);
            try testing.expectEqual(before, h.a.tabs.items.items.len);
            try testing.expectEqual(@import("app_open_chooser.zig").Intent.new_workspace_tab, h.a.view.open_chooser.intent);
            @import("app_open_chooser.zig").choose(&h.a, "local-project");
            try testing.expectEqual(before + 1, h.a.tabs.items.items.len);
            try testing.expect(h.a.tabs.find("a") != null);
        } else if (std.mem.eql(u8, key, "newProject")) {
            try testing.expect(h.a.view.open_chooser.open);
            try testing.expectEqual(@import("app_open_chooser.zig").Intent.new_project, h.a.view.open_chooser.intent);
        } else if (std.mem.eql(u8, key, "openProjectPicker")) {
            try testing.expectEqual(@import("view_tab_strip.zig").Menu.folder, h.a.view.strip.menu.?);
        } else try testing.expect(h.a.picker == .model);
    }
}

test "retention custom panel chords reach their actual panel actions (#793)" {
    for ([_][]const u8{ "toggleFiles", "toggleChanges", "toggleTerminal", "splitTerminal", "splitTerminalDown" }) |key| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try rebind(&h, key);
        h.press(custom);
        if (std.mem.eql(u8, key, "toggleFiles")) {
            try testing.expect(h.a.panels.files_open);
        } else if (std.mem.eql(u8, key, "toggleChanges") or std.mem.eql(u8, key, "toggleTerminal")) {
            try testing.expect(h.a.panels.host_open);
        } else {
            // Keyboard splits inherit the source destination without a picker,
            // including when dispatched through a saved custom binding.
            const split = h.a.tabs.layout() orelse return error.MissingCustomShortcutSplit;
            try testing.expectEqual(@as(usize, 2), split.panes.items.len);
            try testing.expectEqual(if (std.mem.eql(u8, key, "splitTerminal")) @import("tabs.zig").Axis.horizontal else .vertical, split.axis);
            try testing.expect(h.a.view.strip.menu == null);
            try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
            try testing.expectEqualStrings("local", h.a.draftDevice().?);
        }
    }
}

test "retention custom cycle and close chords preserve their conversation (#349, #793)" {
    for ([_][]const u8{ "nextSession", "prevSession", "closeTabWithoutArchiving" }) |key| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.newTab();
        h.a.openChat("b", null);
        h.a.showTab(0);
        h.t.settle(1);
        try rebind(&h, key);
        h.press(custom);
        try testing.expectEqualStrings("b", h.a.selected.?);
        try testing.expect(!h.a.findChat("a").?.archived);
        if (std.mem.eql(u8, key, "closeTabWithoutArchiving")) {
            try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
        } else try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    }
}
