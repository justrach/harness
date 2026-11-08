//! Immediate feedback and bounded tool motion, from synthetic RPC replies.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        // Each step as its own row: these tests are about the detailed transcript.
        h.a.settings.set(.transcript_compact_mode, false);
        h.a.offscreen = true;
        h.a.dark = false;
        h.a.view.sidebar_open = false;
        h.a.openChat("synthetic-feedback", null);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"QueueCommand":{}}
        , .{});
        h.a.engine.state = .connected;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 880, .dark = false });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn apply(h: *Harness, text: []const u8) !void {
        const frame = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
        defer frame.deinit();
        try h.a.transcript.apply(frame.value);
        h.t.frame();
    }
};

test "a send paints its prompt and activity next frame without waiting for the engine echo" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.typeText("Synthetic immediate prompt");
    h.a.send();
    h.t.advance(1.0 / 60.0);
    try testing.expect(h.t.hasText("Synthetic immediate prompt"));
    try testing.expectEqual(@import("workspace.zig").Status.working, h.a.selectedStatus());
    // UI feedback must not corrupt the engine's authoritative row count.
    try testing.expectEqual(@as(usize, 0), h.a.transcript.entries.items.len);
    // Even a deliberately delayed echo must not make the prompt disappear.
    h.t.advance(0.4);
    try testing.expect(h.t.hasText("Synthetic immediate prompt"));
}

test "an authoritative echo replaces local feedback without duplicating or changing document cursors" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.typeText("Synthetic echoed prompt");
    h.a.send();
    h.t.advance(1.0 / 60.0);
    const pending = h.a.pending_sends.items[0];
    const frame = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"reset\":[{{\"id\":\"{s}\",\"role\":\"user\",\"parts\":[{{\"id\":\"p\",\"kind\":\"text\",\"text\":\"Synthetic echoed prompt\"}}]}}]}}",
        .{pending.message},
    );
    defer testing.allocator.free(frame);
    try h.apply(frame);
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    try testing.expectEqual(@as(usize, 1), h.a.transcript.entries.items.len);
    var prompts: usize = 0;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "Synthetic echoed prompt")) {
            prompts += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), prompts);
}

/// The open chat's transcript: its scroll box's offset and how far it goes.
fn transcriptScroll(h: *Harness) struct { offset: f32, max: f32 } {
    for (h.t.ctx.nodes.items) |n| if (n.style.follow_end and n.style.scroll) {
        return .{ .offset = h.t.ctx.scroll.get(n.id) orelse 0, .max = h.t.ctx.scroll_max.get(n.id) orelse 0 };
    };
    return .{ .offset = -1, .max = -1 };
}

test "Enter on a prompt takes a chat read far up back to its end, and it follows the reply" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"reset\":[");
    for (0..30) |i| {
        if (i > 0) try body.append(testing.allocator, ',');
        try body.print(testing.allocator, "{{\"id\":\"m{d}\",\"role\":\"{s}\",\"status\":\"complete\",\"parts\":[{{\"id\":\"t\",\"kind\":\"text\",\"text\":\"Synthetic line {d}\\n\\nA second paragraph so the turn takes room.\"}}]}}", .{ i, if (i % 2 == 0) "user" else "assistant", i });
    }
    try body.appendSlice(testing.allocator, "]}");
    try h.apply(body.items);
    h.t.settle(1);
    const start = transcriptScroll(&h);
    try testing.expect(start.max > 400 and start.offset >= start.max - 1);
    // Read far up.
    h.t.moveTo(600, 300);
    h.t.scroll(600, 300, 2000);
    h.t.settle(1);
    try testing.expect(transcriptScroll(&h).offset < start.max - 400);
    h.a.view.focus_composer = true;
    h.t.settle(1);
    h.t.typeText("Synthetic prompt sent from far up");
    h.t.key(.enter);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    const sent = transcriptScroll(&h);
    try testing.expect(sent.offset >= sent.max - 1);
    const prompt = h.t.findText("Synthetic prompt sent from far up") orelse return error.PromptNotDrawn;
    try testing.expect(prompt.y > 0 and prompt.y + prompt.h < 880);
    // The reply grows under it, and the transcript stays at its end.
    try h.apply("{\"upsert\":[{\"after\":\"m29\",\"entry\":{\"id\":\"reply\",\"role\":\"assistant\",\"status\":\"streaming\",\"parts\":[{\"id\":\"t\",\"kind\":\"text\",\"text\":\"Synthetic reply\\n\\nmore\\n\\nmore\\n\\nmore\\n\\nmore\\n\\nmore\"}]}}]}");
    h.t.settle(1);
    const after = transcriptScroll(&h);
    try testing.expect(after.max > sent.max and after.offset >= after.max - 1);
}

test "a rejected send restores the draft and stops its local working state" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene.?.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{"$err":"Synthetic send rejected"}}
    , .{});
    h.t.typeText("Synthetic rejected prompt");
    h.a.send();
    h.t.advance(1.0 / 60.0);
    try testing.expectEqualStrings("Synthetic rejected prompt", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    try testing.expectEqual(@import("workspace.zig").Status.idle, h.a.selectedStatus());
}

const MotionFixture = struct {
    held_scale: f32 = 1,
    clicks: usize = 0,

    fn view(s: *MotionFixture, c: *ui.Context) void {
        const box = ui.div(c).column().w(300).gap(8);
        defer box.end();
        const k = @import("theme.zig").colors(false);
        @import("view_kit.zig").activityText(c, k, "Reading synthetic files", .{ .size = 12 }, true);
        const button = @import("view_kit.zig").pressFeedback(ui.div(c).row().size(120, 32).control());
        defer button.end();
        s.held_scale = c.node(button.index).style.scale;
        if (button.clicked()) s.clicks += 1;
        ui.text(c, "Synthetic action", .{ .size = 12 });
    }
};

test "a tool click compresses while held, rebounds, and fires only once" {
    var s: MotionFixture = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, MotionFixture.view), .{});
    defer t.deinit();
    try t.hoverText("Synthetic action");
    t.ctx.pointerDown();
    t.frame();
    t.advance(0.04);
    try testing.expect(s.held_scale < 1 and s.held_scale > 0.97);
    try testing.expectEqual(@as(usize, 0), s.clicks);
    t.ctx.pointerUp();
    t.frame();
    t.advance(0.2);
    try testing.expectApproxEqAbs(@as(f32, 1), s.held_scale, 0.001);
    try testing.expectEqual(@as(usize, 1), s.clicks);
}

test "completed historical tools never display active loading cells" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.apply(
        \\{"reset":[{"id":"answer","role":"assistant","status":"complete","parts":[
        \\ {"id":"read","kind":"tool","call":{"kind":"readFile","path":"synthetic.rs"}}]}]}
    );
    try h.t.clickText("Read 1 file");
    h.t.settle(0.3);
    const file = h.t.findText("synthetic.rs") orelse return error.MissingHistoricalTool;
    // Legacy complete snapshots omit resolved. They must not reserve a
    // running clock slot or scramble their path, even after reopening.
    try testing.expectEqual(@as(usize, 0), h.a.view.tool_ui.rows.count());
    try h.t.clickText("Read 1 file");
    h.t.settle(0.3);
    try h.t.clickText("Read 1 file");
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("synthetic.rs"));
    try testing.expectEqual(@as(usize, 0), h.a.view.tool_ui.rows.count());
    for (h.t.ctx.nodes.items) |node| {
        // The fixture's unlisted composer model has its own legitimate
        // catalog loader. Check the tool row, not unrelated window regions.
        if (node.rect.y < file.y - 4 or node.rect.y > file.y + file.h + 4) continue;
        if (node.rect.w == 2 and node.rect.h == 2 and node.style.background != null)
            return error.HistoricalToolStillLoading;
    }
}

test "a new chat in a git project runs in a fresh worktree unless its own checkout is picked (CheckoutPlan)" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{},"Mutate":{}}
    , .{});
    a.engine.state = .connected;
    var spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"git","deviceId":"d","path":"/work/synthetic-repo","gitDetected":true},
        \\ {"id":"plain","deviceId":"d","path":"/work/synthetic-notes","gitDetected":false}]
    , .{});
    defer spaces.deinit();
    try a.spaces.replace(spaces.value);
    const Case = struct { space: []const u8, local: bool, worktree: bool };
    for ([_]Case{
        .{ .space = "git", .local = false, .worktree = true },
        .{ .space = "git", .local = true, .worktree = false },
        .{ .space = "plain", .local = false, .worktree = false },
    }) |case| {
        a.select(null, case.space);
        a.new_checkout_local = case.local;
        a.composer.set("Synthetic first prompt");
        const before = a.engine.sent.items.len;
        a.send();
        var run: ?[]const u8 = null;
        for (a.engine.sent.items[before..]) |f| if (std.mem.indexOf(u8, f, "QueueCommand") != null) {
            run = f;
        };
        const frame = run orelse return error.NoRun;
        const spec = "\"worktree\":{\"repoPath\":\"/work/synthetic-repo\",\"base\":\"\",\"spaceId\":\"git\"}";
        try testing.expectEqual(case.worktree, std.mem.indexOf(u8, frame, spec) != null);
        if (!case.worktree) try testing.expect(std.mem.indexOf(u8, frame, "\"worktree\"") == null);
    }
}

test "a plain chat goes out with no project, on Auto (low), its config saying chatMode (set_chat_mode)" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueCommand":{},"Mutate":{}}
    , .{});
    a.engine.state = .connected;
    var spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"git","deviceId":"d","path":"/work/synthetic-repo","gitDetected":true}]
    , .{});
    defer spaces.deinit();
    try a.spaces.replace(spaces.value);
    var models = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"codegraff/claude-opus-5-5","label":"Claude Opus 5.5"},{"id":"codegraff/auto-high","label":"x"},{"id":"codegraff/auto-low","label":"y"}]
    , .{});
    defer models.deinit();
    try a.models.replace(models.value);
    a.gpa.free(a.models_for);
    a.models_for = try a.gpa.dupe(u8, "graff");
    a.select(null, "git");
    const agent = @import("app_agent.zig");
    agent.setChatMode(&a, true);
    try testing.expect(a.new_chat_mode and agent.newChatSpace(&a) == null);
    try testing.expectEqualStrings("Auto (low)", agent.modelLabel(&a, agent.target(&a).model));
    a.composer.set("Synthetic plain question");
    const before = a.engine.sent.items.len;
    a.send();
    var create: ?[]const u8 = null;
    var run: ?[]const u8 = null;
    for (a.engine.sent.items[before..]) |f| {
        if (std.mem.indexOf(u8, f, "createChat") != null) create = f;
        if (std.mem.indexOf(u8, f, "QueueCommand") != null) run = f;
    }
    const c = create orelse return error.NoCreate;
    try testing.expect(std.mem.indexOf(u8, c, "\"spaceId\"") == null);
    try testing.expect(std.mem.indexOf(u8, c, "\"chatMode\":true") != null);
    try testing.expect(std.mem.indexOf(u8, c, "\"model\":\"codegraff/auto-low\"") != null);
    const r = run orelse return error.NoRun;
    try testing.expect(std.mem.indexOf(u8, r, "\"cwd\":\"~\"") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\"worktree\"") == null);
}

test "the first ⌘W asks; the answer is the default; only an idle chat is archived (archive_choice)" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"Mutate":{},"QueueCommand":{},"WatchDocMessages":{},"WatchQueue":{}}
    , .{});
    a.engine.state = .connected;
    var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"idle","deviceId":"d","title":"Synthetic idle","archived":false},
        \\ {"id":"busy","deviceId":"d","title":"Synthetic busy","archived":false}]
    , .{});
    defer chats.deinit();
    try a.chats.replace(chats.value);
    var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"busy","status":"working","updatedAt":"2099-01-01T00:00:00Z"}]
    , .{});
    defer sessions.deinit();
    try a.sessions.replace(sessions.value);
    const archived = struct {
        fn of(app: *App, id: []const u8) bool {
            var buf: [96]u8 = undefined;
            const want = std.fmt.bufPrint(&buf, "\"op\":\"setChatArchived\",\"chatId\":\"{s}\"", .{id}) catch return false;
            for (app.engine.sent.items) |f| if (std.mem.indexOf(u8, f, want) != null) return true;
            return false;
        }
    }.of;
    // No choice yet: ⌘W asks and nothing closes.
    a.openChat("idle", null);
    a.closeByShortcut();
    try testing.expect(a.view.close_choice);
    try testing.expectEqualStrings("idle", a.selected.?);
    // "Archive it": saved as the default, and this idle chat goes.
    a.chooseCloseArchiving(true);
    try testing.expect(!a.view.close_choice);
    try testing.expect(a.settings.get(.archive_sessions_on_close) and a.settings.get(.archive_on_close_chosen));
    try testing.expect(archived(&a, "idle"));
    // Chosen: the next ⌘W doesn't ask; a working chat stays, with a note.
    a.openChat("busy", null);
    a.closeByShortcut();
    try testing.expect(!a.view.close_choice);
    try testing.expect(!archived(&a, "busy"));
    try testing.expectEqualStrings(@import("archive_close.zig").running_notice, a.view.sidebar_notice[0..a.view.sidebar_notice_len]);
}
