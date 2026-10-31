//! Synthetic headless coverage of the shell's sliding sidebar geometry.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const transcript = @import("view_transcript.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = false;
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic","deviceId":"d","title":"Synthetic sidebar chat","archived":false},
            \\ {"id":"other","deviceId":"d","title":"Other synthetic chat","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("synthetic", null);
        const messages = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[
            \\ {"id":"u1","role":"user","parts":[{"id":"p","kind":"text","text":"First synthetic prompt"}]},
            \\ {"id":"answer","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic sidebar answer"}]},
            \\ {"id":"u2","role":"user","parts":[{"id":"p","kind":"text","text":"Second synthetic prompt"}]}]}
        , .{});
        defer messages.deinit();
        try h.a.transcript.apply(messages.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = false });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn toggle(h: *Harness) void {
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    }

    fn origin(h: *Harness) f32 {
        return h.t.size.w - transcript.mainWidth(&h.t.ctx, &h.a);
    }

    fn geometry(h: *Harness) !void {
        const x = h.origin();
        var main = false;
        var side = false;
        var header = false;
        var rail_ticks: usize = 0;
        for (h.t.ctx.nodes.items) |node| {
            const r = node.rect;
            if (@abs(r.x - x) < 1 and @abs(r.w - (1200 - x)) < 1 and r.h == 780) main = true;
            if (r.w == 256 and r.h == 780 and std.meta.eql(node.style.background, @import("theme.zig").colors(false).sidebar)) {
                try testing.expectApproxEqAbs(x - 256, r.x, 1);
                side = true;
            }
            if (r.h == 2 and r.w == 12 and @abs(r.x - (x + 16)) < 1) rail_ticks += 1;
            switch (node.content) {
                .text => |text| if (std.mem.eql(u8, text.str, "Synthetic sidebar chat") and r.y < 38) {
                    // The mark and its gap follow the animated titlebar clearance.
                    try testing.expectApproxEqAbs(@max(x + 16, 214) + 20, r.x, 1);
                    header = true;
                },
                else => {},
            }
        }
        try testing.expect(main and (side or x == 0) and header);
        try testing.expectEqual(@as(usize, 2), rail_ticks);
        // Read final layout rather than the composer's previous-frame anchor.
        var composer = false;
        for (h.t.ctx.nodes.items) |node| {
            if (node.rect.w == 736 and node.rect.h == 49) {
                try testing.expectApproxEqAbs(x + (1200 - x - 736) / 2, node.rect.x, 1);
                composer = true;
            }
        }
        try testing.expect(composer);
        const answer = h.t.findText("Synthetic sidebar answer") orelse return error.MissingVisibleReply;
        try testing.expect(answer.y >= 38 and answer.y + answer.h < h.t.size.h - 89);
    }
};

test "Cmd+B has an intermediate main viewport width rather than unmounting immediately" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expectApproxEqAbs(@as(f32, 256), h.origin(), 0.01);
    h.toggle();
    h.t.advance(0.08);
    try testing.expect(h.origin() > 0 and h.origin() < 256);
    try h.geometry();
    h.t.advance(0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    try h.geometry();
    const composer_id = h.a.view.composer_id;
    h.toggle();
    h.t.advance(0.08);
    try testing.expect(h.origin() > 0 and h.origin() < 256);
    try h.geometry();
    try testing.expectEqual(composer_id, h.a.view.composer_id);
    // Clipped-off sidebar rows cannot intercept chat-column input.
    const row = h.t.findText("Other synthetic chat") orelse return error.MissingSidebarRow;
    h.t.click(h.origin() + 16, row.y + row.h / 2);
    try testing.expectEqualStrings("synthetic", h.a.selected.?);
    h.t.advance(0.3);
    try testing.expectApproxEqAbs(@as(f32, 256), h.origin(), 0.01);
    try h.geometry();
}

test "sidebar reversals sample the current width and settle without idle animation frames" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.time = h.t.ctx.time;
    h.t.frame();
    h.t.time = h.t.ctx.time + 0.1;
    h.t.frame();
    // Exact CSS ease-out's halfway sample (not a cubic ease-out shortcut).
    try testing.expectApproxEqAbs(@as(f32, 80.73), h.origin(), 0.1);
    const closing = h.origin();
    // Retarget at the very same sample time; shortcut() itself advances
    // the Tester's clock across key-down/up frames.
    h.a.view.sidebar_open = true;
    h.t.time = h.t.ctx.time;
    h.t.frame();
    try testing.expectApproxEqAbs(closing, h.origin(), 0.01);
    h.t.advance(0.05);
    try testing.expect(h.origin() > closing and h.origin() < 256);
    const opening = h.origin();
    h.a.view.sidebar_open = false;
    h.t.time = h.t.ctx.time;
    h.t.frame();
    try testing.expectApproxEqAbs(opening, h.origin(), 0.01);
    h.t.advance(0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    h.t.ctx.focus = 0;
    h.t.settle(1);
    try testing.expect(!h.t.ctx.animating);
    h.t.advance(1);
    try testing.expect(!h.t.ctx.animating);
}

test "mouse and keyboard close search together and restore composer focus" {
    for ([_]bool{ false, true }) |mouse| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        @import("view_sidebar_search.zig").toggle(&h.a);
        h.t.settle(1);
        try testing.expect(h.a.view.search.field_focused);
        if (mouse) h.t.click(100, 21) else h.toggle();
        h.t.frame();
        try testing.expect(!h.a.view.sidebar_open);
        try testing.expect(!h.a.view.search.open);
        try testing.expect(!h.a.view.search.focus);
        try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
        h.t.advance(0.08);
        try testing.expect(h.origin() > 0 and h.origin() < 256);
    }
}

test "Cmd+B preserves file search focus while the sidebar search is open" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    @import("view_sidebar_search.zig").toggle(&h.a);
    h.t.settle(1);
    h.a.panels.files_open = true;
    h.t.settle(1);
    try h.t.clickText("Search files");
    const focused = h.t.ctx.focus;
    try testing.expect(focused != 0 and focused != h.a.view.composer_id);
    try testing.expect(!@import("view_sidebar_search.zig").hasFocus(&h.a));
    h.toggle();
    h.t.frame();
    try testing.expect(!h.a.view.search.open);
    try testing.expectEqual(focused, h.t.ctx.focus);
}

test "Settings keeps its full navigation and reduced motion snaps both directions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.ctx.reduced_motion = true;
    h.toggle();
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    h.toggle();
    try testing.expectApproxEqAbs(@as(f32, 256), h.origin(), 0.01);
    h.toggle();
    _ = h.t.shortcut(.{ .key = ',', .cmd = true });
    try testing.expect(h.a.view.settings_open);
    try testing.expectApproxEqAbs(@as(f32, 256), h.origin(), 0.01);
    h.toggle();
    h.toggle();
    try testing.expectApproxEqAbs(@as(f32, 256), h.origin(), 0.01);
    h.t.ctx.focus = 0;
    h.t.frame();
    try testing.expect(!h.t.ctx.animating);
}
