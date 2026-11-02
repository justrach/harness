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
    gate: Gate = .none,
    /// Sent by an agent (a peer chat), not typed here.
    agent: bool = false,
};

pub const Rows = ws.List(Row, parseRow);

fn parseRow(a: Allocator, o: json.ObjectMap) ?Row {
    var r: Row = .{ .id = ws.str(a, o, "id") orelse return null, .text = ws.str(a, o, "text") orelse "" };
    if (o.get("attachments")) |v| if (v == .array) {
        r.attachments = v.array.items.len;
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

/// A row's text on one line: runs of whitespace become one space.
pub fn oneLine(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |ch| {
        if (n == buf.len) break;
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
    try testing.expect(rows.items[2].gate == .review and rows.items[2].agent);
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("fix the tests", oneLine(&b, rows.items[0].text));
}
