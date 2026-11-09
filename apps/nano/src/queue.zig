//! Messages waiting for the agent's turn to end (`WatchQueue`,
//! crates/doc/src/queue.rs): each frame is the whole queue again. A row may
//! be held: being edited on a device (`editing`), or left for review after
//! its edit expired (`reviewRequired`).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const ws = @import("workspace.zig");

pub const Gate = union(enum) {
    none,
    editing: []const u8,
    review,
};

pub const Row = struct {
    id: []const u8,
    text: []const u8,
    attachments: usize = 0,
    paths: []const []const u8 = &.{},
    gate: Gate = .none,
    /// Sent by an agent (a peer chat), not typed here.
    agent: bool = false,
};

pub const Rows = ws.List(Row, parseRow);

fn parseRow(a: Allocator, o: json.ObjectMap) ?Row {
    var r: Row = .{ .id = ws.str(a, o, "id") orelse return null, .text = ws.str(a, o, "text") orelse "" };
    if (o.get("attachments")) |v| if (v == .array) {
        r.attachments = v.array.items.len;
        var paths: std.ArrayList([]const u8) = .empty;
        for (v.array.items) |path| if (path == .string) {
            const copy = a.dupe(u8, path.string) catch return null;
            paths.append(a, copy) catch return null;
        };
        r.paths = paths.toOwnedSlice(a) catch return null;
    };
    if (ws.str(a, o, "turnOrigin")) |origin| r.agent = !std.mem.eql(u8, origin, "human");
    if (o.get("deliveryGate")) |g| if (g == .object) {
        const kind = ws.str(a, g.object, "kind") orelse "";
        if (std.mem.eql(u8, kind, "editing")) r.gate = .{ .editing = ws.str(a, g.object, "ownerDeviceId") orelse "another device" };
        if (std.mem.eql(u8, kind, "reviewRequired")) r.gate = .review;
    };
    return r;
}

/// The rows in a `WatchQueue` item (`{items, pendingPrompts}`).
pub fn items(v: json.Value) json.Value {
    if (v == .object) if (v.object.get("items")) |i| return i;
    return .{ .array = .init(std.heap.page_allocator) };
}

/// A row's text on one line: runs of whitespace become one space, and
/// validated canonical `harness-invoke:` links project to `/cmd` or `$skill`.
pub fn oneLine(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var space = false;
    const refs = @import("attachment_refs.zig");
    var scratch: [1024]u8 = undefined;
    var temp: std.heap.BufferFirstAllocator = .init(&scratch, std.heap.page_allocator);
    const parsed = refs.parse(temp.allocator(), text) catch refs.Parsed{ .text = text };
    defer refs.deinit(temp.allocator(), parsed);
    const raw = std.mem.trim(u8, parsed.text, " \t\r\n");
    var i: usize = 0;
    var decode_buf: [512]u8 = undefined;
    while (i < raw.len) {
        if (n == buf.len) break;
        if (canonicalInvocationAt(raw, i, &decode_buf)) |inv| {
            if (space and n + 1 < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
            space = false;
            if (n < buf.len) {
                buf[n] = inv.prefix;
                n += 1;
            }
            const copy_n = @min(inv.name.len, buf.len - n);
            @memcpy(buf[n .. n + copy_n], inv.name[0..copy_n]);
            n += copy_n;
            i = inv.end;
            continue;
        }
        const ch = raw[i];
        i += 1;
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            space = true;
            continue;
        }
        if (space and n + 1 < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        space = false;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

const InvocationMatch = struct {
    end: usize,
    prefix: u8,
    name: []const u8,
};

fn canonicalInvocationAt(text: []const u8, start: usize, decode_buf: []u8) ?InvocationMatch {
    if (start + 2 >= text.len or text[start] != '[') return null;
    if (start > 0 and (text[start - 1] == '!' or text[start - 1] == '\\')) return null;
    const prefix = text[start + 1];
    if (prefix != '/' and prefix != '$') return null;
    const scheme = "](harness-invoke:";
    var close_bracket: ?usize = null;
    var j: usize = start + 2;
    while (j < text.len) : (j += 1) {
        if (text[j] == '\\' and j + 1 < text.len) {
            j += 1;
            continue;
        }
        if (text[j] == ']') {
            close_bracket = j;
            break;
        }
        if (text[j] == '\n' or text[j] == '\r') return null;
    }
    const cb = close_bracket orelse return null;
    if (cb == start + 2) return null;
    if (!std.mem.startsWith(u8, text[cb..], scheme)) return null;
    const hex_start = cb + scheme.len;
    const rel_end = std.mem.indexOfScalar(u8, text[hex_start..], ')') orelse return null;
    const hex = text[hex_start .. hex_start + rel_end];
    if (hex.len == 0 or hex.len % 2 != 0 or hex.len / 2 > decode_buf.len) return null;
    const decoded = std.fmt.hexToBytes(decode_buf[0 .. hex.len / 2], hex) catch return null;
    var arena_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const val = json.parseFromSliceLeaky(json.Value, fba.allocator(), decoded, .{}) catch return null;
    if (val != .object) return null;
    const kind_v = val.object.get("kind") orelse return null;
    const name_v = val.object.get("name") orelse return null;
    if (kind_v != .string or name_v != .string) return null;
    const name = name_v.string;
    if (!validInvocationName(name)) return null;
    if (std.mem.eql(u8, kind_v.string, "command")) {
        if (prefix != '/' or val.object.count() != 2) return null;
    } else if (std.mem.eql(u8, kind_v.string, "skill")) {
        if (prefix != '$') return null;
        const path_v = val.object.get("path") orelse return null;
        if (path_v != .string or !validSkillPath(path_v.string)) return null;
        if (val.object.get("command")) |cmd_v| {
            if (cmd_v != .object) return null;
            const cn = cmd_v.object.get("name") orelse return null;
            const ch = cmd_v.object.get("harness") orelse return null;
            if (cn != .string or ch != .string or !validSkillCommandName(cn.string)) return null;
            if (val.object.count() != 4) return null;
        } else if (val.object.count() != 3) return null;
    } else return null;
    const label_in_link = text[start + 2 .. cb];
    if (!matchesEscapedLabel(label_in_link, name)) return null;
    if (name.len > decode_buf.len) return null;
    @memcpy(decode_buf[0..name.len], name);
    return .{
        .end = hex_start + rel_end + 1,
        .prefix = prefix,
        .name = decode_buf[0..name.len],
    };
}

fn validInvocationName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (c <= 0x20 or c == 0x7f) return false;
    return true;
}

fn validSkillPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn validSkillCommandName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != ':' and c != '.') return false;
    }
    return true;
}

fn matchesEscapedLabel(escaped: []const u8, raw_name: []const u8) bool {
    var ei: usize = 0;
    for (raw_name) |rc| {
        if (rc == '\\' or rc == '[' or rc == ']') {
            if (ei + 1 >= escaped.len or escaped[ei] != '\\' or escaped[ei + 1] != rc) return false;
            ei += 2;
        } else if (rc == '`') {
            if (ei + 1 < escaped.len and escaped[ei] == '\\' and escaped[ei + 1] == '`') {
                ei += 2;
            } else if (ei < escaped.len and escaped[ei] == '`') {
                ei += 1;
            } else return false;
        } else {
            if (ei >= escaped.len or escaped[ei] != rc) return false;
            ei += 1;
        }
    }
    return ei == escaped.len;
}

const testing = std.testing;

test "rows read their gates, origin and attachments" {
    var rows: Rows = .init(testing.allocator);
    defer rows.deinit();
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"items":[{"id":"a","text":"fix the\n  tests","turnOrigin":"human","issuedBy":"d","issuedAt":1},
        \\ {"id":"b","text":"x","attachments":["p.png"],"deliveryGate":{"kind":"editing","leaseId":"l","ownerDeviceId":"Laptop","ownerInstanceId":"i","acquiredAtMs":1,"expiresAtMs":2,"baseTextHash":"h"}},
        \\ {"id":"c","text":"y","turnOrigin":"peer","deliveryGate":{"kind":"reviewRequired","previousLeaseId":"l","ownerDeviceId":"d","sinceMs":1,"baseTextHash":"h"}}],
        \\ "pendingPrompts":[]}
    , .{});
    defer parsed.deinit();
    try rows.replace(items(parsed.value));
    try testing.expectEqual(@as(usize, 3), rows.items.len);
    try testing.expectEqualStrings("Laptop", rows.items[1].gate.editing);
    try testing.expectEqual(@as(usize, 1), rows.items[1].attachments);
    try testing.expectEqualStrings("p.png", rows.items[1].paths[0]);
    try testing.expect(rows.items[2].gate == .review and rows.items[2].agent);
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("fix the tests", oneLine(&b, rows.items[0].text));
}

test "oneLine projects canonical harness-invoke links without altering malformed or image links" {
    var b: [160]u8 = undefined;
    // {"kind":"command","name":"goal"} -> 7b226b696e64223a22636f6d6d616e64222c226e616d65223a22676f616c227d
    const cmd_link = "[/goal](harness-invoke:7b226b696e64223a22636f6d6d616e64222c226e616d65223a22676f616c227d) write unit tests";
    try testing.expectEqualStrings("/goal write unit tests", oneLine(&b, cmd_link));

    // {"kind":"skill","name":"demo","path":"/tmp/SKILL.md"} -> 7b226b696e64223a22736b696c6c222c226e616d65223a2264656d6f222c2270617468223a222f746d702f534b494c4c2e6d64227d
    const skill_link = "run [$demo](harness-invoke:7b226b696e64223a22736b696c6c222c226e616d65223a2264656d6f222c2270617468223a222f746d702f534b494c4c2e6d64227d) now";
    try testing.expectEqualStrings("run $demo now", oneLine(&b, skill_link));

    // Malformed or mismatched label stays literal.
    const bad_link = "[/other](harness-invoke:7b226b696e64223a22636f6d6d616e64222c226e616d65223a22676f616c227d)";
    try testing.expectEqualStrings(bad_link, oneLine(&b, bad_link));

    // Image alt-text link is not projected.
    const img_link = "![/goal](harness-invoke:7b226b696e64223a22636f6d6d616e64222c226e616d65223a22676f616c227d)";
    try testing.expectEqualStrings(img_link, oneLine(&b, img_link));
}
