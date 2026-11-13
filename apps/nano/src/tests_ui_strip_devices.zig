//! Explicit, per-draft device targets. All devices/RPCs are synthetic;
//! tests never connect to an engine or change this machine's identity.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const strip = @import("view_tab_strip.zig");

fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}

fn snap(h: *Harness, name: []const u8) void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
    h.t.screenshot(path) catch {};
}

test "strip device target: a computer with no folders is a real selectable projectless target" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try replace(&h.a.spaces,
        \\[{"id":"local-project","deviceId":"local","path":"/synthetic/fieldnotes"}]
    );
    h.a.newTab();
    strip.open(&h.a, .device, .{ .chat = 0 }, .{ .x = 850, .y = 700, .w = 100, .h = 20 });
    h.t.settle(1);
    try h.t.clickText("Build box");
    h.t.settle(1);
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expect(h.a.new_no_project);
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    try testing.expectEqualStrings("local", h.a.device_id.?);
    try testing.expect(h.a.view.strip.menu == null);
}

test "strip device target: the tab's computer label switches a draft with a project" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.select(null, "local-project");
    h.t.settle(1);
    const label = @import("strip_device.zig").localLabel();
    var chip: ?@import("nanoui").ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| {
            if (std.mem.eql(u8, text.str, label) and node.rect.y < 42) chip = node.rect;
        },
        else => {},
    };
    const at = chip orelse return error.MissingStripComputer;
    h.t.click(at.x + at.w / 2, at.y + at.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == .device);
    try h.t.clickText("Build box");
    h.t.settle(1);
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expect(h.a.new_no_project);
}

test "strip device target: a project draft still switches computers from the titlebar" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.select(null, "local-project");
    h.t.settle(1);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    const label = @import("strip_device.zig").localLabel();
    var chip: ?@import("nanoui").ui.Rect = null;
    // The titlebar remains interactive alongside the explicit draft chooser.
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| {
            if (std.mem.eql(u8, text.str, label) and node.rect.y < 38) chip = node.rect;
        },
        else => {},
    };
    const at = chip orelse return error.MissingTitlebarComputer;
    h.t.click(at.x + at.w / 2, at.y + at.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == .device);
    try h.t.clickText("Build box");
    h.t.settle(1);
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expect(h.a.new_no_project);
}

test "strip device target: splits and their tabs park and restore execution device with the prompt" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.pickDraftDevice("remote");
    h.a.composer.set("A synthetic remote draft");
    h.a.splitPane(.horizontal);
    h.a.pickDraftDevice("local");
    h.a.composer.set("A synthetic local draft");
    try testing.expectEqualStrings("remote", strip.device(&h.a, .{ .chat = 0 }).?);
    try testing.expectEqualStrings("local", strip.device(&h.a, .{ .chat = 1 }).?);
    h.a.focusPane(0);
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expectEqualStrings("A synthetic remote draft", h.a.composer.text());
    try testing.expect(h.a.new_no_project);
    h.a.focusPane(1);
    h.a.addChatTab(false);
    try testing.expectEqualStrings("local", h.a.new_device.?);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.showPaneTab(0);
    try testing.expectEqualStrings("local", h.a.new_device.?);
    try testing.expectEqualStrings("A synthetic local draft", h.a.composer.text());
    try testing.expectEqualStrings("local", h.a.device_id.?);
}

test "strip device target: selecting a folder makes its host authoritative again" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.pickDraftDevice("remote");
    h.a.select(null, "local-project");
    try testing.expect(!h.a.new_no_project);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("local", h.a.new_device.?);
    try testing.expectEqualStrings("local", h.a.draftDevice().?);
    h.a.select(null, "remote-project");
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expectEqualStrings("remote-project", h.a.newChatSpace().?.id);
}

test "strip device target: a new sibling inherits the started conversation's actual remote host" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChat("b", null);
    h.a.newTab();
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expectEqualStrings("remote-project", h.a.newChatSpace().?.id);
    h.a.openChat("b", null);
    const before = h.a.new_device;
    h.a.pickDraftDevice("local");
    try testing.expectEqualDeep(before, h.a.new_device);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqualStrings("remote", strip.device(&h.a, strip.active(&h.a)).?);
}

test "strip device target: a queued computer pick keeps its ID when device rows are replaced" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    strip.queueDevice(&h.a, .{ .chat = 0 }, "remote");
    try replace(&h.a.devices,
        \\[{"id":"other","name":"Other computer"},{"id":"local","name":"Studio"},{"id":"remote","name":"Build box"}]
    );
    strip.settle(&h.a);
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expectEqualStrings("local", h.a.device_id.?);
}

test "strip device target: projectless CreateChat carries the picked device rather than the local ID" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.pickDraftDevice("remote");
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"Mutate":{},"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    h.a.composer.set("A synthetic projectless remote request");
    h.a.send();
    var creates: usize = 0;
    for (h.a.engine.sent.items) |request| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, request, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse continue;
        if (params != .object) continue;
        const op = params.object.get("op") orelse continue;
        if (op != .string or !std.mem.eql(u8, op.string, "createChat")) continue;
        creates += 1;
        const device = params.object.get("deviceId") orelse return error.MissingExecutionDevice;
        try testing.expectEqualStrings("remote", device.string);
        if (params.object.get("spaceId")) |space| try testing.expect(space == .null);
    }
    try testing.expectEqual(@as(usize, 1), creates);
    try testing.expectEqualStrings("local", h.a.device_id.?);
}

test "Nanoui request: the draft Run on chooser sends work to the picked computer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.select(null, "local-project");
    h.t.settle(1);
    var label: [128]u8 = undefined;
    try h.t.clickText(try std.fmt.bufPrint(&label, "Run on: {s}", .{@import("strip_device.zig").localLabel()}));
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == .device);
    snap(&h, "computer-chooser");
    try h.t.clickText("Build box");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Run on: Build box"));
    snap(&h, "computer-remote");
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expectEqualStrings("remote", h.a.draftDevice().?);
    try testing.expectEqualStrings("local", h.a.device_id.?);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"Mutate":{},"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    h.a.composer.set("A synthetic request for the chosen computer");
    h.a.send();
    var creates: usize = 0;
    for (h.a.engine.sent.items) |request| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, request, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse continue;
        if (params != .object) continue;
        const op = params.object.get("op") orelse continue;
        if (op != .string or !std.mem.eql(u8, op.string, "createChat")) continue;
        creates += 1;
        try testing.expectEqualStrings("remote", params.object.get("deviceId").?.string);
        if (params.object.get("spaceId")) |space| try testing.expect(space == .null);
    }
    try testing.expectEqual(@as(usize, 1), creates);
}

test "Nanoui request: an existing conversation keeps its execution computer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try testing.expect(!h.t.containsText("Run on:"));
    h.a.pickDraftDevice("remote");
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqualStrings("local", h.a.findChat("a").?.device_id.?);
    try testing.expectEqualStrings("local", h.a.device_id.?);
}

test "split slot computer picker fits its chevron and switches directly while Cmd+D folder menu is open" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    const label = @import("strip_device.zig").localLabel();
    var slot_computer: ?@import("nanoui").ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| {
            if (std.mem.eql(u8, text.str, label) and node.rect.y < 42 and node.rect.x > 650) {
                slot_computer = node.rect;
            }
        },
        else => {},
    };
    const comp = slot_computer orelse return error.MissingSplitSlotComputer;
    // The chevron (9px) after `This Mac` must fit inside `slot-device` without clipping.
    var chevron_fits = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.y < 42 and node.rect.x <= comp.x and node.rect.x + node.rect.w >= comp.x + comp.w + 9) {
            chevron_fits = true;
        }
    }
    try testing.expect(chevron_fits);
    // Clicking `This Mac` while the Cmd+D folder menu is open switches directly to `.device`.
    h.t.click(comp.x + comp.w / 2, comp.y + comp.h / 2);
    h.t.settle(1);
    try testing.expectEqual(strip.Menu.device, h.a.view.strip.menu.?);
    try h.t.clickText("Build box");
    h.t.settle(1);
    try testing.expectEqualStrings("remote", h.a.new_device.?);
    try testing.expect(h.a.new_no_project);
}
