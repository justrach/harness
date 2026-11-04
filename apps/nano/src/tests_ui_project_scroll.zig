//! A long project list scrolls, in both menus that show it.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = false;
        h.a.engine.state = .connected;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 800, .dark = false });
        h.t.settle(1);
        // Far more than a window holds; "project-00" sorts first.
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(testing.allocator);
        try json.append(testing.allocator, '[');
        for (0..60) |i| {
            if (i > 0) try json.append(testing.allocator, ',');
            try json.print(testing.allocator, "{{\"id\":\"s{d}\",\"deviceId\":\"d\",\"path\":\"/work/project-{d:0>2}\"}}", .{ i, i });
        }
        try json.append(testing.allocator, ']');
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json.items, .{});
        defer parsed.deinit();
        try h.a.spaces.replace(parsed.value);
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// `NANO_SNAP_DIR=dir zig build test` saves what the test saw.
    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }

    /// Clicks the text's last copy: the menu paints after the page behind it.
    fn clickLast(h: *Harness, label: []const u8) void {
        var at: ?ui.Rect = null;
        for (h.t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
                at = n.rect;
            },
            else => {},
        };
        const r = at orelse return;
        h.t.click(r.x + 4, r.y + r.h / 2);
    }

    /// Fully inside the window, so it can be seen and clicked.
    fn onScreen(h: *Harness, label: []const u8) bool {
        const r = h.t.findText(label) orelse return false;
        return r.y >= 0 and r.y + r.h <= 800;
    }
};

test "the project filter's menu scrolls to its last project" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.t.clickText("All projects");
    h.t.settle(1);
    try testing.expect(h.a.view.filter_menu);
    // Over the list, under the menu's search.
    const r = h.a.view.filter_anchor.?;
    const x = r.x + 40;
    const y = r.y + r.h + 80;
    h.t.moveTo(x, y);
    h.t.scroll(x, y, -4000);
    h.t.settle(1);
    try testing.expect(h.onScreen("project-59"));
    h.clickLast("project-59");
    h.t.settle(1);
    try testing.expect(!h.a.view.filter_menu);
    try testing.expectEqualStrings("s59", h.a.view.filter.?);
}

test "↓ in the project filter's menu keeps its highlight in view" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.t.clickText("All projects");
    h.t.settle(1);
    for (0..40) |_| {
        _ = h.t.shortcut(.{ .key = ui.Shortcut.down });
        h.t.settle(1);
    }
    // All projects, then the 40th project: index 39.
    const r = h.t.findText("project-39") orelse return error.Missing;
    var list: ?ui.Rect = null;
    for (h.t.ctx.hits.items) |hit| if (hit.scroll) {
        list = hit.rect; // The menu's list paints last.
    };
    try testing.expect(r.y >= list.?.y and r.y + r.h <= list.?.y + list.?.h);
}

test "the new session's project menu scrolls to its last project, with Add folder… in the window throughout" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.t.clickText("Working in");
    h.t.settle(1);
    try testing.expect(h.a.view.space_menu);
    try testing.expect(h.onScreen("Add folder…"));
    h.snap("new-session-projects");
    // Over the list, above Add folder….
    const add = h.t.findText("Add folder…").?;
    h.t.moveTo(add.x + 20, add.y - 40);
    h.t.scroll(add.x + 20, add.y - 40, -4000);
    h.t.settle(1);
    try testing.expect(h.onScreen("Add folder…"));
    const last = h.t.findText("project-59") orelse return error.LastMissing;
    try testing.expect(last.y + last.h <= add.y);
    h.snap("new-session-projects-end");
    h.t.click(last.x + 4, last.y + last.h / 2);
    h.t.settle(1);
    try testing.expect(!h.a.view.space_menu);
    try testing.expectEqualStrings("s59", h.a.newChatSpace().?.id);
}

test "in a short window the new session's project menu still fits" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.t.clickText("Working in");
    h.t.settle(1);
    h.t.resize(1200, 300);
    h.t.settle(1);
    const add = h.t.findText("Add folder…") orelse return error.AddMissing;
    try testing.expect(add.y >= 0 and add.y + add.h <= 300);
}
