//! The GPUI transcript's session-driven working trailer. No reasoning or
//! tool part has to arrive before the running turn is visible.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const tr = @import("transcript.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const workspace = @import("workspace.zig");

// `FLAVOUR_WORDS`, `flavour_seed`, `flavour_word`, `format_elapsed` in
// crates/ui/src/transcript.rs. Keep the order: the seed indexes it.
pub const words = [_][]const u8{
    "Harnessing",    "Thinking",    "Pondering",  "Scheming",  "Brewing",
    "Weaving",       "Tinkering",   "Musing",     "Composing", "Sifting",
    "Untangling",    "Distilling",  "Sketching",  "Plotting",  "Riffing",
    "Combobulating", "Percolating", "Marinating", "Noodling",  "Puzzling",
    "Conjuring",
};

pub fn word(chat_id: []const u8, elapsed: i64) []const u8 {
    var seed: u64 = 0xcbf29ce484222325;
    for (chat_id) |b| seed = (seed ^ b) *% 0x100000001b3;
    const step: u64 = @intCast(@divTrunc(@max(elapsed, 0), 7));
    return words[(seed +% step) % words.len];
}

/// What the live turn says beyond its flavour word: the plan item it is on,
/// the tool it is running, and its latest thought when neither says enough.
pub const Activity = struct {
    now: ?*const tr.Part = null,
    plan: ?[]const u8 = null,
    thought: ?[]const u8 = null,
};

/// Whether the transcript still has an unanswered turn. A session row can
/// stop updating while the model is thinking; that is not evidence the turn
/// ended. A trailing user entry or a streaming reply keeps the trailer
/// truthful, while a stale row after a completed reply stays hidden.
fn turnOpen(t: *const tr.Transcript) bool {
    const last = if (t.entries.items.len > 0) t.entries.items[t.entries.items.len - 1] else return false;
    return last.role == .user or last.status == .streaming;
}

pub fn activity(t: *const tr.Transcript) Activity {
    var out: Activity = .{};
    var i = t.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = &t.entries.items[i];
        if (e.role != .assistant or e.status != .streaming) continue;
        var j = e.parts.items.len;
        while (j > 0) {
            j -= 1;
            const p = &e.parts.items[j];
            if (p.kind == .tool and p.tool == .todo and out.plan == null and p.todo_step.len > 0) out.plan = p.todo_step;
            if (p.kind == .tool and !p.resolved and p.tool != .todo and out.now == null) out.now = p;
            if (p.kind == .reasoning and out.thought == null and std.mem.trim(u8, p.text.items, " \t\r\n").len > 0) out.thought = p.text.items;
            // Every frame asks for this while a turn streams. The newest
            // three facts are all it shows; stop before walking old parts.
            if (out.now != null and out.plan != null and out.thought != null) break;
        }
        break;
    }
    return out;
}

/// One line of a command or thought, capped without cutting UTF-8.
pub fn preview(buf: []u8, text: []const u8, max: usize) []const u8 {
    const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \t\r");
    const cap = @min(@min(line.len, max), buf.len);
    var n = cap;
    while (n > 0 and !std.unicode.utf8ValidateSlice(line[0..n])) n -= 1;
    @memcpy(buf[0..n], line[0..n]);
    if (n < line.len and buf.len > n + 3) {
        @memcpy(buf[n .. n + 3], "…");
        n += 3;
    }
    return buf[0..n];
}

pub fn elapsedLabel(buf: []u8, seconds: i64) []const u8 {
    const s = @max(seconds, 0);
    return if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s}) catch ""
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m {d}s", .{ @divTrunc(s, 60), @mod(s, 60) }) catch ""
    else if (s < 86400)
        std.fmt.bufPrint(buf, "{d}h {d}m", .{ @divTrunc(s, 3600), @divTrunc(@mod(s, 3600), 60) }) catch ""
    else
        std.fmt.bufPrint(buf, "{d}d {d}h", .{ @divTrunc(s, 86400), @divTrunc(@mod(s, 86400), 3600) }) catch "";
}

pub fn trailer(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, t: *const tr.Transcript) void {
    const id = chat_id orelse return;
    const pending = @import("app_send_feedback.zig").active(a, id, t);
    const session = workspace.sessionOf(a.sessions.items, id);
    const now = a.nowMs();
    const quiet = if (pending) |_| false else if (session) |s|
        now - s.updated_ms > workspace.stale_ms
    else
        false;
    if (pending == null and (session == null or session.?.status != .working or (quiet and !turnOpen(t)))) return;
    // A pending question owns the surface, just as GPUI's QuestionPanel.
    for (t.entries.items) |e| for (e.parts.items) |p| {
        if (p.kind == .input and !p.resolved) return;
    };
    const started = if (pending) |p| p.started_ms else session.?.started_ms;
    const elapsed = if (started) |start| @divTrunc(@max(now - start, 0), 1000) else 0;
    ui.key(c, "working-trailer");
    const box = ui.div(c).column().wFull().pt(16).gap(5);
    defer box.end();
    const live = activity(t);
    {
        const row = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer row.end();
        kit.snake(c, k);
        ui.text(c, c.print("{s}…", .{word(id, elapsed)}), kit.style(c, 12, 18, .{ .color = k.muted }));
        var buf: [48]u8 = undefined;
        ui.text(c, c.print("{s}", .{elapsedLabel(&buf, elapsed)}), kit.style(c, 11, 18, .{ .color = k.faint }));
        if (quiet) {
            var updated_buf: [48]u8 = undefined;
            const updated = session.?.updated_ms;
            const silent = @divTrunc(@max(now - updated, 0), 1000);
            ui.text(c, c.print("· Waiting for the model · no update for {s}", .{elapsedLabel(&updated_buf, silent)}), kit.style(c, 11, 18, .{ .color = k.faint }));
        } else if (live.now == null and live.plan == null and live.thought == null) {
            // Before the turn reports a plan, tool or thought, say that it is
            // still deciding what to do without taking another row.
            ui.text(c, "· Working out the next step", kit.style(c, 11, 18, .{ .color = k.faint }));
        }
    }
    if (live.now) |p| {
        var buf: [192]u8 = undefined;
        const detail = if (p.text.items.len > 0) p.text.items else p.chip;
        detailLine(c, k, "Now", c.print("{s} · {s}", .{ p.chip, preview(&buf, detail, 160) }), k.muted);
    }
    if (live.thought) |thought| {
        var buf: [192]u8 = undefined;
        detailLine(c, k, "Thinking", c.print("{s}", .{preview(&buf, thought, 160)}), k.muted);
    }
    if (live.plan) |step| {
        var buf: [192]u8 = undefined;
        detailLine(c, k, "Plan", c.print("{s}", .{preview(&buf, step, 160)}), k.faint);
    }
    // Once per second is enough for elapsed text; the spinner schedules its
    // own animation, and a settled/expired session schedules no frames.
    // An off-screen trailer is not mounted, so it does not keep the window
    // redrawing a clock nobody can see.
    if (kit.loaderOnScreen(c)) c.frameIn(if (c.input.window_active) 1 else kit.background_tick_divisor);
}

fn detailLine(c: *ui.Context, k: theme.Colors, label: []const u8, text: []const u8, color: ui.Color) void {
    const row = ui.div(c).row().wFull().gap(7).itemsStart();
    defer row.end();
    ui.text(c, label, kit.style(c, 11, 18, .{ .weight = .medium, .color = k.faint }));
    const body = ui.div(c).column().grow().w(0);
    defer body.end();
    ui.text(c, text, kit.style(c, 12, 18, .{ .wrap = true, .color = color }));
}

test "a quiet but unanswered turn keeps its working activity" {
    const testing = std.testing;
    const applyJson = struct {
        fn run(t: *tr.Transcript, text: []const u8) !void {
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
            defer parsed.deinit();
            try t.apply(parsed.value);
        }
    }.run;
    var t: tr.Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyJson(&t, "{\"reset\":[{\"id\":\"u\",\"role\":\"user\",\"parts\":[{\"id\":\"p\",\"kind\":\"text\",\"text\":\"inspect this\"}]}]}");
    try testing.expect(turnOpen(&t));

    var done: tr.Transcript = .{ .gpa = testing.allocator };
    defer done.deinit();
    try applyJson(&done, "{\"reset\":[{\"id\":\"a\",\"role\":\"assistant\",\"status\":\"complete\",\"parts\":[{\"id\":\"p\",\"kind\":\"text\",\"text\":\"finished\"}]}]}");
    try testing.expect(!turnOpen(&done));
}

test "working activity names the current plan step and action" {
    const testing = std.testing;
    var t: tr.Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    var frame = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"a","role":"assistant","status":"streaming","parts":[
        \\ {"id":"plan","kind":"tool","resolved":true,"call":{"kind":"todo","items":[
        \\   {"text":"Inspect the saved choice","done":true},
        \\   {"text":"Verify the project grouping","done":false}]}},
        \\ {"id":"thought","kind":"reasoning","text":"Checking the stale writer\nsecond line"},
        \\ {"id":"run","kind":"tool","resolved":false,"call":{"kind":"exec","command":"zig build test"}}]}]}
    , .{});
    defer frame.deinit();
    try t.apply(frame.value);
    const live = activity(&t);
    try testing.expectEqualStrings("Verify the project grouping", live.plan.?);
    try testing.expectEqualStrings("zig build test", live.now.?.text.items);
    try testing.expectEqualStrings("Checking the stale writer\nsecond line", live.thought.?);
    var buf: [192]u8 = undefined;
    try testing.expectEqualStrings("Checking the stale writer", preview(&buf, live.thought.?, 160));
    var short: [8]u8 = undefined;
    const clipped = preview(&short, "aébcde", 2);
    try testing.expectEqualStrings("a…", clipped);
    try testing.expect(std.unicode.utf8ValidateSlice(clipped));
}

test "working trailer uses GPUI's elapsed formatting and seven-second vocabulary rotation" {
    const testing = std.testing;
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("0s", elapsedLabel(&buf, -1));
    try testing.expectEqualStrings("1m 5s", elapsedLabel(&buf, 65));
    try testing.expectEqualStrings("1h 1m", elapsedLabel(&buf, 3665));
    try testing.expectEqualStrings("2d 1h", elapsedLabel(&buf, 176400));
    try testing.expectEqualStrings(word("synthetic", 0), word("synthetic", 6));
    try testing.expect(!std.mem.eql(u8, word("synthetic", 0), word("synthetic", 7)));
    try testing.expectEqualStrings(word("synthetic", 0), word("synthetic", 21 * 7));
}
