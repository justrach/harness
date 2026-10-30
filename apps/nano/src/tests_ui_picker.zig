//! The desktop's model picker, driven with made-up catalogs and no engine.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const catalog =
    \\[{"id":"openai/synthetic-fast","label":"Synthetic Fast","description":"128k context","maker":"openai","billing":"credits","reasoningLevels":["low","high"]},
    \\ {"id":"chatgpt-new/synthetic-plan","label":"Synthetic Plan","description":"500k context","maker":"openai","billing":"plan","reasoningLevels":["high","ultra"]},
    \\ {"id":"anthropic/synthetic-thought","label":"Synthetic Thought","description":"200k context","maker":"anthropic","billing":"credits","reasoningLevels":["low","high"]}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, dark: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.new_harness = try testing.allocator.dupe(u8, "graff");
        h.a.models_for = try testing.allocator.dupe(u8, "graff");
        h.a.view.sidebar_open = false;
        const agents = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"graff","name":"graff","enabled":true},
            \\ {"id":"claude-code","name":"Claude Code","enabled":true},
            \\ {"id":"codex","name":"Codex","enabled":true}]
        , .{});
        defer agents.deinit();
        try h.a.harnesses.replace(agents.value);
        const models = try std.json.parseFromSlice(std.json.Value, testing.allocator, catalog, .{});
        defer models.deinit();
        try h.a.models.replace(models.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 900, .height = 750, .dark = dark });
        h.t.settle(1);
        h.a.togglePicker();
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_PICKER_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "model picker uses Harness tabs, search and a separate reasoning footer" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        h.snap(if (dark) "picker-dark" else "picker-light");
        try testing.expect(h.t.hasText("Starred"));
        try testing.expect(h.t.hasText("graff"));
        try testing.expect(h.t.hasText("Claude Code"));
        try testing.expect(h.t.hasText("Codex"));
        try testing.expect(!h.t.hasText("Agent"));
        try testing.expect(h.t.hasText("Reasoning"));
        try testing.expect(h.t.hasText("Synthetic Plan"));
        const footer = h.t.findText("Reasoning") orelse return error.MissingReasoning;
        const model = h.t.findText("Synthetic Plan") orelse return error.MissingModel;
        try testing.expect(footer.y > model.y);
        const tab = h.t.findText("Starred") orelse return error.MissingTabs;
        const chip = h.a.view.chip_anchor orelse return error.MissingChip;
        try testing.expect(tab.y >= chip.y + chip.h);
    }
}

test "model picker search and reasoning footer use GPUI's rendered text metrics" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const footer = h.t.findText("Reasoning") orelse return error.MissingFooter;
    var found: u3 = 0;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| {
            if (std.mem.startsWith(u8, text.str, "Search models")) {
                try testing.expectEqual(@as(f32, 14), text.style.size);
                try testing.expectEqual(ui.Weight.medium, text.style.weight);
                found |= 1;
            } else if (std.mem.eql(u8, text.str, "Reasoning")) {
                try testing.expectEqual(@as(f32, 13), text.style.size);
                try testing.expectEqual(ui.Weight.medium, text.style.weight);
                found |= 2;
            } else if (std.mem.eql(u8, text.str, "High") and node.rect.y >= footer.y) {
                try testing.expectEqual(@as(f32, 13), text.style.size);
                try testing.expectEqual(ui.Weight.medium, text.style.weight);
                found |= 4;
            }
        },
        else => {},
    };
    try testing.expectEqual(@as(u3, 7), found);
}

test "model search is scoped, stars do not select, and Return picks the starred model" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.t.typeText("PLAN");
    h.t.settle(1);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rows = try @import("model_picker.zig").rows(&h.a, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("chatgpt-new/synthetic-plan", rows[0].model.id);
    try testing.expect(h.t.containsText("Synthetic Plan"));
    const plan = h.t.findText("Synthetic Plan") orelse return error.MissingPlan;
    const footer = h.t.findText("Reasoning") orelse return error.MissingFooter;
    h.t.click(footer.x + @import("view_picker.zig").menu_width - 37, plan.y + plan.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.favorite("graff", "chatgpt-new/synthetic-plan"));
    try testing.expect(h.a.new_model == null);
    try testing.expect(h.a.picker != .none);
    try h.t.clickText("Starred");
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.starred);
    rows = try @import("model_picker.zig").rows(&h.a, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rows.len);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.enter });
    h.t.settle(1);
    try testing.expectEqualStrings("chatgpt-new/synthetic-plan", h.a.new_model.?);
    try testing.expect(h.a.picker == .none);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "the pinned reasoning footer opens its own choices and applies them" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.t.clickText("Reasoning");
    h.t.settle(1);
    try testing.expect(h.t.containsText("Low"));
    try h.t.clickText("Low");
    h.t.settle(1);
    try testing.expectEqualStrings("low", h.a.new_reasoning.?);
    try testing.expect(h.a.new_model == null);
    try testing.expect(h.a.picker == .none);
}

test "agent tabs cycle both ways while an existing chat stays locked to its own agent" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true });
    h.t.settle(1);
    try testing.expectEqualStrings("claude-code", h.a.new_harness);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true, .shift = true });
    h.t.settle(1);
    try testing.expectEqualStrings("graff", h.a.new_harness);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"existing","title":"Synthetic existing chat","archived":false,"config":{"harness":"graff","model":"openai/synthetic-fast"}}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.picker = .none;
    h.a.openChat("existing", null);
    h.t.settle(1);
    h.a.togglePicker();
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Claude Code"));
    try testing.expect(!h.t.hasText("Codex"));
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true });
    h.t.settle(1);
    try testing.expectEqualStrings("graff", h.a.target().harness);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(1);
    try testing.expect(h.a.picker == .none);
}

test "dismissal fades for 100ms without taking composer focus or leaving idle frames" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    try testing.expect(h.a.picker == .none);
    try testing.expect(h.t.hasText("Starred"));
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.advance(0.15);
    try testing.expect(!h.t.hasText("Starred"));
    h.t.ctx.focus = 0;
    h.t.settle(1);
    try testing.expect(!h.t.ctx.animating);
}

test "Escape preserves the model trigger hover until the pointer moves" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(1);
    const chip = h.a.view.chip_anchor orelse return error.MissingChip;
    h.t.click(chip.x + chip.w / 2, chip.y + chip.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.picker != .none);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(1);
    const anchor = h.a.view.chip_anchor orelse return error.MissingChip;
    const fill = for (h.t.ctx.nodes.items) |node| {
        if (std.meta.eql(node.rect, anchor) and node.style.direction == .row) break node.style.background;
    } else return error.MissingChip;
    const color = fill orelse return error.MissingHoverFill;
    try testing.expectApproxEqAbs(@import("theme.zig").colors(true).hover.a, color.a, 0.001);
    h.t.moveTo(880, 40);
    h.t.settle(1);
    for (h.t.ctx.nodes.items) |node| {
        if (std.meta.eql(node.rect, anchor) and node.style.direction == .row) {
            try testing.expect((if (node.style.background) |bg| bg.a else 0) < 0.001);
            return;
        }
    }
    return error.MissingChip;
}

test "a late model catalog never overwrites the agent tab selected after it" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.new_harness = try testing.allocator.dupe(u8, "graff");
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ListModels":{"$seq":[[{"id":"graff/slow","label":"Slow old catalog"}],[{"id":"codex/current","label":"Current catalog"}]]}}
    , .{});
    a.engine.state = .connected;
    a.ensureModels("graff");
    a.ensureModels("codex");
    try testing.expectEqual(@as(usize, 2), a.engine.queued.items.len);
    const old = a.engine.queued.orderedRemove(0);
    defer testing.allocator.free(old);
    const current = a.engine.queued.orderedRemove(0);
    defer testing.allocator.free(current);
    try a.engine.mux.dispatch(current);
    try a.engine.mux.dispatch(old);
    try testing.expectEqualStrings("codex", a.models_for);
    try testing.expectEqualStrings("codex/current", a.models.items[0].id);
    try testing.expectEqualStrings("graff/slow", a.view.model_picker.catalogs.get("graff").?.models.items[0].id);
}

test "large model catalogs only build visible rows and keep the footer pinned" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const small_nodes = h.t.ctx.stats.nodes;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const catalog_rows = try gpa.alloc(@import("workspace.zig").Model, 2000);
    for (catalog_rows, 0..) |*m, i| m.* = .{
        .id = try std.fmt.allocPrint(gpa, "openai/synthetic-{d}", .{i}),
        .label = try std.fmt.allocPrint(gpa, "Synthetic model {d}", .{i}),
        .levels = &.{ "low", "high" },
    };
    try @import("model_picker.zig").copyModels(&h.a.models, catalog_rows);
    h.a.view.model_picker.active = 0;
    h.t.settle(1);
    const large_nodes = h.t.ctx.stats.nodes;
    try testing.expect(large_nodes <= small_nodes * 2);
    const footer = h.t.findText("Reasoning") orelse return error.MissingFooter;
    h.t.scroll(footer.x + 30, footer.y - 50, -100000);
    h.t.settle(1);
    try testing.expect(h.t.containsText("Synthetic model 1999"));
    try testing.expect(h.t.ctx.stats.nodes <= small_nodes * 2);
    const after = h.t.findText("Reasoning") orelse return error.MissingFooter;
    try testing.expectApproxEqAbs(footer.y, after.y, 0.01);
    std.log.info("model picker: 3 models {d} nodes; 2000 models {d} nodes", .{ small_nodes, large_nodes });
}
