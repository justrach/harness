//! Bots in the window, from made-up data: the Bots group in the sidebar,
//! the catch-up, a bot's page and the form that makes one. The engine is a
//! scene: its replies are canned, and what the app sent is read back.
const std = @import("std");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const bots = @import("bots.zig");

/// The clock every time below is read against: 08:06 UTC.
const now_ms: i64 = 1_800_000_000_000 + 6 * 60_000;
const min: i64 = 60_000;

const spaces =
    \\[{"id":"s-comet","deviceId":"d","path":"/repo/comet"},{"id":"s-atlas","deviceId":"d","path":"/repo/atlas"}]
;

/// One ordinary chat in comet, and the standing chats of three bots:
/// notes finished and unread, triage failed, deps stopped on a question.
const chats =
    \\[{"id":"a","deviceId":"d","title":"Sketch the onboarding flow","archived":false,"spaceId":"s-comet","lastMessageAt":"2027-01-15T05:00:00Z","lastSeenAt":"2027-01-15T06:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Tidy notes","archived":false,"spaceId":"s-comet","lastMessageAt":"2027-01-14T05:00:00Z","lastSeenAt":"2027-01-14T06:00:00Z"},
    \\ {"id":"c-notes","deviceId":"d","title":"notes","archived":false,"spaceId":"s-comet","lastMessageAt":"2027-01-15T07:10:00Z","lastMessagePreview":"Draft is ready for comet 0.4."},
    \\ {"id":"c-triage","deviceId":"d","title":"triage","archived":false,"spaceId":"s-comet","lastMessageAt":"2027-01-15T06:05:00Z","lastMessagePreview":"GitHub token rejected. 3 issues unlabeled."},
    \\ {"id":"c-deps","deviceId":"d","title":"deps","archived":false,"spaceId":"s-atlas","lastMessageAt":"2027-01-15T03:40:00Z","lastSeenAt":"2027-01-15T03:41:00Z"}]
;

fn state(comptime gap: bool) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"enabled":true,"nowMs":{d},"lastCheckMs":{d},"gapFromMs":{d},"gapToMs":{d},"about":"Alex. Pacific time.","bots":[
        \\ {{"name":"ada","job":"Coordinate. Don't do their work.","primary":true,"chat":"","routines":[]}},
        \\ {{"name":"deps","job":"Keep dependencies current","project":"/repo/atlas","chat":"c-deps","routines":[]}},
        \\ {{"name":"notes","job":"Draft release notes","project":"/repo/comet","chat":"c-notes","routines":[
        \\   {{"id":"r1","instruction":"Draft the release notes","atMs":{d},"intervalMs":21600000,"runs":11,"missedAtMs":{d},"missedOpen":1}}]}},
        \\ {{"name":"triage","job":"Label new issues","project":"/repo/comet","chat":"c-triage","routines":[]}}]}}
    , .{ now_ms, now_ms, if (gap) now_ms - 565 * min else 0, if (gap) now_ms else 0, now_ms + 112 * min, now_ms - 236 * min });
}

const Harness = struct {
    a: App,
    t: ui.Tester,

    /// `replies` is the scene: what the engine answers, by method.
    fn init(h: *Harness, comptime replies: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.settings.setText("sidebarOrganization", "inOneList");
        h.a.bots.clock_ms = now_ms;
        inline for (.{ .{ spaces, &h.a.spaces }, .{ chats, &h.a.chats } }) |l| {
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, l[0], .{});
            defer parsed.deinit();
            try l[1].replace(parsed.value);
        }
        var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"chatId":"c-triage","status":"errored","updatedAt":"2027-01-15T08:06:00Z"},{"chatId":"c-deps","status":"awaitingInput","updatedAt":"2027-01-15T08:06:00Z"}]
        , .{});
        defer sessions.deinit();
        try h.a.sessions.replace(sessions.value);
        h.a.device_id = try testing.allocator.dupe(u8, "d");
        h.a.openChat("a", null);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, replies, .{});
        h.a.engine.state = .connected;
        // As the app does when its engine connects.
        bots.connected(&h.a);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// The last request sent for `method`, or null.
    fn sent(h: *Harness, comptime method: []const u8) ?[]const u8 {
        var last: ?[]const u8 = null;
        for (h.a.engine.sent.items) |frame| {
            if (std.mem.indexOf(u8, frame, "\"method\":\"" ++ method ++ "\"") != null) last = frame;
        }
        return last;
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

fn has(frame: ?[]const u8, needle: []const u8) bool {
    return if (frame) |f| std.mem.indexOf(u8, f, needle) != null else false;
}

test "the Bots group lists every bot on any project, and a bot's chat only there" {
    var h: Harness = undefined;
    try h.init("{\"BotsState\":" ++ state(false) ++ "}");
    defer h.deinit();
    try testing.expect(h.sent("BotsState") != null);
    try testing.expect(h.t.hasText("Bots"));
    for ([_][]const u8{ "ada", "deps", "notes", "triage" }) |name| try testing.expect(h.t.hasText(name));
    // What each needs, at its row's edge; the project it works in beside it.
    try testing.expect(h.t.hasText("Needs you"));
    try testing.expect(h.t.hasText("Failed"));
    try testing.expect(h.t.hasText("atlas"));
    // One row for a bot's chat: its title is not also a session's.
    try testing.expect(h.t.hasText("Tidy notes"));
    var notes_rows: usize = 0;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "notes")) {
            notes_rows += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), notes_rows);
    // No gap on record: the window stayed on the chat it opened on.
    try testing.expectEqual(bots.Page.none, h.a.bots.page);
    try testing.expect(h.t.hasText("4 to look at"));
    // A filter on another project hides comet's chats, not the bots.
    h.a.view.setFilter(testing.allocator, "s-atlas");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Tidy notes"));
    try testing.expect(h.t.hasText("triage"));
    h.snap("bots-group");
}

test "a launch after a night opens on the catch-up, and each item has its own way out" {
    var h: Harness = undefined;
    try h.init("{\"BotsState\":" ++ state(true) ++ ",\"RunBot\":{\"chatId\":\"c-notes\",\"bot\":\"notes\"},\"BotAction\":" ++ state(true) ++ ",\"Mutate\":{\"ok\":true}}");
    defer h.deinit();
    try testing.expectEqual(bots.Page.inbox, h.a.bots.page);
    try testing.expect(h.t.hasText("While you were away"));
    // Why nothing ran, in the place the person is looking.
    try testing.expect(h.t.containsText("Nothing was checking routines from 22:41 to 08:06."));
    try testing.expect(h.t.containsText("Routines run only while Harness is open."));
    for ([_][]const u8{ "Needs you", "Failed · 06:05", "Done · 07:10", "Did not run" }) |label| try testing.expect(h.t.hasText(label));
    try testing.expect(h.t.hasText("deps · atlas"));
    try testing.expect(h.t.containsText("Draft the release notes · due 04:10. It did not start."));
    try testing.expect(h.t.containsText("Draft is ready for comet 0.4."));
    h.snap("bots-catch-up");

    // A finished run leaves when it is read.
    try h.t.clickText("Mark read");
    h.t.settle(1);
    try testing.expect(has(h.sent("Mutate"), "\"op\":\"markChatSeen\""));
    try testing.expect(has(h.sent("Mutate"), "\"chatId\":\"c-notes\""));

    // A missed routine is run as a new turn now, or let go.
    try h.t.clickText("Run now");
    h.t.settle(1);
    try testing.expect(has(h.sent("RunBot"), "\"bot\":\"notes\""));
    try testing.expect(has(h.sent("RunBot"), "\"routine\":\"r1\""));
    try testing.expect(!has(h.sent("RunBot"), "\"message\""));
    // The run's chat is here already, so the window goes to it.
    try testing.expectEqual(bots.Page.none, h.a.bots.page);
    try testing.expectEqualStrings("c-notes", h.a.selected.?);

    bots.openInbox(&h.a);
    h.t.settle(1);
    // The question is answered in the bot's chat, where its panel is.
    try h.t.clickText("Open to answer");
    h.t.settle(1);
    try testing.expectEqualStrings("c-deps", h.a.selected.?);
}

test "the catch-up's Dismiss clears a missed routine without running it" {
    var h: Harness = undefined;
    try h.init("{\"BotsState\":" ++ state(true) ++ ",\"BotAction\":" ++ state(true) ++ "}");
    defer h.deinit();
    // Two Dismiss buttons: the failed run's, then the missed routine's.
    const failed = h.t.findText("Failed · 06:05").?;
    const missed = h.t.findText("Did not run").?;
    try testing.expect(missed.y > failed.y);
    var target: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "Dismiss") and node.rect.y > missed.y) {
            target = node.rect;
        },
        else => {},
    };
    h.t.click(target.?.x + 4, target.?.y + 4);
    h.t.settle(1);
    try testing.expect(has(h.sent("BotAction"), "\"action\":\"missedClear\""));
    try testing.expect(has(h.sent("BotAction"), "\"routine\":\"r1\""));
    try testing.expect(h.sent("RunBot") == null);
}

test "a bot's page: its routines, its memory, and a message that starts its chat" {
    var h: Harness = undefined;
    try h.init("{\"BotsState\":" ++ state(false) ++ ",\"BotAction\":" ++ state(false) ++
        ",\"BotDetail\":{\"memory\":\"- No marketing adjectives.\\n- Keep three bullets.\",\"log\":\"- 2027-01-15 07:10Z routine r1: Draft is ready\"}" ++
        ",\"RunBot\":{\"chatId\":\"c-new\",\"bot\":\"ada\"}}");
    defer h.deinit();
    // A bot with a chat opens it, under a strip that names the bot.
    try h.t.clickText("notes");
    h.t.settle(1);
    try testing.expectEqualStrings("c-notes", h.a.selected.?);
    try testing.expect(h.t.hasText("Draft release notes"));
    try h.t.clickText("Details");
    h.t.settle(1);
    try testing.expectEqual(bots.Page.bot, h.a.bots.page);
    try testing.expect(has(h.sent("BotDetail"), "\"bot\":\"notes\""));
    try testing.expect(h.t.hasText("Works in comet"));
    try testing.expect(h.t.containsText("Every 6 hours · Draft the release notes"));
    try testing.expect(h.t.containsText("r1 · Next in 1h 52m · 11 runs"));
    try testing.expect(h.t.hasText("Due 04:10 · did not run"));
    try testing.expect(h.t.containsText("Routines run only while Harness is open. Last checked 08:06."));
    try testing.expect(h.t.hasText("No marketing adjectives."));
    // Shared, and edited on the primary bot only.
    try testing.expect(h.t.hasText("Alex. Pacific time."));
    try testing.expect(h.t.containsText("Edit it on your primary bot."));
    h.snap("bots-page");

    try h.t.clickText("Forget");
    h.t.settle(1);
    try testing.expect(has(h.sent("BotAction"), "\"action\":\"forget\""));
    try testing.expect(has(h.sent("BotAction"), "\"text\":\"No marketing adjectives.\""));
    try h.t.clickText("Run now");
    h.t.settle(1);
    try testing.expect(has(h.sent("RunBot"), "\"routine\":\"r1\""));

    // Deleting asks first.
    bots.openBot(&h.a, "notes");
    h.t.settle(1);
    // At the page's foot, below the window's edge.
    h.t.scroll(700, 400, -2000);
    h.t.settle(1);
    try h.t.clickText("Delete bot");
    h.t.settle(1);
    try testing.expect(!has(h.sent("BotAction"), "\"action\":\"remove\""));
    try testing.expect(h.t.containsText("Delete notes and everything it remembers?"));
    try h.t.clickText("Keep");
    h.t.settle(1);
    try testing.expect(!h.t.containsText("Delete notes and everything it remembers?"));

    // A bot with no chat yet opens on its page; its first message makes
    // the chat, and the window goes there once the chat's row arrives.
    try h.t.clickText("ada");
    h.t.settle(1);
    try testing.expectEqual(bots.Page.bot, h.a.bots.page);
    try testing.expect(h.t.containsText("Primary"));
    try h.t.clickText("Ask ada…");
    h.t.typeText("draft the notes for 0.4");
    h.t.settle(1);
    try h.t.clickText("Send");
    h.t.settle(1);
    try testing.expect(has(h.sent("RunBot"), "\"bot\":\"ada\""));
    try testing.expect(has(h.sent("RunBot"), "\"message\":\"draft the notes for 0.4\""));
    try testing.expectEqual(bots.Page.bot, h.a.bots.page);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"c-new","deviceId":"d","title":"ada","archived":false}]
    , .{});
    defer parsed.deinit();
    try h.a.chats.replace(parsed.value);
    h.t.settle(1);
    try testing.expectEqual(bots.Page.none, h.a.bots.page);
    try testing.expectEqualStrings("c-new", h.a.selected.?);
}

test "a new bot: a name and a job, in the project the sidebar is filtered to" {
    var h: Harness = undefined;
    try h.init("{\"BotsState\":" ++ state(false) ++ ",\"BotAction\":" ++ state(false) ++ "}");
    defer h.deinit();
    h.a.view.setFilter(testing.allocator, "s-comet");
    bots.openNew(&h.a);
    h.t.settle(1);
    try testing.expect(h.t.hasText("New bot"));
    try testing.expect(h.t.hasText("Works in comet"));
    h.snap("bots-new");
    // Nothing is sent for a name graff would refuse.
    h.a.bots.name.set("Release Notes");
    h.a.bots.job.set("Draft release notes");
    h.t.settle(1);
    try h.t.clickText("Create");
    h.t.settle(1);
    try testing.expect(h.sent("BotAction") == null);

    h.a.bots.name.set("relnotes");
    h.t.settle(1);
    try h.t.clickText("Create");
    h.t.settle(1);
    const sent = h.sent("BotAction");
    try testing.expect(has(sent, "\"action\":\"create\""));
    try testing.expect(has(sent, "\"bot\":\"relnotes\""));
    try testing.expect(has(sent, "\"text\":\"Draft release notes\""));
    try testing.expect(has(sent, "\"project\":\"/repo/comet\""));
    // Not primary unless asked, and the field is left out, not false.
    try testing.expect(!has(sent, "\"primary\""));
}

test "with no bots the group says so, and an engine without bots draws nothing" {
    var h: Harness = undefined;
    try h.init("{\"BotsState\":{\"enabled\":true,\"bots\":[]}}");
    defer h.deinit();
    try testing.expect(h.t.hasText("Bots"));
    try testing.expect(h.t.containsText("None yet."));
    try testing.expect(!h.t.containsText("to look at"));

    // An engine from before bots: no group, and no way in to a page that
    // could only fail.
    var old: Harness = undefined;
    try old.init("{\"BotsState\":{\"$err\":\"unknown method: BotsState\"}}");
    defer old.deinit();
    try testing.expect(!old.t.hasText("Bots"));
    try testing.expect(!old.t.containsText("None yet."));
    try testing.expect(old.t.hasText("Sketch the onboarding flow"));
}

test "bots are off until turned on in Settings, and off draws nothing" {
    var h: Harness = undefined;
    try h.init("{\"BotsState\":{\"enabled\":false,\"bots\":[]},\"BotAction\":" ++ state(true) ++ "}");
    defer h.deinit();
    // Off: no group, no way in, and the chats are as they were.
    try testing.expect(!h.t.hasText("Bots"));
    try testing.expect(!h.t.containsText("None yet."));
    try testing.expect(h.t.hasText("Sketch the onboarding flow"));
    try testing.expectEqual(bots.Page.none, h.a.bots.page);
    try testing.expect(h.sent("BotAction") == null);

    // The switch is a card in Settings > Agents.
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .harnesses;
    h.t.resize(1200, 1400);
    h.t.settle(2);
    try testing.expect(h.t.hasText("Experimental: Bots"));
    h.snap("bots-off-settings");
    // The switch has no words: it is the first track under the card's title.
    const card_title = h.t.findText("Experimental: Bots").?;
    var track: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 32 and r.h == 18 and r.y > card_title.y and (track == null or r.y < track.?.y)) track = r;
    }
    h.t.click(track.?.x + 16, track.?.y + 9);
    h.t.settle(2);
    try testing.expect(has(h.sent("BotAction"), "\"action\":\"enable\""));
    try testing.expect(h.a.bots.enabled);
    // Turning them on stays in Settings: the catch-up is a launch's.
    try testing.expect(h.a.view.settings_open);
    @import("view_settings.zig").close(&h.a);
    h.t.settle(2);
    try testing.expect(h.t.hasText("Bots"));
    try testing.expect(h.t.hasText("triage"));

    // Off again, as a terminal's `graff bot disable` is seen: the group goes.
    var off = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"enabled\":false,\"bots\":[]}", .{});
    defer off.deinit();
    bots.openInbox(&h.a);
    try bots.apply(&h.a, off.value);
    h.t.settle(2);
    try testing.expectEqual(bots.Page.none, h.a.bots.page);
    try testing.expect(!h.t.hasText("Bots"));
    try testing.expect(!h.t.hasText("Needs you"));
    // A bot's standing chat is an ordinary chat while bots are off.
    try testing.expect(h.t.hasText("triage"));
}
