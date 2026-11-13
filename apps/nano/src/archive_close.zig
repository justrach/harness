//! What closing a chat does to its session (shell/archive_choice.rs,
//! chat_tabs.rs `archive_closed_session_if_idle`): ⌘W and a tab's ✕
//! archive it when Settings › Archived says so and it's idle and shown
//! nowhere else; ⌥⌘W never does. Until a choice is made, the first ⌘W asks.
//! Pure, so the rules are tested without the window.
const std = @import("std");

/// What a close does to the session it closed (`CloseArchive`).
pub const Outcome = enum {
    /// Archiving on close is off, or this close never archives.
    off,
    /// Another tab or pane still shows it.
    still_open,
    /// Working, waiting for input, or a send on its way: left in the sidebar.
    running,
    archive,
};

pub fn decide(may_archive: bool, still_open: bool, running: bool) Outcome {
    if (!may_archive) return .off;
    if (still_open) return .still_open;
    if (running) return .running;
    return .archive;
}

/// Whether ⌘W asks first: no choice made yet, with a chat to close. A file
/// that already had archiving on counts as chosen (`migrated`).
pub fn asks(chosen: bool, archiving_on: bool, has_chat: bool) bool {
    return has_chat and !chosen and !archiving_on;
}

/// The sidebar's note for a running session's close, for 5 seconds.
pub const running_notice = "Still running \u{2014} closed without archiving";
pub const notice_s: f64 = 5;

/// Settings › Archived's line under its switch (`archive_on_close_copy`).
pub fn settingsCopy(buf: []u8, close: []const u8, close_only: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Closing a session tab or pane with {s} or its \u{2715} button archives it if idle, unless it is still open in another tab or pane in this app. The first {s} asks you to choose this default. {s} always closes without archiving. Running sessions and sessions waiting for input remain in the sidebar. Closing the app or a window does not archive sessions.", .{ close, close, close_only }) catch "";
}

/// The first-close dialog's title and body (`archive_choice_copy`).
pub fn choiceTitle(buf: []u8, close: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "What should {s} do when you close a chat?", .{close}) catch "";
}

pub fn choiceBody(buf: []u8, close_only: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Just close it to keep it in the sidebar, or archive it to move an idle session to the archived shelf. Your choice becomes the default for closing chats. You can change it in Settings \u{2192} Archived sessions. Sessions that are running, waiting for input, or still open elsewhere are never archived. {s} always just closes without asking.", .{close_only}) catch "";
}

test "a close archives only an idle session shown nowhere else, when allowed" {
    try std.testing.expectEqual(Outcome.off, decide(false, false, false));
    try std.testing.expectEqual(Outcome.still_open, decide(true, true, true));
    try std.testing.expectEqual(Outcome.running, decide(true, false, true));
    try std.testing.expectEqual(Outcome.archive, decide(true, false, false));
}

test "the first ⌘W asks until a choice is made; archiving already on counts as one" {
    try std.testing.expect(asks(false, false, true));
    try std.testing.expect(!asks(true, false, true));
    try std.testing.expect(!asks(false, true, true));
    try std.testing.expect(!asks(false, false, false));
}

test "the copy names both shortcuts (archive_on_close_copy_names_what_the_toggle_covers)" {
    var b: [600]u8 = undefined;
    const copy = settingsCopy(&b, "\u{2318}W", "\u{2325}\u{2318}W");
    try std.testing.expect(std.mem.indexOf(u8, copy, "The first \u{2318}W asks you to choose this default") != null);
    try std.testing.expect(std.mem.indexOf(u8, copy, "\u{2325}\u{2318}W always closes without archiving.") != null);
    var t: [80]u8 = undefined;
    try std.testing.expectEqualStrings("What should \u{2318}W do when you close a chat?", choiceTitle(&t, "\u{2318}W"));
}
