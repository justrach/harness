//! chat2 sync wire codec, catch-up planner, row cursor rule, and HTTP/2
//! checkpoint/row client (`http-zig`), plus the conformance runner for
//! `protocol/chat2-vectors.json` (`crates/sync/tests/chat2_vectors.rs`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const http_zig = @import("http_zig");

pub const FrameType = struct {
    pub const hello: u8 = 0x01;
    pub const state: u8 = 0x02;
    pub const rows_req: u8 = 0x03;
    pub const row: u8 = 0x04;
    pub const rows_done: u8 = 0x05;
    pub const push: u8 = 0x06;
    pub const ack: u8 = 0x07;
    pub const presence: u8 = 0x08;
    pub const probe: u8 = 0x09;
    pub const probe_ok: u8 = 0x0a;
    pub const @"error": u8 = 0x0b;
};

pub const max_header_bytes: usize = 4096;

pub const StateHeader = struct {
    head_seq: u64 = 0,
    seq_floor: u64 = 0,
    checkpoint_seq: u64 = 0,
    checkpoint_size: u64 = 0,
    row_count: u64 = 0,
    row_bytes: u64 = 0,
};

pub const CatchUpPlan = union(enum) {
    rows_only: struct { after: u64 },
    checkpoint_then_rows: struct { after: u64 },
};

/// Decide the catch-up path from the hello state (`crates/sync/src/chat_client.rs`).
pub fn planCatchUp(cursor: u64, state: StateHeader, frontier_contained: bool) CatchUpPlan {
    const cur = if (cursor > state.head_seq) 0 else cursor;
    if (state.checkpoint_size == 0) {
        return .{ .rows_only = .{ .after = cur } };
    }
    if (frontier_contained) {
        return .{ .rows_only = .{ .after = @max(cur, state.checkpoint_seq) } };
    }
    return .{ .checkpoint_then_rows = .{ .after = state.checkpoint_seq } };
}

/// Contiguity rule for each incoming row (`crates/sync/src/chat_client.rs`).
pub fn nextRowCursor(cursor: u64, seq: u64) ?u64 {
    const next_allowed = cursor +| 1;
    if (seq <= next_allowed) return @max(cursor, seq);
    return null;
}

pub const DecodedFrame = struct {
    kind: u8,
    header_parsed: json.Parsed(json.Value),
    payload: []u8,

    pub fn deinit(self: *DecodedFrame, gpa: Allocator) void {
        self.header_parsed.deinit();
        gpa.free(self.payload);
    }
};

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Writes compact JSON with object keys in lexicographical order and no escaped `/`,
/// matching `protocol/chat2-vectors.json`.
pub fn writeCanonicalJsonValue(gpa: Allocator, w: *std.Io.Writer, v: json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try json.Stringify.encodeJsonString(s, .{}, w),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try w.writeByte(',');
                try writeCanonicalJsonValue(gpa, w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            const keys = try gpa.alloc([]const u8, obj.count());
            defer gpa.free(keys);
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                keys[i] = entry.key_ptr.*;
            }
            std.mem.sort([]const u8, keys, {}, lessThanStrings);
            try w.writeByte('{');
            for (keys, 0..) |k, idx| {
                if (idx > 0) try w.writeByte(',');
                try json.Stringify.encodeJsonString(k, .{}, w);
                try w.writeByte(':');
                try writeCanonicalJsonValue(gpa, w, obj.get(k).?);
            }
            try w.writeByte('}');
        },
    }
}

/// Encode `[type u8][headerLen u32 LE][header JSON][payload]`.
pub fn encodeValue(gpa: Allocator, kind: u8, header: json.Value, payload: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeCanonicalJsonValue(gpa, &aw.writer, header);
    const hdr_bytes = aw.written();
    const out = try gpa.alloc(u8, 5 + hdr_bytes.len + payload.len);
    out[0] = kind;
    std.mem.writeInt(u32, out[1..5], @intCast(hdr_bytes.len), .little);
    @memcpy(out[5 .. 5 + hdr_bytes.len], hdr_bytes);
    @memcpy(out[5 + hdr_bytes.len ..], payload);
    return out;
}

/// Decode `[type u8][headerLen u32 LE][header JSON][payload]`. Returns `null` on malformed frames.
pub fn decode(gpa: Allocator, bytes: []const u8) ?DecodedFrame {
    if (bytes.len < 5) return null;
    const kind = bytes[0];
    const header_len: usize = std.mem.readInt(u32, bytes[1..5], .little);
    if (header_len > max_header_bytes or 5 + header_len > bytes.len) return null;
    var parsed = json.parseFromSlice(json.Value, gpa, bytes[5 .. 5 + header_len], .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    const payload = gpa.dupe(u8, bytes[5 + header_len ..]) catch {
        parsed.deinit();
        return null;
    };
    return .{
        .kind = kind,
        .header_parsed = parsed,
        .payload = payload,
    };
}

/// HTTP/2 client for chat2 room sidecars and checkpoints (`crates/engine/src/chat2_host.rs`),
/// powered by `http-zig`.
pub const HttpCheckpointClient = struct {
    gpa: Allocator,
    io: std.Io,
    edge_url: []const u8,
    bearer_token: ?[]const u8 = null,
    chat_id: []const u8,

    pub fn fetchCheckpointFrontier(self: HttpCheckpointClient) !?[]u8 {
        return self.getBytes("/checkpoint/frontier");
    }

    pub fn fetchCheckpoint(self: HttpCheckpointClient) !?[]u8 {
        return self.getBytes("/checkpoint");
    }

    pub fn fetchRows(self: HttpCheckpointClient, after: u64) ![]u8 {
        var suffix_buf: [64]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&suffix_buf, "/rows?after={d}", .{after});
        return (try self.getBytes(suffix)) orelse try self.gpa.alloc(u8, 0);
    }

    fn getBytes(self: HttpCheckpointClient, suffix: []const u8) !?[]u8 {
        const base = std.mem.trimEnd(u8, self.edge_url, "/");
        const url = try std.fmt.allocPrint(self.gpa, "{s}/chat2/{s}{s}", .{ base, self.chat_id, suffix });
        defer self.gpa.free(url);

        var hdr_buf: [1]http_zig.Header = undefined;
        var auth_val: ?[]u8 = null;
        defer if (auth_val) |v| self.gpa.free(v);
        const extra: []const http_zig.Header = if (self.bearer_token) |tok| blk: {
            auth_val = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{tok});
            hdr_buf[0] = .{ .name = "authorization", .value = auth_val.? };
            break :blk hdr_buf[0..1];
        } else &.{};

        var res = try http_zig.https.request(self.gpa, self.io, "GET", url, extra, &.{});
        defer res.deinit();
        if (res.status == 404 or res.status == 204) return null;
        if (res.status != 200) return error.HttpStatus;
        return try self.gpa.dupe(u8, res.body);
    }
};

fn jsonEqual(a: json.Value, b: json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |av| return b == .bool and av == b.bool,
        .integer => |av| return b == .integer and av == b.integer,
        .float => |av| return b == .float and av == b.float,
        .number_string => |av| return b == .number_string and std.mem.eql(u8, av, b.number_string),
        .string => |av| return b == .string and std.mem.eql(u8, av, b.string),
        .array => |arr| {
            if (b != .array or arr.items.len != b.array.items.len) return false;
            for (arr.items, b.array.items) |ai, bi| {
                if (!jsonEqual(ai, bi)) return false;
            }
            return true;
        },
        .object => |obj| {
            if (b != .object or obj.count() != b.object.count()) return false;
            var it = obj.iterator();
            while (it.next()) |e| {
                const bv = b.object.get(e.key_ptr.*) orelse return false;
                if (!jsonEqual(e.value_ptr.*, bv)) return false;
            }
            return true;
        },
    }
}

fn loadVectors(arena: Allocator) !json.Value {
    const protocol_dir = @import("parity_options").protocol_dir;
    const path = try std.fs.path.join(arena, &.{ protocol_dir, "..", "chat2-vectors.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(4 << 20));
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

fn decodeHex(arena: Allocator, hex_str: []const u8) ![]u8 {
    const out = try arena.alloc(u8, hex_str.len / 2);
    _ = try std.fmt.hexToBytes(out, hex_str);
    return out;
}

fn u64At(v: json.Value, key: []const u8) u64 {
    return @intCast(v.object.get(key).?.integer);
}

test "chat2 vectors: frame_type_bytes_and_header_cap" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try loadVectors(ar.allocator());
    const types = v.object.get("frameTypes").?;
    const pairs = [_]struct { name: []const u8, byte: u8 }{
        .{ .name = "hello", .byte = FrameType.hello },
        .{ .name = "state", .byte = FrameType.state },
        .{ .name = "rowsReq", .byte = FrameType.rows_req },
        .{ .name = "row", .byte = FrameType.row },
        .{ .name = "rowsDone", .byte = FrameType.rows_done },
        .{ .name = "push", .byte = FrameType.push },
        .{ .name = "ack", .byte = FrameType.ack },
        .{ .name = "presence", .byte = FrameType.presence },
        .{ .name = "probe", .byte = FrameType.probe },
        .{ .name = "probeOk", .byte = FrameType.probe_ok },
        .{ .name = "error", .byte = FrameType.@"error" },
    };
    for (pairs) |p| {
        try testing.expectEqual(@as(u64, p.byte), u64At(types, p.name));
    }
    try testing.expectEqual(@as(u64, max_header_bytes), u64At(v, "maxHeaderBytes"));
}

test "chat2 vectors: encodes_exact_bytes_and_decodes_them_back" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVectors(a);
    for (v.object.get("encode").?.array.items) |case| {
        const kind: u8 = @intCast(u64At(case, "kind"));
        const payload = try decodeHex(a, case.object.get("payloadHex").?.string);
        const expect_bytes = try decodeHex(a, case.object.get("bytesHex").?.string);
        const header = case.object.get("header").?;

        const encoded = try encodeValue(testing.allocator, kind, header, payload);
        defer testing.allocator.free(encoded);
        try testing.expectEqualSlices(u8, expect_bytes, encoded);

        var decoded = decode(testing.allocator, encoded).?;
        defer decoded.deinit(testing.allocator);
        try testing.expectEqual(kind, decoded.kind);
        try testing.expect(jsonEqual(header, decoded.header_parsed.value));
        try testing.expectEqualSlices(u8, payload, decoded.payload);
    }
}

test "chat2 vectors: decode_rejects_and_accepts" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try loadVectors(a);
    for (v.object.get("decodeRejects").?.array.items) |case| {
        const bytes = try decodeHex(a, case.object.get("bytesHex").?.string);
        var maybe = decode(testing.allocator, bytes);
        if (maybe) |*f| f.deinit(testing.allocator);
        try testing.expect(maybe == null);
    }
    for (v.object.get("decodeAccepts").?.array.items) |case| {
        const bytes = try decodeHex(a, case.object.get("bytesHex").?.string);
        const payload = try decodeHex(a, case.object.get("payloadHex").?.string);
        var frame = decode(testing.allocator, bytes).?;
        defer frame.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, frame.kind), u64At(case, "kind"));
        try testing.expect(jsonEqual(case.object.get("header").?, frame.header_parsed.value));
        try testing.expectEqualSlices(u8, payload, frame.payload);
    }
}

test "chat2 vectors: plans_catch_up" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try loadVectors(ar.allocator());
    for (v.object.get("catchUp").?.array.items) |case| {
        const st = case.object.get("state").?;
        const state: StateHeader = .{
            .head_seq = u64At(st, "headSeq"),
            .checkpoint_seq = u64At(st, "checkpointSeq"),
            .checkpoint_size = u64At(st, "checkpointSize"),
        };
        const plan = planCatchUp(
            u64At(case, "cursor"),
            state,
            case.object.get("frontierContained").?.bool,
        );
        const expect_obj = case.object.get("expect").?;
        const expect_after = u64At(expect_obj, "after");
        const expect_plan = expect_obj.object.get("plan").?.string;
        if (std.mem.eql(u8, expect_plan, "rowsOnly")) {
            try testing.expectEqual(CatchUpPlan{ .rows_only = .{ .after = expect_after } }, plan);
        } else if (std.mem.eql(u8, expect_plan, "checkpointThenRows")) {
            try testing.expectEqual(CatchUpPlan{ .checkpoint_then_rows = .{ .after = expect_after } }, plan);
        } else {
            return error.UnknownCatchUpPlan;
        }
    }
}

test "chat2 vectors: walks_the_row_cursor" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const v = try loadVectors(ar.allocator());
    const rc = v.object.get("rowCursor").?;
    for (rc.object.get("cases").?.array.items) |case| {
        var cursor = u64At(case, "cursor");
        for (case.object.get("steps").?.array.items) |step| {
            const seq = u64At(step, "seq");
            const next = nextRowCursor(cursor, seq);
            try testing.expectEqual(step.object.get("gap").?.bool, next == null);
            cursor = next orelse cursor;
            try testing.expectEqual(u64At(step, "cursor"), cursor);
        }
    }
}
