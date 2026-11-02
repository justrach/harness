//! ↑/↓ prompt recall in the real composer, on a synthetic chat: no engine,
//! account or saved chats.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const chat = "synthetic-recall";

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.openChat(chat, null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 900, .dark = true });
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, rows, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn press(h: *Harness, key: u21) void {
        _ = h.t.shortcut(.{ .key = key });
        h.t.settle(1);
    }

    fn expectComposer(h: *Harness, want: []const u8) !void {
        try testing.expectEqualStrings(want, h.a.composer.text());
    }

    /// `NANO_SNAP_DIR=dir zig build test` saves what the test saw.
    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

const rows =
    \\{"reset":[
    \\ {"id":"u1","role":"user","parts":[{"id":"p","kind":"text","text":"First synthetic prompt"}]},
    \\ {"id":"a1","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"A synthetic reply"}]},
    \\ {"id":"u2","role":"user","parts":[{"id":"p","kind":"text","text":"[Message from Harness chat Build helper. Sender chat: helper. Agent coordination, not a human request.]\n\nCheck the build."}]},
    \\ {"id":"u3","role":"user","parts":[{"id":"p","kind":"text","text":"Last synthetic prompt"}]}]}
;

test "↑ in an empty composer recalls the chat's prompts, newest first; ↓ comes back to the draft" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.snap("recall-before");
    h.press(ui.Shortcut.up);
    try h.expectComposer("Last synthetic prompt");
    h.snap("recall-after");
    // The agent's message is skipped, and the oldest prompt stays.
    h.press(ui.Shortcut.up);
    try h.expectComposer("First synthetic prompt");
    h.press(ui.Shortcut.up);
    try h.expectComposer("First synthetic prompt");
    h.press(ui.Shortcut.down);
    try h.expectComposer("Last synthetic prompt");
    h.press(ui.Shortcut.down);
    try h.expectComposer("");
    try testing.expect(!h.a.prompt_nav.active());
}

test "↑ recalls only from the text's start, and the draft comes back" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.typeText("unsent draft");
    h.t.settle(1);
    // The caret is at the end: ↑ leaves the draft alone.
    h.press(ui.Shortcut.up);
    try h.expectComposer("unsent draft");
    h.t.key(.home);
    h.t.settle(1);
    h.press(ui.Shortcut.up);
    try h.expectComposer("Last synthetic prompt");
    h.press(ui.Shortcut.down);
    try h.expectComposer("unsent draft");
}

test "leaving the chat while a recalled prompt shows keeps the draft from before recall" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.typeText("unsent draft");
    h.t.key(.home);
    h.t.settle(1);
    h.press(ui.Shortcut.up);
    try h.expectComposer("Last synthetic prompt");
    h.a.select("synthetic-other", null);
    h.t.settle(1);
    try h.expectComposer("");
    h.a.select(chat, null);
    h.t.settle(1);
    try h.expectComposer("unsent draft");
    try testing.expect(!h.a.prompt_nav.active());
}
