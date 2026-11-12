//! The GPUI transcript's spawn genus and task-title rules, without UI or I/O.
const std = @import("std");

pub const Status = enum { running, done, failed, cancelled, disconnected };

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn name(call: std.json.ObjectMap) ?[]const u8 {
    const kind = str(call, "kind") orelse return null;
    if (std.mem.eql(u8, kind, "unknown")) return str(call, "name");
    if (std.mem.eql(u8, kind, "mcp")) return str(call, "tool");
    return null;
}

/// A stray ref on Run is not a spawn. The call's genus decides, as
/// ToolCall::is_subagent_spawn and transcript::is_agent_wait do in Rust.
pub fn isAgent(call: std.json.ObjectMap) bool {
    const n = name(call) orelse return false;
    return std.mem.eql(u8, n, "Agent") or std.mem.startsWith(u8, n, "Agent: ") or
        (std.mem.eql(u8, str(call, "kind") orelse "", "unknown") and std.mem.startsWith(u8, n, "Wait for agent"));
}

fn taskTitle(text: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "Wait for agent")) {
        const colon = std.mem.indexOf(u8, t, ": ") orelse return null;
        t = t[colon + 2 ..];
    }
    var stripped = false;
    for ([_][]const u8{ "agent", "task" }) |prefix| {
        if (t.len < prefix.len or !std.ascii.eqlIgnoreCase(t[0..prefix.len], prefix)) continue;
        const rest = t[prefix.len..];
        if (rest.len == 0 or rest[0] == ':' or std.ascii.isWhitespace(rest[0])) {
            t = std.mem.trim(u8, std.mem.trimStart(u8, rest, ":"), " \t\r\n");
            stripped = true;
        }
        break;
    }
    if (t.len == 0 or std.ascii.eqlIgnoreCase(t, "subagent")) return null;
    if (stripped) {
        const numeric = for (t) |ch| {
            if (!std.ascii.isDigit(ch)) break false;
        } else true;
        if (numeric) return null;
    }
    return t;
}

fn titleLine(line: []const u8) ?[]const u8 {
    var text = line;
    var hashes: usize = 0;
    while (hashes < text.len and text[hashes] == '#') : (hashes += 1) {}
    if (hashes > 0 and hashes <= 6 and hashes < text.len and std.ascii.isWhitespace(text[hashes])) {
        text = text[hashes..];
    }
    text = std.mem.trim(u8, text, " \t*_`");
    if (text.len == 0) return null;
    for ([_][]const u8{ "Context", "Instructions", "System", "Task", "Prompt", "Role", "Constraints" }) |boilerplate| {
        if (std.ascii.eqlIgnoreCase(text, boilerplate)) return null;
    }
    return text;
}

/// An owned, plain first-line title, capped at GPUI's 40 Unicode characters.
/// Prefer the explicit task description over a title synthesized from a prompt.
pub fn title(gpa: std.mem.Allocator, call: std.json.ObjectMap) std.mem.Allocator.Error!?[]u8 {
    if (!isAgent(call)) return null;
    const input = if (call.get("input")) |v| (if (v == .object) v.object else null) else null;
    const candidates = [_]?[]const u8{
        if (input) |o| str(o, "description") else null,
        name(call),
        if (input) |o| str(o, "prompt") else null,
    };
    for (candidates) |candidate| {
        const task = taskTitle(candidate orelse continue) orelse continue;
        var lines = std.mem.tokenizeAny(u8, task, "\r\n");
        while (lines.next()) |line| {
            const raw = std.mem.trim(u8, line, " \t");
            if (raw.len == 0) continue;
            // A prompt's context/role is not its task. Don't fall through
            // into that section's body and turn background prose into a title.
            const text = titleLine(raw) orelse break;
            const utf8 = std.unicode.Utf8View.init(text) catch continue;
            var it = utf8.iterator();
            var end: usize = 0;
            var count: usize = 0;
            while (count < 40) : (count += 1) {
                const codepoint = it.nextCodepointSlice() orelse break;
                end += codepoint.len;
            }
            return try std.fmt.allocPrint(gpa, "{s}{s}", .{ text[0..end], if (end < text.len) "…" else "" });
        }
    }
    return null;
}

test "agent links use task names, metadata fallback and real spawn calls, never worker numbers" {
    const cases = [_]struct { call: []const u8, expected: ?[]const u8 }{
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent: Audit links\"}", .expected = "Audit links" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent: ## Context\\nSynthetic background\",\"input\":{\"description\":\"Check glyph clipping\"}}", .expected = "Check glyph clipping" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Wait for agent 7: ## Context\",\"input\":{\"description\":\"Task: **Review synthetic glyphs**\"}}", .expected = "Review synthetic glyphs" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent: ## Review synthetic links\"}", .expected = "Review synthetic links" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent: ## Context\\nSynthetic background\"}", .expected = null },
        .{ .call = "{\"kind\":\"mcp\",\"tool\":\"Agent: Check browser\"}", .expected = "Check browser" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent\",\"input\":{\"description\":\"Task: Inspect icons\"}}", .expected = "Inspect icons" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent: 42\"}", .expected = null },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent: Taskmaster\"}", .expected = "Taskmaster" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Wait for agent 3: Audit links\"}", .expected = "Audit links" },
        .{ .call = "{\"kind\":\"unknown\",\"name\":\"Agent\"}", .expected = null },
        .{ .call = "{\"kind\":\"exec\",\"command\":\"Agent: not a spawn\"}", .expected = null },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.call, .{});
        defer parsed.deinit();
        const got = try title(std.testing.allocator, parsed.value.object);
        defer if (got) |s| std.testing.allocator.free(s);
        if (case.expected) |expected| try std.testing.expectEqualStrings(expected, got.?) else try std.testing.expect(got == null);
    }
}
