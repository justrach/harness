//! The shortcuts a person can rebind, as the GPUI app keeps them
//! (crates/ui/src/settings.rs `ShortcutId`, `KeymapConfig`): each one's
//! name in `ui-settings.json`'s `keymap`, its label, group and description
//! on Settings › Shortcuts, and its macOS default. Combinations are stored
//! platform-neutral ("mod-shift-r") and shown as "Cmd+Shift+R".
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Group = enum {
    files,
    browser,
    panels,
    sessions,
    projects,
    jump,

    pub fn label(g: Group) []const u8 {
        return switch (g) {
            .files => "Files",
            .browser => "Browser",
            .panels => "Panels",
            .sessions => "Sessions",
            .projects => "Projects",
            .jump => "Jump to session",
        };
    }
};

pub const Shortcut = struct {
    /// Its key in `keymap` ("jumpSession" holds nine, `slot` picks one).
    key: []const u8,
    slot: ?u8 = null,
    group: Group,
    title: []const u8,
    description: []const u8,
    default: []const u8,
};

const jump_description = "Open the session at this place in the sidebar list.";

/// The Appshot capture's, recorded on the Appshots page (Control-Option-Space
/// on the Mac, `ShortcutId::CaptureAppshot`).
pub const appshot: Shortcut = .{ .key = "captureAppshot", .group = .sessions, .title = "Capture Appshot", .description = "", .default = "ctrl-alt-space" };

/// In the page's order (`ShortcutId::ALL`, Appshots' left out: it has a
/// page of its own).
pub const all = [_]Shortcut{
    .{ .key = "saveFile", .group = .files, .title = "Save file", .description = "Save the active workspace file.", .default = "mod-s" },
    .{ .key = "browserReload", .group = .browser, .title = "Reload browser page", .description = "Reload the focused browser tab.", .default = "mod-shift-r" },
    .{ .key = "toggleSidebar", .group = .panels, .title = "Toggle left sidebar", .description = "Show or hide sessions and settings navigation.", .default = "mod-b" },
    .{ .key = "toggleChanges", .group = .panels, .title = "Toggle right sidebar", .description = "Show or hide the right sidebar for the current session.", .default = "mod-r" },
    .{ .key = "toggleFiles", .group = .panels, .title = "Toggle files panel", .description = "Show or hide the files panel for the current session.", .default = "mod-e" },
    .{ .key = "toggleTerminal", .group = .panels, .title = "Toggle terminal", .description = "Show or hide the terminal for the current session.", .default = "mod-j" },
    .{ .key = "splitTerminal", .group = .panels, .title = "Split terminal right", .description = "Split the focused terminal to the right, like Ghostty ⌘D.", .default = "mod-d" },
    .{ .key = "splitTerminalDown", .group = .panels, .title = "Split terminal down", .description = "Split the focused terminal downward.", .default = "mod-shift-d" },
    .{ .key = "newSession", .group = .sessions, .title = "New chat", .description = "Open a new chat tab, preserving the current chat and split layout.", .default = "mod-t" },
    .{ .key = "openModelPicker", .group = .sessions, .title = "Open model picker", .description = "Open the model picker for the current session.", .default = "mod-/" },
    .{ .key = "nextSession", .group = .sessions, .title = "Next tab or session", .description = "Switch to the next tab when two or more are open; otherwise select the next session in the sidebar.", .default = "ctrl-tab" },
    .{ .key = "prevSession", .group = .sessions, .title = "Previous tab or session", .description = "Switch to the previous tab when two or more are open; otherwise select the previous session in the sidebar.", .default = "ctrl-shift-tab" },
    .{ .key = "archiveSession", .group = .sessions, .title = "Archive session", .description = "Move the current session to the archived shelf.", .default = "mod-shift-a" },
    .{ .key = "closeTabWithoutArchiving", .group = .sessions, .title = "Close tab without archiving", .description = "Close the focused pane or tab without archiving, regardless of the archive-on-close setting.", .default = "mod-alt-w" },
    .{ .key = "reopenClosedTab", .group = .sessions, .title = "Reopen closed tab", .description = "Reopen the most recently closed chat tab where it was; press again for earlier ones.", .default = "mod-shift-t" },
    .{ .key = "newProject", .group = .projects, .title = "New project", .description = "Open the new project dialog.", .default = "mod-shift-n" },
    .{ .key = "openProjectPicker", .group = .projects, .title = "Open project picker", .description = "Open the project picker to switch the project new sessions run in.", .default = "mod-shift-p" },
} ++ jumps();

fn jumps() [9]Shortcut {
    var out: [9]Shortcut = undefined;
    for (&out, 0..) |*s, i| s.* = .{
        .key = "jumpSession",
        .slot = @intCast(i),
        .group = .jump,
        .title = std.fmt.comptimePrint("Jump to session {d}", .{i + 1}),
        .description = jump_description,
        .default = std.fmt.comptimePrint("mod-{d}", .{i + 1}),
    };
    return out;
}

/// The read-only group under them: the window's own keys
/// (`fixed_rows`, from the live keymap on macOS).
pub const Fixed = struct { title: []const u8, keys: []const u8 };
pub const fixed_label = "Panes, tabs and the composer";
pub const fixed = [_]Fixed{
    .{ .title = "Split the chat to the right", .keys = "Cmd+D" },
    .{ .title = "Split the chat down", .keys = "Cmd+Shift+D" },
    .{ .title = "Close the pane (back to one column)", .keys = "Cmd+W" },
    .{ .title = "Next pane", .keys = "Cmd+]" },
    .{ .title = "Previous pane", .keys = "Cmd+[" },
    .{ .title = "Move to the pane on the left", .keys = "Opt+Cmd+←" },
    .{ .title = "Move to the pane on the right", .keys = "Opt+Cmd+→" },
    .{ .title = "Move to the pane above", .keys = "Opt+Cmd+↑" },
    .{ .title = "Move to the pane below", .keys = "Opt+Cmd+↓" },
    .{ .title = "Grow the pane to the left", .keys = "Ctrl+Cmd+←" },
    .{ .title = "Grow the pane to the right", .keys = "Ctrl+Cmd+→" },
    .{ .title = "Grow the pane up", .keys = "Ctrl+Cmd+↑" },
    .{ .title = "Grow the pane down", .keys = "Ctrl+Cmd+↓" },
    .{ .title = "Make all panes the same size", .keys = "Ctrl+Cmd+=" },
    .{ .title = "Zoom the pane (and back)", .keys = "Cmd+Shift+Enter" },
    .{ .title = "New chat tab", .keys = "Cmd+T" },
    .{ .title = "Reopen closed chat tab", .keys = "Cmd+Shift+T" },
    .{ .title = "Next chat tab", .keys = "Cmd+Shift+]" },
    .{ .title = "Previous chat tab", .keys = "Cmd+Shift+[" },
    .{ .title = "First chat tab (2–8 for the next ones)", .keys = "Ctrl+1" },
    .{ .title = "Last chat tab", .keys = "Ctrl+9" },
    .{ .title = "Jump to the message box", .keys = "Cmd+L" },
    .{ .title = "Command palette", .keys = "Cmd+K" },
    .{ .title = "Settings", .keys = "Cmd+," },
};

/// "mod-shift-n" as a key-cap shows it, "⇧⌘N" (`badge_combo` on the Mac):
/// the modifiers' glyphs in ⌃⌥⇧⌘ order, then the key, its first letter
/// upper case.
pub fn badge(buf: []u8, combo: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const cut = std.mem.lastIndexOfScalar(u8, combo, '-');
    const key = if (cut) |i| combo[i + 1 ..] else combo;
    const mods = if (cut) |i| combo[0..i] else "";
    const order = [_][2][]const u8{ .{ "ctrl", "⌃" }, .{ "alt", "⌥" }, .{ "shift", "⇧" }, .{ "mod", "⌘" } };
    for (order) |o| {
        var it = std.mem.splitScalar(u8, mods, '-');
        while (it.next()) |part| if (std.mem.eql(u8, part, o[0])) {
            w.writeAll(o[1]) catch {};
            break;
        };
    }
    if (key.len > 0) {
        w.writeByte(std.ascii.toUpper(key[0])) catch {};
        w.writeAll(key[1..]) catch {};
    }
    return w.buffered();
}

/// "mod-shift-r" as the page shows it, "Cmd+Shift+R" (`display_combo`):
/// the stored order, each part named, a key's first letter upper case.
pub fn display(buf: []u8, combo: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var it = std.mem.splitScalar(u8, combo, '-');
    var first = true;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (!first) w.writeByte('+') catch break;
        first = false;
        const name: ?[]const u8 = if (std.mem.eql(u8, part, "mod")) "Cmd" else if (std.mem.eql(u8, part, "alt")) "Opt" else if (std.mem.eql(u8, part, "shift")) "Shift" else if (std.mem.eql(u8, part, "ctrl")) "Ctrl" else null;
        if (name) |n| {
            w.writeAll(n) catch break;
        } else {
            w.writeByte(std.ascii.toUpper(part[0])) catch break;
            w.writeAll(part[1..]) catch break;
        }
    }
    return w.buffered();
}

/// A pressed combination as stored: mod, ctrl, alt, shift, then the key
/// (`combo_from_keystroke_on`); null without Control, Option or Command, or
/// for a key a shortcut can't use.
pub fn fromShortcut(buf: []u8, s: ui.Shortcut) ?[]const u8 {
    if (!s.cmd and !s.ctrl and !s.alt) return null;
    const S = ui.Shortcut;
    const key: []const u8 = switch (s.key) {
        S.tab => "tab",
        S.enter => "enter",
        S.escape => return null,
        S.up => "up",
        S.down => "down",
        S.left => "left",
        S.right => "right",
        else => blk: {
            if (s.key > 127) return null;
            break :blk &[_]u8{std.ascii.toLower(@intCast(s.key))};
        },
    };
    var w: std.Io.Writer = .fixed(buf);
    if (s.cmd) w.writeAll("mod-") catch return null;
    if (s.ctrl) w.writeAll("ctrl-") catch return null;
    if (s.alt) w.writeAll("alt-") catch return null;
    if (s.shift) w.writeAll("shift-") catch return null;
    w.writeAll(key) catch return null;
    return w.buffered();
}

/// ⌘↩ is the composer's, whatever the keymap says.
pub fn reserved(combo: []const u8) bool {
    return std.mem.eql(u8, combo, "mod-enter");
}

const testing = std.testing;

test "combinations shown and stored as the GPUI app's" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Cmd+Shift+R", display(&buf, "mod-shift-r"));
    try testing.expectEqualStrings("Cmd+Opt+W", display(&buf, "mod-alt-w"));
    try testing.expectEqualStrings("Ctrl+Shift+Tab", display(&buf, "ctrl-shift-tab"));
    try testing.expectEqualStrings("Cmd+/", display(&buf, "mod-/"));
    var raw: [64]u8 = undefined;
    try testing.expectEqualStrings("Cmd+Shift+R", display(&buf, fromShortcut(&raw, .{ .key = 'r', .cmd = true, .shift = true }).?));
    try testing.expectEqualStrings("mod-alt-w", fromShortcut(&buf, .{ .key = 'w', .cmd = true, .alt = true }).?);
    try testing.expect(fromShortcut(&buf, .{ .key = 'r' }) == null);
    try testing.expect(fromShortcut(&buf, .{ .key = ui.Shortcut.escape, .cmd = true }) == null);
    try testing.expect(reserved("mod-enter"));
    try testing.expectEqual(@as(usize, 17 + 9), all.len);
    try testing.expectEqualStrings("mod-9", all[all.len - 1].default);
}

test "key-caps as the GPUI app's badges on the Mac (`badge_combos_use_mac_glyphs`)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("⌘1", badge(&buf, "mod-1"));
    try testing.expectEqualStrings("⇧⌘A", badge(&buf, "mod-shift-a"));
    try testing.expectEqualStrings("⇧⌘N", badge(&buf, "shift-mod-n"));
    try testing.expectEqualStrings("⌃⌥⌘Space", badge(&buf, "mod-alt-ctrl-space"));
    try testing.expectEqualStrings("⌘,", badge(&buf, "mod-,"));
    try testing.expectEqualStrings("⌘K", badge(&buf, "mod-k"));
}

/// The command palette's key: fixed, as the GPUI app binds it
/// (`KeyBinding::new(&platform_combo("mod-k"), ToggleCommandPalette)`).
pub const command_palette: ui.Shortcut = .{ .key = 'k', .cmd = true };
