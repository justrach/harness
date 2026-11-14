//! Synthetic split-window regression: no account, provider or personal app data.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;
const question = @import("app_question.zig");

const input =
    \\{"reset":[{"id":"ask","role":"assistant","parts":[{"kind":"input","requestId":"synthetic-question","resolved":false,"questions":[
    \\{"id":"choice","header":"Plan","question":"Which approach should the synthetic agent take?","options":["Keep the existing behavior and add focused regression coverage","Use the simplified implementation with readable native controls"],"multiSelect":true},
    \\{"id":"text","header":"Details","question":"Describe the synthetic implementation plan.","options":[],"multiline":true}]}]}]}
;

const Harness = struct {
    a: App,
    t: ui.Tester,
    fn init(h: *Harness, width: f32, height: f32, splits: usize) !void {
        return h.initWithInput(width, height, splits, input);
    }
    fn initWithInput(h: *Harness, width: f32, height: f32, splits: usize, payload: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.offscreen = true;
        h.a.view.sidebar_open = false;
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"QueueCommand":{},"FocusChat":{},"Mutate":{}}
        , .{});
        h.a.engine.state = .connected;
        h.a.openChat("synthetic-owner", null);
        for (0..splits) |_| _ = try h.a.tabs.split(.horizontal);
        h.a.tabs.focusPane(0);
        h.a.composer.set("Unsent synthetic prompt");
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        question.syncWizard(&h.a);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = width, .height = height, .dark = true });
        h.t.ctx.reduced_motion = true;
        h.draw();
    }
    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
    fn draw(h: *Harness) void {
        h.t.ctx.changed = true;
        h.t.settle(8);
    }
    fn snap(h: *Harness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_QUESTION_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }));
    }
};

fn textRect(t: *ui.Tester, text: []const u8) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |v| if (std.mem.eql(u8, v.str, text)) {
            return n.rect;
        },
        else => {},
    };
    return null;
}

test "question surface narrow split keeps options readable and controls window bounded" {
    var h: Harness = undefined;
    try h.init(1000, 700, 7);
    defer h.deinit();
    try h.snap("narrow-split");
    try testing.expectEqual(@as(usize, 1), textCount(&h.t, "Cancel question"));
    const option = textRect(&h.t, "Keep the existing behavior and add focused regression coverage") orelse return error.MissingOption;
    try testing.expect(option.w >= 300);
    const second = textRect(&h.t, "Use the simplified implementation with readable native controls").?;
    try testing.expect(second.y >= option.y + option.h);
    try testing.expectEqual(@as(usize, 1), textCount(&h.t, "Keep the existing behavior and add focused regression coverage"));
    const submit = textRect(&h.t, "Next") orelse return error.MissingNext;
    try testing.expect(submit.x >= 0 and submit.y >= 0 and submit.x + submit.w <= 1000 and submit.y + submit.h <= 700);
}

fn textCount(t: *ui.Tester, label: []const u8) usize {
    var count: usize = 0;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |v| if (std.mem.eql(u8, v.str, label)) {
            count += 1;
        },
        else => {},
    };
    return count;
}

fn bounded(t: *ui.Tester, label: []const u8, width: f32, height: f32) !void {
    const r = textRect(t, label) orelse return error.MissingControl;
    try testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= width and r.y + r.h <= height);
}

fn command(h: *Harness, kind: []const u8) !std.json.Parsed(std.json.Value) {
    var i = h.a.engine.sent.items.len;
    while (i > 0) {
        i -= 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, h.a.engine.sent.items[i], .{});
        const v = parsed.value;
        if (std.mem.eql(u8, v.object.get("method").?.string, "QueueCommand")) {
            const cmd = v.object.get("params").?.object.get("command").?;
            if (std.mem.eql(u8, cmd.object.get("kind").?.string, kind)) return parsed;
        }
        parsed.deinit();
    }
    return error.NoQuestionCommand;
}

test "question surface keyboard picks free text back next submit preserve exact answers" {
    var h: Harness = undefined;
    try h.init(1000, 700, 7);
    defer h.deinit();
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    _ = h.t.shortcut(.{ .key = '2' });
    h.draw();
    try testing.expect(h.a.wizard.?.picked(1));
    try testing.expectEqualStrings("", h.a.composer.text());
    try h.t.clickText("Next");
    h.draw();
    try testing.expectEqual(@as(usize, 1), h.a.wizard.?.page);
    h.t.typeText("Keep this exact synthetic answer");
    h.draw();
    try testing.expectEqualStrings("Keep this exact synthetic answer", h.a.composer.text());
    // Digits in a nonempty answer remain text; they must not change picks.
    h.t.typeText(" 1");
    h.draw();
    try h.t.clickText("Back");
    h.draw();
    try testing.expectEqual(@as(usize, 0), h.a.wizard.?.page);
    try testing.expect(h.a.wizard.?.picked(1));
    try h.t.clickText("Next");
    h.draw();
    try testing.expectEqualStrings("Keep this exact synthetic answer 1", h.a.composer.text());
    try h.t.clickText("Submit");
    h.draw();
    try testing.expect(h.a.wizard == null);
    try testing.expectEqualStrings("Unsent synthetic prompt", h.a.composer.text());
    var sent = try command(&h, "respondInput");
    defer sent.deinit();
    const params = sent.value.object.get("params").?.object;
    try testing.expectEqualStrings("synthetic-owner", params.get("chatId").?.string);
    const cmd = params.get("command").?.object;
    try testing.expectEqualStrings("synthetic-question", cmd.get("requestId").?.string);
    const answers = cmd.get("answers").?.array.items;
    try testing.expectEqualStrings("Use the simplified implementation with readable native controls", answers[0].object.get("labels").?.array.items[0].string);
    try testing.expectEqualStrings("Keep this exact synthetic answer 1", answers[1].object.get("labels").?.array.items[0].string);
}

test "question surface escape back and cancel keep original prompt and owner fence" {
    var h: Harness = undefined;
    try h.init(1000, 700, 7);
    defer h.deinit();
    _ = h.t.shortcut(.{ .key = '1' });
    h.draw();
    try h.t.clickText("Next");
    h.draw();
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.draw();
    try testing.expectEqual(@as(usize, 0), h.a.wizard.?.page);
    h.t.typeText("Parked answer from owning session");
    h.draw();
    h.a.focusPane(1);
    h.draw();
    try testing.expect(h.a.wizard == null);
    try testing.expectEqual(@as(usize, 0), textCount(&h.t, "Cancel question"));
    h.t.typeText("Neighbor draft");
    h.draw();
    h.a.focusPane(0);
    h.draw();
    try testing.expectEqualStrings("synthetic-owner", h.a.selected.?);
    try testing.expectEqualStrings("Parked answer from owning session", h.a.composer.text());
    try testing.expect(h.a.wizard.?.picked(0));
    try h.t.clickText("Cancel question");
    h.draw();
    try testing.expect(h.a.wizard == null);
    try testing.expectEqualStrings("Unsent synthetic prompt", h.a.composer.text());
    var sent = try command(&h, "dismissInput");
    defer sent.deinit();
    try testing.expectEqualStrings("synthetic-owner", sent.value.object.get("params").?.object.get("chatId").?.string);
    h.a.focusPane(1);
    h.draw();
    try testing.expectEqualStrings("Neighbor draft", h.a.composer.text());
}

test "question surface ordinary wide panes stay inline and moving outlets keeps draft and focus" {
    var h: Harness = undefined;
    try h.init(1200, 780, 0);
    defer h.deinit();
    try testing.expect(!@import("view_question.zig").expanded(&h.t.ctx, &h.a));
    try h.snap("wide-inline");
    h.t.typeText("Draft survives resizing the split");
    h.draw();
    // Change allocation without replacing the selected wizard or composer.
    for (0..7) |_| _ = try h.a.tabs.split(.horizontal);
    h.a.tabs.focusPane(0);
    h.draw();
    try testing.expect(@import("view_question.zig").expanded(&h.t.ctx, &h.a));
    try testing.expectEqualStrings("Draft survives resizing the split", h.a.composer.text());
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.typeText(" and still accepts typing");
    h.draw();
    try testing.expectEqualStrings("Draft survives resizing the split and still accepts typing", h.a.composer.text());
    h.a.tabs.layout().?.zoomed = true;
    h.draw();
    try testing.expect(!@import("view_question.zig").expanded(&h.t.ctx, &h.a));
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    try testing.expectEqualStrings("Draft survives resizing the split and still accepts typing", h.a.composer.text());
}

test "question surface short and small windows bound pinned controls" {
    for ([_][2]f32{ .{ 1000, 360 }, .{ 420, 500 }, .{ 320, 500 } }) |size| {
        var h: Harness = undefined;
        try h.init(size[0], size[1], 7);
        defer h.deinit();
        try bounded(&h.t, "Cancel question", size[0], size[1]);
        try bounded(&h.t, "Next", size[0], size[1]);
        try h.snap(if (size[0] == 1000) "short-split" else if (size[0] == 420) "small-window" else "smallest-window");
        for (0..12) |_| h.t.typeText("First synthetic line\n");
        h.draw();
        try bounded(&h.t, "Cancel question", size[0], size[1]);
        try bounded(&h.t, "Next", size[0], size[1]);
    }
}

test "question surface long content scrolls while controls stay pinned and next page resets scroll" {
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..40) |_| try long.appendSlice(testing.allocator, "A synthetic question paragraph with enough detail to require independent scrolling. ");
    var opts: [20][]const u8 = undefined;
    for (&opts, 0..) |*opt, i| opt.* = try std.fmt.allocPrint(testing.allocator, "Synthetic option {d}: Keep the readable controls and focused regression coverage", .{i + 1});
    defer for (opts) |opt| testing.allocator.free(opt);
    const payload = try std.json.Stringify.valueAlloc(testing.allocator, .{ .reset = .{.{
        .id = "ask",
        .role = "assistant",
        .parts = .{.{
            .kind = "input",
            .requestId = "synthetic-question",
            .questions = .{
                .{ .id = "choice", .header = "Long plan", .question = long.items, .options = opts, .multiSelect = true },
                .{ .id = "text", .header = "Details", .question = "Describe the synthetic plan", .options = [0][]const u8{}, .multiline = true },
            },
        }},
    }} }, .{});
    defer testing.allocator.free(payload);
    var h: Harness = undefined;
    try h.initWithInput(1000, 360, 7, payload);
    defer h.deinit();
    try h.snap("long-content");
    const before = textRect(&h.t, "Next").?;
    // Locate the options' clipping viewport through the first option's
    // ancestors, not an arbitrary offscreen label rect.
    var view: ?u32 = null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |v| if (std.mem.eql(u8, v.str, opts[0])) {
            var parent = n.parent;
            while (parent != 0) {
                const ancestor = h.t.ctx.node(parent);
                if (ancestor.style.scroll) {
                    view = parent;
                    break;
                }
                parent = ancestor.parent;
            }
        },
        else => {},
    };
    const index = view orelse return error.MissingOptionsViewport;
    const viewport = h.t.ctx.node(index).rect;
    const id = h.t.ctx.node(index).id;
    try testing.expect(viewport.h > 0 and viewport.h < 250);
    h.t.scroll(viewport.x + viewport.w / 2, viewport.y + viewport.h / 2, -10000);
    h.draw();
    try testing.expect((h.t.ctx.scroll.get(id) orelse 0) > 0);
    try testing.expectApproxEqAbs(before.y, textRect(&h.t, "Next").?.y, 0.5);
    try bounded(&h.t, "Cancel question", 1000, 360);
    try h.t.clickText(opts[19]);
    h.draw();
    try testing.expect(h.a.wizard.?.picked(19));
    try h.t.clickText("Next");
    h.draw();
    try testing.expectEqual(@as(usize, 1), h.a.wizard.?.page);
    try bounded(&h.t, "Submit", 1000, 360);
    try h.snap("long-content-next-page");
}
