//! Synthetic production dock: queue, growing input and jump affordance share
//! geometry, without engine requests, clipboard access or a visible window.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");

fn view(a: *App, c: *ui.Context) void {
    a.view.chrome.width = c.size.w;
    a.view.chrome.chat_width = c.size.w;
    const root = ui.div(c).column().sizeFull().justifyEnd();
    defer root.end();
    @import("view_composer.zig").docked(c, a, theme.colors(a.dark orelse false));
}

fn queue(a: *App, count: usize) !void {
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(a.gpa);
    try rows.appendSlice(a.gpa, "[");
    for (0..count) |i| {
        if (i > 0) try rows.appendSlice(a.gpa, ",");
        try rows.print(a.gpa, "{{\"id\":\"q{d}\",\"text\":\"Synthetic queued message {d}\"}}", .{ i, i });
    }
    try rows.appendSlice(a.gpa, "]");
    const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, rows.items, .{});
    defer parsed.deinit();
    try a.queue.replace(parsed.value);
}

fn attach(a: *App) !void {
    const Item = @import("app_attachments.zig").Item;
    const item = try a.gpa.create(Item);
    item.* = .{
        .app = a,
        .owner = try a.gpa.dupe(u8, "synthetic"),
        .name = try a.gpa.dupe(u8, "image.png"),
        .bytes = try a.gpa.dupe(u8, @embedFile("reply-image-fixture.png")),
        .target = null,
        .id = "00000000-0000-0000-0000-000000000001".*,
        .status = .ready,
    };
    try a.attachments.items.append(a.gpa, item);
}

fn parentOfText(tester: *ui.Tester, label: []const u8) !u32 {
    for (tester.ctx.nodes.items) |n| {
        if (n.content == .text and std.mem.eql(u8, n.content.text.str, label)) return n.parent;
    }
    return error.MissingDockText;
}

fn trayRect(tester: *ui.Tester) !ui.Rect {
    var at = try parentOfText(tester, "Synthetic queued message 0");
    while (at < tester.ctx.nodes.items.len) {
        const n = tester.ctx.node(at);
        if (n.style.border != null) return n.rect;
        at = n.parent;
    }
    return error.MissingQueueSurface;
}

fn snap(tester: *ui.Tester, width: usize, draft: usize, count: usize) !void {
    const dir = std.c.getenv("NANO_DOCK_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/dock-{d}-{d}-{d}.png", .{ std.mem.span(dir), width, draft, count });
    try tester.screenshot(path);
}

test "composer dock separates queue tray jump button and growing input" {
    theme.registerFonts();
    for ([_]usize{ 320, 520, 900 }) |width| for (0..3) |draft| for ([_]usize{ 1, 8 }) |count| {
        var a: App = .init(t.allocator, t.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = false;
        a.selected = try a.gpa.dupe(u8, "synthetic");
        a.view.strip.focused = .{ .chat = 0 };
        a.view.jump_box = 777;
        a.view.jump_distance = 800;
        try queue(&a, count);
        if (draft > 0) a.composer.set("Synthetic draft\nSecond line");
        if (draft == 2) try attach(&a);
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&a, view), .{ .width = @floatFromInt(width), .height = 600 });
        defer tester.deinit();
        tester.settle(0.5);
        try snap(&tester, width, draft, count);
        const tray = try trayRect(&tester);
        const pill = a.view.composer_anchor orelse return error.MissingComposer;
        const jump = tester.ctx.node(try parentOfText(&tester, "Scroll to bottom")).rect;
        try t.expect(tray.y + tray.h + 7 <= pill.y);
        try t.expect(jump.y + jump.h + 5 <= tray.y);
        try t.expect(jump.y >= 0);
        try t.expect(pill.y + pill.h <= 600);
        if (count == 8) {
            const viewport = for (tester.ctx.nodes.items) |node| {
                if ((tester.ctx.scroll_max.get(node.id) orelse 0) > 0 and node.rect.y >= tray.y and node.rect.y + node.rect.h <= tray.y + tray.h) break node.rect;
            } else return error.MissingQueueScrollViewport;
            tester.moveTo(viewport.x + viewport.w / 2, viewport.y + viewport.h / 2);
            tester.scroll(viewport.x + viewport.w / 2, viewport.y + viewport.h / 2, -10000);
            tester.settle(0.2);
            const last = tester.findText("Synthetic queued message 7") orelse return error.MissingLastQueuedRow;
            try t.expect(last.y >= viewport.y and last.y + last.h <= viewport.y + viewport.h);
        }
        try tester.clickText("Scroll to bottom");
        try t.expect(tester.ctx.scroll_follow.get(777) orelse false);
    };
}
