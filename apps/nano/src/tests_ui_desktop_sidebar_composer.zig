//! Current desktop navigation/composer contracts, with made-up state only.
//! Import from tests.zig; the orchestrator owns running the shared build.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const sidebar = @import("view_sidebar.zig");
const composer = @import("view_composer.zig");
const draft = @import("view_newchat.zig");
const menus = @import("view_sidebar_menus.zig");
const write = @import("view_write.zig");
const settings = @import("settings.zig");
const testing = std.testing;

test {
    _ = @import("tests_ui_sidebar_fade.zig");
}

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, dark: bool) !void {
        theme.registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.account.scope = .local;
        const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-project","deviceId":"synthetic-device","path":"/work/synthetic-notes","gitDetected":false}]
        , .{});
        defer spaces.deinit();
        try h.a.spaces.replace(spaces.value);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-chat","deviceId":"synthetic-device","title":"Synthetic navigation conversation","spaceId":"synthetic-project","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{
            .width = 1200,
            .height = 780,
            .dark = dark,
            .theme = theme.ui(dark),
        });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "retention 194 open workspace rows use each chat harness mark" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"claude","title":"Claude pane","archived":false,"config":{"harness":"claude-code"}},
        \\  {"id":"codex","title":"Codex pane","archived":false,"config":{"harness":"codex"}},
        \\  {"id":"unknown","title":"Future pane","archived":false,"config":{"harness":"future-agent"}} ]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.openChat("claude", null);
    try h.a.tabs.isolateWorkspace();
    h.a.addChatTab(false);
    h.a.openChat("codex", null);
    h.a.addChatTab(false);
    h.a.openChat("unknown", null);
    h.t.settle(1);
    h.snap("retention-194-mixed-harness");
    inline for (.{ .{ "Claude pane", "claude-mark" }, .{ "Codex pane", "openai-mark" }, .{ "Future pane", "graff-mark" } }) |pair| {
        var found = false;
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |text| if (std.mem.eql(u8, text.str, pair[0]) and node.rect.x < sidebar.widthOf(&h.a) and node.rect.y < 210) {
                for (h.t.ctx.nodes.items) |mark| switch (mark.content) {
                    .image => |image| if (@abs(mark.rect.y + mark.rect.h / 2 - node.rect.y - node.rect.h / 2) < 3 and mark.rect.x < node.rect.x) {
                        if (image.source == .encoded and std.mem.eql(u8, image.source.encoded, @import("icons_svg").get(pair[1]))) found = true;
                    },
                    else => {},
                };
            },
            else => {},
        };
        try testing.expect(found);
    }
    // Harness identity does not replace the ordinary list's independent dot.
    var status_dot = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.w == 6 and node.rect.h == 6 and node.rect.x < 30 and node.rect.y > 220 and node.style.background != null) status_dot = true;
    }
    try testing.expect(status_dot);
}

fn textNode(t: *ui.Tester, label: []const u8) ?u32 {
    for (t.ctx.nodes.items, 0..) |node, i| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, label)) return @intCast(i),
        else => {},
    };
    return null;
}

test "draft target controls keep four points around the computer and project" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const code = textNode(&h.t, "Code") orelse return error.NoModeChip;
    const mode = h.t.ctx.node(h.t.ctx.node(code).parent).rect;
    const strip = @import("view_tab_strip.zig");
    var buf: [160]u8 = undefined;
    const label = try std.fmt.bufPrint(&buf, "Run on: {s}", .{strip.deviceLabel(&h.a, strip.device(&h.a, strip.active(&h.a)))});
    const node = textNode(&h.t, label) orelse return error.NoComputerChip;
    const computer = h.t.ctx.node(h.t.ctx.node(node).parent).rect;
    const project = h.a.view.space_anchor orelse return error.NoProjectChip;
    try testing.expectApproxEqAbs(@as(f32, 4), computer.x - mode.x - mode.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 4), project.x - computer.x - computer.w, 0.01);
}

test "desktop parity composer alignment matches the reference and compact width budget" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.dictation.probed.store(1, .release);
    // The shell keeps 234 points outside this pane (sidebar + panel chrome).
    h.t.resize(606, 440);
    h.t.settle(1);
    const pill = h.a.view.composer_anchor orelse return error.NoComposer;
    const field = h.t.ctx.rects.get(h.a.view.composer_id) orelse return error.NoComposerField;
    try testing.expectApproxEqAbs(@as(f32, 340), pill.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 49), pill.h, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 75), field.x - pill.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 212), field.w, 0.01);
    var controls: [3]ui.Rect = undefined;
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 28 and r.h == 28 and r.x > pill.x and r.x < pill.x + pill.w and r.y > pill.y and r.y < pill.y + pill.h) {
            if (n >= controls.len) return error.ExtraComposerControl;
            controls[n] = r;
            n += 1;
        }
    }
    try testing.expectEqual(controls.len, n);
    try testing.expectApproxEqAbs(@as(f32, 9), controls[0].x - pill.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2), controls[1].x - controls[0].x - controls[0].w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 9), pill.x + pill.w - controls[2].x - controls[2].w, 0.01);
    for (controls) |r| try testing.expectApproxEqAbs(pill.y + pill.h / 2, r.y + r.h / 2, 0.01);
    const model = h.a.view.chip_anchor orelse return error.NoModelChip;
    const code = textNode(&h.t, "Code") orelse return error.NoModeChip;
    const mode = h.t.ctx.node(h.t.ctx.node(code).parent).rect;
    const project = h.a.view.space_anchor orelse return error.NoProjectChip;
    try testing.expectApproxEqAbs(@as(f32, 10), model.x - pill.x, 0.01);
    try testing.expectApproxEqAbs(pill.y + pill.h + 8, model.y, 0.01);
    try testing.expectApproxEqAbs(model.y + 12, mode.y + mode.h / 2, 0.01);
    try testing.expectApproxEqAbs(model.y + 12, project.y + project.h / 2, 0.01);
    const last = textNode(&h.t, "Tour this project") orelse return error.NoStarter;
    const chip = h.t.ctx.node(h.t.ctx.node(last).parent).rect;
    try testing.expectApproxEqAbs(@as(f32, 24), pill.y - chip.y - chip.h, 0.01);
    h.snap("alignment-reference-width");

    // GPUI's compact_capacity is the measured field less eight points.
    // Six fewer pane points cross its 200-point compact minimum even empty.
    h.t.resize(600, 440);
    h.t.settle(1);
    try testing.expect(h.a.view.composer_expanded);
    try testing.expect(h.a.view.composer_anchor.?.h >= composer.expanded_min);
}

test "desktop parity sidebar history has a six point trailing gap and a 350ms tooltip" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var controls: [2]ui.Rect = undefined;
    var count: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 26 and r.h == 26 and r.y >= 736 and r.x < sidebar.widthOf(&h.a)) {
            if (count >= controls.len) return error.ExtraFooterControl;
            controls[count] = r;
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectApproxEqAbs(@as(f32, 6), controls[1].x - controls[0].x - controls[0].w, 0.01);
    h.t.moveTo(controls[0].x + 13, controls[0].y + 13);
    h.t.advance(0.3);
    try testing.expect(h.t.tooltipText() == null);
    h.t.advance(0.06);
    try testing.expectEqualStrings("Chat history", h.t.tooltipText() orelse return error.MissingHistoryTooltip);
}

test "desktop parity drafts and conversations share the compact dock and maximum width" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        try testing.expect(h.a.selected == null);
        const fresh = h.a.view.composer_anchor orelse return error.NoDraftComposer;
        try testing.expectApproxEqAbs(@as(f32, 49), fresh.h, 1);
        try testing.expectApproxEqAbs(@as(f32, 736), fresh.w, 1);
        try testing.expect(fresh.y > 600);
        try testing.expect(!h.t.hasText("Working in"));
        const starter = h.t.findText("Build something new") orelse return error.NoStarter;
        try testing.expect(starter.y + starter.h <= fresh.y);
        h.snap(if (dark) "desktop-draft-dark" else "desktop-draft-light");
        h.a.openChatInTab("synthetic-chat");
        h.t.settle(1);
        const established = h.a.view.composer_anchor orelse return error.NoSessionComposer;
        try testing.expectApproxEqAbs(fresh.x, established.x, 1);
        try testing.expectApproxEqAbs(fresh.w, established.w, 1);
        try testing.expectApproxEqAbs(fresh.y + fresh.h, established.y + established.h, 1);
        try testing.expect(!h.t.hasText("Build something new"));
    }
}

test "desktop parity starter keeps suggestions, focuses input, and targets a fresh folder" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try testing.expect(h.t.hasText("Tour this project"));
    try h.t.clickText("Build something new");
    h.t.settle(0.3);
    try testing.expect(h.a.new_no_project);
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expect(std.mem.endsWith(u8, h.a.composer.text(), "My idea: "));
    try testing.expect(h.t.hasText("Build something new"));
    try testing.expect(!h.t.hasText("Tour this project"));
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    try testing.expect(h.a.view.composer_anchor.?.h >= composer.expanded_min);
    h.snap("desktop-starter-expanded");
}

test "sidebar avatar keeps signed-in identity in its tooltip and menu" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.account.scope = .synced;
    h.a.account.user = .{
        .name = try testing.allocator.dupe(u8, "Synthetic User"),
        .email = try testing.allocator.dupe(u8, "synthetic@example.invalid"),
    };
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Synthetic User"));
    // Footer whitespace is not a second click target.
    h.t.click(100, 758);
    try testing.expect(!h.a.view.account_menu);
    const avatar = h.a.view.account_anchor orelse return error.NoAvatar;
    h.t.moveTo(avatar.x + avatar.w / 2, avatar.y + avatar.h / 2);
    h.t.advance(0.5);
    try testing.expect(h.t.hasText("Account menu: Synthetic User"));
    h.t.click(avatar.x + avatar.w / 2, avatar.y + avatar.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.account_menu);
    try testing.expect(h.t.hasText("synthetic@example.invalid"));
}

test "desktop parity sidebar starts with project filter and exposes only current menu fields" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try testing.expectEqual(@as(f32, 224), sidebar.widthOf(&h.a));
    const filter = h.t.findText("All projects") orelse return error.NoProjectFilter;
    try testing.expect(filter.y < 80);
    try testing.expect(!h.t.hasText("Tabs · 1"));
    // Footer whitespace must not open the avatar's account menu.
    h.t.click(100, 758);
    try testing.expect(!h.a.view.account_menu);
    menus.openView(&h.a);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Organize"));
    try testing.expect(h.t.hasText("Sort"));
    try testing.expect(h.t.hasText("Last activity"));
    try testing.expect(h.t.hasText("All"));
    const last_act = h.t.findText("Last activity").?;
    h.t.moveTo(last_act.x + 4, last_act.y + last_act.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("1d"));
    try testing.expect(h.t.hasText("3d"));
    try testing.expect(h.t.hasText("7d"));
    try testing.expect(h.t.hasText("30d"));
    try h.t.clickText("7d");
    h.t.settle(0.3);
    try testing.expectEqual(settings.LastActivity.d7, h.a.settings.lastActivity());
    // Completed (unseen ✓) and pinned sessions older than 7d must be filtered out.
    const now = std.Io.Clock.Timestamp.now(testing.io, .real).raw.toMilliseconds();
    const old_ms = now - 14 * 24 * 60 * 60 * 1000;
    const recent_ms = now - 2 * 60 * 60 * 1000;
    const aged = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"recent-chat","deviceId":"synthetic-device","title":"Recent item","spaceId":"synthetic-project","archived":false},
        \\ {"id":"old-completed","deviceId":"synthetic-device","title":"Old completed","spaceId":"synthetic-project","archived":false},
        \\ {"id":"old-pinned","deviceId":"synthetic-device","title":"Old pinned","spaceId":"synthetic-project","archived":false}]
    , .{});
    defer aged.deinit();
    try h.a.chats.replace(aged.value);
    h.a.chats.items[0].last_message_ms = recent_ms;
    h.a.chats.items[1].last_message_ms = old_ms;
    h.a.chats.items[2].last_message_ms = old_ms;
    h.a.settings.setPins(&.{"old-pinned"});
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Recent item"));
    try testing.expect(!h.t.hasText("Old completed"));
    try testing.expect(!h.t.hasText("Old pinned"));
    try h.t.clickText("Last activity");
    h.a.settings.setText("sidebarLastActivity", "all");
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Compact"));
    try testing.expect(h.t.hasText("Archived"));
    try testing.expect(!h.t.hasText("Show"));
    try testing.expect(!h.t.hasText("Agent icon"));
    try h.t.clickText("Compact");
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Agent icon"));
    try testing.expect(h.t.hasText("Last updated"));
    try testing.expect(h.t.hasText("Project name"));
    try h.t.clickText("Last updated");
    h.t.settle(0.3);
    try testing.expect(!h.a.settings.get(.sidebar_show_updated));
    try testing.expect(h.a.view.more_menu);
    h.snap("desktop-sidebar-display-menu");
}

test "desktop parity Write has a top toolbar and saves the same draft back to the dock" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.composer.set("Synthetic draft");
    write.open(&h.a);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Edit message"));
    try testing.expect(h.t.hasText("Send now"));
    try testing.expect(h.t.hasText("Save"));
    try testing.expect(!h.t.hasText("Done"));
    const save = h.t.findText("Save") orelse return error.NoSave;
    const edit = h.t.findText("Edit message") orelse return error.NoEditLabel;
    const edit_node = textNode(&h.t, "Edit message") orelse return error.NoEditLabel;
    const label_node = h.t.ctx.node(edit_node).parent;
    const toolbar_node = h.t.ctx.node(label_node).parent;
    const bar = h.t.ctx.node(toolbar_node).rect;
    var divider: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        if (node.parent == toolbar_node and node.rect.h == 1) divider = node.rect;
    }
    const rule = divider orelse return error.NoToolbarDivider;
    try testing.expectApproxEqAbs(bar.x, rule.x, 0.01);
    try testing.expectApproxEqAbs(bar.w, rule.w, 0.01);
    try testing.expectApproxEqAbs(bar.y + write.toolbar_h - 1, rule.y, 0.01);
    try testing.expectApproxEqAbs(edit.y, save.y, 2);
    try testing.expect(save.y < 140);
    h.snap("desktop-write-toolbar");
    try h.t.clickText("Save");
    h.t.settle(0.3);
    try testing.expect(!h.a.view.write_open);
    try testing.expectEqualStrings("Synthetic draft", h.a.composer.text());
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "desktop parity Write Escape saves the draft and restores persistent starters" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.composer.set("Synthetic keyboard round trip");
    _ = h.t.shortcut(write.toggle);
    h.t.settle(0.3);
    try testing.expect(h.a.view.write_open);
    try testing.expect(h.t.hasText("Save"));
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(0.3);
    try testing.expect(!h.a.view.write_open);
    try testing.expect(h.t.hasText("Build something new"));
    try testing.expectEqualStrings("Synthetic keyboard round trip", h.a.composer.text());
    h.snap("desktop-write-keyboard-roundtrip");
}

test "clicking the composer expand button opens Write even on an attachment-only draft with empty text" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try @import("app_attachments.zig").stage(&h.a, "image.png", "synthetic-png-bytes");
    h.t.settle(0.3);
    try testing.expectEqual(@as(usize, 0), h.a.composer.text().len);
    var expand_rect: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.w == 28 and node.rect.h == 28 and node.rect.y > 680 and node.rect.x > 300 and node.rect.x < 500) {
            expand_rect = node.rect;
        }
    }
    const r = expand_rect orelse return error.NoExpandButton;
    h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.a.view.write_open);
    try testing.expect(h.t.hasText("Edit message"));
}

test "desktop parity layout rules cover narrow wrapping, reserved context, and Write gutters" {
    const widths = [_]f32{ 100, 100, 100 };
    try testing.expectEqual(@as(usize, 2), draft.chipRowEnd(&widths, 0, 206));
    try testing.expectEqual(@as(usize, 1), draft.chipRowEnd(&widths, 0, 205));
    try testing.expectEqual(@as(usize, 1), draft.chipRowEnd(&widths, 0, 0));
    try testing.expectEqual(@as(f32, 30), sidebar.contextHeight(false, false, false, false));
    for (1..16) |mask| try testing.expectEqual(@as(f32, 38), sidebar.contextHeight(mask & 1 != 0, mask & 2 != 0, mask & 4 != 0, mask & 8 != 0));
    try testing.expectEqual(@as(usize, 5), menus.viewItemCount(true));
    try testing.expectEqual(@as(usize, 10), menus.viewItemCount(false));
    try testing.expect(settings.LastActivity.d1.matches(1_000_000, 1_000_000 + 23 * 60 * 60 * 1000));
    try testing.expect(!settings.LastActivity.d1.matches(1_000_000, 1_000_000 + 25 * 60 * 60 * 1000));
    try testing.expect(settings.LastActivity.d7.matches(1_000_000, 1_000_000 + 6 * 24 * 60 * 60 * 1000));
    try testing.expect(!settings.LastActivity.d7.matches(1_000_000, 1_000_000 + 8 * 24 * 60 * 60 * 1000));
    try testing.expect(settings.LastActivity.all.matches(1_000_000, 1_000_000 + 365 * 24 * 60 * 60 * 1000));
    try testing.expectEqual(menus.Choice.archived, menus.displayRows(true)[0]);
    try testing.expectEqual(@as(f32, 380), write.pageWidth(420));
    try testing.expectEqual(@as(f32, 400), write.pageWidth(480));
    try testing.expectEqual(@as(f32, 720), write.pageWidth(1600));
}

test "desktop parity settings default to project groups and clamp saved sidebar widths" {
    var s: settings.Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer s.deinit();
    try testing.expectEqual(settings.Organization.by_project, s.organization());
    try testing.expectEqual(@as(f32, 224), s.sidebarWidth());
    s.setNumber("sidebarWidth", 10);
    try testing.expectEqual(@as(f32, 224), s.sidebarWidth());
    s.setNumber("sidebarWidth", 900);
    try testing.expectEqual(@as(f32, 400), s.sidebarWidth());
    s.setNumber("sidebarWidth", 300);
    try testing.expectEqual(@as(f32, 300), s.sidebarWidth());
    try testing.expectEqualStrings("General", settings.Section.appearance.group());
    try testing.expectEqualStrings("Agents", settings.Section.agents.group());
    try testing.expectEqualStrings("Devices and data", settings.Section.archived.group());
}

test "desktop parity project navigation reuses its workspace and keeps peer conversations" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-project","deviceId":"synthetic-device","path":"/work/notes","gitDetected":false},
        \\ {"id":"other-project","deviceId":"synthetic-device","path":"/work/other","gitDetected":false}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"first","deviceId":"synthetic-device","title":"First conversation","spaceId":"synthetic-project","archived":false},
        \\ {"id":"second","deviceId":"synthetic-device","title":"Second conversation","spaceId":"synthetic-project","archived":false},
        \\ {"id":"other","deviceId":"synthetic-device","title":"Other project conversation","spaceId":"other-project","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.openChat("first", "synthetic-project");
    const palette = @import("view_palette.zig");
    palette.activate(&h.a, .{ .chat = "other" });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.layout() != null);
    try testing.expectEqualStrings("other", h.a.selected.?);
    h.t.settle(1);
    const project_group = h.t.findText("notes") orelse return error.NoProjectGroup;
    var other_workspace_row = false;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.startsWith(u8, text.str, "Other project") and node.rect.x < sidebar.widthOf(&h.a) and node.rect.y < project_group.y) {
            other_workspace_row = true;
        },
        else => {},
    };
    try testing.expect(other_workspace_row);
    palette.activate(&h.a, .{ .chat = "second" });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
    try testing.expectEqualStrings("second", h.a.selected.?);
    const split = h.a.tabs.layout().?;
    try testing.expectEqual(@as(usize, 2), split.groups[split.focus].count());
    palette.activate(&h.a, .{ .chat = "first" });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("first", h.a.selected.?);
}

test "retention 794 New workspace remains distinct from the pane New tab action" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChat("synthetic-chat", "synthetic-project");
    try h.a.tabs.isolateWorkspace();
    h.t.settle(1);
    const workspaces = h.a.tabs.items.items.len;
    const old_layout = h.a.tabs.layout().?;
    const old_tabs = old_layout.groups[0].items.items.ptr;
    const old_panes = old_layout.panes.items.len;
    // The pane menu's New tab asks for a destination in the existing panel.
    const strip = @import("view_tab_strip.zig");
    strip.newTab(&h.a, .{ .chat = old_layout.focus });
    h.t.settle(1);
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expectEqual(@import("app_open_chooser.zig").Intent.new_tab, h.a.view.open_chooser.intent);
    try testing.expectEqual(workspaces, h.a.tabs.items.items.len);
    @import("app_open_chooser.zig").close(&h.a);
    h.t.settle(1);
    var create: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 26 and r.h == 26 and r.y >= 736 and r.x < sidebar.widthOf(&h.a)) {
            if (create == null or r.x > create.?.x) create = r;
        }
    }
    const button = create orelse return error.NoWorkspaceCreate;
    h.t.moveTo(button.x + 13, button.y + 13);
    h.t.advance(0.4);
    try testing.expectEqualStrings("New workspace", h.t.tooltipText() orelse return error.NoWorkspaceTooltip);
    h.snap("retention-794-new-workspace-label");
    h.t.click(button.x + 13, button.y + 13);
    h.t.settle(1);
    try testing.expectEqual(workspaces + 1, h.a.tabs.items.items.len);
    try testing.expectEqual(old_panes, h.a.tabs.splits.items[0].?.panes.items.len);
    try testing.expect(h.a.tabs.splits.items[0].?.groups[0].items.items.ptr == old_tabs);
    try testing.expect(!h.a.view.open_chooser.open);
}

test "desktop parity sidebar exposes independent drafts and restores their prompts" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChat("synthetic-chat", "synthetic-project");
    try h.a.tabs.isolateWorkspace();
    h.a.addChatTab(false);
    h.a.composer.set("First workspace draft");
    h.a.newWorkspaceSession();
    h.a.composer.set("Second workspace draft");
    h.t.settle(1);
    try testing.expect(h.t.hasText("New session"));
    try h.t.clickText("New session");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
    try testing.expectEqualStrings("First workspace draft", h.a.composer.text());
}

test "draft computer selection remains available in the titlebar" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        h.a.select(null, "synthetic-project");
        h.t.settle(1);
        const computer = h.a.view.strip.device_anchor orelse return error.NoComputerChip;
        try testing.expect(computer.y < 38);
        const project = h.a.view.space_anchor orelse return error.NoProjectChip;
        try testing.expect(project.y > 38);
    }
}

test "desktop parity account menu shows one identity line and an avatar-only footer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try testing.expect(!h.t.hasText("Local only"));
    h.a.view.account_menu = true;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Stored on this device"));
    try testing.expect(!h.t.hasText("Local only"));
    const identity = h.t.findText("Stored on this device") orelse return error.NoIdentity;
    const sign_in = h.t.findText("Sign in with Codegraff") orelse return error.NoSignIn;
    try testing.expect(identity.y < sign_in.y);
    const sign_in_node = textNode(&h.t, "Sign in with Codegraff") orelse return error.NoSignIn;
    const label = h.t.ctx.node(sign_in_node).parent;
    const row = h.t.ctx.node(h.t.ctx.node(label).parent).rect;
    // GPUI menu_row_base uses five points above and below its 13-point text.
    try testing.expectApproxEqAbs(@as(f32, 31), row.h, 0.1);
}

test "desktop parity projectless drafts retain a footer computer picker" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.pickDraftDevice("synthetic-projectless-device");
    h.t.settle(1);
    try testing.expect(h.a.newChatSpace() == null);
    var label_buf: [160]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, "Run on: {s}", .{@import("view_tab_strip.zig").deviceLabel(&h.a, h.a.draftDevice())});
    var footer: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, label) and node.rect.y > 38) {
            footer = node.rect;
        },
        else => {},
    };
    const computer = footer orelse return error.NoComputerChip;
    h.t.click(computer.x + computer.w / 2, computer.y + computer.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == .device);
    try testing.expect(h.a.view.strip.device_anchor.?.y > 38);
    try testing.expect(h.t.hasText("No project"));
}

/// A draft in a project with git: the footer's full set of controls.
fn gitDraft(h: *Harness) !void {
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-git","deviceId":"synthetic-device","name":"synthetic","path":"/work/synthetic","gitDetected":true}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    if (h.a.space) |old| h.a.gpa.free(old);
    h.a.space = try h.a.gpa.dupe(u8, "synthetic-git");
    h.a.new_ref = try h.a.gpa.dupe(u8, "main");
    h.a.select(null, null);
    h.t.settle(1);
    // Anchors are the frame before's: one more so they are this layout's.
    h.t.frame();
}

/// The footer's controls after the model chip: every 20-point box in its
/// 24-point row.
fn footerControls(h: *Harness, out: []ui.Rect) ![]ui.Rect {
    const model = h.a.view.chip_anchor orelse return error.NoModelChip;
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.h != 20 or r.w <= 0 or r.y < model.y or r.y + r.h > model.y + 24 or r.x < model.x + model.w) continue;
        if (n >= out.len) return error.ExtraFooterControl;
        out[n] = r;
        n += 1;
    }
    return out[0..n];
}

test "draft footer controls end inside the composer in split panes" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try gitDraft(&h);
    var buf: [8]ui.Rect = undefined;

    // Unsplit there is room: every control keeps its words.
    for ([_][]const u8{ "Code", "synthetic", "New worktree", "From main" }) |label| try testing.expect(h.t.hasText(label));
    try testing.expectEqual(@as(usize, 5), (try footerControls(&h, &buf)).len);

    h.a.splitPane(.horizontal);
    // A fresh sibling intentionally resets Git picks. Choose its own base
    // before checking the full footer's responsive geometry.
    try testing.expect(h.a.new_ref == null);
    h.a.new_ref = try h.a.gpa.dupe(u8, "main");
    h.t.settle(1);
    for ([_]f32{ 1440, 1200, 1000, 900 }) |window_w| {
        h.t.resize(window_w, 780);
        h.t.settle(1);
        if (window_w == 1200) h.snap("draft-footer-split-pane");
        const pill = h.a.view.composer_anchor orelse return error.NoComposer;
        const controls = try footerControls(&h, &buf);
        // Mode, computer, project, checkout and ref: none left out, none
        // past the row's 10-point inset, each whole or its 28-point glyph.
        try testing.expectEqual(@as(usize, 5), controls.len);
        for (controls, 0..) |r, i| {
            try testing.expect(r.x + r.w <= pill.x + pill.w - 10 + 0.01);
            try testing.expect(r.w >= 28);
            if (i > 0) try testing.expectApproxEqAbs(@as(f32, 4), r.x - controls[i - 1].x - controls[i - 1].w, 0.01);
        }
        // The ref is the last to give up its words.
        if (window_w >= 1000) try testing.expect(h.t.hasText("From main"));
    }

    // 900 points wide: the checkout is a glyph that still opens its menu,
    // and says what it is.
    try testing.expect(!h.t.hasText("New worktree"));
    const checkout = h.a.view.checkout_anchor orelse return error.NoCheckoutChip;
    try testing.expectApproxEqAbs(@as(f32, 28), checkout.w, 0.01);
    h.t.moveTo(checkout.x + checkout.w / 2, checkout.y + checkout.h / 2);
    h.t.advance(0.56);
    try testing.expectEqualStrings("New worktree", h.t.tooltipText() orelse return error.NoTooltip);
    h.t.click(checkout.x + checkout.w / 2, checkout.y + checkout.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.checkout_menu);
    try testing.expect(h.t.hasText("Current checkout"));
}

test "zen mode flattens sidebar and footer hierarchy while developer mode restores full controls" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try gitDraft(&h);

    // Developer mode exposes git checkout/branch chips in the draft footer.
    try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
    try testing.expect(h.t.hasText("New worktree"));
    try testing.expect(h.t.hasText("From main"));

    // Switching to Zen mode flattens the sidebar to a single list and hides git plumbing in the footer.
    h.a.settings.applyUiMode(.zen);
    h.a.settings.setNumber("sidebarWidth", 256);
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expectEqual(settings.Organization.in_one_list, h.a.settings.organization());
    try testing.expect(!h.t.hasText("New worktree"));
    try testing.expect(!h.t.hasText("From main"));

    // Toggling UI mode returns to Developer mode and restores the full hierarchy.
    h.a.settings.toggleUiMode();
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
    try testing.expectEqual(settings.Organization.by_project, h.a.settings.organization());
    try testing.expect(h.t.hasText("New worktree"));
    try testing.expect(h.t.hasText("From main"));

    // 1-click sidebar footer pill switches straight from Dev -> Zen and Zen -> Dev.
    const dev_pill = textNode(&h.t, "Dev") orelse return error.NoSidebarModePill;
    const pill_rect = h.t.ctx.node(h.t.ctx.node(dev_pill).parent).rect;
    h.t.click(pill_rect.x + pill_rect.w / 2, pill_rect.y + pill_rect.h / 2);
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expect(h.t.hasText("Zen"));
    try testing.expect(!h.t.hasText("New worktree"));

    // Cmd+Shift+M toggles back to Developer mode in one shortcut, and again back to Zen.
    try testing.expect(h.t.shortcut(.{ .key = 'm', .cmd = true, .shift = true }));
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
    try testing.expect(h.t.hasText("New worktree"));
    try testing.expect(h.t.shortcut(.{ .key = 'm', .cmd = true, .shift = true }));
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());

    // Individual moving parts can be turned on and off independently while keeping Zen's flat list.
    h.a.settings.toggleMovingPart(.git_checkout_chrome);
    h.t.settle(0.3);
    try testing.expect(h.a.settings.hierarchyProfile().shows_git_checkout_chrome);
    try testing.expect(h.a.settings.hierarchyProfile().flat_session_list);
    try testing.expect(h.t.hasText("New worktree"));
    h.a.settings.toggleMovingPart(.git_checkout_chrome);
    h.t.settle(0.3);
    try testing.expect(!h.a.settings.hierarchyProfile().shows_git_checkout_chrome);
    try testing.expect(!h.t.hasText("New worktree"));

    // Command palette preserves 4 idle actions and surfaces mode/part switches when queried.
    const pal = @import("palette.zig");
    try testing.expectEqual(@as(usize, 4), pal.actionsFor("", true).len);
    try testing.expect(pal.actionsFor("zen", true).len >= 1);
    try testing.expect(pal.actionsFor("rail", true).len >= 1);
}

test "zeron sidebar layout, titlebar back/forward navigation, and smooth disclosure collapse" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.a.settings.setNumber("sidebarWidth", 256);
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"proj-h","deviceId":"synthetic-device","name":"Harness","path":"/work/harness","gitDetected":true},
        \\ {"id":"proj-m","deviceId":"synthetic-device","name":"Mail","path":"/work/mail","gitDetected":true}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const now = std.Io.Clock.Timestamp.now(testing.io, .real).raw.toMilliseconds();
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"c-init","deviceId":"synthetic-device","title":"Initial Greeting Session","config":{"harness":"claude-code"},"spaceId":"proj-h","archived":false},
        \\ {"id":"c-casual","deviceId":"synthetic-device","title":"Casual Greeting Session","config":{"harness":"codex"},"spaceId":"proj-m","archived":false},
        \\ {"id":"c-arch","deviceId":"synthetic-device","title":"hey there","config":{"harness":"claude-code"},"spaceId":"proj-m","archived":true}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.chats.items[0].last_message_ms = now;
    h.a.chats.items[1].last_message_ms = now - 23 * 60 * 60 * 1000;
    h.a.chats.items[2].last_message_ms = now - 23 * 60 * 60 * 1000;
    h.t.settle(1);

    // Titlebar hosts [⋯] at y < 38, and filterRow is a full-width rounded pill ("All projects").
    const more = h.a.view.more_anchor orelse return error.MissingMoreButton;
    try testing.expect(more.y < 38);
    const filter = h.a.view.filter_anchor orelse return error.MissingFilterPill;
    try testing.expect(filter.w >= 200);
    try testing.expect(h.t.hasText("All projects"));
    try testing.expect(h.t.hasText("Sessions"));
    try testing.expect(h.t.hasText("Archived"));

    // Navigate Home -> c-init -> c-casual, then verify [←] and [→] history navigation.
    try testing.expect(!h.a.canGoBack());
    h.a.openChatInTab("c-init");
    h.t.settle(0.4);
    try testing.expect(h.a.canGoBack());
    try testing.expect(!h.a.canGoForward());
    h.snap("desktop-zeron-sidebar");

    h.a.goBack();
    h.t.settle(0.4);
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.canGoForward());
    h.a.goForward();
    h.t.settle(0.4);
    try testing.expectEqualStrings("c-init", h.a.selected.?);

    // Smooth 0.18s disclosure collapse & expand on "Sessions".
    const hasCasualInSidebar = struct {
        fn check(t: *ui.Tester) bool {
            for (t.ctx.nodes.items) |n| switch (n.content) {
                .text => |tx| if (n.rect.x < 256 and std.mem.startsWith(u8, tx.str, "Casual Greeting")) return true,
                else => {},
            };
            return false;
        }
    }.check;
    try testing.expect(hasCasualInSidebar(&h.t));
    try h.t.clickText("Sessions");
    h.t.advance(0.06);
    try testing.expect(!h.a.view.sessions_open);
    // Mid-collapse: disclosure tween is active and still revealing partial rows.
    const sess_tw = h.a.view.disclosures.get("sessions") orelse return error.MissingSessionsTween;
    try testing.expect(sess_tw.animating(h.t.ctx.time, false));
    h.t.settle(1);
    try testing.expect(!hasCasualInSidebar(&h.t));
    try testing.expect(h.t.hasText("Sessions (2)"));
    try h.t.clickText("Sessions (2)");
    h.t.settle(1);
    try testing.expect(hasCasualInSidebar(&h.t));
}

test "zeron Home agent-update island morphs between pill and expandable card and dispatches ApplyHarnessUpdate" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Synthetic Mac Studio","online":true}]
    , .{});
    defer devs.deinit();
    try h.a.devices.replace(devs.value);
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

    const updates = @import("agent_updates.zig");
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.319","latestVersion":"2.1.322","phase":"available","canApply":true},
        \\ {"harness":"pi","installedVersion":"1.5.0","latestVersion":"1.5.2","phase":"available","canApply":true},
        \\ {"harness":"opencode","installedVersion":"1.0.2-R2040.1","latestVersion":"1.4.15-R8339.1","phase":"available","canApply":true}]
    );
    h.t.settle(1);
    h.t.frame();

    // Collapsed pill state: [w, 38], bottom-anchored on Home.
    try testing.expect(h.t.hasText("3 agent updates \u{00b7} Synthetic Mac Studio"));
    const pill_rect = h.a.agent_updates.card_rect orelse return error.MissingUpdatePill;
    try testing.expectApproxEqAbs(@as(f32, 38), pill_rect.h, 1);
    h.snap("desktop-agent-updates-pill");

    // Click pill to expand upward into the 360px card; verify mid-flight C0 morph!
    h.t.click(pill_rect.x + pill_rect.w / 2, pill_rect.y + pill_rect.h / 2);
    h.t.advance(0.08);
    const mid_rect = h.a.agent_updates.card_rect orelse return error.MissingMidUpdateCard;
    try testing.expect(mid_rect.h > 42 and mid_rect.h < 228);
    // Bottom edge stays anchored while expanding upward.
    try testing.expectApproxEqAbs(pill_rect.y + pill_rect.h, mid_rect.y + mid_rect.h, 2);

    h.t.settle(1);
    const card_rect = h.a.agent_updates.card_rect orelse return error.MissingExpandedUpdateCard;
    try testing.expectApproxEqAbs(@as(f32, 360), card_rect.w, 1);
    try testing.expectApproxEqAbs(@as(f32, 230), card_rect.h, 1);
    try testing.expect(h.t.hasText("Claude Code"));
    try testing.expect(h.t.hasText("2.1.319 \u{2192} 2.1.322"));
    try testing.expect(h.t.hasText("Pi"));
    try testing.expect(h.t.hasText("OpenCode"));
    h.snap("desktop-agent-updates-expanded");

    // Click first [Update] button and verify ApplyHarnessUpdate is dispatched.
    try h.t.clickText("Update");
    h.t.settle(0.3);
    const last = h.a.agent_updates.last_action orelse return error.MissingDispatchedUpdateAction;
    try testing.expectEqualStrings("ApplyHarnessUpdate", last.method);
    try testing.expectEqualStrings("claude-code", last.harness);
}

test "Home agent-update island dismisses with its close button and returns only when the updates change" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Synthetic Mac Studio","online":true}]
    , .{});
    defer devs.deinit();
    try h.a.devices.replace(devs.value);
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

    const updates = @import("agent_updates.zig");
    const updated =
        \\[{"harness":"claude-code","installedVersion":"2.1.322","latestVersion":"2.1.322","phase":"updated"},
        \\ {"harness":"pi","installedVersion":"1.5.2","latestVersion":"1.5.2","phase":"updated"},
        \\ {"harness":"opencode","installedVersion":"1.4.15","latestVersion":"1.4.15","phase":"updated"}]
    ;
    try updates.setTestStatuses(&h.a, "synthetic-device", true, updated);
    h.t.settle(1);
    h.t.frame();
    try testing.expect(h.t.hasText("3 agents updated \u{00b7} Synthetic Mac Studio"));
    const pill = h.a.agent_updates.card_rect orelse return error.MissingUpdatePill;
    h.snap("desktop-agent-updates-dismiss-before");

    // The close button sits at the pill's right edge (1px border, 8px trailing, 24px button).
    h.t.click(pill.x + pill.w - 1 - 8 - 12, pill.y + pill.h / 2);
    h.t.settle(1);
    h.t.frame();
    try testing.expect(!h.t.hasText("3 agents updated \u{00b7} Synthetic Mac Studio"));
    try testing.expect(!h.a.agent_updates.expanded);
    try testing.expect(!updates.hasVisible(&h.a));
    h.snap("desktop-agent-updates-dismiss-after");

    // The same statuses arriving again (the engine re-sends its snapshot) stay dismissed.
    try updates.setTestStatuses(&h.a, "synthetic-device", true, updated);
    h.t.settle(1);
    h.t.frame();
    try testing.expect(!updates.hasVisible(&h.a));

    // A new update changes what is visible, so the island comes back.
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.322","latestVersion":"2.1.330","phase":"available","canApply":true}]
    );
    h.t.settle(1);
    h.t.frame();
    try testing.expect(updates.hasVisible(&h.a));
    try testing.expect(h.t.hasText("Claude Code 2.1.330 available \u{00b7} Synthetic Mac Studio"));
}

test "Home agent-update island auto-dismisses completed updates after five seconds" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Synthetic Mac Studio","online":true}]
    , .{});
    defer devs.deinit();
    try h.a.devices.replace(devs.value);
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");
    const updates = @import("agent_updates.zig");
    const updated =
        \\[{"harness":"codex","installedVersion":"1.0.0","latestVersion":"1.0.0","phase":"updated"}]
    ;
    try updates.setTestStatuses(&h.a, "synthetic-device", true, updated);
    const start = h.t.time;
    h.t.settle(0.3);
    h.t.frame();
    try testing.expect(updates.hasVisible(&h.a));
    try testing.expect(h.a.agent_updates.card_rect != null);
    h.snap("desktop-agent-updates-timeout-before");

    // The app must schedule the timeout even when there is no other activity.
    try testing.expectEqual(@as(?f64, start + 5), updates.tick(&h.a, h.t.ctx.time));
    h.t.time = start + 4.99;
    h.t.frame();
    try testing.expect(updates.hasVisible(&h.a));
    // Repeated engine snapshots must not restart the countdown.
    try updates.setTestStatuses(&h.a, "synthetic-device", true, updated);
    h.t.time = start + 5;
    h.t.frame();
    try testing.expect(!updates.hasVisible(&h.a));
    try testing.expect(h.a.agent_updates.card_rect == null);
    h.snap("desktop-agent-updates-timeout-after");

    try updates.setTestStatuses(&h.a, "synthetic-device", true, updated);
    h.t.advance(1);
    try testing.expect(!updates.hasVisible(&h.a));

    // A different completed version gets its own full five seconds.
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"codex","installedVersion":"1.1.0","latestVersion":"1.1.0","phase":"updated"}]
    );
    const next_start = h.t.time;
    h.t.frame();
    h.t.time = next_start + 4.99;
    h.t.frame();
    try testing.expect(updates.hasVisible(&h.a));
    h.t.time = next_start + 5;
    h.t.frame();
    try testing.expect(!updates.hasVisible(&h.a));
}

test "Home agent-update island keeps unfinished updates and failures visible beyond five seconds" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const updates = @import("agent_updates.zig");
    for ([_][]const u8{ "available", "downloading", "failed" }) |phase| {
        var buf: [512]u8 = undefined;
        try updates.setTestStatuses(&h.a, "synthetic-device", true, try std.fmt.bufPrint(&buf,
            \\[{{"harness":"codex","phase":"updated"}},{{"harness":"pi","phase":"{s}"}}]
        , .{phase}));
        h.t.frame();
        h.t.advance(6);
        try testing.expect(updates.hasVisible(&h.a));
    }
}

test "desktop 3-pane horizontal split contains tool rows, question chips, and session footer within each pane" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.t.resize(1280, 780);
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"proj-split","deviceId":"synthetic-device","name":"harness","path":"/work/harness","gitDetected":true}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"split-a","deviceId":"synthetic-device","title":"Left Split Pane","spaceId":"proj-split","cwd":"/work/.graff/worktrees/s1","branch":"feat/split-a","archived":false},
        \\ {"id":"split-b","deviceId":"synthetic-device","title":"Center Split Pane","spaceId":"proj-split","cwd":"/work/.graff/worktrees/s2","branch":"feat/split-b","archived":false},
        \\ {"id":"split-c","deviceId":"synthetic-device","title":"Right Split Pane","spaceId":"proj-split","cwd":"/work/.graff/worktrees/s3","branch":"feat/split-c","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);

    h.a.openChatInTab("split-a");
    h.a.splitPane(.horizontal);
    h.a.tabs.setCurrent("split-b");
    h.a.select("split-b", "proj-split");
    h.a.splitPane(.horizontal);
    h.a.tabs.setCurrent("split-c");
    h.a.select("split-c", "proj-split");
    h.a.focusPane(1);
    h.t.settle(1);

    const doc_b = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"e1","role":"assistant","status":"complete","parts":[
        \\  {"id":"t1","kind":"tool","resolved":true,"call":{"kind":"shell","command":"git status --short"}},
        \\  {"id":"t2","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"apps/nano/src/view_question.zig"}},
        \\  {"id":"m1","kind":"text","text":"Checking where `main`, the branches and the worktrees stand before changing anything."},
        \\  {"id":"q1","kind":"input","resolved":true,"questions":[{"id":"q-main","header":"Cleanup","question":"This worktree is now on `main`, level with `origin/main` (b3727a7), which cleanup mode should run?","options":["Prune clean throwaway worktrees","Keep all worktrees"]}]}
        \\]}]}
    , .{});
    defer doc_b.deinit();
    try h.a.transcript.apply(doc_b.value);
    h.t.settle(1);
    h.t.frame();
    h.snap("desktop-3pane-split-fixed");

    // Verify no text node inside the center pane overflows into the right pane.
    const q_label = h.t.findText("Question") orelse return error.MissingQuestionChip;
    const layout_s = h.a.tabs.layout() orelse return error.MissingSplitLayout;
    try testing.expectEqual(@as(usize, 3), layout_s.panes.items.len);
    const pane_each = h.a.view.chrome.chat_width / 3;
    const center_right = sidebar.widthOf(&h.a) + h.a.view.chrome.leading + pane_each * 2;
    try testing.expect(q_label.x + q_label.w < center_right);
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.startsWith(u8, tx.str, "This worktree is now")) {
            try testing.expect(node.rect.x + node.rect.w <= center_right + 1);
        },
        else => {},
    };
}
