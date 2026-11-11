//! Executes all shared mobile parity vectors in `apps/parity/vectors/*.json`
//! and `apps/parity/perf-contract.json` against pure Zig `mobile_parity.zig`
//! and `queue.zig`.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const mp = @import("mobile_parity.zig");
const queue = @import("queue.zig");
const vectors_dir = @import("parity_options").vectors_dir;

fn loadVector(arena: std.mem.Allocator, name: []const u8) !json.Value {
    const path = try std.fs.path.join(arena, &.{ vectors_dir, name });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(8 << 20));
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

fn loadParentFile(arena: std.mem.Allocator, name: []const u8) !json.Value {
    const path = try std.fs.path.join(arena, &.{ vectors_dir, "..", name });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(4 << 20));
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

fn optInt(o: json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn optStr(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

test "mobile parity: presence-rule.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try loadVector(ar.allocator(), "presence-rule.json");
    try testing.expectEqual(mp.live_fresh_ms, v.object.get("liveFreshMs").?.integer);
    try testing.expectEqual(mp.dark_ms, v.object.get("darkMs").?.integer);
    try testing.expectEqual(mp.warmup_ms, v.object.get("warmupMs").?.integer);

    for (v.object.get("cases").?.array.items) |c_val| {
        const c = c_val.object;
        const now = c.get("now").?.integer;
        const received = optInt(c, "received");
        const connected = c.get("connected").?.bool;
        const joined_at = optInt(c, "joinedAt");
        const row_last = optInt(c, "rowLastSeen");

        const st = mp.presenceStatus(now, received, connected, joined_at, row_last);
        const lv = mp.presenceLiveness(now, received, connected, joined_at, row_last);
        const next = mp.presenceNextChange(now, received, connected, joined_at, row_last);

        try testing.expectEqualStrings(c.get("status").?.string, st.name());
        try testing.expectEqualStrings(c.get("liveness").?.string, lv.name());
        try testing.expectEqual(optInt(c, "nextChange"), next);
    }
}

test "mobile parity: home-grouping.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "home-grouping.json");

    var chats: std.ArrayList(mp.HomeChatRef) = .empty;
    for (v.object.get("chats").?.array.items) |ch_v| {
        const o = ch_v.object;
        try chats.append(a, .{
            .id = o.get("id").?.string,
            .space_id = optStr(o, "spaceId"),
            .device_id = o.get("deviceId").?.string,
        });
    }

    for (v.object.get("cases").?.array.items) |case_v| {
        const co = case_v.object;
        var pinned: std.ArrayList([]const u8) = .empty;
        for (co.get("pinned").?.array.items) |pv| try pinned.append(a, pv.string);
        const got = try mp.groupHomeChats(a, chats.items, mp.GroupBy.fromStr(co.get("by").?.string), pinned.items);
        const want = co.get("expect").?.array.items;
        try testing.expectEqual(want.len, got.len);
        for (want, got) |w_val, g_sec| {
            const wo = w_val.object;
            try testing.expectEqualStrings(wo.get("id").?.string, g_sec.id);
            try testing.expectEqualStrings(wo.get("kind").?.string, g_sec.kind);
            const w_chats = wo.get("chats").?.array.items;
            try testing.expectEqual(w_chats.len, g_sec.chats.len);
            for (w_chats, g_sec.chats) |wc, gc| try testing.expectEqualStrings(wc.string, gc);
        }
    }
}

test "mobile parity: composer-stop.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try loadVector(ar.allocator(), "composer-stop.json");
    try testing.expectEqual(mp.stop_grace_ms, v.object.get("graceMs").?.integer);
    for (v.object.get("cases").?.array.items) |c_val| {
        const co = c_val.object;
        const allowed = mp.isStopAllowed(co.get("nowMs").?.integer, optInt(co, "questionClosedAtMs"));
        try testing.expectEqual(co.get("allowed").?.bool, allowed);
    }
}

test "mobile parity: localhost-pages.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "localhost-pages.json");
    for (v.object.get("cases").?.array.items) |c_val| {
        const co = c_val.object;
        const got = try mp.normalizeLocalhostUrl(a, co.get("input").?.string);
        const want = optStr(co, "opens");
        if (want) |w| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(w, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "mobile parity: account-deletion.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "account-deletion.json");
    const model = v.object.get("model").?.object;
    try testing.expectEqualStrings(model.get("noAccount").?.string, mp.account_no_account_copy);
    try testing.expectEqualStrings(model.get("unreachable").?.string, mp.account_unreachable_copy);

    for (v.object.get("cases").?.array.items) |c_val| {
        const co = c_val.object;
        const status: u16 = @intCast(co.get("status").?.integer);
        const got = try mp.parseAccountDeletion(a, status, co.get("body").?.string);
        const eo = co.get("expect").?.object;
        const kind = eo.get("kind").?.string;
        if (std.mem.eql(u8, kind, "deleted")) {
            try testing.expect(got == .deleted);
        } else {
            try testing.expect(got == .refused);
            try testing.expectEqualStrings(eo.get("message").?.string, got.refused.message);
            const tok_v = eo.get("tokens").?;
            if (tok_v == .null) {
                try testing.expect(got.refused.tokens == null);
            } else {
                try testing.expect(got.refused.tokens != null);
                try testing.expectEqualStrings(tok_v.object.get("accessToken").?.string, got.refused.tokens.?.access_token);
                try testing.expectEqualStrings(tok_v.object.get("refreshToken").?.string, got.refused.tokens.?.refresh_token);
            }
        }
    }
}

fn jsonFloat(v: json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

test "mobile parity: annotations.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "annotations.json");
    for (v.object.get("cases").?.array.items) |c_val| {
        const co = c_val.object;
        var marks: std.ArrayList(mp.AnnotationMark) = .empty;
        for (co.get("marks").?.array.items) |mv| {
            const mo = mv.object;
            if (std.mem.eql(u8, mo.get("kind").?.string, "box")) {
                try marks.append(a, .{ .box = .{
                    .x = jsonFloat(mo.get("x").?),
                    .y = jsonFloat(mo.get("y").?),
                    .w = jsonFloat(mo.get("w").?),
                    .h = jsonFloat(mo.get("h").?),
                    .text = mo.get("text").?.string,
                } });
            } else {
                try marks.append(a, .{ .text = .{
                    .x = jsonFloat(mo.get("x").?),
                    .y = jsonFloat(mo.get("y").?),
                    .text = mo.get("text").?.string,
                } });
            }
        }
        const got = try mp.annotationPromptBlock(a, co.get("name").?.string, marks.items);
        const want = optStr(co, "prompt");
        if (want) |w| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(w, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "mobile parity: agent-readiness.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "agent-readiness.json");
    for (v.object.get("cases").?.array.items) |c_val| {
        const co = c_val.object;
        var devs: std.ArrayList(mp.DeviceAgentInput) = .empty;
        for (co.get("devices").?.array.items) |dv| {
            const do = dv.object;
            var entries: std.ArrayList(mp.AgentReportEntry) = .empty;
            if (do.get("agents")) |av| if (av == .array) {
                for (av.array.items) |ag_v| {
                    const ao = ag_v.object;
                    try entries.append(a, .{
                        .id = ao.get("id").?.string,
                        .installed = if (ao.get("installed")) |iv| iv.bool else true,
                        .enabled = if (ao.get("enabled")) |ev| ev.bool else true,
                        .can_install = if (ao.get("canInstall")) |cv| cv.bool else false,
                    });
                }
            };
            try devs.append(a, .{
                .id = do.get("id").?.string,
                .online = do.get("online").?.bool,
                .agents = try entries.toOwnedSlice(a),
            });
        }
        const got = try mp.evalAgentReadiness(a, devs.items);
        const eo = co.get("expect").?.object;
        try testing.expectEqualStrings(eo.get("state").?.string, got.state.name());
        const want_agents = eo.get("agents").?.array.items;
        try testing.expectEqual(@as(usize, 3), want_agents.len);
        for (want_agents, got.agents) |wa_v, ga| {
            const wao = wa_v.object;
            try testing.expectEqualStrings(wao.get("id").?.string, ga.id);
            try testing.expectEqualStrings(wao.get("status").?.string, ga.status.name());
            const w_devs = wao.get("devices").?.array.items;
            try testing.expectEqual(w_devs.len, ga.devices.len);
            for (w_devs, ga.devices) |wd, gd| try testing.expectEqualStrings(wd.string, gd);
        }
    }
}

test "mobile parity: registry-projection.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "registry-projection.json");
    const got = try mp.projectRegistry(a, v.object.get("rows").?.array.items);
    const eo = v.object.get("expect").?.object;

    const want_devs = eo.get("devices").?.array.items;
    const want_names = eo.get("deviceNames").?.array.items;
    const want_caps = eo.get("deviceCapabilities").?.array.items;
    try testing.expectEqual(want_devs.len, got.devices.len);
    for (got.devices, 0..) |d, i| {
        try testing.expectEqualStrings(want_devs[i].string, d.id);
        try testing.expectEqualStrings(want_names[i].string, d.name);
        const wc = want_caps[i].array.items;
        try testing.expectEqual(wc.len, d.capabilities.len);
        for (wc, d.capabilities) |w_cap, g_cap| try testing.expectEqualStrings(w_cap.string, g_cap);
    }

    const want_spaces = eo.get("spaces").?.array.items;
    try testing.expectEqual(want_spaces.len, got.spaces.len);
    for (want_spaces, got.spaces) |ws_v, gs| try testing.expectEqualStrings(ws_v.string, gs.id);

    const want_chats = eo.get("chats").?.array.items;
    try testing.expectEqual(want_chats.len, got.chats.len);
    for (want_chats, got.chats) |wc_v, gc| {
        var rg_buf: [24]u8 = undefined;
        const rg_str: []const u8 = if (gc.room_gen) |rg| try std.fmt.bufPrint(&rg_buf, "{d}", .{rg}) else "-";
        const formatted = try std.fmt.allocPrint(a, "{s}|{s}|{s}|{s}|{s}|{s}|{s}|{d}", .{
            gc.id,
            gc.title orelse "-",
            if (gc.archived) "true" else "false",
            gc.harness orelse "-",
            gc.model orelse "-",
            rg_str,
            gc.space_id orelse "-",
            gc.created_at,
        });
        try testing.expectEqualStrings(wc_v.string, formatted);
    }

    const want_sessions = eo.get("sessions").?.object;
    try testing.expectEqual(want_sessions.count(), got.sessions.len);
    for (got.sessions) |gs| {
        try testing.expectEqualStrings(want_sessions.get(gs.chat_id).?.string, gs.status);
    }

    const want_pinned = eo.get("pinned").?.array.items;
    try testing.expectEqual(want_pinned.len, got.pinned.len);
    for (want_pinned, got.pinned) |wp, gp| try testing.expectEqualStrings(wp.string, gp);

    try testing.expect(!mp.viewerCanMutateChat(false, false));
    try testing.expect(!mp.viewerCanMutateChat(true, true));
    try testing.expect(mp.viewerCanMutateChat(true, false));
}

test "mobile parity: transcript-decode.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "transcript-decode.json");
    for (v.object.get("cases").?.array.items) |c_val| {
        const co = c_val.object;
        const got_entries = try mp.decodeSessionEntries(a, co.get("messages").?.array.items);
        const want_entries = co.get("entries").?.array.items;
        try testing.expectEqual(want_entries.len, got_entries.len);
        for (want_entries, got_entries) |we_v, ge| {
            const weo = we_v.object;
            try testing.expectEqualStrings(weo.get("entry").?.string, try ge.headerLine(a));
            const wp = weo.get("parts").?.array.items;
            try testing.expectEqual(wp.len, ge.parts.len);
            for (wp, ge.parts) |w_part, g_part| try testing.expectEqualStrings(w_part.string, g_part);
        }

        const got_rows = try mp.decodeSessionQueue(a, co.get("queue").?.array.items);
        const want_rows = co.get("rows").?.array.items;
        try testing.expectEqual(want_rows.len, got_rows.len);
        for (want_rows, got_rows) |wr, gr| try testing.expectEqualStrings(wr.string, gr);
    }
}

test "mobile parity: message-queue.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVector(a, "message-queue.json");
    try testing.expectEqualStrings(v.object.get("attachmentOnlyText").?.string, mp.attachment_only_text);

    for (v.object.get("label").?.array.items) |c_val| {
        var buf: [64]u8 = undefined;
        const got = mp.queueLabel(&buf, c_val.object.get("count").?.integer);
        const want = optStr(c_val.object, "expect");
        if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }

    for (v.object.get("oneLine").?.array.items) |c_val| {
        var buf: [256]u8 = undefined;
        const got = queue.oneLine(&buf, c_val.object.get("text").?.string);
        try testing.expectEqualStrings(c_val.object.get("expect").?.string, got);
    }

    for (v.object.get("neighbour").?.array.items) |c_val| {
        const co = c_val.object;
        const got = mp.queueNeighbour(co.get("from").?.integer, co.get("direction").?.integer, co.get("count").?.integer);
        try testing.expectEqual(optInt(co, "expect"), got);
    }

    for (v.object.get("editedText").?.array.items) |c_val| {
        const co = c_val.object;
        const got = mp.queueEditedText(co.get("text").?.string, co.get("hasAttachments").?.bool);
        const want = optStr(co, "expect");
        if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }

    for (v.object.get("visibleText").?.array.items) |c_val| {
        const co = c_val.object;
        const has_att = co.get("attachments").?.array.items.len > 0;
        const got = mp.queueVisibleText(co.get("text").?.string, has_att);
        try testing.expectEqualStrings(co.get("expect").?.string, got);
    }

    for (v.object.get("primaryAction").?.array.items) |c_val| {
        const co = c_val.object;
        const got = mp.queuePrimaryAction(co.get("supportsActions").?.bool, co.get("pending").?.bool, optStr(co, "gate"));
        const want = optStr(co, "expect");
        if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }

    for (v.object.get("acknowledged").?.array.items) |c_val| {
        const co = c_val.object;
        try testing.expectEqual(co.get("expect").?.bool, mp.queueAcknowledged(co.get("action").?.string, co.get("reply").?));
    }

    for (v.object.get("composerEdit").?.array.items) |c_val| {
        const co = c_val.object;
        const got = try mp.queueComposerEdit(a, co.get("leaseText").?.string, co.get("hasAttachments").?.bool, co.get("commit").?.string);
        const want = optStr(co, "expect");
        if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }

    for (v.object.get("editResults").?.array.items) |c_val| {
        const co = c_val.object;
        var res: std.ArrayList([]const u8) = .empty;
        for (co.get("results").?.array.items) |rv| try res.append(a, rv.string);
        try testing.expectEqual(co.get("terminal").?.bool, mp.queueEditTerminal(res.items));
    }

    const moves = v.object.get("moves").?.object;
    var list: std.ArrayList([]const u8) = .empty;
    for (moves.get("texts").?.array.items) |tv| try list.append(a, tv.string);
    for (moves.get("steps").?.array.items) |step_v| {
        const so = step_v.object;
        const is_by = std.mem.eql(u8, so.get("op").?.string, "by");
        const delta = if (is_by) so.get("by").?.integer else so.get("to").?.integer;
        mp.queueMove(list.items, so.get("row").?.string, delta, is_by);
        const want = so.get("expect").?.array.items;
        for (want, list.items) |w_item, g_item| try testing.expectEqualStrings(w_item.string, g_item);
    }
}

test "mobile parity: perf-contract.json" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try loadParentFile(ar.allocator(), "perf-contract.json");
    const spans = v.object.get("spans").?.object;
    const wire = v.object.get("wire").?.object;
    for (std.enums.values(mp.PerfSpan)) |sp| {
        try testing.expectEqual(spans.get(sp.key()).?.integer, sp.budgetMs());
        try testing.expectEqualStrings(wire.get(sp.key()).?.string, sp.wireName());
    }
}
