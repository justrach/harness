//! The engine's RPC frames (crates/rpc/src/lib.rs): one JSON object per
//! WebSocket text message.
//!
//! - client → engine: `{id, method, params}` to call, `{id, cancel: true}`
//!   to stop a stream;
//! - engine → client: `{id, ok}` or `{id, err}` for a call, `{id, item}`…
//!   then `{id, done: true}` (or `{id, err}`) for a stream.
//!
//! `Mux` numbers calls and hands each reply to the handler that made it.
//! It lives on the UI thread; the connection only moves bytes.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

/// `{}`: Zig writes an empty anonymous struct as `[]`, which the engine
/// refuses where it expects a map.
pub const Empty = struct {};
pub const empty: Empty = .{};

pub const Reply = union(enum) {
    ok: json.Value,
    err: []const u8,
    item: json.Value,
    done,
};

/// Called with each reply to call `id`. The reply's memory lasts only for
/// the call: copy what is kept.
pub const Handler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, id: u64, reply: Reply) void,
    /// A checked stream (`subscribe_checked`): the engine first answers
    /// `ok` (`{"stream": true}`) to say it started, so `ok` doesn't end it,
    /// and an older engine's `unknown method` comes back as `err`.
    checked: bool = false,

    pub fn checkedStream(h: Handler) Handler {
        var x = h;
        x.checked = true;
        return x;
    }

    pub fn of(comptime T: type, ctx: *T, comptime func: fn (*T, u64, Reply) void) Handler {
        return .{ .ctx = ctx, .func = struct {
            fn f(c: ?*anyopaque, id: u64, r: Reply) void {
                func(@ptrCast(@alignCast(c.?)), id, r);
            }
        }.f };
    }
};

pub const Mux = struct {
    gpa: Allocator,
    next_id: u64 = 1,
    pending: std.AutoHashMapUnmanaged(u64, Handler) = .empty,

    pub fn deinit(m: *Mux) void {
        m.pending.deinit(m.gpa);
    }

    /// Registers a call and returns its id and frame, which the caller
    /// sends and frees.
    pub fn call(m: *Mux, method: []const u8, params: anytype, handler: Handler) !struct { id: u64, frame: []u8 } {
        const id = m.next_id;
        // Absent, not null: the engine's optional fields default when missing.
        const frame = try json.Stringify.valueAlloc(m.gpa, .{ .id = id, .method = method, .params = params }, .{ .emit_null_optional_fields = false });
        errdefer m.gpa.free(frame);
        try m.pending.put(m.gpa, id, handler);
        m.next_id += 1;
        return .{ .id = id, .frame = frame };
    }

    /// Stops listening to `id`; returns the frame that tells the engine to
    /// stop its stream (send and free it).
    pub fn cancel(m: *Mux, id: u64) ![]u8 {
        _ = m.pending.remove(id);
        return json.Stringify.valueAlloc(m.gpa, .{ .id = id, .cancel = true }, .{});
    }

    /// The connection dropped: every call ends with `err`.
    pub fn failAll(m: *Mux, why: []const u8) void {
        var it = m.pending.iterator();
        while (it.next()) |e| e.value_ptr.func(e.value_ptr.ctx, e.key_ptr.*, .{ .err = why });
        m.pending.clearRetainingCapacity();
    }

    /// One frame from the engine to the handler waiting for it. A reply to
    /// no one (a stream cancelled meanwhile) is dropped.
    pub fn dispatch(m: *Mux, text: []const u8) !void {
        var parsed = try json.parseFromSlice(json.Value, m.gpa, text, .{});
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.BadFrame,
        };
        const id: u64 = switch (obj.get("id") orelse return error.BadFrame) {
            .integer => |i| std.math.cast(u64, i) orelse return error.BadFrame,
            else => return error.BadFrame,
        };
        const reply: Reply = if (obj.get("err")) |e|
            .{ .err = if (e == .string) e.string else "error" }
        else if (obj.get("item")) |v|
            .{ .item = v }
        else if (obj.get("done")) |d|
            (if (d == .bool and d.bool) .done else return error.BadFrame)
        else
            .{ .ok = obj.get("ok") orelse .null };
        const handler = m.pending.get(id) orelse return;
        const last = switch (reply) {
            .item => false,
            .ok => !handler.checked,
            else => true,
        };
        if (last) _ = m.pending.remove(id);
        handler.func(handler.ctx, id, reply);
    }
};

const testing = std.testing;

const Log = struct {
    oks: usize = 0,
    items: usize = 0,
    done: bool = false,
    err: [32]u8 = undefined,
    err_len: usize = 0,

    fn on(l: *Log, _: u64, r: Reply) void {
        switch (r) {
            .ok => l.oks += 1,
            .item => l.items += 1,
            .done => l.done = true,
            .err => |e| {
                @memcpy(l.err[0..e.len], e);
                l.err_len = e.len;
            },
        }
    }
};

test "empty params and fields are objects, not arrays" {
    var m: Mux = .{ .gpa = testing.allocator };
    defer m.deinit();
    var log: Log = .{};
    const c = try m.call("WatchChats", .{ .x = empty }, .of(Log, &log, Log.on));
    defer testing.allocator.free(c.frame);
    try testing.expectEqualStrings("{\"id\":1,\"method\":\"WatchChats\",\"params\":{\"x\":{}}}", c.frame);
}

test "a call's frame names its id, method and params" {
    var m: Mux = .{ .gpa = testing.allocator };
    defer m.deinit();
    var log: Log = .{};
    const c = try m.call("FocusChat", .{ .chat_id = "c1" }, .of(Log, &log, Log.on));
    defer testing.allocator.free(c.frame);
    try testing.expectEqualStrings("{\"id\":1,\"method\":\"FocusChat\",\"params\":{\"chat_id\":\"c1\"}}", c.frame);
}

test "a stream's items reach its handler until done, then it is forgotten" {
    var m: Mux = .{ .gpa = testing.allocator };
    defer m.deinit();
    var log: Log = .{};
    const c = try m.call("WatchChats", .{}, .of(Log, &log, Log.on));
    testing.allocator.free(c.frame);
    try m.dispatch("{\"id\":1,\"item\":[1]}");
    try m.dispatch("{\"id\":1,\"item\":[2]}");
    try m.dispatch("{\"id\":1,\"done\":true}");
    try m.dispatch("{\"id\":1,\"item\":[3]}");
    try testing.expectEqual(@as(usize, 2), log.items);
    try testing.expect(log.done);
    try testing.expectEqual(@as(u32, 0), m.pending.count());
}

test "a unary null ok, an error, and a dropped connection" {
    var m: Mux = .{ .gpa = testing.allocator };
    defer m.deinit();
    var a: Log = .{};
    var b: Log = .{};
    var c: Log = .{};
    for ([_]*Log{ &a, &b, &c }) |l| testing.allocator.free((try m.call("X", null, .of(Log, l, Log.on))).frame);
    try m.dispatch("{\"id\":1,\"ok\":null}");
    try m.dispatch("{\"id\":2,\"err\":\"nope\"}");
    m.failAll("closed");
    try testing.expectEqual(@as(usize, 1), a.oks);
    try testing.expectEqualStrings("nope", b.err[0..b.err_len]);
    try testing.expectEqualStrings("closed", c.err[0..c.err_len]);
}

test "cancel forgets the stream and says so to the engine" {
    var m: Mux = .{ .gpa = testing.allocator };
    defer m.deinit();
    var log: Log = .{};
    testing.allocator.free((try m.call("WatchSessions", .{}, .of(Log, &log, Log.on))).frame);
    const f = try m.cancel(1);
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("{\"id\":1,\"cancel\":true}", f);
    try m.dispatch("{\"id\":1,\"item\":{}}");
    try testing.expectEqual(@as(usize, 0), log.items);
}

test "a checked stream's ok says it started; its items follow until done" {
    var m: Mux = .{ .gpa = testing.allocator };
    defer m.deinit();
    var log: Log = .{};
    const c = try m.call("WatchCheckoutChangeRequest", .{ .cwd = "/r", .branch = "b" }, Handler.of(Log, &log, Log.on).checkedStream());
    defer testing.allocator.free(c.frame);
    try m.dispatch("{\"id\":1,\"ok\":{\"stream\":true}}");
    try m.dispatch("{\"id\":1,\"item\":{}}");
    try testing.expectEqual(@as(usize, 1), log.oks);
    try testing.expectEqual(@as(usize, 1), log.items);
    try m.dispatch("{\"id\":1,\"done\":true}");
    try testing.expect(log.done);
    try testing.expectEqual(@as(usize, 0), m.pending.count());
}
