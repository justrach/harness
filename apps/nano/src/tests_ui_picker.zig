//! The desktop's model picker, driven with made-up catalogs and no engine.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const catalog =
    \\[{"id":"openai/synthetic-fast","label":"Synthetic Fast","description":"128k context","maker":"openai","billing":"credits","reasoningLevels":["low","high"]},
    \\ {"id":"openai/synthetic-max","label":"Synthetic Max","description":"256k context","maker":"openai","billing":"credits","reasoningLevels":["high","max"]},
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

test "the picker: agent tabs, a search, and the models in a section per route" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        h.snap(if (dark) "picker-dark" else "picker-light");
        for ([_][]const u8{ "Starred", "graff", "Claude Code", "Codex", "OpenAI", "ChatGPT plan", "Anthropic", "Synthetic Plan" }) |t|
            try testing.expect(h.t.hasText(t));
        // No reasoning tray on the list: reasoning is the model's page.
        try testing.expect(!h.t.hasText("Reasoning"));
        const openai = h.t.findText("OpenAI") orelse return error.MissingSection;
        const fast = inPicker(&h, "Synthetic Fast") orelse return error.MissingModel;
        const plan_head = h.t.findText("ChatGPT plan") orelse return error.MissingSection;
        const plan_row = inPicker(&h, "Synthetic Plan") orelse return error.MissingModel;
        // Subscription ("plan") routes and models lead non-subscription ("credits") ones.
        try testing.expect(plan_head.y < plan_row.y and plan_row.y < openai.y and openai.y < fast.y);
        const tab = h.t.findText("Starred") orelse return error.MissingTabs;
        const chip = h.a.view.chip_anchor orelse return error.MissingChip;
        try testing.expect(tab.y + tab.h < chip.y);
    }
}

test "model picker search uses GPUI's rendered text metrics" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    var found = false;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.startsWith(u8, text.str, "Search models")) {
            try testing.expectEqual(@as(f32, 14), text.style.size);
            try testing.expectEqual(ui.Weight.medium, text.style.weight);
            found = true;
        },
        else => {},
    };
    try testing.expect(found);
}

/// `label` in the picker, not the composer chip's (which names the model
/// too): the docked new-chat picker opens above its footer chip.
fn inPicker(h: *Harness, label: []const u8) ?ui.Rect {
    const chip = h.a.view.chip_anchor orelse return null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| if (std.mem.eql(u8, t.str, label) and n.rect.y + n.rect.h < chip.y) return n.rect,
        else => {},
    };
    return null;
}

/// The star at the right end of `label`'s row.
fn star(h: *Harness, label: []const u8) !ui.Rect {
    const row = inPicker(h, label) orelse return error.MissingModel;
    var best: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .image, .icon => if (n.rect.y < row.y + row.h and n.rect.y + n.rect.h > row.y and (best == null or n.rect.x > best.?.x)) {
            best = n.rect;
        },
        else => {},
    };
    return best orelse error.MissingStar;
}

fn clickRow(h: *Harness, label: []const u8) !void {
    const r = inPicker(h, label) orelse return error.MissingModel;
    h.t.click(r.x + 4, r.y + r.h / 2);
    h.t.settle(1);
}

test "model search is scoped, stars do not select, and Return opens then uses the starred model" {
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
    const s = try star(&h, "Synthetic Plan");
    h.t.click(s.x + s.w / 2, s.y + s.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.favorite("graff", "chatgpt-new/synthetic-plan"));
    try testing.expect(h.a.new_model == null);
    try testing.expect(h.a.picker != .none);
    try h.t.clickText("Starred");
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.starred);
    rows = try @import("model_picker.zig").rows(&h.a, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rows.len);
    // Return opens the model's page; Return there uses it.
    _ = h.t.shortcut(.{ .key = ui.Shortcut.enter });
    h.t.settle(1);
    try testing.expect(h.t.hasText("Use model"));
    try testing.expect(h.a.new_model == null);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.enter });
    h.t.settle(1);
    try testing.expectEqualStrings("chatgpt-new/synthetic-plan", h.a.new_model.?);
    try testing.expect(h.a.picker == .none);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "model picker: text-field Return opens the filtered model and confirms it" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.t.typeText("synthetic-max");
    h.t.settle(1);
    h.t.key(.enter);
    h.t.settle(1);
    h.snap("picker-return");
    try testing.expect(h.t.hasText("Use model"));
    try testing.expectEqualStrings("openai/synthetic-max", h.a.view.model_picker.stage.?.model);
    try testing.expect(h.a.new_model == null);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.enter });
    h.t.settle(1);
    try testing.expectEqualStrings("openai/synthetic-max", h.a.new_model.?);
    try testing.expect(h.a.picker == .none);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    try testing.expectEqualStrings("", h.a.composer.text());
}

test "model picker: clicking Configure opens the highlighted model" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.t.typeText("synthetic-max");
    h.t.settle(1);
    try h.t.clickText("Configure");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Use model"));
    try testing.expectEqualStrings("openai/synthetic-max", h.a.view.model_picker.stage.?.model);
    try testing.expect(h.a.new_model == null);
    try h.t.clickText("Use model");
    h.t.settle(1);
    try testing.expectEqualStrings("openai/synthetic-max", h.a.new_model.?);
    try testing.expect(h.a.picker == .none);
}

test "a row under the pointer shows a detail card of what the catalog says, and only that" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const fast = inPicker(&h, "Synthetic Fast") orelse return error.MissingModel;
    h.t.moveTo(fast.x + 4, fast.y + 4);
    h.t.frame();
    try testing.expect(!h.t.hasText("via OpenAI"));
    h.t.advance(0.25);
    h.snap("picker-detail");
    for ([_][]const u8{ "via OpenAI", "Reasoning", "Low – High", "Billing", "Credits", "128k context" }) |t|
        try testing.expect(h.t.hasText(t));
    // Nothing the catalog didn't say: no context window listed for it.
    try testing.expect(!h.t.hasText("Context"));
    const card = h.a.view.model_picker.detail_rect orelse return error.MissingCard;
    try testing.expect(card.x >= fast.x + fast.w);
    // Escape takes the card first, then the picker.
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(1);
    try testing.expect(h.a.view.model_picker.detail == null);
    try testing.expect(h.a.picker != .none);
}

test "a model's page: its reasoning on a slider, the keys and a drag move it, Use model applies both" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try clickRow(&h, "Synthetic Fast");
    h.snap("picker-page");
    for ([_][]const u8{ "Models", "via OpenAI", "Reasoning", "Faster", "Deeper", "Use model" }) |t|
        try testing.expect(h.t.hasText(t));
    try testing.expect(h.a.new_model == null);
    // Escape goes back to the list; the model again, then ← to Low.
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Use model"));
    try testing.expect(h.a.picker != .none);
    try clickRow(&h, "Synthetic Fast");
    _ = h.t.shortcut(.{ .key = ui.Shortcut.left });
    h.t.settle(1);
    try testing.expect(h.t.hasText("Low"));
    // A press at the track's right end picks the deepest level.
    const track = h.a.view.model_picker.track orelse return error.MissingTrack;
    h.t.moveTo(track.x + track.w - 1, track.y + track.h / 2);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
    try testing.expect(h.t.hasText("High"));
    try h.t.clickText("Use model");
    h.t.settle(1);
    try testing.expectEqualStrings("openai/synthetic-fast", h.a.new_model.?);
    try testing.expectEqualStrings("high", h.a.new_reasoning.?);
    try testing.expect(h.a.picker == .none);
}

test "the model picker fades and lifts in, then settles its animation frames" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.togglePicker();
    h.t.settle(1);
    h.a.togglePicker();
    h.t.frame();
    try testing.expect(h.a.view.model_picker.opened_at != null);
    try testing.expect(h.t.ctx.animating);
    var translucent = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.style.radius == 12 and node.style.opacity < 0.99) translucent = true;
    }
    try testing.expect(translucent);
    h.t.settle(1);
    try testing.expect(!h.t.ctx.animating);
}

test "choosing Max commits one config and updates the open chat immediately" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.picker = .none;
    h.t.settle(1);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"max-chat","deviceId":"d","title":"Max chat","archived":false,
        \\  "config":{"harness":"graff","model":"openai/synthetic-max","reasoning":"high"}}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.openChat("max-chat", null);
    h.a.picker = .none;
    h.a.engine.state = .connected;
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"Mutate":{}}
    , .{});
    h.t.settle(1);
    try testing.expectEqualStrings("high", h.a.target().reasoning.?);
    h.a.togglePicker();
    h.t.settle(1);
    try clickRow(&h, "Synthetic Max");
    _ = h.t.shortcut(.{ .key = ui.Shortcut.right });
    h.t.settle(1);
    try h.t.clickText("Use model");
    h.t.settle(1);
    try testing.expect(h.a.picker == .none);
    try testing.expectEqualStrings("max", h.a.findChat("max-chat").?.reasoning.?);
    try testing.expectEqualStrings("max", h.a.target().reasoning.?);
    var configs: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse continue;
        if (params != .object) continue;
        const op = params.object.get("op") orelse continue;
        if (op != .string or !std.mem.eql(u8, op.string, "setChatConfig")) continue;
        configs += 1;
        const config = params.object.get("config") orelse return error.MissingConfig;
        try testing.expectEqualStrings("openai/synthetic-max", config.object.get("model").?.string);
        try testing.expectEqualStrings("max", config.object.get("reasoning").?.string);
    }
    try testing.expectEqual(@as(usize, 1), configs);
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

test "agent tabs that overflow the card scroll, and the viewed one is always in view" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const agents = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"graff","name":"graff","enabled":true},
        \\ {"id":"claude-code","name":"Claude Code","enabled":true},
        \\ {"id":"cursor","name":"Cursor","enabled":true},
        \\ {"id":"devin","name":"Devin","enabled":true},
        \\ {"id":"opencode","name":"OpenCode","enabled":true},
        \\ {"id":"codex","name":"Codex","enabled":true}]
    , .{});
    defer agents.deinit();
    try h.a.harnesses.replace(agents.value);
    h.a.picker = .none;
    h.t.settle(1);
    h.a.togglePicker();
    h.t.settle(1);
    const card = cardRect(&h) orelse return error.MissingCard;
    // Codex is past the card's edge until something brings it in.
    const far = inPicker(&h, "Codex") orelse return error.MissingTab;
    try testing.expect(far.x >= card.x + card.w);
    // Selecting it from the keyboard scrolls it fully into view.
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true, .shift = true });
    h.t.settle(1);
    try testing.expectEqualStrings("codex", h.a.new_harness);
    h.snap("picker-tabs-overflow");
    const codex = inPicker(&h, "Codex") orelse return error.MissingTab;
    try testing.expect(codex.x >= card.x and codex.x + codex.w <= card.x + card.w);
    // Opening again on Codex starts with it in view.
    h.a.picker = .none;
    h.t.settle(1);
    h.a.view.model_picker.tab_offset = 0;
    h.a.togglePicker();
    h.t.settle(1);
    const again = inPicker(&h, "Codex") orelse return error.MissingTab;
    try testing.expect(again.x + again.w <= card.x + card.w);
    // Wrapping forward to graff scrolls back to the start.
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true });
    h.t.settle(1);
    try testing.expectEqualStrings("graff", h.a.new_harness);
    const first = inPicker(&h, "graff") orelse return error.MissingTab;
    try testing.expect(first.x >= card.x);
    // The wheel over the row pans it both ways; the chat behind stays put.
    const row = (inPicker(&h, "graff") orelse return error.MissingTab).y + 4;
    const mid = card.x + card.w / 2;
    h.t.moveTo(mid, row);
    h.t.scroll(mid, row, 400);
    h.t.settle(1);
    try testing.expectEqual(@as(f32, 0), h.a.view.model_picker.tab_offset);
    h.t.scroll(mid, row, -400);
    h.t.settle(1);
    const scrolled = inPicker(&h, "Codex") orelse return error.MissingTab;
    try testing.expect(scrolled.x >= card.x and scrolled.x + scrolled.w <= card.x + card.w);
    try testing.expect(inPicker(&h, "Starred").?.x + 44 < card.x);
    // A trackpad swipes it sideways (the wheel's x), back to the start.
    h.t.ctx.input.scroll = .{ .x = 400 };
    h.t.frame();
    h.t.settle(1);
    try testing.expectEqual(@as(f32, 0), h.a.view.model_picker.tab_offset);
}

/// The picker card's columns: 356 wide from the chip's leading edge.
fn cardRect(h: *Harness) ?ui.Rect {
    const chip = h.a.view.chip_anchor orelse return null;
    const x = std.math.clamp(chip.x, 8, 900 - 356 - 8);
    return .{ .x = x, .y = 0, .w = 356, .h = 750 };
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

test "model picker remembers a new chat's agent model and reasoning across launches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(base);
    const settings_path = try std.fs.path.join(testing.allocator, &.{ base, "ui-settings.json" });
    defer testing.allocator.free(settings_path);
    const defaults_path = try std.fs.path.join(testing.allocator, &.{ base, "composer-defaults.json" });
    defer testing.allocator.free(defaults_path);

    var first: App = .init(testing.allocator, testing.io, 1);
    defer first.deinit();
    first.settings.path = try testing.allocator.dupe(u8, settings_path);
    first.new_harness = try testing.allocator.dupe(u8, "graff");
    first.setHarness("claude-code");
    first.setModel("anthropic/synthetic-thought");
    first.pickReasoning("high");

    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, defaults_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(body);
    var saved_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer saved_arena.deinit();
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, saved_arena.allocator(), body, .{});
    try testing.expectEqualStrings("claude-code", saved.object.get("harness").?.string);
    try testing.expectEqualStrings("anthropic/synthetic-thought", saved.object.get("modelByHarness").?.object.get("claude-code").?.object.get("id").?.string);
    try testing.expectEqualStrings("high", saved.object.get("reasoning").?.string);

    var second: App = .init(testing.allocator, testing.io, 1);
    defer second.deinit();
    second.settings.path = try testing.allocator.dupe(u8, settings_path);
    second.new_harness = try testing.allocator.dupe(u8, "graff");
    @import("composer_defaults.zig").apply(&second);
    try testing.expectEqualStrings("claude-code", second.new_harness);
    try testing.expectEqualStrings("anthropic/synthetic-thought", second.new_model.?);
    try testing.expectEqualStrings("high", second.new_reasoning.?);
}

test "model picker memory keeps GPUI's favorites options other agents and unknown keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(base);
    const settings_path = try std.fs.path.join(testing.allocator, &.{ base, "ui-settings.json" });
    defer testing.allocator.free(settings_path);
    const defaults_path = try std.fs.path.join(testing.allocator, &.{ base, "composer-defaults.json" });
    defer testing.allocator.free(defaults_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = defaults_path, .data =
        \\{"harness":"graff",
        \\ "modelByHarness":{"graff":{"id":"anthropic/remembered","label":"Remembered"},
        \\                   "codex":{"id":"codex/unchanged","label":"Unchanged"}},
        \\ "reasoning":"low",
        \\ "favorites":[{"harness":"codex","model":"codex/unchanged"}],
        \\ "modelOptionsByModel":{"graff":{"anthropic/remembered":{"fastMode":"on"}}},
        \\ "syntheticKeep":{"nested":[1,2]}}
    });

    var app: App = .init(testing.allocator, testing.io, 1);
    defer app.deinit();
    app.settings.path = try testing.allocator.dupe(u8, settings_path);
    app.new_harness = try testing.allocator.dupe(u8, "graff");
    app.setHarness("codex");
    app.setModel("openai/synthetic-fresh");
    app.pickReasoning("high");

    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, defaults_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(body);
    var saved_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer saved_arena.deinit();
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, saved_arena.allocator(), body, .{});
    const root = saved.object;
    try testing.expectEqualStrings("codex", root.get("harness").?.string);
    try testing.expectEqualStrings("high", root.get("reasoning").?.string);
    const by_harness = root.get("modelByHarness").?.object;
    try testing.expectEqualStrings("openai/synthetic-fresh", by_harness.get("codex").?.object.get("id").?.string);
    try testing.expectEqualStrings("anthropic/remembered", by_harness.get("graff").?.object.get("id").?.string);
    try testing.expectEqualStrings("codex/unchanged", root.get("favorites").?.array.items[0].object.get("model").?.string);
    try testing.expectEqualStrings("on", root.get("modelOptionsByModel").?.object.get("graff").?.object.get("anthropic/remembered").?.object.get("fastMode").?.string);
    try testing.expectEqual(@as(i64, 2), root.get("syntheticKeep").?.object.get("nested").?.array.items[1].integer);
}

test "large model catalogs only build the rows in view" {
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
    const first = inPicker(&h, "Synthetic model 0") orelse return error.MissingRow;
    h.t.scroll(first.x + 30, first.y, -100000);
    h.t.settle(1);
    try testing.expect(h.t.containsText("Synthetic model 1999"));
    try testing.expect(h.t.ctx.stats.nodes <= small_nodes * 2);
    std.log.info("model picker: 3 models {d} nodes; 2000 models {d} nodes", .{ small_nodes, large_nodes });
}

test "the model picker keeps its agent tabs below the titlebar in a short window and shows keyboard hints" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    for ([_][]const u8{ "Navigate", "Configure", "Close", "Plan", "500k", "128k" }) |label| {
        try testing.expect(h.t.hasText(label));
    }
    h.t.size.h = 460;
    h.t.settle(1);
    const starred = inPicker(&h, "Starred") orelse return error.MissingStarredTab;
    try testing.expect(starred.y >= @import("panel_chrome.zig").header_height + 6);
    for ([_][]const u8{ "Navigate", "Configure", "Close", "Plan", "500k" }) |label| {
        try testing.expect(h.t.hasText(label));
    }
}
