//! Synthetic production composer/editor + real JSON mux boundary. Never a provider run.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        try h.initTheme(true);
    }
    fn initTheme(h: *Harness, dark: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = dark;
        h.a.offscreen = true;
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"completion-chat","deviceId":"local","title":"Synthetic completion","config":{"harness":"mock"},"cwd":"/synthetic/completion","archived":false} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.device_id = try testing.allocator.dupe(u8, "local");
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"ListCommands":[{"name":"goal","description":"Synthetic goal command"},{"name":"compact","description":"Compact the synthetic context"}],"ListSkills":[{"name":"review","path":"/synthetic/skills/review.md","description":"Synthetic review skill","enabled":true}],"QueueCommand":{"commandId":"synthetic-command"},"FocusChat":{},"Mutate":{}}
        , .{});
        h.a.engine.state = .connected;
        h.a.openChat("completion-chat", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = dark });
        h.t.settle(2);
    }
    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
    fn draw(h: *Harness) void {
        _ = h.a.engine.pump();
        // The fixture has no NSWindow for App.redraw; request the same rebuild
        // the native window would receive after a catalog callback.
        h.t.ctx.changed = true;
        h.t.settle(2);
        _ = h.a.engine.pump();
        h.t.ctx.changed = true;
        h.t.settle(2);
    }
    fn draft(h: *Harness, text: []const u8, caret: usize) void {
        h.a.composer.set(text);
        h.a.composer.want_caret = caret;
        h.a.view.focus_composer = true;
        h.draw();
    }
};

test "completion slash menu inactive rows retain the theme surface in both schemes" {
    var valid = true;
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.initTheme(dark);
        defer h.deinit();
        h.draft("/", 1);
        const menu = h.t.ctx.rects.get(h.a.completion.menu_id) orelse return error.MissingCompletionMenu;
        const colors = @import("theme.zig").colors(dark);
        var rows: usize = 0;
        var selected: usize = 0;
        for (h.t.ctx.nodes.items) |node| {
            const r = node.rect;
            if (node.style.radius != 7 or r.h != 46 or r.y < menu.y or r.y + r.h > menu.y + menu.h) continue;
            rows += 1;
            const active = std.meta.eql(node.style.background, colors.selected);
            selected += @intFromBool(active);
            valid = valid and (active or std.meta.eql(node.style.background, ui.Color.transparent));
        }
        try testing.expect(rows > 1);
        try testing.expectEqual(@as(usize, 1), selected);
        if (std.c.getenv("NANO_COMPLETION_UX_SNAP_DIR")) |path| {
            var buf: [1024]u8 = undefined;
            try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/slash-{s}.png", .{ std.mem.span(path), if (dark) "dark" else "light" }));
        }
        _ = h.t.shortcut(.{ .key = ui.Shortcut.down });
        h.draw();
        try testing.expectEqual(@as(usize, 1), h.a.completion.active);
        _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
        h.draw();
        try testing.expect(!std.mem.eql(u8, "/", h.a.composer.text()));
    }
    try testing.expect(valid);
}

test "completion restores original issue575 Tab path without deleting adjacent prompt" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.draft("/goalprompt text remains", 5);
    try testing.expect(h.t.hasText("Synthetic goal command"));
    if (std.c.getenv("NANO_COMPLETION_SNAP")) |path| try h.t.screenshot(std.mem.span(path));
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    try testing.expectEqualStrings("/goal prompt text remains", h.a.composer.text());
    _ = h.t.shortcut(.{ .key = 'z', .cmd = true });
    h.draw();
    try testing.expectEqualStrings("/goalprompt text remains", h.a.composer.text());
    _ = h.t.shortcut(.{ .key = 'z', .cmd = true, .shift = true });
    h.draw();
    try testing.expectEqualStrings("/goal prompt text remains", h.a.composer.text());
    const restored = (try @import("composer_completion.zig").prompt(&h.a)) orelse return error.LostRedoSelection;
    defer testing.allocator.free(restored);
    try testing.expect(std.mem.indexOf(u8, restored, "harness-invoke:") != null);
}

fn lastPrompt(h: *Harness) !?[]u8 {
    var result: ?[]u8 = null;
    for (h.a.engine.sent.items) |frame| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const v = parsed.value;
        if (!std.mem.eql(u8, v.object.get("method").?.string, "QueueCommand")) continue;
        const cmd = v.object.get("params").?.object.get("command").?;
        const request = cmd.object.get("request") orelse continue;
        const prompt = request.object.get("prompt") orelse continue;
        if (result) |old| testing.allocator.free(old);
        result = try testing.allocator.dupe(u8, prompt.string);
    }
    return result;
}

test "completion acceptance remains one lossless undo for drafts beyond toolkit snapshot capacity" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var suffix: [2400]u8 = undefined;
    @memset(&suffix, 'x');
    const before = try std.fmt.allocPrint(testing.allocator, "/goal{s}", .{suffix[0..]});
    defer testing.allocator.free(before);
    const after = try std.fmt.allocPrint(testing.allocator, "/goal {s}", .{suffix[0..]});
    defer testing.allocator.free(after);
    h.draft(before, 5);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    try testing.expectEqualStrings(after, h.a.composer.text());
    _ = h.t.shortcut(.{ .key = 'z', .cmd = true });
    h.draw();
    try testing.expectEqualStrings(before, h.a.composer.text());
    _ = h.t.shortcut(.{ .key = 'z', .cmd = true, .shift = true });
    h.draw();
    try testing.expectEqualStrings(after, h.a.composer.text());
    const encoded = (try @import("composer_completion.zig").prompt(&h.a)) orelse return error.LostLongRedoSelection;
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "harness-invoke:") != null);
}

test "completion selected command reaches actual QueueCommand wire but pasted slash stays literal" {
    for ([_]bool{ false, true }) |accepted| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        h.draft("/goalprompt text remains", 5);
        if (accepted) {
            // Native AppKit command path, not only Tester shortcuts.
            h.t.textOps(&.{.{ .command = .insert_tab }});
            h.draw();
            try testing.expectEqualStrings("/goal prompt text remains", h.a.composer.text());
        }
        h.a.send();
        const wire = (try lastPrompt(&h)) orelse return error.NoQueueCommand;
        defer testing.allocator.free(wire);
        if (accepted) {
            try testing.expect(std.mem.indexOf(u8, wire, "harness-invoke:") != null);
            try testing.expect(std.mem.endsWith(u8, wire, " prompt text remains"));
        } else try testing.expectEqualStrings("/goalprompt text remains", wire);
    }
}

test "completion skill acceptance preserves suffix and exact catalog identity on wire" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.draft("$reviewprompt remains", 7);
    try testing.expect(h.t.hasText("Synthetic review skill"));
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    try testing.expectEqualStrings("$review prompt remains", h.a.composer.text());
    h.a.send();
    const wire = (try lastPrompt(&h)) orelse return error.NoQueueCommand;
    defer testing.allocator.free(wire);
    const expected = try @import("composer_completion.zig").canonical(testing.allocator, .{ .name = "review", .description = "", .path = "/synthetic/skills/review.md" });
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.startsWith(u8, wire, expected));
    try testing.expect(std.mem.endsWith(u8, wire, " prompt remains"));
}

test "completion local model action removes only its trigger and never sends the remaining draft" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.draft("/modelprompt remains", 6);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    try testing.expectEqualStrings("prompt remains", h.a.composer.text());
    try testing.expect(h.a.picker != .none);
    try testing.expect(try lastPrompt(&h) == null);
}

test "completion mouse accepts while the text field blurs on press" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.draft("/goalprompt remains", 5);
    try h.t.clickText("Synthetic goal command");
    h.draw();
    try testing.expectEqualStrings("/goal prompt remains", h.a.composer.text());
}

test "completion identical plain paste replaces selected provenance without gaining intent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.draft("/goalprompt remains", 5);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    const text = "/goal prompt remains";
    h.t.textOps(&.{ .{ .select = .{ .anchor = 0, .caret = text.len } }, .{ .insert = text } });
    h.draw();
    try testing.expectEqualStrings(text, h.a.composer.text());
    const encoded = try @import("composer_completion.zig").prompt(&h.a);
    defer if (encoded) |p| testing.allocator.free(p);
    try testing.expect(encoded == null);
}

test "completion accepted draft survives ordinary chat parking and restores only explicit sidecar" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.draft("/goalprompt remains", 5);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    h.a.select("other-synthetic-chat", null);
    h.draw();
    h.a.select("completion-chat", null);
    h.draw();
    try testing.expectEqualStrings("/goal prompt remains", h.a.composer.text());
    const encoded = (try @import("composer_completion.zig").prompt(&h.a)) orelse return error.LostParkedSelection;
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "harness-invoke:") != null);
}

test "completion new canvas tab parking and first run retain accepted identity before selecting new chat" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.replaceCurrent(null);
    @import("app_agent.zig").setHarness(&h.a, "mock");
    h.draft("$reviewprompt remains", 7);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    h.a.newTab();
    h.draw();
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.showTab(0);
    h.draw();
    try testing.expectEqualStrings("$review prompt remains", h.a.composer.text());
    h.a.send();
    const wire = (try lastPrompt(&h)) orelse return error.NoQueueCommand;
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOf(u8, wire, "harness-invoke:") != null);
    try testing.expect(std.mem.endsWith(u8, wire, " prompt remains"));
    try testing.expectEqualStrings("", h.a.composer.text());
}

fn replies(h: *Harness, text: []const u8) !void {
    if (h.a.engine.scene) |*old| old.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    @import("composer_completion.zig").retry(&h.a);
}

test "completion exact compact wins before compact-at and actual UI acceptance keeps its provenance" {
    for ([_]bool{ false, true }) |native_tab| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try replies(&h,
            \\{"ListCommands":[{"name":"compact-at","description":"Compact at a synthetic turn"},{"name":"compact","description":"Compact the synthetic context"},{"name":"compact-after","description":"Compact after a synthetic turn"}],"ListSkills":[]}
        );
        h.draft("/compact", 8);
        const completion = @import("composer_completion.zig");
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const rows = try completion.entries(&h.a, arena.allocator(), @import("completion_rules.zig").token("/compact", 8).?);
        try testing.expectEqual(@as(usize, 3), rows.len);
        try testing.expectEqualStrings("compact", rows[h.a.completion.active].name);
        try testing.expectEqualStrings("compact-at", rows[1].name);
        try testing.expectEqualStrings("compact-after", rows[2].name);
        // Merely typing an exact name must not mint invocation provenance.
        try testing.expect(try completion.prompt(&h.a) == null);
        if (!native_tab) if (std.c.getenv("NANO_COMPLETION_EXACT_SNAP")) |path| try h.t.screenshot(std.mem.span(path));
        if (native_tab) h.t.textOps(&.{.{ .command = .insert_tab }}) else _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
        h.draw();
        try testing.expectEqualStrings("/compact ", h.a.composer.text());
        h.a.send();
        const wire = (try lastPrompt(&h)) orelse return error.NoQueueCommand;
        defer testing.allocator.free(wire);
        const expected = try completion.canonical(testing.allocator, .{ .name = "compact", .description = "" });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, std.mem.trim(u8, wire, " "));
    }
}

test "completion exact skill wins in slash and dollar menus while partial queries preserve catalog order" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try replies(&h,
        \\{"ListCommands":[],"ListSkills":[{"name":"review-extra","path":"/synthetic/skills/review-extra.md","enabled":true},{"name":"review","path":"/synthetic/skills/review.md","enabled":true}]}
    );
    const completion = @import("composer_completion.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "/rev", "$rev", "/review", "$review" }) |text| {
        h.draft(text, text.len);
        const rows = try completion.entries(&h.a, arena.allocator(), @import("completion_rules.zig").token(text, text.len).?);
        try testing.expectEqual(@as(usize, 2), rows.len);
        try testing.expectEqualStrings(if (text.len == 4) "review-extra" else "review", rows[0].name);
        try testing.expect(rows[0].path != null);
    }
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    try testing.expectEqualStrings("$review ", h.a.composer.text());
    const encoded = (try completion.prompt(&h.a)) orelse return error.MissingSkillSelection;
    defer testing.allocator.free(encoded);
    const expected = try completion.canonical(testing.allocator, .{ .name = "review", .description = "", .path = "/synthetic/skills/review.md" });
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.startsWith(u8, encoded, expected));
}

test "completion provider collisions keep native command identity and namespace local model action" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try replies(&h,
        \\{"ListCommands":[{"name":"model","description":"Provider model command"}],"ListSkills":[]}
    );
    h.draft("/model", 6);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    try testing.expectEqualStrings("/model ", h.a.composer.text());
    try testing.expectEqual(.none, h.a.picker);
    const encoded = (try @import("composer_completion.zig").prompt(&h.a)) orelse return error.MissingProviderSelection;
    defer testing.allocator.free(encoded);
    h.draft("/harness:modeltail", 14);
    _ = h.t.shortcut(.{ .key = ui.Shortcut.tab });
    h.draw();
    try testing.expectEqualStrings("tail", h.a.composer.text());
    try testing.expect(h.a.picker != .none);
}

test "completion failed discovery offers actual RPC retry and recovers without sending" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try replies(&h,
        \\{"ListCommands":{"$seq":[{"$err":"synthetic unavailable"},[{"name":"goal","description":"Recovered goal command"}]]},"ListSkills":[]}
    );
    h.draft("/goal", 5);
    try testing.expect(h.t.hasText("Retry command discovery"));
    try h.t.clickText("Retry command discovery");
    h.draw();
    try testing.expect(h.t.hasText("Recovered goal command"));
    try testing.expect(try lastPrompt(&h) == null);
}

test "completion catalog requests use existing scoped camelCase RPC and exclude unrelated host discovery" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.draft("/goal", 5);
    var commands = false;
    var skills = false;
    for (h.a.engine.sent.items) |frame| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const method = v.object.get("method").?.string;
        if (!std.mem.eql(u8, method, "ListCommands") and !std.mem.eql(u8, method, "ListSkills")) continue;
        const params = v.object.get("params").?.object;
        try testing.expectEqualStrings("mock", params.get("harness").?.string);
        try testing.expectEqualStrings("completion-chat", params.get("chatId").?.string);
        try testing.expect(params.get("targetDeviceId") == null);
        if (std.mem.eql(u8, method, "ListCommands")) commands = true else skills = true;
    }
    try testing.expect(commands and skills);
}
