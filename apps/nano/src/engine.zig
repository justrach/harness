//! The connection to a Harness engine: the daemon (or `harness headless`)
//! on `ws://127.0.0.1:{HARNESS_IPC_PORT|27664}`.
//!
//! A thread of its own dials and reads; each message reaches the UI thread
//! through `nanoui.App.after` and goes to `rpc.Mux` there. Calls are written
//! from the UI thread. When the socket drops, every call ends with an error
//! and the thread dials again after a pause.
const std = @import("std");
const nanoui = @import("nanoui");
const ws = @import("ws.zig");
const rpc = @import("rpc.zig");
const Allocator = std.mem.Allocator;

pub const default_port: u16 = 27664;

pub const State = enum { connecting, connected, disconnected };

pub const Events = struct {
    ctx: ?*anyopaque = null,
    /// On the UI thread: connected (watches start here) or lost.
    state: ?*const fn (ctx: ?*anyopaque, State) void = null,
};

pub const Engine = struct {
    gpa: Allocator,
    io: std.Io,
    port: u16,
    events: Events = .{},
    mux: rpc.Mux,
    state: State = .connecting,
    /// The client calls are written to, from the `connected` delivery on.
    client: ?*ws.Client = null,
    /// The client the reader thread holds, for `deinit` to wake it.
    live: std.atomic.Value(?*ws.Client) = .init(null),
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// A headless scene's made-up replies, by method (snap.zig; the GPUI
    /// renderer's `replies`): calls are answered from them, a frame later.
    scene: ?std.json.Parsed(std.json.Value) = null,
    /// Those answers, waiting for `pump`.
    queued: std.ArrayList([]u8) = .empty,
    /// The calls a scene answered, as sent, and how many of each method's
    /// `$seq` replies are used.
    sent: std.ArrayList([]u8) = .empty,
    seq_used: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(gpa: Allocator, io: std.Io, port: u16) Engine {
        return .{ .gpa = gpa, .io = io, .port = port, .mux = .{ .gpa = gpa } };
    }

    /// The port in `HARNESS_IPC_PORT`, else the default.
    pub fn portFrom(env: *const std.process.Environ.Map) u16 {
        const v = env.get("HARNESS_IPC_PORT") orelse return default_port;
        return std.fmt.parseInt(u16, v, 10) catch default_port;
    }

    /// Starts dialing; `e` must stay where it is from now on.
    pub fn start(e: *Engine) !void {
        e.thread = try std.Thread.spawn(.{}, run, .{e});
    }

    pub fn deinit(e: *Engine) void {
        e.stopping.store(true, .release);
        if (e.live.load(.acquire)) |c| c.shutdown();
        if (e.thread) |t| t.join();
        if (e.live.load(.acquire)) |c| c.deinit(e.gpa);
        if (e.scene) |*sc| sc.deinit();
        for (e.queued.items) |q| e.gpa.free(q);
        e.queued.deinit(e.gpa);
        for (e.sent.items) |q| e.gpa.free(q);
        e.sent.deinit(e.gpa);
        e.seq_used.deinit(e.gpa);
        e.mux.deinit();
    }

    /// Calls `method`; `handler` hears the reply (or each stream item). The
    /// id cancels a stream. Without a connection it fails at once.
    /// Connected to an engine, or answering from a scene.
    pub fn up(e: *const Engine) bool {
        return e.state == .connected and (e.client != null or e.scene != null);
    }

    pub fn call(e: *Engine, method: []const u8, params: anytype, handler: rpc.Handler) ?u64 {
        if (e.scene != null) return e.sceneCall(method, params, handler);
        const c = if (e.state == .connected) e.client else null;
        if (c == null) {
            handler.func(handler.ctx, 0, .{ .err = "not connected" });
            return null;
        }
        const req = e.mux.call(method, params, handler) catch return null;
        defer e.gpa.free(req.frame);
        c.?.sendText(req.frame) catch {
            _ = e.mux.pending.remove(req.id);
            handler.func(handler.ctx, req.id, .{ .err = "send failed" });
            return null;
        };
        return req.id;
    }

    /// A call a scene answers: its reply (under `$items`, each item and the
    /// end; `$err`, that error; `$seq`, the next of several, the last kept)
    /// queued as the engine would send it; else "isn't in this scene".
    fn sceneCall(e: *Engine, method: []const u8, params: anytype, handler: rpc.Handler) ?u64 {
        const req = e.mux.call(method, params, handler) catch return null;
        e.sent.append(e.gpa, req.frame) catch e.gpa.free(req.frame);
        const replies = e.scene.?.value;
        const entry = if (replies == .object) replies.object.getEntry(method) else null;
        var reply = if (entry) |en| en.value_ptr.* else null;
        if (reply) |r| if (r == .object) if (r.object.get("$seq")) |list| if (list == .array and list.array.items.len > 0) {
            // Keyed by the scene's own name for it, which outlives the call.
            const used = e.seq_used.getOrPut(e.gpa, entry.?.key_ptr.*) catch null;
            const n = if (used) |u| (if (u.found_existing) u.value_ptr.* else 0) else 0;
            if (used) |u| u.value_ptr.* = n + 1;
            reply = list.array.items[@min(n, list.array.items.len - 1)];
        };
        const Frame = struct { id: u64, ok: ?std.json.Value = null, item: ?std.json.Value = null, err: ?[]const u8 = null, done: ?bool = null };
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(e.gpa);
        if (reply) |r| {
            const items = if (r == .object) r.object.get("$items") else null;
            const failure = if (r == .object) r.object.get("$err") else null;
            if (failure) |why| {
                frames.append(e.gpa, .{ .id = req.id, .err = if (why == .string) why.string else "error" }) catch {};
            } else if (items) |list| {
                if (list == .array) for (list.array.items) |it| frames.append(e.gpa, .{ .id = req.id, .item = it }) catch {};
                frames.append(e.gpa, .{ .id = req.id, .done = true }) catch {};
            } else frames.append(e.gpa, .{ .id = req.id, .ok = r }) catch {};
        } else frames.append(e.gpa, .{ .id = req.id, .err = "isn't in this scene" }) catch {};
        for (frames.items) |f| {
            const text = std.json.Stringify.valueAlloc(e.gpa, f, .{ .emit_null_optional_fields = false }) catch continue;
            e.queued.append(e.gpa, text) catch e.gpa.free(text);
        }
        return req.id;
    }

    /// Delivers a scene's queued answers; true when there were any.
    pub fn pump(e: *Engine) bool {
        if (e.queued.items.len == 0) return false;
        const batch = e.queued.toOwnedSlice(e.gpa) catch return false;
        defer e.gpa.free(batch);
        for (batch) |q| {
            defer e.gpa.free(q);
            e.mux.dispatch(q) catch {};
        }
        return true;
    }

    pub fn cancel(e: *Engine, id: u64) void {
        const frame = e.mux.cancel(id) catch return;
        defer e.gpa.free(frame);
        if (e.state == .connected) if (e.client) |c| c.sendText(frame) catch {};
    }

    fn run(e: *Engine) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(e.gpa);
        while (!e.stopping.load(.acquire)) {
            const c = ws.Client.connect(e.gpa, e.io, e.port, "/") catch {
                e.post(.{ .state = .disconnected });
                e.pause();
                continue;
            };
            e.live.store(c, .release);
            e.post(.{ .state = .connected, .client = c });
            while (true) {
                _ = c.readMessage(e.gpa, &buf) catch break;
                const bytes = e.gpa.dupe(u8, buf.items) catch continue;
                e.post(.{ .message = bytes });
            }
            if (e.stopping.load(.acquire)) return;
            e.live.store(null, .release);
            e.post(.{ .state = .disconnected, .client = c });
            e.pause();
        }
    }

    fn pause(e: *Engine) void {
        // Two seconds, as the GPUI app waits before it resubscribes.
        var left: usize = 20;
        while (left > 0 and !e.stopping.load(.acquire)) : (left -= 1)
            std.Io.sleep(e.io, .fromMilliseconds(100), .awake) catch return;
    }

    const Delivery = struct {
        e: *Engine = undefined,
        message: ?[]u8 = null,
        state: ?State = null,
        /// The client the state is about: taken on connect, freed on loss.
        client: ?*ws.Client = null,

        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const d: *Delivery = @ptrCast(@alignCast(ctx.?));
            const e = d.e;
            defer e.gpa.destroy(d);
            if (d.message) |m| {
                defer e.gpa.free(m);
                e.mux.dispatch(m) catch |err| std.log.warn("harness-nano: bad frame: {t}", .{err});
                return;
            }
            const s = d.state orelse return;
            switch (s) {
                .connected => e.client = d.client,
                .disconnected => if (d.client) |c| {
                    if (e.client == c) e.client = null;
                    e.mux.failAll("disconnected");
                    c.deinit(e.gpa);
                },
                .connecting => {},
            }
            if (e.state == s) return;
            e.state = s;
            if (e.events.state) |f| f(e.events.ctx, s);
        }
    };

    fn post(e: *Engine, d: Delivery) void {
        const p = e.gpa.create(Delivery) catch return;
        p.* = d;
        p.e = e;
        nanoui.App.after(0, p, Delivery.run);
    }
};
