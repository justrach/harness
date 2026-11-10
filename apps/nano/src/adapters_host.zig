//! Agent Adapters & External History Importer (`crates/harness/src/{claude,codex,opencode,pi,cursor,external_history}`).
//!
//! Normalizes wire events from:
//! - Claude Code CLI (`--output-format stream-json`)
//! - Codex (`codex app-server` JSON-RPC 2.0 notifications)
//! - OpenCode (`http-zig` HTTP/2 REST API `/session`, `/session/{id}/message`)
//! - Pi & Cursor CLI JSONL streams
//! - Read-only External Conversation Importer (`AGENTS.md` #168: imported
//!   conversations from Claude Code, Codex, or other agents seed a new `graff`
//!   `SessionDoc` and never `--resume` or spend the source agent's credits).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const http_zig = @import("http_zig");
const session_doc = @import("session_doc.zig");

pub const AdapterOutcome = enum {
    delta_applied,
    turn_complete,
    ignored,
};

// -----------------------------------------------------------------------------
// 1. Claude Code CLI JSONL normalizer (`crates/harness/src/claude/normalize.rs`)
// -----------------------------------------------------------------------------
pub fn applyClaudeLine(
    gpa: Allocator,
    doc: *session_doc.SessionDoc,
    assistant_msg_id: []const u8,
    line: []const u8,
) !AdapterOutcome {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .ignored;
    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch return .ignored;
    defer parsed.deinit();
    if (parsed.value != .object) return .ignored;
    const root = parsed.value.object;

    const ty = if (root.get("type")) |v| (if (v == .string) v.string else "") else "";
    if (std.mem.eql(u8, ty, "stream_event")) {
        const ev = root.get("event") orelse return .ignored;
        if (ev != .object) return .ignored;
        const delta = ev.object.get("delta") orelse return .ignored;
        if (delta != .object) return .ignored;
        const d_type = if (delta.object.get("type")) |v| (if (v == .string) v.string else "") else "";
        if (std.mem.eql(u8, d_type, "text_delta")) {
            const txt = if (delta.object.get("text")) |v| (if (v == .string) v.string else "") else "";
            _ = try doc.appendPartDelta(assistant_msg_id, "part-text", "text", txt);
            return .delta_applied;
        }
        if (std.mem.eql(u8, d_type, "thinking_delta")) {
            const txt = if (delta.object.get("thinking")) |v| (if (v == .string) v.string else "") else "";
            _ = try doc.appendPartDelta(assistant_msg_id, "part-reasoning", "reasoning", txt);
            return .delta_applied;
        }
    } else if (std.mem.eql(u8, ty, "assistant")) {
        const msg = root.get("message") orelse return .ignored;
        if (msg != .object) return .ignored;
        if (msg.object.get("content")) |content| if (content == .array) {
            for (content.array.items) |block| {
                if (block != .object) continue;
                const btype = if (block.object.get("type")) |v| (if (v == .string) v.string else "") else "";
                if (std.mem.eql(u8, btype, "text")) {
                    const txt = if (block.object.get("text")) |v| (if (v == .string) v.string else "") else "";
                    _ = try doc.appendPartDelta(assistant_msg_id, "part-text", "text", txt);
                } else if (std.mem.eql(u8, btype, "thinking")) {
                    const txt = if (block.object.get("thinking")) |v| (if (v == .string) v.string else "") else "";
                    _ = try doc.appendPartDelta(assistant_msg_id, "part-reasoning", "reasoning", txt);
                }
            }
            return .delta_applied;
        };
    } else if (std.mem.eql(u8, ty, "result")) {
        try doc.setMessageStatus(assistant_msg_id, "complete");
        return .turn_complete;
    }
    return .ignored;
}

// -----------------------------------------------------------------------------
// 2. Codex App-Server JSON-RPC normalizer (`crates/harness/src/codex/normalize.rs`)
// -----------------------------------------------------------------------------
pub fn applyCodexLine(
    gpa: Allocator,
    doc: *session_doc.SessionDoc,
    assistant_msg_id: []const u8,
    line: []const u8,
) !AdapterOutcome {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .ignored;
    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch return .ignored;
    defer parsed.deinit();
    if (parsed.value != .object) return .ignored;
    const root = parsed.value.object;

    const method = if (root.get("method")) |v| (if (v == .string) v.string else "") else "";
    const params = root.get("params") orelse return .ignored;
    if (params != .object) return .ignored;

    if (std.mem.eql(u8, method, "item/agentMessage/delta")) {
        const delta = if (params.object.get("delta")) |v| (if (v == .string) v.string else "") else "";
        _ = try doc.appendPartDelta(assistant_msg_id, "part-text", "text", delta);
        return .delta_applied;
    }
    if (std.mem.eql(u8, method, "item/reasoning/summaryTextDelta") or std.mem.eql(u8, method, "item/reasoning/textDelta")) {
        const delta = if (params.object.get("delta")) |v| (if (v == .string) v.string else "") else "";
        _ = try doc.appendPartDelta(assistant_msg_id, "part-reasoning", "reasoning", delta);
        return .delta_applied;
    }
    if (std.mem.eql(u8, method, "turn/completed")) {
        try doc.setMessageStatus(assistant_msg_id, "complete");
        return .turn_complete;
    }
    return .ignored;
}

// -----------------------------------------------------------------------------
// 3. Pi & Cursor CLI stream normalizer (`crates/harness/src/{pi,cursor}/`)
// -----------------------------------------------------------------------------
pub fn applyPiOrCursorLine(
    gpa: Allocator,
    doc: *session_doc.SessionDoc,
    assistant_msg_id: []const u8,
    line: []const u8,
) !AdapterOutcome {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .ignored;
    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch return .ignored;
    defer parsed.deinit();
    if (parsed.value != .object) return .ignored;
    const root = parsed.value.object;

    const ty = if (root.get("type")) |v| (if (v == .string) v.string else "") else "";
    if (std.mem.eql(u8, ty, "text_delta")) {
        const delta = if (root.get("delta")) |v| (if (v == .string) v.string else "") else "";
        _ = try doc.appendPartDelta(assistant_msg_id, "part-text", "text", delta);
        return .delta_applied;
    }
    if (std.mem.eql(u8, ty, "thinking_delta")) {
        const delta = if (root.get("delta")) |v| (if (v == .string) v.string else "") else "";
        _ = try doc.appendPartDelta(assistant_msg_id, "part-reasoning", "reasoning", delta);
        return .delta_applied;
    }
    if (std.mem.eql(u8, ty, "agent_end") or std.mem.eql(u8, ty, "turn_end")) {
        try doc.setMessageStatus(assistant_msg_id, "complete");
        return .turn_complete;
    }
    return .ignored;
}

// -----------------------------------------------------------------------------
// 4. OpenCode HTTP/2 Client (`crates/harness/src/opencode/mod.rs`) over `http-zig`
// -----------------------------------------------------------------------------
pub const OpenCodeClient = struct {
    gpa: Allocator,
    io: std.Io,
    base_url: []const u8,

    pub fn sendPrompt(
        self: OpenCodeClient,
        session_id: []const u8,
        prompt_text: []const u8,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "{s}/session/{s}/message",
            .{ std.mem.trimEnd(u8, self.base_url, "/"), session_id },
        );
        defer self.gpa.free(url);

        const body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"parts\":[{{\"type\":\"text\",\"text\":{f}}}]}}",
            .{json.fmt(prompt_text, .{})},
        );
        defer self.gpa.free(body);

        const headers = [_]http_zig.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
        };
        var resp = try http_zig.https.request(self.gpa, self.io, "POST", url, &headers, body);
        defer resp.deinit(self.gpa);
        if (resp.status < 200 or resp.status >= 300) return error.OpenCodeHttpError;
        return self.gpa.dupe(u8, resp.body);
    }
};

// -----------------------------------------------------------------------------
// 5. External Conversation Importer (`AGENTS.md` #168: continue in `graff`)
// -----------------------------------------------------------------------------
pub const ImportedConversation = struct {
    target_harness: []const u8 = "graff",
    source_agent: []const u8,
    imported_messages: usize,
};

/// Import a read-only JSONL transcript from Claude Code, Codex, or another agent
/// into `doc` so the conversation continues in a `graff` session (`AGENTS.md` #168).
/// Never re-launches or `--resume`s the source agent.
pub fn importExternalJsonlToGraffDoc(
    gpa: Allocator,
    doc: *session_doc.SessionDoc,
    source_agent: []const u8,
    jsonl_text: []const u8,
) !ImportedConversation {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, jsonl_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = json.parseFromSlice(json.Value, gpa, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        const role = if (obj.get("role")) |r|
            (if (r == .string) r.string else null)
        else if (obj.get("type")) |t|
            (if (t == .string and (std.mem.eql(u8, t.string, "user") or std.mem.eql(u8, t.string, "assistant"))) t.string else null)
        else
            null;
        const role_str = role orelse continue;

        const content_str: []const u8 = if (obj.get("content")) |c|
            (if (c == .string) c.string else "")
        else if (obj.get("text")) |t|
            (if (t == .string) t.string else "")
        else
            "";
        if (content_str.len == 0) continue;

        count += 1;
        const msg_id = try std.fmt.allocPrint(gpa, "imp-msg-{d}", .{count});
        defer gpa.free(msg_id);
        const part_id = try std.fmt.allocPrint(gpa, "imp-part-{d}", .{count});
        defer gpa.free(part_id);

        if (std.mem.eql(u8, role_str, "user")) {
            try doc.appendUserMessage(msg_id, part_id, content_str, @intCast(1000 + count));
        } else {
            try doc.beginAssistantMessage(msg_id, @intCast(1000 + count));
            _ = try doc.appendPartDelta(msg_id, part_id, "text", content_str);
            try doc.setMessageStatus(msg_id, "complete");
        }
    }
    return .{
        .target_harness = "graff",
        .source_agent = source_agent,
        .imported_messages = count,
    };
}

test "Claude, Codex, Pi/Cursor normalizers and External History Importer (continue in graff #168)" {
    const gpa = testing.allocator;
    var doc = try session_doc.SessionDoc.init(gpa, "chat-adapters", "dev-1");
    defer doc.deinit();

    // 1. Claude stream-json
    try doc.beginAssistantMessage("claude-1", 1000);
    try testing.expectEqual(
        AdapterOutcome.delta_applied,
        try applyClaudeLine(gpa, &doc, "claude-1", "{\"type\":\"stream_event\",\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from Claude\"}}}"),
    );
    try testing.expectEqual(
        AdapterOutcome.turn_complete,
        try applyClaudeLine(gpa, &doc, "claude-1", "{\"type\":\"result\",\"subtype\":\"success\"}"),
    );
    try testing.expectEqualStrings("Hello from Claude", doc.messages.items[0].parts.items[0].text.items);

    // 2. Codex app-server JSON-RPC
    try doc.beginAssistantMessage("codex-1", 2000);
    try testing.expectEqual(
        AdapterOutcome.delta_applied,
        try applyCodexLine(gpa, &doc, "codex-1", "{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"Hello from Codex\"}}"),
    );
    try testing.expectEqual(
        AdapterOutcome.turn_complete,
        try applyCodexLine(gpa, &doc, "codex-1", "{\"method\":\"turn/completed\",\"params\":{}}"),
    );
    try testing.expectEqualStrings("Hello from Codex", doc.messages.items[1].parts.items[0].text.items);

    // 3. External conversation import -> always continues in graff (#168)
    var imported_doc = try session_doc.SessionDoc.init(gpa, "chat-imported", "dev-1");
    defer imported_doc.deinit();
    const res = try importExternalJsonlToGraffDoc(
        gpa,
        &imported_doc,
        "claude",
        "{\"role\":\"user\",\"content\":\"Fix the bug\"}\n{\"role\":\"assistant\",\"content\":\"Here is the fix.\"}\n",
    );
    try testing.expectEqualStrings("graff", res.target_harness);
    try testing.expectEqual(@as(usize, 2), res.imported_messages);
    try testing.expectEqual(@as(usize, 2), imported_doc.messages.items.len);
}
