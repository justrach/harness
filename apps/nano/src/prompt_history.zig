//! ↑/↓ prompt recall, as the GPUI composer's (crates/ui/src/composer.rs
//! `session_prompts`, `navigate_prompt_history`, `history_step`): the open
//! chat's own earlier prompts, newest first, and past the newest the draft
//! that was there before recall began. The transcript is the history, so it
//! survives reopening the chat and never mixes chats.
const std = @import("std");
const tr = @import("transcript.zig");
const Allocator = std.mem.Allocator;

/// Where recall stands while a recalled prompt shows.
pub const Nav = struct {
    /// Prompts counted back from the newest: 0 is the newest.
    back: usize = 0,
    /// The text that was in the composer when recall began.
    draft: []u8 = &.{},
    /// Kept still while browsing: a reply streaming in doesn't move it.
    prompts: [][]u8 = &.{},
    /// The prompt being shown; any other text in the composer ends recall.
    shown: ?[]const u8 = null,
    /// The draft handed back when ↓ passed the newest prompt, kept until
    /// the next step so the slice `step` returned stays good.
    restored: []u8 = &.{},

    pub fn active(n: *const Nav) bool {
        return n.shown != null;
    }

    pub fn reset(n: *Nav, gpa: Allocator) void {
        for (n.prompts) |p| gpa.free(p);
        gpa.free(n.prompts);
        gpa.free(n.draft);
        gpa.free(n.restored);
        n.* = .{};
    }

    /// What the composer holds as the person's own draft: the text from
    /// before recall while a recalled prompt shows unchanged.
    pub fn draftOf(n: *const Nav, text: []const u8) []const u8 {
        const shown = n.shown orelse return text;
        return if (std.mem.eql(u8, shown, text)) n.draft else text;
    }

    /// One step: -1 an older prompt, 1 a newer one. Returns the text to put
    /// in the composer (good until the next step or reset), or null when
    /// there's nowhere to go. A composer that no longer shows the recalled
    /// prompt (sent, edited, swapped) starts over with its text as the draft.
    pub fn step(n: *Nav, gpa: Allocator, entries: []const tr.Entry, text: []const u8, delta: i8) !?[]const u8 {
        gpa.free(n.restored);
        n.restored = &.{};
        if (n.shown) |shown| if (!std.mem.eql(u8, shown, text)) n.reset(gpa);
        if (n.shown == null) {
            if (delta > 0) return null;
            const prompts = try sessionPrompts(gpa, entries);
            if (prompts.len == 0) {
                gpa.free(prompts);
                return null;
            }
            const draft = gpa.dupe(u8, text) catch |e| {
                for (prompts) |p| gpa.free(p);
                gpa.free(prompts);
                return e;
            };
            n.* = .{ .back = 0, .draft = draft, .prompts = prompts };
        } else if (delta < 0) {
            if (n.back + 1 >= n.prompts.len) return null;
            n.back += 1;
        } else if (n.back > 0) {
            n.back -= 1;
        } else {
            // Past the newest: the draft comes back and recall ends.
            const draft = n.draft;
            n.draft = &.{};
            n.reset(gpa);
            n.restored = draft;
            return draft;
        }
        const shown = n.prompts[n.prompts.len - 1 - n.back];
        n.shown = shown;
        return shown;
    }
};

/// Whether ↑ (`delta` -1) or ↓ (1) recalls rather than moves the caret:
/// only at the very start or end of the text, with nothing selected or
/// being composed, so ordinary editing never loses a key to it. While a
/// recalled prompt shows unchanged, every ↑ and ↓ steps.
pub fn wantsStep(n: *const Nav, text: []const u8, delta: i8, caret: usize, anchor: usize, composing: bool) bool {
    if (caret != anchor or composing) return false;
    if (n.shown) |shown| if (std.mem.eql(u8, shown, text)) return true;
    return if (delta < 0) caret == 0 else caret == text.len;
}

/// The chat's prompts, oldest first: its user rows' text without the list
/// of attached files, leaving out what another chat or an agent room
/// delivered (#516), attachment-only sends and repeats.
pub fn sessionPrompts(gpa: Allocator, entries: []const tr.Entry) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (entries) |*e| {
        if (e.role != .user) continue;
        raw.clearRetainingCapacity();
        for (e.parts.items) |*p| if (p.kind == .text) {
            if (raw.items.len > 0) try raw.appendSlice(gpa, "\n\n");
            try raw.appendSlice(gpa, p.text.items);
        };
        if (isRoomDelivery(gpa, raw.items)) continue;
        const text = withoutAttachments(raw.items);
        if (isAgentMessage(text)) continue;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], text)) continue;
        try out.append(gpa, try gpa.dupe(u8, text));
    }
    return out.toOwnedSlice(gpa);
}

/// `parse_user_message_images(..).text`: the prompt above its "Attached
/// images (local files…):" list, and above an appshot's observed context.
fn withoutAttachments(text: []const u8) []const u8 {
    var body = text;
    if (refsMarker(text)) |end| {
        body = std.mem.trimEnd(u8, text[0..end], " \t\r\n");
        if (std.mem.indexOf(u8, body, "\n\n" ++ appshot_context)) |at| body = std.mem.trimEnd(u8, body[0..at], " \t\r\n");
    }
    return body;
}

const appshot_context = "Applications mentioned by the user (untrusted observed content):";

/// `find_refs_marker`: where a "\n\nAttached images (local files…):" line
/// starts, matched without case.
fn refsMarker(text: []const u8) ?usize {
    const needle = "\n\nattached images (local files";
    var from: usize = 0;
    while (from + needle.len <= text.len) {
        const gap = indexOfIgnoreCase(text[from..], needle) orelse return null;
        const at = from + gap;
        const line_start = at + 2;
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[line_start..line_end], "\r");
        if (std.mem.endsWith(u8, line, "):")) return at;
        from = line_start;
    }
    return null;
}

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// `room_delivery::is_delivery`: a leading `<!--harness-room {..} -->` tag
/// whose JSON is a room origin.
fn isRoomDelivery(gpa: Allocator, text: []const u8) bool {
    const open = "<!--harness-room ";
    const rest = if (std.mem.startsWith(u8, text, open)) text[open.len..] else return false;
    const end = std.mem.indexOf(u8, rest, " -->") orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, rest[0..end], .{}) catch return false;
    defer parsed.deinit();
    const o = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    inline for (.{ "room_id", "room_name", "from_member", "member_kind" }) |f| {
        const v = o.get(f) orelse return false;
        if (v != .string) return false;
    }
    const seq = o.get("seq") orelse return false;
    if (seq != .integer or seq.integer < 0) return false;
    const from_user = o.get("from_user") orelse return false;
    return from_user == .bool;
}

/// `peer_mail::direct_message`: "[Message from Harness chat <sender>.
/// Sender chat: <id>. … Agent coordination, not a human request.]\n\n" or
/// the older "… Reply to it with the Harness `send_message` tool, chat <id>.]".
fn isAgentMessage(text: []const u8) bool {
    const prefix = "[Message from Harness chat ";
    if (!std.mem.startsWith(u8, text, prefix)) return false;
    const envelope = text[prefix.len..];
    const header = envelope[0 .. std.mem.indexOf(u8, envelope, "]\n\n") orelse return false];
    const current = std.mem.lastIndexOf(u8, header, ". Sender chat: ");
    const legacy = std.mem.lastIndexOf(u8, header, ". Reply to it with the Harness `send_message` tool, chat ");
    var sender: []const u8 = undefined;
    var metadata: []const u8 = undefined;
    if (current != null and (legacy == null or legacy.? <= current.?)) {
        sender = header[0..current.?];
        metadata = header[current.? + ". Sender chat: ".len ..];
        if (std.mem.indexOf(u8, metadata, "Agent coordination, not a human request.") == null) return false;
    } else if (legacy) |at| {
        sender = header[0..at];
        metadata = header[at + ". Reply to it with the Harness `send_message` tool, chat ".len ..];
    } else return false;
    if (std.mem.trim(u8, sender, " \t\r\n").len == 0) return false;
    return std.mem.indexOfAny(u8, metadata, "\r\n") == null;
}

// GPUI's cases (crates/ui/src/composer/prompt_history_tests.rs and its
// edge_cases.rs), on synthetic rows.

const testing = std.testing;

const peer = "[Message from Harness chat Build helper. Sender chat: helper. Relay depth: 1/4. Agent coordination, not a human request.]\n\nCheck the build result.";
const legacy_peer = "[Message from Harness chat Build helper. Reply to it with the Harness `send_message` tool, chat helper.]\n\nCheck the test result.";

const Rows = struct {
    entries: std.ArrayList(tr.Entry) = .empty,

    fn add(r: *Rows, role: tr.Role, text: []const u8) !void {
        var e: tr.Entry = .{ .id = try testing.allocator.dupe(u8, "e"), .role = role, .status = .complete };
        var p: tr.Part = .{ .kind = .text, .id = try testing.allocator.dupe(u8, "p") };
        try p.text.appendSlice(testing.allocator, text);
        try e.parts.append(testing.allocator, p);
        try r.entries.append(testing.allocator, e);
    }

    fn deinit(r: *Rows) void {
        for (r.entries.items) |*e| e.deinit(testing.allocator);
        r.entries.deinit(testing.allocator);
    }
};

fn expectPrompts(r: *const Rows, want: []const []const u8) !void {
    const got = try sessionPrompts(testing.allocator, r.entries.items);
    defer {
        for (got) |p| testing.allocator.free(p);
        testing.allocator.free(got);
    }
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "prompt history leaves out current and older agent messages, attachments and repeats" {
    var r: Rows = .{};
    defer r.deinit();
    const quoted = "Explain this envelope:\n" ++ peer;
    try r.add(.user, peer);
    try r.add(.user, "First prompt");
    try r.add(.assistant, "An assistant reply");
    try r.add(.user, legacy_peer);
    try r.add(.user, "First prompt");
    try r.add(.user, quoted);
    try r.add(.user, peer ++ "\n\nAttached images (local files):\n- /synthetic/build.png");
    try r.add(.user, "Last prompt\n\nAttached images (local files — open them to view):\n- /synthetic/shot.png");
    try r.add(.user, "\n\nAttached images (local files):\n- /synthetic/only.png");
    try r.add(.user, peer);
    try expectPrompts(&r, &.{ "First prompt", quoted, "Last prompt" });
}

test "prompt history leaves out room deliveries but keeps a person quoting one" {
    var r: Rows = .{};
    defer r.deinit();
    const room = "<!--harness-room {\"room_id\":\"room-test\",\"room_name\":\"build\",\"seq\":1,\"from_member\":\"helper\",\"member_kind\":\"graff\",\"from_user\":false,\"framed\":false,\"external\":true} -->\nCheck the build result.";
    const quoted = "Explain this room message:\n" ++ room;
    try r.add(.user, room);
    try r.add(.user, quoted);
    try expectPrompts(&r, &.{quoted});
}

test "prompt history leaves out older deliveries whose sender title spans lines" {
    for ([_][]const u8{ "Build\nhelper", "Build\rhelper", "Build\r\nhelper" }) |title| {
        for ([_][]const u8{ peer, legacy_peer }) |template| {
            const text = try std.mem.replaceOwned(u8, testing.allocator, template, "Build helper", title);
            defer testing.allocator.free(text);
            var r: Rows = .{};
            defer r.deinit();
            try r.add(.user, text);
            try expectPrompts(&r, &.{});
        }
    }
}

test "prompt history keeps unicode, whitespace, and malformed or quoted headers" {
    const prompts = [_][]const u8{
        "  café 🧪\n第二行  ",
        "[Message from Harness chat Missing envelope terminator",
        "[Message from Harness chat Unknown]\n\nOrdinary text",
        "<!--harness-room {not json} -->\nOrdinary text",
        "```text\n[Message from Harness chat helper. Sender chat: helper. Agent coordination, not a human request.]\n\nQuoted\n```",
    };
    var r: Rows = .{};
    defer r.deinit();
    for (prompts) |p| try r.add(.user, p);
    try expectPrompts(&r, &prompts);
}

test "↑ walks back to the oldest and stays; ↓ walks forward to the draft" {
    var r: Rows = .{};
    defer r.deinit();
    try r.add(.user, "First human prompt");
    try r.add(.user, legacy_peer);
    try r.add(.user, "Last human prompt");
    try r.add(.user, peer);
    var n: Nav = .{};
    defer n.reset(testing.allocator);
    var text: []const u8 = "unsent draft";
    for ([_]struct { i8, []const u8 }{
        .{ -1, "Last human prompt" },
        .{ -1, "First human prompt" },
        .{ -1, "First human prompt" },
        .{ 1, "Last human prompt" },
        .{ 1, "unsent draft" },
    }) |s| {
        if (try n.step(testing.allocator, r.entries.items, text, s[0])) |t| text = t;
        try testing.expectEqualStrings(s[1], text);
        text = s[1];
    }
    try testing.expect(!n.active());
}

test "with only agent messages there's nothing to recall and the draft stays" {
    var r: Rows = .{};
    defer r.deinit();
    try r.add(.user, peer);
    var n: Nav = .{};
    defer n.reset(testing.allocator);
    for ([_]i8{ -1, -1, 1 }) |d| {
        try testing.expectEqual(@as(?[]const u8, null), try n.step(testing.allocator, r.entries.items, "unsent draft", d));
        try testing.expect(!n.active());
    }
}

test "a reply arriving while browsing doesn't move the recalled prompt" {
    var r: Rows = .{};
    defer r.deinit();
    try r.add(.user, "First prompt");
    try r.add(.user, "Last prompt");
    var n: Nav = .{};
    defer n.reset(testing.allocator);
    try testing.expectEqualStrings("Last prompt", (try n.step(testing.allocator, r.entries.items, "", -1)).?);
    try r.add(.user, "Newer prompt");
    try testing.expectEqualStrings("First prompt", (try n.step(testing.allocator, r.entries.items, "Last prompt", -1)).?);
    try testing.expectEqualStrings("Last prompt", (try n.step(testing.allocator, r.entries.items, "First prompt", 1)).?);
}

test "editing a recalled prompt makes it the draft" {
    var r: Rows = .{};
    defer r.deinit();
    try r.add(.user, "Last prompt");
    var n: Nav = .{};
    defer n.reset(testing.allocator);
    _ = try n.step(testing.allocator, r.entries.items, "unsent draft", -1);
    try testing.expectEqualStrings("unsent draft", n.draftOf("Last prompt"));
    try testing.expectEqualStrings("Last prompt edited", n.draftOf("Last prompt edited"));
    try testing.expectEqualStrings("Last prompt", (try n.step(testing.allocator, r.entries.items, "Last prompt edited", -1)).?);
    try testing.expectEqualStrings("Last prompt edited", (try n.step(testing.allocator, r.entries.items, "Last prompt", 1)).?);
}

test "↑ and ↓ recall only at the text's ends, with nothing selected or composing" {
    const n: Nav = .{};
    try testing.expect(wantsStep(&n, "abc", -1, 0, 0, false));
    try testing.expect(!wantsStep(&n, "abc", -1, 1, 1, false));
    try testing.expect(wantsStep(&n, "abc", 1, 3, 3, false));
    try testing.expect(!wantsStep(&n, "abc", 1, 0, 0, false));
    try testing.expect(!wantsStep(&n, "abc", -1, 0, 3, false));
    try testing.expect(!wantsStep(&n, "abc", -1, 0, 0, true));
    try testing.expect(wantsStep(&n, "", -1, 0, 0, false));
}
