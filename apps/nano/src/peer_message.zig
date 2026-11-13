//! Presentation metadata for the two deployed peer envelopes. Recognition
//! is not authentication and never changes delivery permissions or storage.
const std = @import("std");
pub const Message = struct { sender: []const u8, body: []const u8 };

pub fn parse(text: []const u8) ?Message {
    const prefix = "[Message from Harness chat ";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const end = std.mem.indexOf(u8, rest, "]\n\n") orelse return null;
    const header = rest[0..end];
    if (std.mem.indexOfAny(u8, header, "\r\n") != null) return null;
    // A title can itself contain either routing phrase. Match the last
    // deployed suffix, with the same precedence as prompt-history filtering.
    const current_marker = ". Sender chat: ";
    const legacy_marker = ". Reply to it with the Harness `send_message` tool, chat ";
    const current = std.mem.lastIndexOf(u8, header, current_marker);
    const legacy = std.mem.lastIndexOf(u8, header, legacy_marker);
    const sender_end = if (current != null and (legacy == null or legacy.? <= current.?)) blk: {
        const metadata = header[current.? + current_marker.len ..];
        if (std.mem.indexOf(u8, metadata, "Agent coordination, not a human request.") == null) return null;
        break :blk current.?;
    } else legacy orelse return null;
    const sender = header[0..sender_end];
    if (std.mem.trim(u8, sender, " \t").len == 0) return null;
    return .{ .sender = sender, .body = rest[end + 3 ..] };
}

pub fn editable(text: []const u8, origin_is_peer: bool) bool {
    return !origin_is_peer and parse(text) == null;
}

test "retention peer rightmost deployed suffix owns sender identity" {
    const raw = "[Message from Harness chat Title. Sender chat: literal title words. Reply to it with the Harness `send_message` tool, chat fixture.]\n\nSynthetic body.";
    const message = parse(raw) orelse return error.MissingPeer;
    try std.testing.expectEqualStrings("Title. Sender chat: literal title words", message.sender);
    try std.testing.expectEqualStrings("Synthetic body.", message.body);
}

test "retention peer current and legacy envelope parsing is presentation only" {
    const t = std.testing;
    for ([_][]const u8{
        "[Message from Harness chat Synthetic sender. Sender chat: fixture. Agent coordination, not a human request.]\n\nSynthetic body.\n\nSecond paragraph.",
        "[Message from Harness chat Synthetic sender. Reply to it with the Harness `send_message` tool, chat fixture.]\n\nSynthetic body.\n\nSecond paragraph.",
    }) |raw| {
        const p = parse(raw).?;
        try t.expectEqualStrings("Synthetic sender", p.sender);
        try t.expectEqualStrings("Synthetic body.\n\nSecond paragraph.", p.body);
        try t.expect(!editable(raw, false));
    }
    for ([_][]const u8{
        "Ordinary human prompt",                                                                                         "Explain: [Message from Harness chat Sender. Sender chat: fixture. Agent coordination, not a human request.]\n\nQuoted body",
        "[Message from Harness chat Sender]\n\nIncomplete envelope",                                                     "[Message from Harness chat Sender. Sender chat: fixture.]\n\nMissing coordination marker",
        "[Message from Harness chat . Reply to it with the Harness `send_message` tool, chat fixture.]\n\nEmpty sender",
    }) |raw| {
        try t.expect(parse(raw) == null);
        try t.expect(editable(raw, false));
    }
    try t.expect(!editable("Structured-origin peer body", true));
}
