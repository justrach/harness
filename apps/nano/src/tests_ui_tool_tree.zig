//! Focused current-desktop task-tree/access-map regressions. Synthetic
//! wire data only. Orchestrator imports this module from tests.zig.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

test {
    _ = @import("tool_rows.zig");
    _ = @import("tool_ui_state.zig");
    _ = @import("tool_access.zig");
    _ = @import("tool_access_cache.zig");
}

pub const fixture =
    \\{"reset":[{"id":"prompt","role":"user","parts":[{"id":"text","kind":"text","text":"Check the synthetic parser"}]},
    \\{"id":"reply","role":"assistant","status":"complete","durationMs":2000,"parts":[
    \\ {"id":"tests","kind":"tool","call":{"kind":"exec","command":"zig build test"},"resolved":true,"output":"48 passed; 0 failed"},
    \\ {"id":"probe","kind":"tool","call":{"kind":"exec","command":"zig build check"},"resolved":true,"isError":true,"output":"1 failed"},
    \\ {"id":"search","kind":"tool","call":{"kind":"search","pattern":"parse","path":"src"},"resolved":true,"output":"src/parser.zig:3:parse\nsrc/lexer.zig:8:parse"},
    \\ {"id":"glob","kind":"tool","call":{"kind":"glob","pattern":"src/*.zig"},"resolved":true,"output":"src/parser.zig\nsrc/lexer.zig"},
    \\ {"id":"read","kind":"tool","call":{"kind":"readFile","path":"src/parser.zig"},"resolved":true,"output":"fn parse() void {}"},
    \\ {"id":"edit","kind":"tool","call":{"kind":"editFile","path":"src/parser.zig"},"resolved":true,"diffStats":[{"path":"src/parser.zig","additions":8,"deletions":3}]},
    \\ {"id":"answer","kind":"text","text":"The synthetic parser is ready."}]}]}
;

const summary = "Ran 2 commands · edited 1 file · read 1 file · searched 2 times · 1 failed";

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.settings.set(.transcript_compact_mode, false);
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic","deviceId":"synthetic-device","title":"Synthetic parser","cwd":"/synthetic","archived":false,"config":{"harness":"graff","model":"synthetic-model"}}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("synthetic", null);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, fixture, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1440, .height = 1000, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn click(h: *Harness, text: []const u8) !void {
        try h.t.clickText(text);
        h.t.settle(1);
    }
};

fn textRect(t: *ui.Tester, text: []const u8) !ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |value| if (std.mem.eql(u8, value.str, text)) return n.rect,
        else => {},
    };
    return error.TextMissing;
}

test "expanded tree results live beside the command, not in a duplicate list" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.click(summary);
    try testing.expect(h.t.hasText("48 passed"));
    try testing.expect(!h.t.hasText("1 failed"));
    try testing.expect(h.t.hasText("2 matches"));
    try testing.expect(h.t.hasText("2 files"));
    try testing.expect(h.t.hasText("+8"));
    try testing.expect(h.t.hasText("−3"));
    try testing.expect(h.t.hasText("Tool access"));
    try testing.expect(!h.t.hasText("Review"));
    try testing.expect(@import("view_turn_work.zig").changes(&h.t.ctx, &h.a) == null);
    const command = try textRect(&h.t, "zig build test");
    const result = try textRect(&h.t, "48 passed");
    try testing.expect(@abs((command.y + command.h / 2) - (result.y + result.h / 2)) < 5);
    try testing.expect(result.x > command.x + command.w);
    try h.click("Run");
    try testing.expect(h.t.containsText("48 passed; 0 failed"));
    try h.click(summary);
    try testing.expect(!h.t.hasText("48 passed"));
    try testing.expect(!h.t.hasText("Tool access"));
}

test "access map opens from the footer and shows real call input and output" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.click(summary);
    try h.click("Tool access");
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqual(@import("app_panels.zig").TabKind.tool_access, h.a.panels.activeTab().?.kind);
    try testing.expect(h.t.hasText("3/5 tools · 6 calls"));
    try h.click("Terminal");
    try testing.expect(h.t.hasText("INPUT"));
    try testing.expect(h.t.hasText("OUTPUT"));
    // Release opens on the latest call, with real history selection.
    try testing.expect(h.t.containsText("zig build check"));
    try testing.expect(h.t.containsText("1 failed"));
    try h.click("Run zig build test");
    try testing.expect(h.t.containsText("48 passed; 0 failed"));
    try testing.expect(!h.t.hasText("Replay"));
    try testing.expect(!h.t.hasText("Edit input"));
    const title = try textRect(&h.t, "Terminal");
    h.t.click(title.x - 46, title.y + 12);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Not used yet"));
}

test "a narrow access graph pans sideways to its output-family card" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.click(summary);
    try h.click("Tool access");
    const terminal = try textRect(&h.t, "Terminal");
    h.t.moveTo(terminal.x + 4, terminal.y + 4);
    h.t.ctx.input.scroll.x = -400;
    h.t.frame();
    h.t.settle(1);
    try testing.expect(h.a.view.tool_ui.map_scroll > 0);
    try h.click("Web search");
    try testing.expect(h.t.hasText("graff hasn't called it yet"));
}

test "a subagent tab shows its own boundary instead of borrowing the chat graph" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.a.transcript.entries.items[1].parts.append(h.a.gpa, .{
        .id = try h.a.gpa.dupe(u8, "synthetic-child"),
        .kind = .tool,
        .agent = true,
        .chip = "Agent",
        .subagent_title = try h.a.gpa.dupe(u8, "Synthetic worker"),
        .subagent_status = .running,
        .invocation = try h.a.gpa.dupe(u8, "{\"kind\":\"unknown\",\"name\":\"Agent: Synthetic worker\",\"input\":{\"model\":\"synthetic-child-model\"}}"),
    });
    h.t.settle(1);
    try h.click(summary);
    try h.click("Tool access");
    var tab: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "Synthetic worker") and (tab == null or node.rect.y < tab.?.y)) {
            tab = node.rect;
        },
        else => {},
    };
    const target = tab orelse return error.SubagentTabMissing;
    h.t.click(target.x + target.w / 2, target.y + target.h / 2);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.view.tool_ui.selected_agent);
    try testing.expect(h.t.containsText("Its tool calls are in its own transcript. Open it from the chat."));
    try testing.expect(h.t.hasText("synthetic-child-model"));
    try testing.expect(!h.t.hasText("Terminal"));
}

test "opening an edit preserves its structured result and actual arguments" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.click(summary);
    try h.click("Edit");
    try testing.expect(h.t.hasText("src/parser.zig"));
    try testing.expect(h.t.containsText("editFile"));
    try testing.expect(h.t.hasText("+8"));
}

test "desktop issues failed tool keeps red title and expandable error details" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.click(summary);
    try testing.expect(!h.t.hasText("1 failed"));
    const command = try textRect(&h.t, "zig build check");
    var red = false;
    const danger = h.t.ctx.theme.danger;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "Run") and @abs(node.rect.y - command.y) < 5) {
            red = std.meta.eql(text.style.color, danger);
        },
        else => {},
    };
    try testing.expect(red);
    h.t.click(command.x + 4, command.y + command.h / 2);
    h.t.settle(1);
    try testing.expect(h.t.containsText("1 failed"));
    try testing.expect(h.a.transcript.entries.items[1].parts.items[1].is_error);
}

test "agent rows use task labels and leave room for descenders in narrow panes" {
    const Fixture = struct {
        a: App,
        dark: bool = true,
        fn view(f: *@This(), c: *ui.Context) void {
            const k = @import("theme.zig").colors(f.dark);
            const box = ui.div(c).column().sizeFull().bg(k.background).p(8);
            defer box.end();
            const entry = &f.a.transcript.entries.items[0];
            for (entry.parts.items, 0..) |*part, i| {
                @import("view_tool_tree.zig").row(c, &f.a, k, entry, part, i + 1 == entry.parts.items.len, "synthetic-parent");
            }
        }
    };
    @import("theme.zig").registerFonts();
    var f: Fixture = .{ .a = .init(testing.allocator, testing.io, 1) };
    defer f.a.deinit();
    f.a.offscreen = true;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[
        \\ {"id":"spawn","kind":"tool","resolved":true,"subagentRef":"synthetic-child","subagentStatus":"running","call":{"kind":"unknown","name":"Agent: ## Context\nSynthetic background","input":{"description":"Check glyphs"}}},
        \\ {"id":"wait","kind":"tool","resolved":true,"isError":true,"call":{"kind":"unknown","name":"Wait for agent 7: ## Context","input":{"description":"Check glyphs"}}}]}]}
    , .{});
    defer parsed.deinit();
    try f.a.transcript.apply(parsed.value);
    for ([_]bool{ true, false }) |dark| {
        f.dark = dark;
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 300, .height = 110, .dark = dark });
        defer t.deinit();
        t.settle(0.2);
        if (dark) if (std.c.getenv("NANO_AGENT_ROWS_SNAPSHOT")) |path| try t.screenshot(std.mem.span(path));
        try testing.expect(!t.containsText("## Context"));
        try testing.expect(t.hasText("Check glyphs"));
        for (t.ctx.nodes.items) |node| switch (node.content) {
            .text => |text| {
                if (std.mem.eql(u8, text.str, "Agent") or std.mem.eql(u8, text.str, "Waiting on")) {
                    try testing.expect(text.style.line_height >= 20);
                    try testing.expect(node.rect.h >= 20);
                }
            },
            else => {},
        };
        t.resize(240, 110);
        t.settle(0.2);
        try testing.expect(!t.containsText("## Context"));
        try testing.expect(t.hasText("Waiting on"));
        var elided = false;
        for (t.ctx.nodes.items) |node| switch (node.content) {
            .text => |text| if (std.mem.endsWith(u8, text.str, "…")) {
                elided = true;
            },
            else => {},
        };
        try testing.expect(elided);
    }
}

test "a newly mounted agent title settles to its actual available width" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"wide-answer","role":"assistant","status":"complete","parts":[
        \\ {"id":"wide-worker","kind":"tool","resolved":true,"subagentRef":"synthetic-wide-child","subagentStatus":"done","call":{"kind":"mcp","server":"synthetic","tool":"Agent","input":{"description":"Review synthetic glyph clipping"}}}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Review synthetic glyph clipping"));
}
