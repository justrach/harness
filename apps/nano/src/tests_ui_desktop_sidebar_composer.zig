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

test "desktop parity layout rules cover narrow wrapping, reserved context, and Write gutters" {
    const widths = [_]f32{ 100, 100, 100 };
    try testing.expectEqual(@as(usize, 2), draft.chipRowEnd(&widths, 0, 206));
    try testing.expectEqual(@as(usize, 1), draft.chipRowEnd(&widths, 0, 205));
    try testing.expectEqual(@as(usize, 1), draft.chipRowEnd(&widths, 0, 0));
    try testing.expectEqual(@as(f32, 30), sidebar.contextHeight(false, false, false, false));
    for (1..16) |mask| try testing.expectEqual(@as(f32, 38), sidebar.contextHeight(mask & 1 != 0, mask & 2 != 0, mask & 4 != 0, mask & 8 != 0));
    try testing.expectEqual(@as(usize, 4), menus.viewItemCount(true));
    try testing.expectEqual(@as(usize, 9), menus.viewItemCount(false));
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
