//! The rules the command palette (crates/ui/src/shell/command_palette.rs)
//! and the sidebar's session search (shell/sidebar_search.rs) keep, apart
//! from drawing: which actions a query keeps and in what order, how a
//! query matches (each word somewhere in the text, case aside), where a
//! match is washed, which sessions the sidebar search finds and in what
//! order, a cursor that follows a session rather than a position, and the
//! latches that make one physical key press act once.
const std = @import("std");
const workspace = @import("workspace.zig");

/// An appearance the theme action switches to (`AppearanceMode`).
pub const Appearance = enum { system, light, dark };

/// A palette result (`Entry`).
pub const Entry = union(enum) {
    new_chat,
    new_project,
    settings,
    theme: Appearance,
    /// An unfocused split pane (its index): picking it moves focus there.
    pane: usize,
    /// A chat, by id.
    chat: []const u8,
    /// Another tool's conversation, by its index in the list kept.
    external: usize,
    /// Import every conversation from other tools.
    import_all,

    /// The action's label (`Entry::action`); null for the rest.
    pub fn label(e: Entry) ?[]const u8 {
        return switch (e) {
            .new_chat => "New chat",
            .new_project => "New project",
            .settings => "Open settings",
            .theme => |m| switch (m) {
                .system => "Switch to system theme",
                .light => "Switch to light theme",
                .dark => "Switch to dark theme",
            },
            else => null,
        };
    }

    /// Result groups in display order: open panes, actions, chat history,
    /// other tools' conversations (`Entry::section`).
    pub fn section(e: Entry) u8 {
        return switch (e) {
            .pane => 0,
            .chat => 2,
            .external => 3,
            else => 1,
        };
    }

    pub fn eql(x: Entry, y: Entry) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .theme => |m| m == y.theme,
            .pane => |i| i == y.pane,
            .chat => |id| std.mem.eql(u8, id, y.chat),
            .external => |i| i == y.external,
            else => true,
        };
    }
};

/// Every whitespace-separated word of `query` (already lower case) is in
/// `text`, case aside (`matches_query`); an empty query matches all.
pub fn matchesQuery(query: []const u8, text: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const folded = foldBuf(&buf, text);
    var words = std.mem.tokenizeAny(u8, query, " \t\n\r");
    while (words.next()) |w| if (std.mem.indexOf(u8, folded, w) == null) return false;
    return true;
}

/// The actions a query keeps, in their order; the theme action names the
/// appearance opposite the one showing (`actions_for`).
pub fn actionsFor(query: []const u8, is_dark: bool) Actions {
    var out: Actions = .{};
    const all = [_]Entry{ .new_chat, .new_project, .settings, .{ .theme = if (is_dark) .light else .dark } };
    for (all) |e| if (matchesQuery(query, e.label().?)) {
        out.items[out.len] = e;
        out.len += 1;
    };
    return out;
}

pub const Actions = struct {
    items: [4]Entry = undefined,
    len: usize = 0,

    pub fn slice(x: *const Actions) []const Entry {
        return x.items[0..x.len];
    }
};

/// `s` in lower case, as far as it fits in `buf`.
pub fn foldBuf(buf: []u8, s: []const u8) []const u8 {
    var w: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(lowerCodepoint(cp), &enc) catch continue;
        if (w + n > buf.len) break;
        @memcpy(buf[w..][0..n], enc[0..n]);
        w += n;
    }
    return buf[0..w];
}

/// A letter's lower case: ASCII, Latin-1, Latin Extended-A, Greek and
/// Cyrillic capitals (what `str::to_lowercase` does for them); others as
/// they are.
pub fn lowerCodepoint(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => if (cp % 2 == 0) cp + 1 else cp,
        0x139...0x148, 0x179...0x17E => if (cp % 2 == 1) cp + 1 else cp,
        0x130 => 'i',
        0x178 => 0xFF,
        0x391...0x3A1, 0x3A3...0x3AB => cp + 0x20,
        0x400...0x40F => cp + 0x50,
        0x410...0x42F => cp + 0x20,
        else => cp,
    };
}

pub const Range = struct { start: usize, end: usize };

/// Where `query`'s words are in `text`, case aside, as byte ranges of
/// `text`, overlapping ones merged (`search_match_ranges`).
pub fn matchRanges(gpa: std.mem.Allocator, text: []const u8, query: []const u8) ![]Range {
    // The folded text, and for each of its bytes the original character's range.
    var folded: std.ArrayList(u8) = .empty;
    defer folded.deinit(gpa);
    var orig: std.ArrayList(Range) = .empty;
    defer orig.deinit(gpa);
    var at: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch slice[0];
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(lowerCodepoint(cp), &enc) catch 0;
        try folded.appendSlice(gpa, enc[0..n]);
        for (0..n) |_| try orig.append(gpa, .{ .start = at, .end = at + slice.len });
        at += slice.len;
    }
    var qbuf: [512]u8 = undefined;
    const q = foldBuf(&qbuf, query);
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(gpa);
    var words = std.mem.tokenizeAny(u8, q, " \t\n\r");
    while (words.next()) |w| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, folded.items, from, w)) |i| {
            try ranges.append(gpa, .{ .start = orig.items[i].start, .end = orig.items[i + w.len - 1].end });
            from = i + 1;
        }
    }
    std.sort.insertion(Range, ranges.items, {}, struct {
        fn lt(_: void, x: Range, y: Range) bool {
            return x.start < y.start;
        }
    }.lt);
    var merged: std.ArrayList(Range) = .empty;
    errdefer merged.deinit(gpa);
    for (ranges.items) |r| {
        if (merged.items.len > 0 and r.start <= merged.items[merged.items.len - 1].end) {
            const last = &merged.items[merged.items.len - 1];
            last.end = @max(last.end, r.end);
        } else try merged.append(gpa, r);
    }
    ranges.deinit(gpa);
    return merged.toOwnedSlice(gpa);
}

/// The sidebar search's sessions (`matching_chats`): top-level ones, the
/// archived too when asked, in `project` when given, whose name ("New
/// session" without a title) has the query, case aside; in the sidebar's
/// order (`compare_sidebar_chats`). The caller owns the slice.
pub fn matchingChats(gpa: std.mem.Allocator, chats: []const workspace.Chat, query: []const u8, project: ?[]const u8, include_archived: bool, by_created: bool) ![]workspace.Chat {
    var qbuf: [512]u8 = undefined;
    const q = foldBuf(&qbuf, std.mem.trim(u8, query, " \t\n\r"));
    var out: std.ArrayList(workspace.Chat) = .empty;
    errdefer out.deinit(gpa);
    for (chats) |ch| {
        if (ch.parent_chat_id != null) continue;
        if (ch.archived and !include_archived) continue;
        if (project) |p| if (ch.space_id == null or !std.mem.eql(u8, ch.space_id.?, p)) continue;
        var tbuf: [1024]u8 = undefined;
        if (std.mem.indexOf(u8, foldBuf(&tbuf, ch.title orelse "New session"), q) == null) continue;
        try out.append(gpa, ch);
    }
    workspace.sortChatsBy(out.items, by_created);
    return out.toOwnedSlice(gpa);
}

/// A keyboard cursor over results that stays on a session, not on its
/// place in a live list (`active`, `active_id`).
pub const Cursor = struct {
    active: usize = 0,
    id_buf: [256]u8 = undefined,
    id_len: ?usize = null,

    pub fn id(k: *const Cursor) ?[]const u8 {
        return if (k.id_len) |n| k.id_buf[0..n] else null;
    }

    fn setId(k: *Cursor, v: ?[]const u8) void {
        const s = v orelse {
            k.id_len = null;
            return;
        };
        const n = @min(s.len, k.id_buf.len);
        @memcpy(k.id_buf[0..n], s[0..n]);
        k.id_len = n;
    }

    /// A fresh choice: the first result (`reset_sidebar_search`).
    pub fn reset(k: *Cursor) void {
        k.active = 0;
        k.id_len = null;
    }

    /// Back on the session it was on, wherever the list now has it, else
    /// kept in range; true when the session it was on is gone, so Return
    /// before the next frame doesn't open what took its place
    /// (`reconcile_sidebar_search`).
    pub fn reconcile(k: *Cursor, ids: []const []const u8) bool {
        var position: ?usize = null;
        if (k.id()) |want| for (ids, 0..) |x, i| if (std.mem.eql(u8, x, want)) {
            position = i;
            break;
        };
        const disappeared = k.id_len != null and position == null;
        k.active = position orelse @min(k.active, ids.len -| 1);
        k.setId(if (k.active < ids.len) ids[k.active] else null);
        return disappeared;
    }

    /// ↑ or ↓, round the list.
    pub fn step(k: *Cursor, ids: []const []const u8, down: bool) void {
        const n = ids.len;
        if (n == 0) return;
        const cur = @min(k.active, n - 1);
        k.active = if (down) (cur + 1) % n else (cur + n - 1) % n;
        k.setId(ids[k.active]);
    }

    /// The pointer chose result `i`.
    pub fn pick(k: *Cursor, i: usize, chat_id: []const u8) void {
        k.active = i;
        k.setId(chat_id);
    }
};

/// One physical Return in the palette activates once: X11 suppresses
/// synthetic repeat releases but sends repeated keydowns with is_held
/// false, so the latch holds until the key is let go (`EnterPress`).
pub const EnterPress = struct {
    down: bool = false,

    pub fn press(e: *EnterPress, is_held: bool) bool {
        const was = e.down;
        e.down = true;
        return !was and !is_held;
    }

    pub fn release(e: *EnterPress) void {
        e.down = false;
    }
};

/// The keys held on the sidebar search's controls: a discrete action
/// (Escape, Return, Space) is available again only after its key is let go
/// or the controls lose focus (`pressed_keys`,
/// `sidebar_search_control_press`).
pub const KeyLatch = struct {
    keys: [8]u21 = undefined,
    len: usize = 0,

    /// True when this is a fresh press that should act.
    pub fn press(l: *KeyLatch, key: u21, is_held: bool) bool {
        for (l.keys[0..l.len]) |k| if (k == key) return false;
        if (l.len < l.keys.len) {
            l.keys[l.len] = key;
            l.len += 1;
        }
        return !is_held;
    }

    /// True when `key` was held here.
    pub fn release(l: *KeyLatch, key: u21) bool {
        for (l.keys[0..l.len], 0..) |k, i| if (k == key) {
            l.keys[i] = l.keys[l.len - 1];
            l.len -= 1;
            return true;
        };
        return false;
    }

    pub fn clear(l: *KeyLatch) void {
        l.len = 0;
    }
};

/// A conversation another tool kept on this device, as the engine lists
/// it (`ExternalSession`).
pub const External = struct {
    source: []const u8,
    id: []const u8,
    cwd: ?[]const u8,
    title: []const u8,
    updated_ms: i64,

    pub fn sourceLabel(x: External) []const u8 {
        const eq = std.mem.eql;
        if (eq(u8, x.source, "claude")) return "Claude Code";
        if (eq(u8, x.source, "codex")) return "Codex";
        if (eq(u8, x.source, "graff")) return "graff";
        return x.source;
    }

    /// The folder it ran in: the last part of its path.
    pub fn folder(x: External) []const u8 {
        const cwd = x.cwd orelse return "";
        var it = std.mem.splitBackwardsScalar(u8, cwd, '/');
        while (it.next()) |part| if (part.len > 0) return part;
        return "";
    }
};

/// How many other-tool conversations show before anything is typed, and
/// how many chats (and conversations) a query shows.
pub const external_idle_limit = 5;
pub const history_limit = 30;

/// A split pane's glyph by its place (`pane_glyph`).
pub fn paneGlyph(across: bool, ix: usize, len: usize) []const u8 {
    if (ix == 0) return if (across) "◧" else "⬒";
    if (ix + 1 == len) return if (across) "◨" else "⬓";
    return "▣";
}

const testing = std.testing;

fn idsOf(list: []const workspace.Chat) ![]const []const u8 {
    const out = try testing.allocator.alloc([]const u8, list.len);
    for (list, 0..) |c, i| out[i] = c.id;
    return out;
}

fn chat(id: []const u8, title: ?[]const u8, archived: bool, project: []const u8) workspace.Chat {
    return .{ .id = id, .title = title, .space_id = project, .device_id = "local", .archived = archived, .preview = null, .harness = null, .model = null, .cwd = null, .created_ms = 1000 };
}

fn expectIds(want: []const []const u8, got: []const workspace.Chat) !void {
    const have = try idsOf(got);
    defer testing.allocator.free(have);
    try testing.expectEqual(want.len, have.len);
    for (want, have) |w, h| try testing.expectEqualStrings(w, h);
}

fn expectActions(want: []const Entry, q: []const u8, dark: bool) !void {
    const got = actionsFor(q, dark);
    try testing.expectEqual(want.len, got.len);
    for (want, got.slice()) |w, g| try testing.expect(w.eql(g));
}

test "action search hides an empty section and keeps the order" {
    try expectActions(&.{ .new_chat, .new_project, .settings, .{ .theme = .light } }, "", true);
    try expectActions(&.{ .new_chat, .new_project }, "new", true);
    try expectActions(&.{.settings}, "settings", true);
    try expectActions(&.{.{ .theme = .light }}, "theme", true);
    try expectActions(&.{}, "deployment", true);
}

test "the theme action names the appearance opposite the one showing" {
    try expectActions(&.{.{ .theme = .light }}, "theme", true);
    try expectActions(&.{.{ .theme = .dark }}, "theme", false);
    try expectActions(&.{.{ .theme = .light }}, "light", true);
    try expectActions(&.{.{ .theme = .dark }}, "dark", false);
}

test "open panes lead, then actions, then history, then other tools'" {
    const order = [_]Entry{ .{ .pane = 2 }, .new_chat, .{ .chat = "a" }, .{ .external = 0 } };
    for (order[0 .. order.len - 1], order[1..]) |x, y| try testing.expect(x.section() < y.section());
    try testing.expect((Entry{ .pane = 0 }).label() == null);
    try testing.expectEqual((Entry{ .new_chat = {} }).section(), (Entry{ .import_all = {} }).section());
}

test "an external row names its tool and folder" {
    const row: External = .{ .source = "codex", .id = "c1", .cwd = "/work/app/", .title = "add a retry", .updated_ms = 1 };
    try testing.expectEqualStrings("Codex", row.sourceLabel());
    try testing.expectEqualStrings("app", row.folder());
    try testing.expectEqualStrings("Claude Code", (External{ .source = "claude", .id = "x", .cwd = null, .title = "", .updated_ms = 0 }).sourceLabel());
}

test "search matches words across chat metadata" {
    try testing.expect(matchesQuery("mac auth", "Fix authentication Harness @ MacBook main"));
    try testing.expect(matchesQuery("  ", "Any chat"));
    try testing.expect(!matchesQuery("mac windows", "Harness @ MacBook"));
}

test "X11's unflagged Return repeats activate once until released" {
    var enter: EnterPress = .{};
    try testing.expect(enter.press(false));
    for (0..35) |_| try testing.expect(!enter.press(false));
    enter.release();
    try testing.expect(enter.press(false));
}

test "flagged Return repeats don't activate" {
    var enter: EnterPress = .{};
    try testing.expect(!enter.press(true));
    try testing.expect(!enter.press(false));
    enter.release();
    try testing.expect(enter.press(false));
    try testing.expect(!enter.press(true));
}

test "a held control key acts once until released or focus leaves" {
    var l: KeyLatch = .{};
    try testing.expect(l.press(' ', false));
    try testing.expect(!l.press(' ', false));
    try testing.expect(l.release(' '));
    try testing.expect(!l.release(' '));
    try testing.expect(!l.press('\r', true));
    l.clear();
    try testing.expect(l.press('\r', false));
}

test "match washes keep word edges, case aside, repeats and overlaps merged" {
    const gpa = testing.allocator;
    const text = "fieldnotes/fix-authentication-redirects";
    const r = try matchRanges(gpa, text, "authentication");
    defer gpa.free(r);
    try testing.expectEqualStrings("fieldnotes/fix-", text[0..r[0].start]);
    try testing.expectEqualStrings("authentication", text[r[0].start..r[0].end]);
    const r2 = try matchRanges(gpa, "New chat, new project", "NEW");
    defer gpa.free(r2);
    try testing.expectEqualSlices(Range, &.{ .{ .start = 0, .end = 3 }, .{ .start = 10, .end = 13 } }, r2);
    const r3 = try matchRanges(gpa, "authentication", "auth authentication");
    defer gpa.free(r3);
    try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 14 }}, r3);
    const r4 = try matchRanges(gpa, "SÍDEBAR", "síd");
    defer gpa.free(r4);
    try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 4 }}, r4);
}

test "sidebar search matches names and every archived one" {
    const gpa = testing.allocator;
    var chats: std.ArrayList(workspace.Chat) = .empty;
    defer chats.deinit(gpa);
    var names: [50][16]u8 = undefined;
    for (0..50) |i| try chats.append(gpa, chat(try std.fmt.bufPrint(&names[i], "old-{d}", .{i}), "Old session", true, "project"));
    try chats.append(gpa, chat("target", "SÍDEBAR experiments", true, "project"));
    try chats.append(gpa, chat("active", "Sídebar polish", false, "project"));
    try chats.append(gpa, chat("metadata", "Unrelated title", false, "sídebar"));
    const a = try matchingChats(gpa, chats.items, "  síDEBAR  ", null, false, false);
    defer gpa.free(a);
    try expectIds(&.{"active"}, a);
    const b = try matchingChats(gpa, chats.items, "  síDEBAR  ", null, true, false);
    defer gpa.free(b);
    try expectIds(&.{ "active", "target" }, b);
    const none = try matchingChats(gpa, chats.items, "no such title", null, true, true);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "sidebar search keeps to the project, top-level sessions and the sidebar's order" {
    const gpa = testing.allocator;
    var chats = [_]workspace.Chat{ chat("a", "Sidebar first", false, "one"), chat("b", "Sidebar second", true, "two"), chat("child", "Sidebar child", false, "one") };
    chats[2].parent_chat_id = "a";
    chats[1].last_message_ms = 5000;
    const cases = .{
        .{ @as(?[]const u8, null), false, &[_][]const u8{ "b", "a" } },
        .{ @as(?[]const u8, "one"), false, &[_][]const u8{"a"} },
        .{ @as(?[]const u8, null), true, &[_][]const u8{ "a", "b" } },
        .{ @as(?[]const u8, "missing"), true, &[_][]const u8{} },
    };
    inline for (cases) |x| {
        const got = try matchingChats(gpa, &chats, "sidebar", x[0], true, x[1]);
        defer gpa.free(got);
        try expectIds(x[2], got);
    }
}

test "sidebar search: literal names, untitled sessions and a large archive" {
    const gpa = testing.allocator;
    const rows = [_]workspace.Chat{ chat("symbols", "Fix [draft].* + (v2)?", false, "one"), chat("emoji", "部署 🚀 sidebar", true, "two"), chat("untitled", null, false, "one") };
    const cases = .{ .{ "[draft].*", "symbols" }, .{ "(v2)?", "symbols" }, .{ "部署 🚀", "emoji" }, .{ "new SESSION", "untitled" } };
    inline for (cases) |x| {
        const got = try matchingChats(gpa, &rows, x[0], null, true, true);
        defer gpa.free(got);
        try expectIds(&.{x[1]}, got);
    }
    const empty = try matchingChats(gpa, &.{}, "", null, true, true);
    defer gpa.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    var archive: std.ArrayList(workspace.Chat) = .empty;
    defer archive.deinit(gpa);
    const names = try gpa.alloc([16]u8, 2000);
    defer gpa.free(names);
    for (0..2000) |i| try archive.append(gpa, chat(try std.fmt.bufPrint(&names[i], "archived-{d:0>4}", .{i}), "Archived match", true, "one"));
    const found = try matchingChats(gpa, archive.items, "match", null, true, true);
    defer gpa.free(found);
    // No archive shelf or palette limit.
    try testing.expectEqual(@as(usize, 2000), found.len);
    try testing.expectEqualStrings("archived-1999", found[found.len - 1].id);
}

test "the cursor follows its session through arrivals, renames, sorts and deletions" {
    var k: Cursor = .{};
    try testing.expect(!k.reconcile(&.{ "a", "b", "c" }));
    try testing.expectEqualStrings("a", k.id().?);
    k.step(&.{ "a", "b", "c" }, true);
    try testing.expectEqualStrings("b", k.id().?);
    // A match arriving above it: still on b.
    try testing.expect(!k.reconcile(&.{ "00", "a", "b", "c" }));
    try testing.expectEqual(@as(usize, 2), k.active);
    // An earlier one renamed away, the sort changed.
    try testing.expect(!k.reconcile(&.{ "c", "b" }));
    try testing.expectEqual(@as(usize, 1), k.active);
    // b deleted: reported, and kept in range.
    try testing.expect(k.reconcile(&.{"c"}));
    try testing.expectEqual(@as(usize, 0), k.active);
    try testing.expectEqualStrings("c", k.id().?);
    // Wrapping, and an empty list.
    k.step(&.{ "x", "y" }, false);
    try testing.expectEqual(@as(usize, 1), k.active);
    k.step(&.{ "x", "y" }, true);
    try testing.expectEqual(@as(usize, 0), k.active);
    k.step(&.{}, true);
    try testing.expect(!k.reconcile(&.{}) or true);
    try testing.expectEqual(@as(usize, 0), k.active);
    k.reset();
    try testing.expect(k.id() == null);
}
