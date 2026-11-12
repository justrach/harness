//! Zig ACP (Agent Client Protocol) & Graff session driver (`crates/harness/src/acp/`).
//!
//! Formats outgoing ACP JSON-RPC 2.0 envelopes (`initialize`, `session/new`,
//! `session/load`, `session/prompt`, `session/cancel`), normalizes incoming
//! `session/update` notifications (`agent_message_chunk`, `agent_thought_chunk`,
//! `tool_call`, `tool_call_update`) directly into a `SessionDoc`, and spawns
//! ACP subprocesses over `std.process.spawn`.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const session_doc = @import("session_doc.zig");

pub const AcpEvent = union(enum) {
    text_delta: struct { msg_id: []const u8, part_id: []const u8, delta: []const u8, total_len: usize },
    reasoning_delta: struct { msg_id: []const u8, part_id: []const u8, delta: []const u8, total_len: usize },
    tool_update: struct { tool_call_id: []const u8, title: []const u8 },
    turn_complete: struct { stop_reason: []const u8 },
    ignored,
};

pub fn encodeInitialize(gpa: Allocator, id: u64) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":1,\"clientCapabilities\":{{}}}}}}\n",
        .{id},
    );
}

pub fn encodeSessionNew(gpa: Allocator, id: u64, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/new\",\"params\":{{\"cwd\":{f},\"mcpServers\":[]}}}}\n",
        .{ id, json.fmt(cwd, .{}) },
    );
}

pub fn encodeSessionLoad(gpa: Allocator, id: u64, session_id: []const u8, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/load\",\"params\":{{\"sessionId\":{f},\"cwd\":{f},\"mcpServers\":[]}}}}\n",
        .{ id, json.fmt(session_id, .{}), json.fmt(cwd, .{}) },
    );
}

pub fn encodeGraffModels(gpa: Allocator, id: u64) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"graff/models\",\"params\":{{}}}}\n",
        .{id},
    );
}

/// Query `graff acp` via the `graff/models` ACP extension (matching `crates/harness/src/acp/graff_models.rs`)
/// and return the top-level JSON array `[...]` of authenticated models for `ListModels`.
pub fn discoverGraffModelsJson(gpa: Allocator, io: std.Io, graff_exe: []const u8) ![]u8 {
    if (comptime !std.process.can_spawn) return error.UnsupportedPlatform;
    var child = try std.process.spawn(io, .{
        .argv = &.{ graff_exe, "acp" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var in_buf: [4096]u8 = undefined;
    var out_buf: [256 * 1024]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &in_buf);
    var reader = child.stdout.?.readerStreaming(io, &out_buf);
    const w = &writer.interface;
    const r = &reader.interface;

    const init_line = try encodeInitialize(gpa, 1);
    defer gpa.free(init_line);
    const new_line = try encodeSessionNew(gpa, 2, "/tmp");
    defer gpa.free(new_line);
    const models_line = try encodeGraffModels(gpa, 3);
    defer gpa.free(models_line);

    try w.writeAll(init_line);
    try w.writeAll(new_line);
    try w.writeAll(models_line);
    try w.flush();

    var lines_read: usize = 0;
    while (lines_read < 64) : (lines_read += 1) {
        const line = (r.takeDelimiter('\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        const id_val = root.get("id") orelse continue;
        if (id_val != .integer or id_val.integer != 3) continue;
        const res_val = root.get("result") orelse break;
        if (res_val != .object) break;
        const rows_val = res_val.object.get("models") orelse break;
        if (rows_val != .array) break;

        var cur_provider: ?[]const u8 = null;
        var cur_model: ?[]const u8 = null;
        if (res_val.object.get("current")) |cur| {
            if (cur == .object) {
                if (cur.object.get("provider")) |p| if (p == .string) {
                    cur_provider = p.string;
                };
                if (cur.object.get("model")) |m| if (m == .string) {
                    cur_model = m.string;
                };
            }
        }

        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const out = &aw.writer;
        try out.writeByte('[');
        var count: usize = 0;

        // First pass: emit the current default model first (if authenticated), then all other authenticated rows.
        for (0..2) |pass| {
            for (rows_val.array.items) |row_val| {
                if (row_val != .object) continue;
                const row = row_val.object;
                const auth = row.get("authenticated") orelse continue;
                if (auth != .bool or !auth.bool) continue;
                const prov_v = row.get("provider") orelse continue;
                const name_v = row.get("name") orelse continue;
                if (prov_v != .string or name_v != .string) continue;
                const prov = prov_v.string;
                const name = name_v.string;
                if (prov.len == 0 or name.len == 0) continue;

                const is_current = (cur_provider != null and cur_model != null and
                    std.mem.eql(u8, cur_provider.?, prov) and std.mem.eql(u8, cur_model.?, name));
                if ((pass == 0 and !is_current) or (pass == 1 and is_current)) continue;

                const maker = if (row.get("maker")) |mv| (if (mv == .string) mv.string else prov) else prov;
                const cost = if (row.get("cost")) |cv| (if (cv == .string) cv.string else "") else "";
                const ctx_num: i64 = if (row.get("context")) |cx| (if (cx == .integer) cx.integer else 200000) else 200000;

                const full_id = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prov, name });
                defer gpa.free(full_id);

                if (count > 0) try out.writeByte(',');
                count += 1;

                try out.print(
                    "{{\"id\":{f},\"label\":{f},\"maker\":{f},\"description\":{f},\"billing\":{f},\"context\":{d},\"reasoningLevels\":[",
                    .{
                        json.fmt(full_id, .{}),
                        json.fmt(name, .{}),
                        json.fmt(maker, .{}),
                        json.fmt(prov, .{}),
                        json.fmt(cost, .{}),
                        ctx_num,
                    },
                );
                if (row.get("effortLevels")) |el| {
                    if (el == .array) {
                        var first_el = true;
                        for (el.array.items) |ev| {
                            if (ev != .string) continue;
                            if (!first_el) try out.writeByte(',');
                            first_el = false;
                            try out.print("{f}", .{json.fmt(ev.string, .{})});
                        }
                    }
                }
                try out.writeAll("]}");
            }
        }
        try out.writeByte(']');
        if (count > 0) return aw.toOwnedSlice();
        aw.deinit();
        break;
    }
    return error.GraffModelsUnavailable;
}

pub fn encodeSessionPrompt(gpa: Allocator, id: u64, session_id: []const u8, prompt_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/prompt\",\"params\":{{\"sessionId\":{f},\"prompt\":[{{\"type\":\"text\",\"text\":{f}}}]}}}}\n",
        .{ id, json.fmt(session_id, .{}), json.fmt(prompt_text, .{}) },
    );
}

pub fn encodeSessionCancel(gpa: Allocator, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{{\"sessionId\":{f}}}}}\n",
        .{json.fmt(session_id, .{})},
    );
}

/// Apply one line of ACP JSON-RPC stdout from `graff` or another ACP agent to `doc`.
pub fn applyAcpLine(
    gpa: Allocator,
    doc: *session_doc.SessionDoc,
    assistant_msg_id: []const u8,
    line: []const u8,
) !AcpEvent {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    return applyAcpLineLeaky(arena.allocator(), doc, assistant_msg_id, line);
}

/// Arena-reusing variant of `applyAcpLine`: parses JSON into `scratch_arena` without
/// creating/destroying a heap arena per streaming token.
pub fn applyAcpLineLeaky(
    scratch_arena: Allocator,
    doc: *session_doc.SessionDoc,
    assistant_msg_id: []const u8,
    line: []const u8,
) !AcpEvent {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .ignored;
    const parsed_val = json.parseFromSliceLeaky(json.Value, scratch_arena, trimmed, .{}) catch return .ignored;
    if (parsed_val != .object) return .ignored;
    const root = parsed_val.object;

    if (root.get("method")) |m| {
        if (m == .string and std.mem.eql(u8, m.string, "session/update")) {
            const params = root.get("params") orelse return .ignored;
            if (params != .object) return .ignored;
            const update = params.object.get("update") orelse return .ignored;
            if (update != .object) return .ignored;
            const kind_val = update.object.get("sessionUpdate") orelse return .ignored;
            if (kind_val != .string) return .ignored;

            if (std.mem.eql(u8, kind_val.string, "agent_message_chunk")) {
                const content = update.object.get("content") orelse return .ignored;
                if (content != .object) return .ignored;
                const text_val = content.object.get("text") orelse return .ignored;
                if (text_val != .string) return .ignored;
                const total = try doc.appendPartDelta(assistant_msg_id, "part-text", "text", text_val.string);
                return .{ .text_delta = .{
                    .msg_id = assistant_msg_id,
                    .part_id = "part-text",
                    .delta = text_val.string,
                    .total_len = total,
                } };
            }
            if (std.mem.eql(u8, kind_val.string, "agent_thought_chunk")) {
                const content = update.object.get("content") orelse return .ignored;
                if (content != .object) return .ignored;
                const text_val = content.object.get("text") orelse return .ignored;
                if (text_val != .string) return .ignored;
                const total = try doc.appendPartDelta(assistant_msg_id, "part-reasoning", "reasoning", text_val.string);
                return .{ .reasoning_delta = .{
                    .msg_id = assistant_msg_id,
                    .part_id = "part-reasoning",
                    .delta = text_val.string,
                    .total_len = total,
                } };
            }
            if (std.mem.eql(u8, kind_val.string, "tool_call") or std.mem.eql(u8, kind_val.string, "tool_call_update")) {
                const tc_id = if (update.object.get("toolCallId")) |v| (if (v == .string) v.string else "tool-1") else "tool-1";
                const title = if (update.object.get("title")) |v| (if (v == .string) v.string else "Tool") else "Tool";
                const status_s = if (update.object.get("status")) |sv| (if (sv == .string) sv.string else "") else "";
                const resolved = std.mem.eql(u8, status_s, "completed") or std.mem.eql(u8, status_s, "failed");
                const is_error = std.mem.eql(u8, status_s, "failed");
                const acp_kind = if (update.object.get("kind")) |kv| (if (kv == .string) kv.string else "") else "";
                const call_json = if (std.mem.eql(u8, acp_kind, "execute"))
                    try std.fmt.allocPrint(scratch_arena, "{{\"kind\":\"exec\",\"command\":{f}}}", .{json.fmt(title, .{})})
                else if (std.mem.eql(u8, acp_kind, "read"))
                    try std.fmt.allocPrint(scratch_arena, "{{\"kind\":\"readFile\",\"path\":{f}}}", .{json.fmt(title, .{})})
                else if (std.mem.eql(u8, acp_kind, "edit"))
                    try std.fmt.allocPrint(scratch_arena, "{{\"kind\":\"editFile\",\"path\":{f}}}", .{json.fmt(title, .{})})
                else if (std.mem.eql(u8, acp_kind, "search"))
                    try std.fmt.allocPrint(scratch_arena, "{{\"kind\":\"search\",\"pattern\":{f}}}", .{json.fmt(title, .{})})
                else
                    try std.fmt.allocPrint(scratch_arena, "{{\"kind\":\"unknown\",\"name\":{f}}}", .{json.fmt(title, .{})});
                try doc.upsertToolPart(assistant_msg_id, tc_id, call_json, null, resolved, is_error);
                return .{ .tool_update = .{ .tool_call_id = tc_id, .title = title } };
            }
        }
    }

    if (root.get("result")) |res| {
        if (res == .object) {
            if (res.object.get("stopReason")) |sr| {
                if (sr == .string) {
                    try doc.setMessageStatus(assistant_msg_id, "complete");
                    return .{ .turn_complete = .{ .stop_reason = sr.string } };
                }
            }
        }
    }
    if (root.get("error")) |err_val| {
        if (err_val == .object) {
            const msg = if (err_val.object.get("message")) |m| (if (m == .string) m.string else "ACP error") else "ACP error";
            _ = try doc.appendPartDelta(assistant_msg_id, "part-text", "text", msg);
            try doc.setMessageStatus(assistant_msg_id, "complete");
            return .{ .turn_complete = .{ .stop_reason = "error" } };
        }
    }
    return .ignored;
}

pub const TurnSessionOptions = struct {
    /// Existing `graff` session ID to resume via `session/load` when continuing on the same checkout.
    resume_session_id: ?[]const u8 = null,
    /// `<earlier-conversation>`-seeded prompt sent ONLY if `session/load` is skipped or fails and
    /// `session/new` starts a fresh session (`crates/engine/src/external_history/mod.rs`).
    fallback_seeded_prompt: ?[]const u8 = null,
    /// Receives a heap-duped slice (`gpa`) of the active `sessionId` established for this turn.
    out_session_id: ?*?[]u8 = null,
};

/// Spawn an ACP agent subprocess (e.g. `graff acp`), resume an existing session via
/// `session/load` when `opts.resume_session_id` is set (draining any replayed history updates
/// until the `session/load` RPC response arrives, and falling back to `session/new` +
/// `opts.fallback_seeded_prompt` on error), and invoke `on_line(ctx, scratch, line)` for each
/// live turn line without holding any external lock across pipe I/O.
pub fn runSubprocessTurnResumable(
    gpa: Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    session_id: []const u8,
    prompt_text: []const u8,
    opts: TurnSessionOptions,
    ctx: *anyopaque,
    on_line: *const fn (ctx: *anyopaque, scratch: Allocator, line: []const u8) bool,
) !void {
    if (comptime !std.process.can_spawn) return error.UnsupportedPlatform;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .cwd = .{ .path = cwd },
    });
    defer child.kill(io);

    var in_buf: [8192]u8 = undefined;
    var out_buf: [65536]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &in_buf);
    var reader = child.stdout.?.readerStreaming(io, &out_buf);
    const w = &writer.interface;
    const r = &reader.interface;

    const init_line = try encodeInitialize(gpa, 1);
    defer gpa.free(init_line);
    try w.writeAll(init_line);

    var resolved_sid: ?[]u8 = null;
    defer if (resolved_sid) |s| gpa.free(s);
    var resumed_ok = false;
    var next_rpc_id: u64 = 2;

    if (opts.resume_session_id) |resume_sid| {
        if (resume_sid.len > 0) {
            const load_id = next_rpc_id;
            next_rpc_id += 1;
            const load_line = try encodeSessionLoad(gpa, load_id, resume_sid, cwd);
            defer gpa.free(load_line);
            try w.writeAll(load_line);
            try w.flush();

            var drain_lines: usize = 0;
            while (drain_lines < 100_000) : (drain_lines += 1) {
                const line = (r.takeDelimiter('\n') catch break) orelse break;
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;
                var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const root = parsed.value.object;
                const id_v = root.get("id") orelse continue;
                if (id_v == .integer and id_v.integer == @as(i64, @intCast(load_id))) {
                    if (root.get("error") == null and root.get("result") != null) {
                        resolved_sid = try gpa.dupe(u8, resume_sid);
                        resumed_ok = true;
                    }
                    break;
                }
            }
        }
    }

    if (!resumed_ok) {
        const new_id = next_rpc_id;
        next_rpc_id += 1;
        const new_line = try encodeSessionNew(gpa, new_id, cwd);
        defer gpa.free(new_line);
        try w.writeAll(new_line);
        try w.flush();

        var handshake_lines: usize = 0;
        while (handshake_lines < 1_024) : (handshake_lines += 1) {
            const line = (r.takeDelimiter('\n') catch break) orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const root = parsed.value.object;
            if (root.get("id")) |id_v| {
                if (id_v == .integer and id_v.integer == @as(i64, @intCast(new_id))) {
                    if (root.get("result")) |res| {
                        if (res == .object) {
                            if (res.object.get("sessionId")) |sid_v| {
                                if (sid_v == .string and sid_v.string.len > 0) {
                                    resolved_sid = try gpa.dupe(u8, sid_v.string);
                                }
                            }
                        }
                    }
                    break;
                }
            }
        }
    }

    const active_sid = resolved_sid orelse session_id;
    if (opts.out_session_id) |out_ptr| {
        if (active_sid.len > 0) {
            out_ptr.* = try gpa.dupe(u8, active_sid);
        }
    }

    const effective_prompt = if (resumed_ok)
        prompt_text
    else
        (opts.fallback_seeded_prompt orelse prompt_text);

    const prompt_id = next_rpc_id;
    const prompt_line = try encodeSessionPrompt(gpa, prompt_id, active_sid, effective_prompt);
    defer gpa.free(prompt_line);
    try w.writeAll(prompt_line);
    try w.flush();

    var line_arena = std.heap.ArenaAllocator.init(gpa);
    defer line_arena.deinit();

    while (true) {
        defer _ = line_arena.reset(.{ .retain_with_limit = 64 * 1024 });
        const line = (r.takeDelimiter('\n') catch break) orelse break;
        if (!on_line(ctx, line_arena.allocator(), line)) break;
    }
}

/// Spawn an ACP agent subprocess (e.g. `graff acp`), stream a prompt turn over
/// stdin/stdout pipes, and invoke `on_line(ctx, scratch, line)` for each stdout line
/// without holding any external lock while blocked on subprocess pipe I/O.
/// Returning `false` from `on_line` terminates the subprocess early (e.g. on `interrupt`).
pub fn runSubprocessTurnLines(
    gpa: Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    session_id: []const u8,
    prompt_text: []const u8,
    ctx: *anyopaque,
    on_line: *const fn (ctx: *anyopaque, scratch: Allocator, line: []const u8) bool,
) !void {
    return runSubprocessTurnResumable(
        gpa,
        io,
        argv,
        cwd,
        session_id,
        prompt_text,
        .{},
        ctx,
        on_line,
    );
}

/// Spawn an ACP agent subprocess (e.g. `graff acp`), stream a prompt turn over
/// stdin/stdout pipes, and fold all `session/update` notifications into `doc`.
pub fn runSubprocessTurn(
    gpa: Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    doc: *session_doc.SessionDoc,
    assistant_msg_id: []const u8,
    session_id: []const u8,
    prompt_text: []const u8,
    on_update_ctx: ?*anyopaque,
    on_update: ?*const fn (ctx: *anyopaque, ev: AcpEvent) void,
) !void {
    const SyncLineCtx = struct {
        doc: *session_doc.SessionDoc,
        assistant_msg_id: []const u8,
        on_update_ctx: ?*anyopaque,
        on_update: ?*const fn (ctx: *anyopaque, ev: AcpEvent) void,

        fn handle(raw: *anyopaque, scratch: Allocator, line: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const ev = applyAcpLineLeaky(scratch, self.doc, self.assistant_msg_id, line) catch return false;
            if (ev != .ignored) {
                if (self.on_update) |cb| cb(self.on_update_ctx.?, ev);
            }
            return ev != .turn_complete;
        }
    };
    var lctx = SyncLineCtx{
        .doc = doc,
        .assistant_msg_id = assistant_msg_id,
        .on_update_ctx = on_update_ctx,
        .on_update = on_update,
    };
    return runSubprocessTurnLines(gpa, io, argv, cwd, session_id, prompt_text, &lctx, SyncLineCtx.handle);
}

test "ACP JSON-RPC stream normalizes chunks and stopReason into SessionDoc" {
    const gpa = testing.allocator;
    var doc = try session_doc.SessionDoc.init(gpa, "chat-acp", "dev-1");
    defer doc.deinit();

    try doc.beginAssistantMessage("msg-a1", 2000);
    _ = try applyAcpLine(
        gpa,
        &doc,
        "msg-a1",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Thinking...\"}}}}",
    );
    _ = try applyAcpLine(
        gpa,
        &doc,
        "msg-a1",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Hello from Zig ACP!\"}}}}",
    );
    const done_ev = try applyAcpLine(
        gpa,
        &doc,
        "msg-a1",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    );
    try testing.expect(done_ev == .turn_complete);
    try testing.expectEqual(@as(usize, 2), doc.messages.items[0].parts.items.len);
    try testing.expectEqualStrings("Thinking...", doc.messages.items[0].parts.items[0].text.items);
    try testing.expectEqualStrings("Hello from Zig ACP!", doc.messages.items[0].parts.items[1].text.items);
    try testing.expectEqualStrings("complete", doc.messages.items[0].status.?);
}

test "runSubprocessTurnResumable drains session/load replay and falls back to seeded session/new" {
    if (comptime !std.process.can_spawn) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;

    const LineFold = struct {
        doc: *session_doc.SessionDoc,
        asst_id: []const u8,
        fn onLine(raw: *anyopaque, scratch: Allocator, line: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const ev = applyAcpLineLeaky(scratch, self.doc, self.asst_id, line) catch return false;
            return ev != .turn_complete;
        }
    };

    // Case A: `session/load` succeeds -> drains replayed `session/update` notifications before `id:2`
    // and sends the clean unseeded `prompt_text`!
    {
        var doc = try session_doc.SessionDoc.init(gpa, "chat-resume-ok", "dev-1");
        defer doc.deinit();
        try doc.beginAssistantMessage("msg-a-ok", 3000);

        const script_ok =
            \\while IFS= read -r line; do
            \\  case "$line" in
            \\    *'"method":"session/load"'*)
            \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-desktop-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"STALE_REPLAY_SHOULD_DRAIN"}}}}'
            \\      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-desktop-1"}}'
            \\      ;;
            \\    *'"method":"session/prompt"'*)
            \\      case "$line" in
            \\        *'SEEDED_FALLBACK_UNUSED'*) reply="BAD_SEEDED" ;;
            \\        *'How do we improve our ranking?'*) reply="RESUMED_CLEAN_OK" ;;
            \\        *) reply="UNEXPECTED" ;;
            \\      esac
            \\      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-desktop-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"$reply\"}}}}"
            \\      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
            \\      exit 0
            \\      ;;
            \\  esac
            \\done
        ;
        const argv = [_][]const u8{ "/bin/sh", "-c", script_ok };
        var established: ?[]u8 = null;
        defer if (established) |s| gpa.free(s);
        var fold = LineFold{ .doc = &doc, .asst_id = "msg-a-ok" };

        try runSubprocessTurnResumable(
            gpa,
            io,
            &argv,
            "/tmp",
            "chat-resume-ok",
            "How do we improve our ranking?",
            .{
                .resume_session_id = "sess-desktop-1",
                .fallback_seeded_prompt = "SEEDED_FALLBACK_UNUSED",
                .out_session_id = &established,
            },
            &fold,
            LineFold.onLine,
        );
        try testing.expectEqualStrings("sess-desktop-1", established.?);
        try testing.expectEqual(@as(usize, 1), doc.messages.items[0].parts.items.len);
        try testing.expectEqualStrings("RESUMED_CLEAN_OK", doc.messages.items[0].parts.items[0].text.items);
    }

    // Case B: `session/load` returns JSON-RPC error -> falls back to `session/new` (`id:3`)
    // and sends `<earlier-conversation>` `fallback_seeded_prompt` (`id:4`)!
    {
        var doc = try session_doc.SessionDoc.init(gpa, "chat-resume-fb", "dev-1");
        defer doc.deinit();
        try doc.beginAssistantMessage("msg-a-fb", 4000);

        const script_fb =
            \\while IFS= read -r line; do
            \\  case "$line" in
            \\    *'"method":"session/load"'*)
            \\      printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"session not found"}}'
            \\      ;;
            \\    *'"method":"session/new"'*)
            \\      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"sess-minted-local-7"}}'
            \\      ;;
            \\    *'"method":"session/prompt"'*)
            \\      case "$line" in
            \\        *'<earlier-conversation>'*'Prior baseline 0.74'*'How do we improve our ranking?'*) reply="FALLBACK_SEEDED_OK" ;;
            \\        *) reply="MISSING_SEED" ;;
            \\      esac
            \\      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-minted-local-7\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"$reply\"}}}}"
            \\      printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
            \\      exit 0
            \\      ;;
            \\  esac
            \\done
        ;
        const argv = [_][]const u8{ "/bin/sh", "-c", script_fb };
        var established: ?[]u8 = null;
        defer if (established) |s| gpa.free(s);
        var fold = LineFold{ .doc = &doc, .asst_id = "msg-a-fb" };

        try runSubprocessTurnResumable(
            gpa,
            io,
            &argv,
            "/tmp",
            "chat-resume-fb",
            "How do we improve our ranking?",
            .{
                .resume_session_id = "sess-remote-missing",
                .fallback_seeded_prompt = "<earlier-conversation>\nAssistant: Prior baseline 0.74\n</earlier-conversation>\n\nHow do we improve our ranking?",
                .out_session_id = &established,
            },
            &fold,
            LineFold.onLine,
        );
        try testing.expectEqualStrings("sess-minted-local-7", established.?);
        try testing.expectEqual(@as(usize, 1), doc.messages.items[0].parts.items.len);
        try testing.expectEqualStrings("FALLBACK_SEEDED_OK", doc.messages.items[0].parts.items[0].text.items);
    }
}
