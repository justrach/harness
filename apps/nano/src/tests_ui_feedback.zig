//! Immediate feedback and bounded tool motion, from synthetic RPC replies.
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
        h.a.view.sidebar_open = false;
        h.a.openChat("synthetic-feedback", null);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"QueueCommand":{}}
        , .{});
        h.a.engine.state = .connected;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 880, .dark = false });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn apply(h: *Harness, text: []const u8) !void {
        const frame = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
        defer frame.deinit();
        try h.a.transcript.apply(frame.value);
        h.t.frame();
    }
};

test "a send paints its prompt and activity next frame without waiting for the engine echo" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.typeText("Synthetic immediate prompt");
    h.a.send();
    h.t.advance(1.0 / 60.0);
    try testing.expect(h.t.hasText("Synthetic immediate prompt"));
    try testing.expectEqual(@import("workspace.zig").Status.working, h.a.selectedStatus());
    // UI feedback must not corrupt the engine's authoritative row count.
    try testing.expectEqual(@as(usize, 0), h.a.transcript.entries.items.len);
    // Even a deliberately delayed echo must not make the prompt disappear.
    h.t.advance(0.4);
    try testing.expect(h.t.hasText("Synthetic immediate prompt"));
}

test "an authoritative echo replaces local feedback without duplicating or changing document cursors" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.typeText("Synthetic echoed prompt");
    h.a.send();
    h.t.advance(1.0 / 60.0);
    const pending = h.a.pending_sends.items[0];
    const frame = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"reset\":[{{\"id\":\"{s}\",\"role\":\"user\",\"parts\":[{{\"id\":\"p\",\"kind\":\"text\",\"text\":\"Synthetic echoed prompt\"}}]}}]}}",
        .{pending.message},
    );
    defer testing.allocator.free(frame);
    try h.apply(frame);
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.transcript.entries.items.len);
    var prompts: usize = 0;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "Synthetic echoed prompt")) {
            prompts += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), prompts);
}

test "a rejected send restores the draft and stops its local working state" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene.?.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{"$err":"Synthetic send rejected"}}
    , .{});
    h.t.typeText("Synthetic rejected prompt");
    h.a.send();
    h.t.advance(1.0 / 60.0);
    try testing.expectEqualStrings("Synthetic rejected prompt", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    try testing.expectEqual(@import("workspace.zig").Status.idle, h.a.selectedStatus());
}

const MotionFixture = struct {
    held_scale: f32 = 1,
    clicks: usize = 0,

    fn view(s: *MotionFixture, c: *ui.Context) void {
        const box = ui.div(c).column().w(300).gap(8);
        defer box.end();
        const k = @import("theme.zig").colors(false);
        @import("view_kit.zig").activityText(c, k, "Reading synthetic files", .{ .size = 12 }, true);
        const button = @import("view_kit.zig").pressFeedback(ui.div(c).row().size(120, 32).control());
        defer button.end();
        s.held_scale = c.node(button.index).style.scale;
        if (button.clicked()) s.clicks += 1;
        ui.text(c, "Synthetic action", .{ .size = 12 });
    }
};

test "a tool click compresses while held, rebounds, and fires only once" {
    var s: MotionFixture = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, MotionFixture.view), .{});
    defer t.deinit();
    try t.hoverText("Synthetic action");
    t.ctx.pointerDown();
    t.frame();
    t.advance(0.04);
    try testing.expect(s.held_scale < 1 and s.held_scale > 0.97);
    try testing.expectEqual(@as(usize, 0), s.clicks);
    t.ctx.pointerUp();
    t.frame();
    t.advance(0.2);
    try testing.expectApproxEqAbs(@as(f32, 1), s.held_scale, 0.001);
    try testing.expectEqual(@as(usize, 1), s.clicks);
}

test "completed historical tools never display active loading cells" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.apply(
        \\{"reset":[{"id":"answer","role":"assistant","status":"complete","parts":[
        \\ {"id":"read","kind":"tool","call":{"kind":"readFile","path":"synthetic.rs"}}]}]}
    );
    try h.t.clickText("Read 1 file");
    h.t.settle(0.3);
    const file = h.t.findText("synthetic.rs") orelse return error.MissingHistoricalTool;
    for (h.t.ctx.nodes.items) |node| {
        // The fixture's unlisted composer model has its own legitimate
        // catalog loader. Check the tool row, not unrelated window regions.
        if (node.rect.y < file.y - 4 or node.rect.y > file.y + file.h + 4) continue;
        if (node.rect.w == 2 and node.rect.h == 2 and node.style.background != null)
            return error.HistoricalToolStillLoading;
    }
}
