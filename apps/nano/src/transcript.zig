//! A chat's transcript as `WatchDocMessages` sends it
//! (crates/doc/src/transcript_delta.rs): a `reset` with every entry first,
//! then deltas of `remove`d ids, `upsert`ed entries placed after an anchor,
//! and text `append`ed to a text or reasoning part, with the byte length and
//! entry count they must reach. A delta that doesn't fit is
//! `error.Desync`: the caller resubscribes for a fresh reset, as
//! `apply_transcript_frame` asks of the GPUI app.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const Role = enum { user, assistant, system };
pub const EntryStatus = enum { streaming, complete, aborted };

pub const PartKind = enum { text, reasoning, tool, image, visual, delegation, input, @"error", other };

/// A tool call's kind (`ToolCall`, crates/proto/src/agent.rs).
pub const ToolKind = enum { exec, readFile, writeFile, editFile, applyPatch, search, glob, webFetch, webSearch, todo, mcp, unknown };

/// A question an agent asks (`UserInputQuestion`, crates/proto/src/agent.rs).
pub const Question = struct {
    id: []const u8,
    header: []const u8,
    question: []const u8,
    options: []const []const u8,
    multi_select: bool = false,
    multiline: bool = false,
    prefill: ?[]const u8 = null,
};

/// Recorded tool result, not a working-tree snapshot. No edit timestamp exists
/// in the current protocol; the chart must not turn createdAt into one.
pub const Edit = struct {
    path: []const u8,
    additions: ?u64 = null,
    deletions: ?u64 = null,
    old_text: ?[]const u8 = null,
    new_text: ?[]const u8 = null,
    new_file: bool = false,
};

pub const Part = struct {
    id: []u8,
    kind: PartKind,
    /// Text and reasoning: their text. A tool: what it ran (the command,
    /// path, pattern, URL or tool name). An error: its message.
    text: std.ArrayList(u8) = .empty,
    tool: ToolKind = .unknown,
    /// A tool's chip, as the desktop labels it ("Run", "Agent", "Waiting on").
    chip: []const u8 = "Tool",
    /// The file a tool read or changed, for counting distinct files.
    path: []u8 = &.{},
    /// A tool has finished, or an input request was answered.
    resolved: bool = false,
    is_error: bool = false,
    /// An input part's request and its questions, in `arena`.
    request_id: []const u8 = "",
    questions: []const Question = &.{},
    edits: []const Edit = &.{},
    arena: ?*std.heap.ArenaAllocator = null,

    fn deinit(p: *Part, gpa: Allocator) void {
        gpa.free(p.id);
        gpa.free(p.path);
        p.text.deinit(gpa);
        if (p.arena) |a| {
            a.deinit();
            gpa.destroy(a);
        }
    }
};

pub const Entry = struct {
    id: []u8,
    role: Role,
    status: EntryStatus,
    /// Message creation time only, epoch milliseconds; never an edit time.
    created_at: ?u64 = null,
    parts: std.ArrayList(Part) = .empty,

    fn deinit(e: *Entry, gpa: Allocator) void {
        gpa.free(e.id);
        for (e.parts.items) |*p| p.deinit(gpa);
        e.parts.deinit(gpa);
    }
};

pub const Transcript = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// A reset has come that holds the whole history (not only the tail an
    /// `openingTail` watch sends first).
    complete: bool = false,
    /// The context window used, from the last frame that said.
    tokens: ?u64 = null,
    window: ?u64 = null,

    pub fn deinit(t: *Transcript) void {
        t.clear();
        t.entries.deinit(t.gpa);
    }

    pub fn clear(t: *Transcript) void {
        for (t.entries.items) |*e| e.deinit(t.gpa);
        t.entries.clearRetainingCapacity();
        t.complete = false;
        t.tokens = null;
        t.window = null;
    }

    /// Applies one `TranscriptUpdate`.
    pub fn apply(t: *Transcript, frame: json.Value) !void {
        const o = switch (frame) {
            .object => |o| o,
            else => return error.Desync,
        };
        defer if (o.get("contextUsage")) |u| if (u == .object) {
            t.tokens = uint(u.object.get("tokens"));
            t.window = uint(u.object.get("window"));
        };
        if (o.get("reset")) |r| {
            const pending = if (o.get("historyPending")) |h| h == .bool and h.bool else false;
            // The tail again once the whole history is here: nothing new.
            if (pending and t.complete) return;
            t.clear();
            for (array(r)) |v| try t.entries.append(t.gpa, try parseEntry(t.gpa, v));
            t.complete = !pending;
            return;
        }
        for (array(o.get("remove"))) |v| if (v == .string) if (t.find(v.string)) |i| {
            var gone = t.entries.orderedRemove(i);
            gone.deinit(t.gpa);
        };
        for (array(o.get("upsert"))) |u| {
            if (u != .object) return error.Desync;
            var entry = try parseEntry(t.gpa, u.object.get("entry") orelse return error.Desync);
            errdefer entry.deinit(t.gpa);
            if (t.find(entry.id)) |i| {
                var old = t.entries.orderedRemove(i);
                old.deinit(t.gpa);
            }
            const at: usize = switch (u.object.get("after") orelse .null) {
                .string => |anchor| (t.find(anchor) orelse return error.Desync) + 1,
                else => 0,
            };
            try t.entries.insert(t.gpa, at, entry);
        }
        for (array(o.get("append"))) |a| {
            if (a != .object) return error.Desync;
            const entry_id = string(a.object.get("entry")) orelse return error.Desync;
            const part_id = string(a.object.get("part")) orelse return error.Desync;
            const i = t.find(entry_id) orelse return error.Desync;
            const part = for (t.entries.items[i].parts.items) |*p| {
                if ((p.kind == .text or p.kind == .reasoning) and std.mem.eql(u8, p.id, part_id)) break p;
            } else return error.Desync;
            try part.text.appendSlice(t.gpa, string(a.object.get("text")) orelse "");
            if (part.text.items.len != uint(a.object.get("len")) orelse return error.Desync) return error.Desync;
        }
        if (o.get("count")) |n| if (t.entries.items.len != uint(n) orelse return error.Desync) return error.Desync;
    }

    /// From the back: the target is almost always the live tail entry.
    fn find(t: *Transcript, id: []const u8) ?usize {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, t.entries.items[i].id, id)) return i;
        }
        return null;
    }
};

fn array(v: ?json.Value) []const json.Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn string(v: ?json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn uint(v: ?json.Value) ?u64 {
    const x = v orelse return null;
    return if (x == .integer) std.math.cast(u64, x.integer) else null;
}

fn parseEntry(gpa: Allocator, v: json.Value) !Entry {
    if (v != .object) return error.Desync;
    const o = v.object;
    const role = std.meta.stringToEnum(Role, string(o.get("role")) orelse "") orelse .system;
    const status = std.meta.stringToEnum(EntryStatus, string(o.get("status")) orelse "") orelse .complete;
    var e: Entry = .{ .id = try gpa.dupe(u8, string(o.get("id")) orelse return error.Desync), .role = role, .status = status, .created_at = uint(o.get("createdAt")) };
    errdefer e.deinit(gpa);
    for (array(o.get("parts"))) |p| if (p == .object) try e.parts.append(gpa, try parsePart(gpa, p.object));
    return e;
}

fn parsePart(gpa: Allocator, o: json.ObjectMap) !Part {
    const kind = std.meta.stringToEnum(PartKind, string(o.get("kind")) orelse "") orelse .other;
    var p: Part = .{ .id = try gpa.dupe(u8, string(o.get("id")) orelse ""), .kind = kind };
    errdefer p.deinit(gpa);
    switch (kind) {
        .text, .reasoning => try p.text.appendSlice(gpa, string(o.get("text")) orelse ""),
        .@"error" => try p.text.appendSlice(gpa, string(o.get("message")) orelse ""),
        .tool => {
            p.resolved = if (o.get("resolved")) |r| r == .bool and r.bool else false;
            p.is_error = if (o.get("isError")) |r| r == .bool and r.bool else false;
            try toolCall(gpa, &p, o.get("call"));
            try parseEdits(gpa, &p, o);
        },
        .input => {
            p.resolved = if (o.get("resolved")) |r| r == .bool and r.bool else false;
            try parseQuestions(gpa, &p, o);
        },
        .image => try p.text.appendSlice(gpa, string(o.get("name")) orelse ""),
        .visual => try p.text.appendSlice(gpa, string(o.get("title")) orelse ""),
        .delegation, .other => {},
    }
    return p;
}

fn parseEdits(gpa: Allocator, p: *Part, o: json.ObjectMap) !void {
    if (!p.resolved or p.is_error) return;
    const stats = array(o.get("diffStats"));
    const inline_diff = o.get("diff");
    if (stats.len == 0 and (inline_diff == null or inline_diff.? != .object)) return;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    p.arena = arena;
    const a = arena.allocator();
    var edits: std.ArrayList(Edit) = .empty;
    for (stats) |stat| {
        if (stat != .object) continue;
        const so = stat.object;
        const path = string(so.get("path")) orelse continue;
        if (path.len == 0) continue;
        try edits.append(a, .{ .path = try a.dupe(u8, path), .additions = uint(so.get("additions")), .deletions = uint(so.get("deletions")) });
    }
    if (inline_diff) |d| if (d == .object) {
        const path = string(d.object.get("path")) orelse {
            p.edits = try edits.toOwnedSlice(a);
            return;
        };
        if (path.len == 0) {
            p.edits = try edits.toOwnedSlice(a);
            return;
        }
        var match: ?usize = null;
        for (edits.items, 0..) |edit, i| if (std.mem.eql(u8, edit.path, path)) {
            match = i;
            break;
        };
        if (match == null) {
            try edits.append(a, .{ .path = try a.dupe(u8, path) });
            match = edits.items.len - 1;
        }
        const edit = &edits.items[match.?];
        if (string(d.object.get("oldText"))) |text| edit.old_text = try a.dupe(u8, text);
        if (string(d.object.get("newText"))) |text| edit.new_text = try a.dupe(u8, text);
        edit.new_file = edit.old_text == null;
        // Only new-file line counts are unambiguous without a diff algorithm.
        if (edit.new_file and edit.additions == null) if (edit.new_text) |text| {
            if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) {
                p.edits = try edits.toOwnedSlice(a);
                return;
            }
            edit.additions = if (text.len == 0) 0 else std.mem.count(u8, text, "\n") + @as(u64, if (text[text.len - 1] == '\n') 0 else 1);
            edit.deletions = 0;
        };
    };
    p.edits = try edits.toOwnedSlice(a);
}

fn parseQuestions(gpa: Allocator, p: *Part, o: json.ObjectMap) !void {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    p.arena = arena;
    const a = arena.allocator();
    p.request_id = try a.dupe(u8, string(o.get("requestId")) orelse p.id);
    var qs: std.ArrayList(Question) = .empty;
    for (array(o.get("questions"))) |q| {
        if (q != .object) continue;
        const qo = q.object;
        var opts: std.ArrayList([]const u8) = .empty;
        for (array(qo.get("options"))) |opt| if (opt == .string) try opts.append(a, try a.dupe(u8, opt.string));
        try qs.append(a, .{
            .id = try a.dupe(u8, string(qo.get("id")) orelse ""),
            .header = try a.dupe(u8, string(qo.get("header")) orelse ""),
            .question = try a.dupe(u8, string(qo.get("question")) orelse ""),
            .options = opts.items,
            .multi_select = if (qo.get("multiSelect")) |v| v == .bool and v.bool else false,
            .multiline = if (qo.get("multiline")) |v| v == .bool and v.bool else false,
            .prefill = if (string(qo.get("prefill"))) |s| try a.dupe(u8, s) else null,
        });
    }
    p.questions = qs.items;
}

/// A tool call (`ToolCall`, tagged by `kind`; fields keep their Rust
/// names): its kind, what it ran, and the file it touched.
fn toolCall(gpa: Allocator, p: *Part, call: ?json.Value) !void {
    const c = call orelse return;
    if (c != .object) return;
    const o = c.object;
    p.tool = std.meta.stringToEnum(ToolKind, string(o.get("kind")) orelse "") orelse .unknown;
    // The file a write, edit or patch touched, for counting distinct files.
    if (p.tool == .writeFile or p.tool == .editFile or p.tool == .applyPatch) {
        if (string(o.get("path"))) |f| p.path = try gpa.dupe(u8, f);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c_ = @import("tools.zig").chipContent(arena.allocator(), o);
    p.chip = c_.label;
    try p.text.appendSlice(gpa, c_.detail);
}

const testing = std.testing;

fn applyText(t: *Transcript, text: []const u8) !void {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
}

test "a reset, then an upsert after an anchor, then streamed text" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t,
        \\{"reset":[{"id":"u1","role":"user","parts":[{"kind":"text","id":"p","text":"hi"}],"createdAt":1,"deviceId":"d"}],
        \\ "contextUsage":{"tokens":10,"window":200}}
    );
    try testing.expect(t.complete);
    try testing.expectEqual(@as(?u64, 200), t.window);
    try applyText(&t,
        \\{"upsert":[{"after":"u1","entry":{"id":"a1","role":"assistant","status":"streaming",
        \\  "parts":[{"kind":"text","id":"t","text":"Hel"}],"createdAt":2,"deviceId":"d"}}],"count":2}
    );
    try applyText(&t,
        \\{"append":[{"entry":"a1","part":"t","text":"lo","len":5}],"count":2}
    );
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    try testing.expectEqualStrings("Hello", t.entries.items[1].parts.items[0].text.items);
    try testing.expectEqual(EntryStatus.streaming, t.entries.items[1].status);
}

test "a delta that doesn't fit is a desync" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"kind":"text","id":"t","text":"ab"}]}]}
    );
    try testing.expectError(error.Desync, applyText(&t, "{\"append\":[{\"entry\":\"a\",\"part\":\"t\",\"text\":\"c\",\"len\":9}]}"));
    t.clear();
    try applyText(&t, "{\"reset\":[]}");
    try testing.expectError(error.Desync, applyText(&t,
        \\{"upsert":[{"after":"missing","entry":{"id":"x","role":"user","parts":[]}}]}
    ));
    try testing.expectError(error.Desync, applyText(&t, "{\"count\":3}"));
}

test "the tail first, the whole history after, and the tail again ignored" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t, "{\"reset\":[{\"id\":\"b\",\"role\":\"user\",\"parts\":[]}],\"historyPending\":true}");
    try testing.expect(!t.complete);
    try applyText(&t, "{\"reset\":[{\"id\":\"a\",\"role\":\"user\",\"parts\":[]},{\"id\":\"b\",\"role\":\"user\",\"parts\":[]}]}");
    try applyText(&t, "{\"reset\":[{\"id\":\"b\",\"role\":\"user\",\"parts\":[]}],\"historyPending\":true}");
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
}

test "an input part keeps its request and questions" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"kind":"input","id":"r1","requestId":"r1","resolved":false,
        \\  "questions":[{"id":"q1","header":"Approach","question":"Which one?","options":["A","B"],"multiSelect":true}]}]}]}
    );
    const p = &t.entries.items[0].parts.items[0];
    try testing.expectEqualStrings("r1", p.request_id);
    try testing.expectEqual(@as(usize, 2), p.questions[0].options.len);
    try testing.expect(p.questions[0].multi_select);
    try testing.expect(!p.resolved);
}

test "remove, a tool's summary, and replacing an entry by id" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"kind":"tool","id":"k","resolved":true,"isError":false,
        \\  "call":{"kind":"exec","command":"zig build test"}}]},{"id":"b","role":"user","parts":[]}]}
    );
    try testing.expectEqualStrings("zig build test", t.entries.items[0].parts.items[0].text.items);
    try testing.expectEqualStrings("Run", t.entries.items[0].parts.items[0].chip);
    try testing.expectEqual(ToolKind.exec, t.entries.items[0].parts.items[0].tool);
    try applyText(&t,
        \\{"remove":["b"],"upsert":[{"after":null,"entry":{"id":"a","role":"assistant","status":"complete","parts":[]}}],"count":1}
    );
    try testing.expectEqual(@as(usize, 0), t.entries.items[0].parts.items.len);
}
