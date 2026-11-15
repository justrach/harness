//! Shared icon controls exercised with synthetic input in NanoUI's offscreen
//! tester. No application, visible window, engine, or persisted user state.
const std = @import("std");
const ui = @import("nanoui").ui;
const kit = @import("view_kit.zig");
const theme = @import("theme.zig");
const testing = std.testing;

const labels = [_][]const u8{ "Close panel", "Refresh branch", "Copy link", "Add" };

const Controls = struct {
    activations: [4]usize = .{ 0, 0, 0, 0 },

    fn view(s: *Controls, c: *ui.Context) void {
        const row = ui.div(c).row().p(20).gap(12);
        defer row.end();
        const k = theme.colors(false);
        if (kit.iconButton(c, k, .close, .{ .tip = .{ .text = labels[0] } })) s.activations[0] += 1;
        if (kit.iconButton(c, k, .refresh, .{ .disabled = true, .label = labels[1] })) s.activations[1] += 1;
        // Explicit names take precedence over explanatory tooltip copy.
        if (kit.iconButton(c, k, .copy, .{ .on = true, .label = labels[2], .tip = .{ .text = "Copy the current link" } })) s.activations[2] += 1;
        if (kit.iconButton(c, k, .plus, .{})) s.activations[3] += 1;
    }
};

const Harness = struct {
    controls: Controls = .{},
    t: ui.Tester = undefined,

    fn init(h: *Harness) !void {
        try h.t.init(testing.allocator, .init(&h.controls, Controls.view), .{
            .width = 240,
            .height = 100,
            .theme = theme.ui(false),
        });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
    }

    fn index(h: *Harness, control: usize) !u32 {
        for (h.t.ctx.a11y_items.items) |item| {
            if (std.mem.eql(u8, labels[control], item.label)) return item.node_index;
        }
        return error.MissingIconControl;
    }

    fn id(h: *Harness, control: usize) !u64 {
        return h.t.ctx.node(try h.index(control)).id;
    }

    fn click(h: *Harness, control: usize) !void {
        const r = h.t.ctx.node(try h.index(control)).rect;
        h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    }

    fn expectRing(h: *Harness, control: usize, visible: bool) !void {
        const n = h.t.ctx.node(try h.index(control));
        if (!visible) return testing.expect(n.style.border == null);
        const color = n.style.border orelse return error.MissingKeyboardRing;
        try testing.expectEqualDeep(theme.colors(false).accent, color);
        try testing.expect(n.style.border_width > 0);
        // Assert the border reached the renderer, not merely the view state.
        for (h.t.instances.items) |instance| {
            if (@abs(instance.rect[0] - n.rect.x) < 0.1 and
                @abs(instance.rect[1] - n.rect.y) < 0.1 and
                @abs(instance.rect[2] - n.rect.w) < 0.1 and
                @abs(instance.rect[3] - n.rect.h) < 0.1 and
                instance.border_width > 0 and instance.border_color[3] > 0)
                return;
        }
        return error.KeyboardRingNotPainted;
    }
};

test "shared icon controls Tab skips disabled controls and cycles once per button" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    try testing.expectEqual(@as(usize, 3), h.t.ctx.last_focusable_ids.items.len);
    try testing.expectEqual(@as(u64, 0), h.t.ctx.focus);
    for ([_]usize{ 0, 2, 3, 0 }) |control| {
        h.t.key(.tab);
        try testing.expectEqual(try h.id(control), h.t.ctx.focus);
    }
    try testing.expectEqualDeep([_]usize{ 0, 0, 0, 0 }, h.controls.activations);
}

test "shared icon controls Enter and Space activate only the focused button" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    h.t.key(.tab);
    h.t.key(.enter);
    try testing.expectEqualDeep([_]usize{ 1, 0, 0, 0 }, h.controls.activations);
    h.t.typeText(" ");
    try testing.expectEqualDeep([_]usize{ 2, 0, 0, 0 }, h.controls.activations);
    h.t.key(.tab);
    try testing.expect(h.t.shortcut(.{ .key = ' ' }));
    try testing.expectEqualDeep([_]usize{ 2, 0, 1, 0 }, h.controls.activations);
    try testing.expect(h.t.shortcut(.{ .key = ui.Shortcut.enter }));
    try testing.expectEqualDeep([_]usize{ 2, 0, 2, 0 }, h.controls.activations);
    h.t.settle(1);
    try testing.expectEqualDeep([_]usize{ 2, 0, 2, 0 }, h.controls.activations);
}

test "shared icon controls pointer and accessibility activate exactly once" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    try h.click(0);
    try testing.expectEqualDeep([_]usize{ 1, 0, 0, 0 }, h.controls.activations);
    try testing.expectEqual(try h.id(0), h.t.ctx.focus);
    h.t.ctx.a11yPress(try h.id(2));
    h.t.frame();
    try testing.expectEqualDeep([_]usize{ 1, 0, 1, 0 }, h.controls.activations);
    try testing.expectEqual(try h.id(2), h.t.ctx.focus);
    h.t.settle(1);
    try testing.expectEqualDeep([_]usize{ 1, 0, 1, 0 }, h.controls.activations);
}

test "shared icon controls disabled buttons reject pointer keyboard and accessibility" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const disabled_id = try h.id(1);
    try testing.expect(!h.t.ctx.node(try h.index(1)).interactive);
    try testing.expect(std.mem.indexOfScalar(u64, h.t.ctx.last_focusable_ids.items, disabled_id) == null);
    try h.click(1);
    h.t.ctx.a11yPress(disabled_id);
    h.t.frame();
    // Even stale/programmatically assigned focus must not activate a disabled control.
    h.t.ctx.focus = disabled_id;
    h.t.key(.enter);
    h.t.ctx.focus = disabled_id;
    h.t.typeText(" ");
    h.t.settle(1);
    try testing.expectEqualDeep([_]usize{ 0, 0, 0, 0 }, h.controls.activations);
    try testing.expectEqual(@as(u64, 0), h.t.ctx.focus);
    try h.expectRing(1, false);
}

test "shared icon controls keyboard focus ring is visible and mouse focus has no ring" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    try h.expectRing(0, false);
    h.t.key(.tab);
    try h.expectRing(0, true);
    try h.expectRing(2, false);
    h.t.key(.tab);
    try h.expectRing(0, false);
    try h.expectRing(2, true);
    // Pointer modality removes the ring even when the same button keeps focus.
    try h.click(2);
    h.t.settle(1);
    try testing.expectEqual(try h.id(2), h.t.ctx.focus);
    try h.expectRing(2, false);
    try h.click(0);
    h.t.settle(1);
    try testing.expectEqual(try h.id(0), h.t.ctx.focus);
    try h.expectRing(0, false);
    h.t.key(.tab);
    try h.expectRing(2, true);
}

test "shared icon controls expose native button names enabled and selected states" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var elements: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&h.t.ctx, arena.allocator(), &elements);
    try testing.expectEqual(@as(usize, 4), elements.items.len);
    for (elements.items, 0..) |element, i| {
        try testing.expectEqual(.button, element.role);
        try testing.expectEqualStrings(labels[i], element.label);
        try testing.expectEqual(i != 1, element.enabled);
        try testing.expectEqual(i == 2, element.selected);
        try testing.expect(!element.implied);
    }
}
