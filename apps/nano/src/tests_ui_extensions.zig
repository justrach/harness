//! Offscreen UI tests for Settings › Extensions panel rendering and actions.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const set = @import("view_settings.zig");
const ext = @import("extension_panel.zig");
const view = @import("view_settings_extensions.zig");
const Harness = @import("tests_ui_tab_strip.zig").Harness;

test "extensions state replace validates schema and swaps arenas cleanly" {
    const ok_json =
        \\{"version":1,"panels":[{"plugin":"demo.ok","title":"Runners","root":{"kind":"column","children":[{"kind":"stat","label":"State","value":"Online"}]}}]}
    ;
    const bad_json =
        \\{"version":1,"panels":[{"plugin":"bad","title":"Bad","root":{"kind":"html","text":"x"}}]}
    ;
    var s: view.State = .{};
    defer s.deinit(testing.allocator);

    var p1 = try json.parseFromSlice(json.Value, testing.allocator, ok_json, .{});
    defer p1.deinit();
    try s.replace(testing.allocator, p1.value);
    try testing.expectEqual(@as(usize, 1), s.panels.len);
    try testing.expectEqualStrings("demo.ok", ext.str(s.panels[0], "plugin"));

    var p2 = try json.parseFromSlice(json.Value, testing.allocator, bad_json, .{});
    defer p2.deinit();
    try testing.expectError(error.InvalidExtensionPanel, s.replace(testing.allocator, p2.value));
    try testing.expectEqual(@as(usize, 1), s.panels.len);
    try testing.expectEqualStrings("demo.ok", ext.str(s.panels[0], "plugin"));
}

test "extensions settings page stays within container width and invokes button actions" {
    const spaces_json =
        \\[{"id":"sp-local","path":"/tmp/acme-app","name":"acme-app"}]
    ;
    const scene_json =
        \\{
        \\  "ListNativeExtensions": {
        \\    "version": 1,
        \\    "panels": [
        \\      {
        \\        "plugin": "github-runners",
        \\        "title": "GitHub Actions Runners",
        \\        "root": {
        \\          "kind": "column",
        \\          "children": [
        \\            {
        \\              "kind": "row",
        \\              "children": [
        \\                {"kind": "stat", "label": "Online", "value": "2 / 2"},
        \\                {"kind": "stat", "label": "Busy", "value": "1"},
        \\                {"kind": "stat", "label": "Uptime", "value": "14m"},
        \\                {"kind": "stat", "label": "Disk free", "value": "30.0 GiB"}
        \\              ]
        \\            },
        \\            {"kind": "text", "text": "macOS M3 Max runners for acme/app with automatic cloud fallback."},
        \\            {
        \\              "kind": "row",
        \\              "children": [
        \\                {"kind": "button", "label": "Refresh", "action": "refresh"},
        \\                {"kind": "button", "label": "Pause Local", "action": "pause"}
        \\              ]
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    ]
        \\  },
        \\  "InvokeNativeExtension": {"version": 1, "panel": {"title": "GitHub Actions Runners", "root": {"kind": "text", "text": "ok"}}}
        \\}
    ;
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();

    var sp = try json.parseFromSlice(json.Value, testing.allocator, spaces_json, .{});
    defer sp.deinit();
    try h.a.spaces.replace(sp.value);
    h.a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator, scene_json, .{});
    h.a.settings.setSection(.extensions);
    set.open(&h.a);
    h.t.resize(1120, 740);
    h.t.settle(0.2);

    try testing.expect(h.t.hasText("GitHub Actions Runners"));
    try testing.expect(h.t.hasText("github-runners"));
    try testing.expect(h.t.hasText("2 / 2"));
    try testing.expect(h.t.hasText("30.0 GiB"));
    for (h.t.ctx.nodes.items) |node| {
        try testing.expect(node.rect.x + node.rect.w <= 1120.5);
    }

    try h.t.clickText("Pause Local");
    h.t.settle(0.2);

    var saw_list: usize = 0;
    var saw_invoke = false;
    for (h.a.engine.sent.items) |frame| {
        if (std.mem.indexOf(u8, frame, "\"ListNativeExtensions\"") != null) saw_list += 1;
        if (std.mem.indexOf(u8, frame, "\"InvokeNativeExtension\"") != null and
            std.mem.indexOf(u8, frame, "\"action\":\"pause\"") != null)
        {
            saw_invoke = true;
        }
    }
    try testing.expect(saw_invoke);
    try testing.expect(saw_list >= 2);
}
