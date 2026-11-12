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

fn snap(h: *Harness, name: []const u8) void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
    h.t.screenshot(path) catch {};
}

test "retention 309 header-only invocation has no duplicate expandable body" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"brief","kind":"tool","call":{"kind":"exec","command":"echo synthetic"},"resolved":true}]}]}
    , .{});
    defer doc.deinit();
    try h.a.transcript.apply(doc.value);
    h.t.settle(1);
    try h.click("Ran 1 command");
    try testing.expect(h.t.hasText("echo synthetic"));
    try h.click("Run");
    snap(&h, "retention-309-header-only");
    try testing.expect(!h.t.containsText("\"command\""));
    try testing.expect(!h.a.view.groupOpen("detail/synthetic/reply/brief", false));
    // INPUT in AccessMap still has the original structured arguments.
    try h.click("Tool access");
    try h.click("Terminal");
    try testing.expect(h.t.containsText("echo synthetic"));
    const preserved = h.a.transcript.entries.items[0].parts.items[0].invocation;
    try testing.expect(std.mem.indexOf(u8, preserved, "\"command\"") != null);
    try testing.expect(std.mem.indexOf(u8, preserved, "echo synthetic") != null);
    snap(&h, "retention-309-access-map-input");
}

test "retention 309 a clipped header retains its invocation until the pane has room" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"brief","kind":"tool","call":{"kind":"exec","command":"echo synthetic"},"resolved":true}]}]}
    , .{});
    defer doc.deinit();
    try h.a.transcript.apply(doc.value);
    h.t.settle(1);
    try h.click("Ran 1 command");
    h.t.resize(420, 1000);
    h.t.settle(1);
    try h.click("Run");
    try testing.expect(h.t.containsText("\"command\""));
    h.t.resize(1440, 1000);
    h.t.settle(1);
    try testing.expect(!h.t.containsText("\"command\""));
}

test "retention 309 useful bodies preserve long and multiline arguments sidecars and literal output" {
    const docs = [_][]const u8{
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"body","kind":"tool","call":{"kind":"exec","command":"echo synthetic\nsecond line"},"resolved":true}]}]}
        ,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"body","kind":"tool","call":{"kind":"exec","command":"echo synthetic arguments with enough detail to overflow a short command header while remaining useful in its original invocation body for inspection"},"resolved":true}]}]}
        ,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"body","kind":"tool","call":{"kind":"exec","command":"echo synthetic"},"resolved":true,"output":"<script>synthetic()</script> https://example.invalid/synthetic"}]}]}
        ,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"body","kind":"tool","call":{"kind":"exec","command":"echo synthetic"},"resolved":true,"outputRef":"synthetic-sidecar"}]}]}
        ,
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"body","kind":"tool","call":{"kind":"exec","command":"echo https://example.invalid/synthetic"},"resolved":true}]}]}
        ,
    };
    for (docs, 0..) |doc, i| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
        try h.click("Ran 1 command");
        try h.click("Run");
        try testing.expect(h.t.containsText("\"command\""));
        try testing.expect(h.a.view.groupOpen("detail/synthetic/reply/body", false));
        if (i == 2) {
            // Text stays native, including HTML-looking text. URL spans retain
            // their existing browser routing rather than executing any markup.
            try testing.expect(h.t.containsText("<script>synthetic()</script>"));
            var linked = false;
            for (h.t.ctx.nodes.items) |node| switch (node.content) {
                .text => |text| if (std.mem.indexOf(u8, text.str, "https://example.invalid/synthetic") != null and text.spans.len > 0) {
                    for (text.spans) |span| if (span.underline) {
                        linked = true;
                    };
                },
                else => {},
            };
            try testing.expect(linked);
        }
        if (i == 3) try testing.expect(h.t.hasText("Show full output"));
    }
}

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
