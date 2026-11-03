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
    if (pending == null and (session == null or session.?.status != .working or now - session.?.updated_ms > workspace.stale_ms)) return;
    // A pending question owns the surface, just as GPUI's QuestionPanel.
    for (t.entries.items) |e| for (e.parts.items) |p| {
        if (p.kind == .input and !p.resolved) return;
    };
    const started = if (pending) |p| p.started_ms else session.?.started_ms;
    const elapsed = if (started) |start| @divTrunc(@max(now - start, 0), 1000) else 0;
    ui.key(c, "working-trailer");
    const row = ui.div(c).row().wFull().pt(16).gap(8).itemsCenter();
    defer row.end();
    kit.snake(c, k);
    ui.text(c, c.print("{s}…", .{word(id, elapsed)}), kit.style(c, 12, 18, .{ .color = k.muted }));
    var buf: [48]u8 = undefined;
    ui.text(c, c.print("{s}", .{elapsedLabel(&buf, elapsed)}), kit.style(c, 11, 18, .{ .color = k.faint }));
    // Once per second is enough for elapsed text; the spinner schedules its
    // own animation, and a settled/expired session schedules no frames.
    c.frameIn(1);
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
