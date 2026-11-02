//! The session footer under an open chat's composer, driven headlessly on
//! made-up projects and chats and no engine (pickers.rs `render_footer`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const graff = @import("app_graff_worktree.zig");

const testing = std.testing;

const spaces =
    \\[{"id":"g","deviceId":"d","path":"/work/fieldnotes","gitDetected":true},
    \\ {"id":"n","deviceId":"d","path":"/work/sketches","gitDetected":false}]
;

const chats =
    \\[{"id":"local","deviceId":"d","title":"Local","archived":false,"spaceId":"g","cwd":"/work/fieldnotes","branch":null},
    \\ {"id":"tree","deviceId":"d","title":"Tree","archived":false,"spaceId":"g","cwd":"/work/fieldnotes-wt/footer","branch":"feat/footer"},
    \\ {"id":"graff","deviceId":"d","title":"Graff","archived":false,"spaceId":"g","cwd":"/work/fieldnotes/.graff/worktrees/harness-ab12","branch":"wt-ab12"},
    \\ {"id":"plain","deviceId":"d","title":"Plain","archived":false,"spaceId":"n","cwd":"/work/sketches","branch":"main"},
    \\ {"id":"loose","deviceId":"d","title":"Loose","archived":false,"cwd":"/work/elsewhere","branch":"main"}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, chat: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        var s = try std.json.parseFromSlice(std.json.Value, testing.allocator, spaces, .{});
        defer s.deinit();
        try h.a.spaces.replace(s.value);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        h.a.openChat(chat, null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// `NANO_SNAP_DIR=dir`, running the test binary: saves what it saw.
    fn snap(h: *Harness, name: []const u8) void {
        const d = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(d), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "the project's own checkout with no branch: Local checkout, No ref" {
    var h: Harness = undefined;
    try h.init("local");
    defer h.deinit();
    h.snap("footer-local");
    try testing.expect(h.t.hasText("Local checkout"));
    try testing.expect(h.t.hasText("No ref"));
    try testing.expect(!h.t.hasText("Merge back"));
}

test "another folder of the project: Worktree, and the row's branch" {
    var h: Harness = undefined;
    try h.init("tree");
    defer h.deinit();
    try testing.expect(h.t.hasText("Worktree"));
    try testing.expect(h.t.hasText("feat/footer"));
    try testing.expect(!h.t.hasText("Local checkout"));
    try testing.expect(!h.t.hasText("No ref"));
}

test "a Graff worktree: its label and actions; an action's verdict, and Discard once Graff asks for it" {
    var h: Harness = undefined;
    try h.init("graff");
    defer h.deinit();
    h.snap("footer-graff");
    try testing.expect(h.t.hasText("Graff worktree"));
    try testing.expect(h.t.hasText("wt-ab12"));
    try testing.expect(h.t.hasText("Merge back"));
    try testing.expect(h.t.hasText("Archive"));
    try testing.expect(h.t.hasText("Remove"));
    try testing.expect(!h.t.hasText("Discard anyway"));
    // No engine: the call fails at once, and says so.
    try h.t.clickText("Merge back");
    h.t.settle(1);
    try testing.expect(h.a.graff_worktree.busy == null);
    try testing.expect(h.t.hasText("not connected"));
    // Graff kept the tree: its work is only there.
    h.a.graff_worktree.busy = try testing.allocator.dupe(u8, "graff");
    h.a.graff_worktree.busy_tree = try testing.allocator.dupe(u8, "/work/fieldnotes/.graff/worktrees/harness-ab12");
    graff.apply(&h.a, "graff", .kept, "Kept /work/fieldnotes/.graff/worktrees/harness-ab12: 2 commits ONLY on this branch\nrerun with --discard");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Kept harness-ab12: 2 commits ONLY on this branch"));
    try testing.expect(h.t.hasText("Discard anyway"));
}

test "no footer for a project without git, nor a chat outside a project" {
    for ([_][]const u8{ "plain", "loose" }) |id| {
        var h: Harness = undefined;
        try h.init(id);
        defer h.deinit();
        try testing.expect(!h.t.hasText("Local checkout"));
        try testing.expect(!h.t.hasText("Worktree"));
        try testing.expect(!h.t.hasText("No ref"));
        try testing.expect(!h.t.hasText("main"));
    }
}

test "the footer sits in its 24-point slot 8 under the pill, and follows the pill as it grows" {
    var h: Harness = undefined;
    try h.init("local");
    defer h.deinit();
    for ([_][]const u8{ "", "one\ntwo" }) |text| {
        h.a.composer.set(text);
        h.t.settle(1);
        h.t.frame();
        const pill = h.a.view.composer_anchor.?;
        const label = h.t.findText("Local checkout").?;
        const slot_top = pill.y + pill.h + 8;
        try testing.expect(label.y >= slot_top);
        try testing.expect(label.y + label.h <= slot_top + 24);
        // As wide as the conversation column: 736.
        try testing.expectEqual(@as(f32, 736), pill.w);
    }
}
