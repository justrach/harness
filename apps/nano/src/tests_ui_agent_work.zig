//! Offscreen UI regressions for subagent & task management:
//! composer-footer Agent Work pill + popover card, structured `.todo` checklist,
//! live `Agent` rows with `WatchToolProgress` tails, parked `graff/waiting`
//! banner, and `.subagent` surface header + steer bar. Synthetic data only.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

test {
    _ = @import("agent_work.zig");
    _ = @import("app_tool_progress.zig");
    _ = @import("view_agent_work.zig");
}

const synthetic_chats =
    \\[{"id":"chat-syn","deviceId":"dev-syn","title":"Subagent task verification","cwd":"/work/synthetic","archived":false,"config":{"harness":"graff","model":"gpt-6.1-sol"}}]
;

const live_fixture =
    \\{"reset":[
    \\  {"id":"u1","role":"user","parts":[{"id":"up","kind":"text","text":"Verify the subagent and task UI"}]},
    \\  {"id":"a1","role":"assistant","status":"streaming","createdAt":10000,"parts":[
    \\    {"id":"todo-1","kind":"tool","resolved":true,"call":{"kind":"todo","items":[
    \\      {"text":"Map adapter events","done":true},
    \\      {"text":"Prove state machine bounds","done":false},
    \\      {"text":"Render showcase snapshots","done":false}]}},
    \\    {"id":"ag-1","kind":"tool","resolved":false,"subagentRef":"doc-lean-1","call":{
    \\      "kind":"unknown","name":"Agent: Lean verifier","input":{"model":"claude-opus-4-6"}}},
    \\    {"id":"ag-2","kind":"tool","resolved":false,"subagentRef":"doc-ui-2","call":{
    \\      "kind":"unknown","name":"Agent: Layout auditor","input":{"model":"gpt-6.1-sol"}}},
    \\    {"id":"edit-1","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"src/agent_work.zig"},"diffStats":[{"path":"src/agent_work.zig","additions":24,"deletions":2}]},
    \\    {"id":"exec-1","kind":"tool","resolved":false,"call":{"kind":"exec","command":"zig build test"}}
    \\  ]}
    \\],"contextUsage":{"tokens":42000,"window":200000}}
;

const live_progress =
    \\[
    \\  {"toolId":"ag-1","output":"▸ Checking 360 state cells\n▸ Proving card_within_window","state":"running"},
    \\  {"toolId":"ag-2","output":"▸ Measuring descender clearance","state":"running"}
    \\]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, transcript_json: []const u8, progress_json: ?[]const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        h.a.settings.set(.transcript_compact_mode, false);

        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator, synthetic_chats, .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("chat-syn", null);

        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, transcript_json, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);

        if (progress_json) |pj| {
            var prog = try std.json.parseFromSlice(std.json.Value, testing.allocator, pj, .{});
            defer prog.deinit();
            try h.a.tool_progress.replace(&h.a, prog.value);
        }

        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1280, .height = 820, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
};

test "footer Agent Work chip opens clamped popover and links into subagent surface" {
    var h: Harness = undefined;
    try h.init(live_fixture, live_progress);
    defer h.deinit();

    // Footer chip shows live agent count beside the context meter.
    try testing.expect(h.t.hasText("2 agents"));
    const anchor = h.a.view.agent_work.anchor orelse return error.MissingAgentWorkAnchor;

    // Click the footer chip to pin open the Agent Work popover card.
    h.t.click(anchor.x + anchor.w / 2, anchor.y + anchor.h / 2);
    h.t.advance(0.2);
    h.t.settle(1);

    try testing.expect(h.a.view.agent_work.open);
    try testing.expect(h.t.hasText("Tasks"));
    try testing.expect(h.t.hasText("1 of 3"));
    try testing.expect(h.t.hasText("Map adapter events"));
    try testing.expect(h.t.hasText("Prove state machine bounds"));
    try testing.expect(h.t.hasText("2 agents running"));
    try testing.expect(h.t.hasText("Lean verifier"));
    try testing.expect(h.t.hasText("Proving card_within_window"));
    try testing.expect(h.t.hasText("claude-opus-4-6"));
    try testing.expect(h.t.hasText("Agents"));
    try testing.expect(h.t.hasText("Terminal"));
    try testing.expect(h.t.hasText("Files"));

    const card = h.a.view.agent_work.card orelse return error.MissingAgentWorkCard;
    try testing.expect(card.x >= 8);
    try testing.expect(card.y >= 8);
    try testing.expect(card.x + card.w <= 1280 - 8 + 0.5);
    try testing.expect(card.y + card.h <= 820 - 8 + 0.5);

    // Clicking a linked subagent row inside the popover opens the right-hand subagent surface with header + steer bar.
    try h.t.clickText("claude-opus-4-6");
    h.t.settle(2);
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqual(@import("app_panels.zig").TabKind.subagent, h.a.panels.activeTab().?.kind);
    try testing.expect(h.t.containsText("Steer Lean verifier"));
}

test "expanding Todo in the task tree renders a structured checklist instead of raw JSON" {
    var h: Harness = undefined;
    try h.init(live_fixture, live_progress);
    defer h.deinit();

    // Top-level subagent rows stream live WatchToolProgress tails directly in the transcript.
    try testing.expect(h.t.hasText("Proving card_within_window"));

    // Open the Todo group ("Updated todos"), then expand the Todo row.
    try h.t.clickText("Updated todos");
    h.t.advance(0.35);
    h.t.settle(1);
    try testing.expect(h.t.hasText("1/3 done"));

    try h.t.clickText("Todo");
    h.t.advance(0.35);
    h.t.settle(1);

    try testing.expect(h.t.hasText("Map adapter events"));
    try testing.expect(h.t.hasText("Prove state machine bounds"));
    try testing.expect(h.t.hasText("Render showcase snapshots"));
    // Never dump raw JSON invocation text for structured todo checklists.
    try testing.expect(!h.t.containsText("\"kind\": \"todo\""));
}

test "parked session displays cross-turn graff/waiting subagent status until cleared" {
    const settled_turn =
        \\{"reset":[
        \\  {"id":"u1","role":"user","parts":[{"id":"up","kind":"text","text":"Spawn background audit"}]},
        \\  {"id":"a1","role":"assistant","status":"complete","parts":[
        \\    {"id":"p1","kind":"text","text":"Launched the background audit; I will wake when it reports back."}
        \\  ]}
        \\]}
    ;
    const waiting_progress =
        \\[{"toolId":"harness:graff-waiting","output":"{\"text\":\"Waiting on 1 background subagent\",\"wakes\":true,\"agents\":[{\"id\":\"bg-1\",\"name\":\"Security auditor\",\"model\":\"claude-opus-4-6\",\"task\":\"Scanning auth routes\"}]}","state":"parked"}]
    ;

    var h: Harness = undefined;
    try h.init(settled_turn, waiting_progress);
    defer h.deinit();

    try testing.expect(h.t.hasText("Waiting on 1 background subagent"));
    try testing.expect(h.t.hasText("· wakes when done"));
    try testing.expect(h.t.hasText("1 agent running"));

    // Clearing graff/waiting removes both the banner and the running footer pill.
    var cleared = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
    defer cleared.deinit();
    try h.a.tool_progress.replace(&h.a, cleared.value);
    h.t.settle(1);

    try testing.expect(!h.t.hasText("Waiting on 1 background subagent"));
    try testing.expect(!h.t.hasText("1 agent running"));
}
