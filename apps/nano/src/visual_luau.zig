//! Sandboxed Luau runtime for interactive native visuals (`crates/visual` 1:1).
const std = @import("std");

pub const c = @import("luau_c");

extern "c" fn malloc(size: usize) ?*anyopaque;
extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;

pub const max_source_bytes: usize = 64 * 1024;
pub const max_memory_bytes: usize = 16 * 1024 * 1024;
pub const call_budget_ns: i128 = 20 * std.time.ns_per_ms;
pub const max_nodes: usize = 512;
pub const max_depth: usize = 24;
pub const max_text_bytes: usize = 8 * 1024;
pub const max_series: usize = 256;

pub const Kind = enum {
    column,
    row,
    text,
    stat,
    chart,
    button,
    toggle,
    slider,
    rule,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .column => "column",
            .row => "row",
            .text => "text",
            .stat => "stat",
            .chart => "chart",
            .button => "button",
            .toggle => "toggle",
            .slider => "slider",
            .rule => "rule",
        };
    }

    pub const all = [_]Kind{ .column, .row, .text, .stat, .chart, .button, .toggle, .slider, .rule };

    pub fn fromName(s: []const u8) ?Kind {
        for (all) |k| {
            if (std.mem.eql(u8, s, k.name())) return k;
        }
        return null;
    }
};

pub const Input = union(enum) {
    click,
    boolean: bool,
    number: f64,
};

pub const Node = struct {
    kind: Kind,
    text: []const u8 = "",
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 1,
    values: []const f64 = &.{},
    labels: []const []const u8 = &.{},
    handler: ?u64 = null,
    children: []const Node = &.{},
};

const Expected = union(enum) {
    click,
    boolean,
    number: struct { min: f64, max: f64 },
};

const Handler = struct {
    func_ref: c_int,
    expected: Expected,
};

const MemTracker = struct {
    used: usize = 0,
    limit: usize = max_memory_bytes,
};

const Budget = struct {
    start_ns: i128 = 0,
    armed: bool = false,
    timed_out: bool = false,
};

pub const InitResult = union(enum) {
    ok: *Visual,
    err: []u8,
};

pub const RenderResult = union(enum) {
    ok: Node,
    err: []u8,
};

pub const Visual = struct {
    gpa: std.mem.Allocator,
    tracker: MemTracker = .{},
    budget: Budget = .{},
    L: *c.lua_State = undefined,
    renderer_ref: c_int = c.LUA_NOREF,
    handlers: std.AutoHashMapUnmanaged(u64, Handler) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, source: []const u8) InitResult {
        if (source.len > max_source_bytes) {
            return .{ .err = gpa.dupe(u8, "visual source exceeds 64 KiB") catch return .{ .err = &.{} } };
        }
        const v = gpa.create(Visual) catch return .{ .err = gpa.dupe(u8, "not enough memory") catch &.{} };
        v.* = .{ .gpa = gpa };
        errdefer {
            v.deinit();
        }

        const L = c.lua_newstate(allocFn, &v.tracker) orelse {
            gpa.destroy(v);
            return .{ .err = gpa.dupe(u8, "not enough memory") catch &.{} };
        };
        v.L = L;

        openSafeLibs(L);
        installUi(L);
        c.luaL_sandbox(L);
        c.luaL_sandboxthread(L);

        const cb = c.lua_callbacks(L);
        cb.*.userdata = &v.budget;
        cb.*.interrupt = interruptFn;

        v.armBudget();
        var compile_opts = std.mem.zeroes(c.lua_CompileOptions);
        compile_opts.optimizationLevel = 1;
        compile_opts.debugLevel = 1;
        var bc_size: usize = 0;
        const bc = c.luau_compile(source.ptr, source.len, &compile_opts, &bc_size);
        if (bc == null) {
            v.disarmBudget();
            v.deinit();
            return .{ .err = gpa.dupe(u8, "visual compilation failed") catch &.{} };
        }
        const load_rc = c.luau_load(L, "=visual", bc, bc_size, 0);
        free(bc);
        if (load_rc != 0) {
            const msg = popError(gpa, L);
            v.disarmBudget();
            v.deinit();
            return .{ .err = msg };
        }

        if (c.lua_pcall(L, 0, 1, 0) != 0) {
            const msg = if (v.budget.timed_out) blk: {
                c.lua_settop(L, 0);
                break :blk gpa.dupe(u8, "visual execution exceeded 20 ms") catch return .{ .err = &.{} };
            } else popError(gpa, L);
            v.disarmBudget();
            v.deinit();
            return .{ .err = msg };
        }

        if (v.checkBudget()) |msg| {
            v.disarmBudget();
            v.deinit();
            return .{ .err = gpa.dupe(u8, msg) catch &.{} };
        }
        v.disarmBudget();

        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_settop(L, 0);
            v.deinit();
            return .{ .err = gpa.dupe(u8, "visual script must return a render function") catch &.{} };
        }
        v.renderer_ref = c.lua_ref(L, -1);
        c.lua_settop(L, 0);
        return .{ .ok = v };
    }

    pub fn deinit(v: *Visual) void {
        const gpa = v.gpa;
        if (v.renderer_ref != c.LUA_NOREF) _ = c.lua_unref(v.L, v.renderer_ref);
        v.clearHandlers();
        v.handlers.deinit(gpa);
        c.lua_close(v.L);
        gpa.destroy(v);
    }

    pub fn usedMemory(v: *const Visual) usize {
        return v.tracker.used;
    }

    pub fn gcCollect(v: *Visual) void {
        _ = c.lua_gc(v.L, c.LUA_GCCOLLECT, 0);
    }

    pub fn render(v: *Visual, arena: std.mem.Allocator) RenderResult {
        v.clearHandlers();
        return v.execute(arena, null, null);
    }

    pub fn call(v: *Visual, arena: std.mem.Allocator, handler_id: u64, input: Input) RenderResult {
        const h = v.handlers.get(handler_id) orelse {
            return .{ .err = v.gpa.dupe(u8, "unknown or stale visual handler") catch &.{} };
        };
        if (!matchesExpected(h.expected, input)) {
            return .{ .err = v.gpa.dupe(u8, "visual handler input has the wrong type or is outside its range") catch &.{} };
        }
        _ = c.lua_getref(v.L, h.func_ref);
        v.clearHandlers();
        return v.execute(arena, true, input);
    }

    fn clearHandlers(v: *Visual) void {
        var it = v.handlers.valueIterator();
        while (it.next()) |h| _ = c.lua_unref(v.L, h.func_ref);
        v.handlers.clearRetainingCapacity();
    }

    fn armBudget(v: *Visual) void {
        v.budget = .{
            .start_ns = nowNs(),
            .armed = true,
            .timed_out = false,
        };
    }

    fn disarmBudget(v: *Visual) void {
        v.budget.armed = false;
    }

    fn checkBudget(v: *const Visual) ?[]const u8 {
        if (v.budget.timed_out or (nowNs() - v.budget.start_ns) >= call_budget_ns) {
            return "visual execution exceeded 20 ms";
        }
        return null;
    }

    fn execute(v: *Visual, arena: std.mem.Allocator, has_event_fn: ?bool, input: ?Input) RenderResult {
        const L = v.L;
        v.armBudget();
        defer {
            v.disarmBudget();
            c.lua_settop(L, 0);
        }

        if (has_event_fn != null) {
            const nargs: c_int = switch (input.?) {
                .click => 0,
                .boolean => |b| blk: {
                    c.lua_pushboolean(L, if (b) 1 else 0);
                    break :blk 1;
                },
                .number => |n| blk: {
                    c.lua_pushnumber(L, n);
                    break :blk 1;
                },
            };
            if (c.lua_pcall(L, nargs, 0, 0) != 0) {
                if (v.budget.timed_out) return .{ .err = v.gpa.dupe(u8, "visual execution exceeded 20 ms") catch &.{} };
                return .{ .err = popError(v.gpa, L) };
            }
            if (v.checkBudget()) |msg| return .{ .err = v.gpa.dupe(u8, msg) catch &.{} };
        }

        _ = c.lua_getref(L, v.renderer_ref);
        if (c.lua_pcall(L, 0, 1, 0) != 0) {
            if (v.budget.timed_out) return .{ .err = v.gpa.dupe(u8, "visual execution exceeded 20 ms") catch &.{} };
            return .{ .err = popError(v.gpa, L) };
        }
        if (v.checkBudget()) |msg| return .{ .err = v.gpa.dupe(u8, msg) catch &.{} };

        var parser: Parser = .{
            .gpa = v.gpa,
            .arena = arena,
            .visual = v,
            .next_id = &v.next_id,
        };
        errdefer parser.cleanupOnError(L);
        const node = parser.parse(L, -1, 1) catch |err| {
            parser.cleanupOnError(L);
            const msg = parser.err_msg orelse switch (err) {
                error.OutOfMemory => "not enough memory",
                else => "invalid visual node",
            };
            return .{ .err = v.gpa.dupe(u8, msg) catch &.{} };
        };
        if (v.checkBudget()) |msg| {
            parser.cleanupOnError(L);
            return .{ .err = v.gpa.dupe(u8, msg) catch &.{} };
        }
        v.handlers.deinit(v.gpa);
        v.handlers = parser.handlers;
        parser.handlers = .empty;
        return .{ .ok = node };
    }
};

pub fn check(gpa: std.mem.Allocator, source: []const u8) ?[]u8 {
    switch (Visual.init(gpa, source)) {
        .ok => |v| {
            defer v.deinit();
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            switch (v.render(arena.allocator())) {
                .ok => return null,
                .err => |e| return e,
            }
        },
        .err => |e| return e,
    }
}

fn matchesExpected(expected: Expected, input: Input) bool {
    return switch (expected) {
        .click => input == .click,
        .boolean => input == .boolean,
        .number => |range| switch (input) {
            .number => |n| std.math.isFinite(n) and n >= range.min and n <= range.max,
            else => false,
        },
    };
}

fn performanceCounterNs(counter: i64, frequency: i64) i128 {
    // Widen before multiplying: a long-running QPC can overflow i64 even
    // though the resulting nanosecond timestamp fits comfortably in i128.
    return @divTrunc(@as(i128, counter) * std.time.ns_per_s, frequency);
}

// Transcript widget tests exercise layout and callbacks, not host scheduling.
// Keep their clock deterministic without changing the production 20 ms budget
// or the real-clock sandbox tests. Advancing on every probe still stops loops.
pub const TestClock = if (@import("builtin").is_test) struct {
    previous: ?i128,
    threadlocal var time_ns: ?i128 = null;

    pub fn init() @This() {
        const previous = time_ns;
        time_ns = 0;
        return .{ .previous = previous };
    }

    pub fn deinit(clock: @This()) void {
        time_ns = clock.previous;
    }
} else struct {};

fn nowNs() i128 {
    if (@import("builtin").is_test) {
        if (TestClock.time_ns) |time| {
            TestClock.time_ns = time + std.time.ns_per_us;
            return time;
        }
    }
    if (@import("builtin").os.tag == .windows) {
        const windows = std.os.windows;
        var counter: windows.LARGE_INTEGER = undefined;
        var frequency: windows.LARGE_INTEGER = undefined;
        // These are the monotonic performance-counter APIs std.Io.Threaded
        // uses too. Never substitute wall time for the sandbox deadline.
        if (!windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency <= 0 or
            !windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool())
            @panic("monotonic performance counter unavailable");
        return performanceCounterNs(counter, frequency);
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0)
        @panic("monotonic clock unavailable");
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn allocFn(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const tracker: *MemTracker = @ptrCast(@alignCast(ud.?));
    if (nsize == 0) {
        if (ptr != null) {
            tracker.used -|= osize;
            free(ptr);
        }
        return null;
    }
    if (ptr == null) {
        if (nsize > tracker.limit -| tracker.used) return null;
        const p = malloc(nsize) orelse return null;
        tracker.used += nsize;
        return p;
    }
    if (nsize > osize) {
        const delta = nsize - osize;
        if (delta > tracker.limit -| tracker.used) return null;
    }
    const p = realloc(ptr, nsize) orelse return null;
    tracker.used = (tracker.used -| osize) + nsize;
    return p;
}

fn interruptFn(L_opt: ?*c.lua_State, gc: c_int) callconv(.c) void {
    _ = gc;
    const L = L_opt orelse return;
    const cb = c.lua_callbacks(L);
    const ud = cb.*.userdata orelse return;
    const budget: *Budget = @ptrCast(@alignCast(ud));
    if (!budget.armed) return;
    if (budget.timed_out or (nowNs() - budget.start_ns) >= call_budget_ns) {
        budget.timed_out = true;
        c.luaL_errorL(L, "visual execution exceeded 20 ms");
    }
}

fn popError(gpa: std.mem.Allocator, L: *c.lua_State) []u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len);
    const msg = if (ptr != null and len > 0) ptr[0..len] else "visual execution failed";
    const out = gpa.dupe(u8, msg) catch return &.{};
    c.lua_settop(L, 0);
    return out;
}

fn openSafeLibs(L: *c.lua_State) void {
    const libs = [_]struct { name: [:0]const u8, func: c.lua_CFunction }{
        .{ .name = "", .func = c.luaopen_base },
        .{ .name = "table", .func = c.luaopen_table },
        .{ .name = "string", .func = c.luaopen_string },
        .{ .name = "math", .func = c.luaopen_math },
        .{ .name = "utf8", .func = c.luaopen_utf8 },
    };
    for (libs) |lib| {
        c.lua_pushcclosurek(L, lib.func, lib.name.ptr, 0, null);
        c.lua_pushlstring(L, lib.name.ptr, lib.name.len);
        c.lua_call(L, 1, 0);
    }
    const disabled = [_][:0]const u8{
        "print",    "warn",   "require",        "load",    "loadstring",
        "loadfile", "dofile", "collectgarbage", "getfenv", "setfenv",
        "newproxy",
    };
    for (disabled) |name| {
        c.lua_pushnil(L);
        c.lua_rawsetfield(L, c.LUA_GLOBALSINDEX, name.ptr);
    }
}

fn installUi(L: *c.lua_State) void {
    c.lua_createtable(L, 0, 9);
    for (Kind.all) |k| {
        const z: [:0]const u8 = switch (k) {
            .column => "column",
            .row => "row",
            .text => "text",
            .stat => "stat",
            .chart => "chart",
            .button => "button",
            .toggle => "toggle",
            .slider => "slider",
            .rule => "rule",
        };
        c.lua_pushinteger(L, @backingInt(k));
        c.lua_pushcclosurek(L, uiConstructor, z.ptr, 1, null);
        c.lua_rawsetfield(L, -2, z.ptr);
    }
    _ = c.lua_setreadonly(L, -1, 1);
    c.lua_rawsetfield(L, c.LUA_GLOBALSINDEX, "ui");
}

fn uiConstructor(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const raw_kind = c.lua_tointegerx(L, c.lua_upvalueindex(1), null);
    const kind: Kind = @fromBackingInt(@intCast(@as(u8, @intCast(raw_kind))));

    if (c.lua_gettop(L) < 1) {
        c.luaL_errorL(L, "visual constructors require a property table (or a text string)");
    }

    const arg_type = c.lua_type(L, 1);
    if (kind == .text and arg_type == c.LUA_TSTRING) {
        c.lua_createtable(L, 0, 2);
        c.lua_pushvalue(L, 1);
        c.lua_rawsetfield(L, -2, "text");
        const kname = kind.name();
        c.lua_pushlstring(L, kname.ptr, kname.len);
        c.lua_rawsetfield(L, -2, "__kind");
        return 1;
    }

    if (arg_type != c.LUA_TTABLE) {
        c.luaL_errorL(L, "visual constructors require a property table (or a text string)");
    }

    if (checkProperties(L, 1, kind, false)) |err_msg| {
        c.luaL_errorL(L, "%s", err_msg.ptr);
    }

    const kname = kind.name();
    c.lua_pushlstring(L, kname.ptr, kname.len);
    c.lua_rawsetfield(L, 1, "__kind");
    c.lua_settop(L, 1);
    return 1;
}

fn checkProperties(L: *c.lua_State, table_idx: c_int, kind: Kind, tagged: bool) ?[:0]const u8 {
    if (c.lua_getmetatable(L, table_idx) != 0) {
        c.lua_settop(L, -2);
        return "unsupported visual property (styling is not supported)";
    }
    const allowed: []const []const u8 = switch (kind) {
        .column, .row, .rule => &.{},
        .text => &.{"text"},
        .stat => &.{ "label", "value" },
        .chart => &.{ "label", "values", "labels" },
        .button => &.{ "label", "onClick" },
        .toggle => &.{ "label", "value", "onChange" },
        .slider => &.{ "label", "value", "min", "max", "onChange" },
    };
    const abs_idx = if (table_idx < 0) c.lua_gettop(L) + table_idx + 1 else table_idx;
    var count: usize = 0;
    c.lua_pushnil(L);
    while (c.lua_next(L, abs_idx) != 0) {
        count += 1;
        if (count > max_nodes + 8) {
            c.lua_settop(L, -3);
            return "too many visual properties";
        }
        const key_type = c.lua_type(L, -2);
        var valid = false;
        if (key_type == c.LUA_TNUMBER and (kind == .column or kind == .row)) {
            const n = c.lua_tonumberx(L, -2, null);
            if (std.math.isFinite(n) and @floor(n) == n and n >= 1 and n <= @as(f64, @floatFromInt(max_nodes))) {
                valid = true;
            }
        } else if (key_type == c.LUA_TSTRING) {
            var klen: usize = 0;
            const kptr = c.lua_tolstring(L, -2, &klen);
            if (kptr != null) {
                const kname = kptr[0..klen];
                if (tagged and std.mem.eql(u8, kname, "__kind")) {
                    valid = true;
                } else {
                    for (allowed) |a| {
                        if (std.mem.eql(u8, kname, a)) {
                            valid = true;
                            break;
                        }
                    }
                }
            }
        }
        c.lua_settop(L, -2); // pop value, keep key for next lua_next
        if (!valid) {
            c.lua_settop(L, -2); // pop key
            return "unsupported visual property (styling is not supported)";
        }
    }
    return null;
}

const Parser = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    visual: *Visual,
    next_id: *u64,
    nodes: usize = 0,
    text_bytes: usize = 0,
    series: usize = 0,
    handlers: std.AutoHashMapUnmanaged(u64, Handler) = .empty,
    err_msg: ?[]const u8 = null,

    fn fail(p: *Parser, msg: []const u8) error{InvalidVisual} {
        p.err_msg = msg;
        return error.InvalidVisual;
    }

    fn cleanupOnError(p: *Parser, L: *c.lua_State) void {
        var it = p.handlers.valueIterator();
        while (it.next()) |h| _ = c.lua_unref(L, h.func_ref);
        p.handlers.deinit(p.gpa);
        p.handlers = .empty;
    }

    fn parse(p: *Parser, L: *c.lua_State, idx: c_int, depth: usize) (error{ InvalidVisual, OutOfMemory })!Node {
        if (p.visual.checkBudget()) |msg| return p.fail(msg);
        if (depth > max_depth) return p.fail("visual tree exceeds maximum depth");
        p.nodes += 1;
        if (p.nodes > max_nodes) return p.fail("visual tree exceeds maximum node count");

        const abs_idx = if (idx < 0) c.lua_gettop(L) + idx + 1 else idx;
        if (c.lua_type(L, abs_idx) != c.LUA_TTABLE) return p.fail("visual nodes must be tables");
        if (c.lua_getmetatable(L, abs_idx) != 0) {
            c.lua_settop(L, -2);
            return p.fail("unsupported visual property (styling is not supported)");
        }

        _ = c.lua_rawgetfield(L, abs_idx, "__kind");
        if (c.lua_type(L, -1) != c.LUA_TSTRING) {
            c.lua_settop(L, -2);
            return p.fail("unsupported visual node kind");
        }
        var klen: usize = 0;
        const kptr = c.lua_tolstring(L, -1, &klen);
        const kind = if (kptr != null) Kind.fromName(kptr[0..klen]) else null;
        c.lua_settop(L, -2);
        const k = kind orelse return p.fail("unsupported visual node kind");

        if (checkProperties(L, abs_idx, k, true)) |msg| return p.fail(msg);

        return switch (k) {
            .column, .row => .{
                .kind = k,
                .children = try p.parseChildren(L, abs_idx, depth),
            },
            .text => .{
                .kind = .text,
                .text = try p.readTextField(L, abs_idx, "text"),
            },
            .stat => blk: {
                const label = try p.readLabel(L, abs_idx);
                const val = try p.readTextField(L, abs_idx, "value");
                if (label.len > 0) {
                    p.text_bytes += 2;
                    if (p.text_bytes > max_text_bytes) return p.fail("visual text exceeds 8 KiB");
                    break :blk .{
                        .kind = .stat,
                        .text = try std.fmt.allocPrint(p.arena, "{s}: {s}", .{ label, val }),
                    };
                }
                break :blk .{ .kind = .stat, .text = val };
            },
            .chart => try p.parseChart(L, abs_idx),
            .button => .{
                .kind = .button,
                .text = try p.readLabel(L, abs_idx),
                .handler = try p.readHandler(L, abs_idx, "onClick", .click),
            },
            .toggle => .{
                .kind = .toggle,
                .text = try p.readLabel(L, abs_idx),
                .value = if (try p.readBool(L, abs_idx, "value")) 1.0 else 0.0,
                .handler = try p.readHandler(L, abs_idx, "onChange", .boolean),
            },
            .slider => try p.parseSlider(L, abs_idx),
            .rule => .{ .kind = .rule },
        };
    }

    fn parseChildren(p: *Parser, L: *c.lua_State, abs_idx: c_int, depth: usize) ![]const Node {
        var max_ix: usize = 0;
        var count: usize = 0;
        c.lua_pushnil(L);
        while (c.lua_next(L, abs_idx) != 0) {
            if (c.lua_type(L, -2) == c.LUA_TNUMBER) {
                const n = c.lua_tonumberx(L, -2, null);
                const ix: usize = @intFromFloat(n);
                count += 1;
                if (ix > max_ix) max_ix = ix;
            }
            c.lua_settop(L, -2);
        }
        if (count != max_ix) return p.fail("visual child list cannot contain holes");
        if (count == 0) return &.{};

        const out = try p.arena.alloc(Node, count);
        for (1..count + 1) |i| {
            _ = c.lua_rawgeti(L, abs_idx, @intCast(i));
            out[i - 1] = p.parse(L, -1, depth + 1) catch |e| {
                c.lua_settop(L, -2);
                return e;
            };
            c.lua_settop(L, -2);
        }
        return out;
    }

    fn parseChart(p: *Parser, L: *c.lua_State, abs_idx: c_int) !Node {
        const label = try p.readLabel(L, abs_idx);
        _ = c.lua_rawgetfield(L, abs_idx, "values");
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -2);
            return p.fail("chart values must be a table");
        }
        const vals_idx = c.lua_gettop(L);
        const vals = p.parseValuesSeq(L, vals_idx) catch |e| {
            c.lua_settop(L, -2);
            return e;
        };
        c.lua_settop(L, -2);

        var labels: []const []const u8 = &.{};
        _ = c.lua_rawgetfield(L, abs_idx, "labels");
        if (c.lua_type(L, -1) != c.LUA_TNIL) {
            if (c.lua_type(L, -1) != c.LUA_TTABLE) {
                c.lua_settop(L, -2);
                return p.fail("chart labels must be a table");
            }
            const lbl_idx = c.lua_gettop(L);
            labels = p.parseLabelsSeq(L, lbl_idx, vals.len) catch |e| {
                c.lua_settop(L, -2);
                return e;
            };
        }
        c.lua_settop(L, -2);

        return .{
            .kind = .chart,
            .text = label,
            .values = vals,
            .labels = labels,
        };
    }

    fn parseValuesSeq(p: *Parser, L: *c.lua_State, tbl_idx: c_int) ![]const f64 {
        if (c.lua_getmetatable(L, tbl_idx) != 0) {
            c.lua_settop(L, -2);
            return p.fail("chart values must be a plain sequence");
        }
        var count: usize = 0;
        var max_ix: usize = 0;
        c.lua_pushnil(L);
        while (c.lua_next(L, tbl_idx) != 0) {
            count += 1;
            if (count > max_series) {
                c.lua_settop(L, -3);
                return p.fail("chart series exceeds 256 values");
            }
            if (c.lua_type(L, -2) != c.LUA_TNUMBER) {
                c.lua_settop(L, -3);
                return p.fail("chart values must be a sequence without extra keys");
            }
            const k = c.lua_tonumberx(L, -2, null);
            if (!std.math.isFinite(k) or @floor(k) != k or k < 1 or k > @as(f64, @floatFromInt(max_series))) {
                c.lua_settop(L, -3);
                return p.fail("chart values must be a sequence");
            }
            const ix: usize = @intFromFloat(k);
            if (ix > max_ix) max_ix = ix;
            c.lua_settop(L, -2);
        }
        if (count != max_ix) return p.fail("chart values sequence cannot contain holes");
        p.series += count;
        if (p.series > max_series) return p.fail("chart series exceeds 256 values");

        const out = try p.arena.alloc(f64, count);
        for (1..count + 1) |i| {
            _ = c.lua_rawgeti(L, tbl_idx, @intCast(i));
            var isnum: c_int = 0;
            const n = c.lua_tonumberx(L, -1, &isnum);
            const t = c.lua_type(L, -1);
            c.lua_settop(L, -2);
            if (t != c.LUA_TNUMBER or isnum == 0 or !std.math.isFinite(n)) {
                return p.fail("chart values must be finite numbers");
            }
            out[i - 1] = n;
        }
        return out;
    }

    fn parseLabelsSeq(p: *Parser, L: *c.lua_State, tbl_idx: c_int, expected_len: usize) ![]const []const u8 {
        if (c.lua_getmetatable(L, tbl_idx) != 0) {
            c.lua_settop(L, -2);
            return p.fail("chart labels must be a plain sequence");
        }
        var count: usize = 0;
        var max_ix: usize = 0;
        c.lua_pushnil(L);
        while (c.lua_next(L, tbl_idx) != 0) {
            count += 1;
            if (count > max_series) {
                c.lua_settop(L, -3);
                return p.fail("chart labels exceed 256 items");
            }
            if (c.lua_type(L, -2) != c.LUA_TNUMBER) {
                c.lua_settop(L, -3);
                return p.fail("chart labels must be a sequence");
            }
            const k = c.lua_tonumberx(L, -2, null);
            if (!std.math.isFinite(k) or @floor(k) != k or k < 1 or k > @as(f64, @floatFromInt(max_series))) {
                c.lua_settop(L, -3);
                return p.fail("chart labels must be a sequence");
            }
            const ix: usize = @intFromFloat(k);
            if (ix > max_ix) max_ix = ix;
            c.lua_settop(L, -2);
        }
        if (count != max_ix) return p.fail("chart labels cannot contain holes");
        if (count != expected_len) return p.fail("chart labels length must match values length");

        const out = try p.arena.alloc([]const u8, count);
        for (1..count + 1) |i| {
            _ = c.lua_rawgeti(L, tbl_idx, @intCast(i));
            out[i - 1] = p.readTextAt(L, -1) catch |e| {
                c.lua_settop(L, -2);
                return e;
            };
            c.lua_settop(L, -2);
        }
        return out;
    }

    fn parseSlider(p: *Parser, L: *c.lua_State, abs_idx: c_int) !Node {
        const label = try p.readLabel(L, abs_idx);
        const min_val = try p.readRequiredFinite(L, abs_idx, "min");
        const max_val = try p.readRequiredFinite(L, abs_idx, "max");
        const val = try p.readRequiredFinite(L, abs_idx, "value");
        if (min_val > max_val or val < min_val or val > max_val) {
            return p.fail("invalid slider range or value");
        }
        const handler = try p.readHandler(L, abs_idx, "onChange", .{ .number = .{ .min = min_val, .max = max_val } });
        return .{
            .kind = .slider,
            .text = label,
            .value = val,
            .min = min_val,
            .max = max_val,
            .handler = handler,
        };
    }

    fn readTextField(p: *Parser, L: *c.lua_State, abs_idx: c_int, field: [:0]const u8) ![]const u8 {
        _ = c.lua_rawgetfield(L, abs_idx, field.ptr);
        defer c.lua_settop(L, -2);
        return p.readTextAt(L, -1);
    }

    fn readLabel(p: *Parser, L: *c.lua_State, abs_idx: c_int) ![]const u8 {
        _ = c.lua_rawgetfield(L, abs_idx, "label");
        defer c.lua_settop(L, -2);
        if (c.lua_type(L, -1) == c.LUA_TNIL) return "";
        return p.readTextAt(L, -1);
    }

    fn readTextAt(p: *Parser, L: *c.lua_State, idx: c_int) ![]const u8 {
        const t = c.lua_type(L, idx);
        var slice: []const u8 = "";
        if (t == c.LUA_TSTRING) {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, idx, &len);
            if (len > max_text_bytes) return p.fail("visual text exceeds 8 KiB");
            if (p.text_bytes + len > max_text_bytes) return p.fail("visual text exceeds 8 KiB");
            slice = try p.arena.dupe(u8, ptr[0..len]);
        } else if (t == c.LUA_TNUMBER) {
            const n = c.lua_tonumberx(L, idx, null);
            if (!std.math.isFinite(n)) return p.fail("expected visual text or a finite number");
            const formatted = try std.fmt.allocPrint(p.arena, "{d}", .{n});
            if (p.text_bytes + formatted.len > max_text_bytes) return p.fail("visual text exceeds 8 KiB");
            slice = formatted;
        } else {
            return p.fail("expected visual text or a finite number");
        }
        p.text_bytes += slice.len;
        return slice;
    }

    fn readBool(p: *Parser, L: *c.lua_State, abs_idx: c_int, field: [:0]const u8) !bool {
        _ = c.lua_rawgetfield(L, abs_idx, field.ptr);
        defer c.lua_settop(L, -2);
        if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return p.fail("toggle value must be a boolean");
        return c.lua_toboolean(L, -1) != 0;
    }

    fn readRequiredFinite(p: *Parser, L: *c.lua_State, abs_idx: c_int, field: [:0]const u8) !f64 {
        _ = c.lua_rawgetfield(L, abs_idx, field.ptr);
        defer c.lua_settop(L, -2);
        if (c.lua_type(L, -1) != c.LUA_TNUMBER) return p.fail("expected a finite number");
        const n = c.lua_tonumberx(L, -1, null);
        if (!std.math.isFinite(n)) return p.fail("expected a finite number");
        return n;
    }

    fn readHandler(p: *Parser, L: *c.lua_State, abs_idx: c_int, field: [:0]const u8, expected: Expected) !?u64 {
        _ = c.lua_rawgetfield(L, abs_idx, field.ptr);
        const t = c.lua_type(L, -1);
        if (t == c.LUA_TNIL) {
            c.lua_settop(L, -2);
            return null;
        }
        if (t != c.LUA_TFUNCTION) {
            c.lua_settop(L, -2);
            return p.fail("visual handler must be a function");
        }
        const id = p.next_id.*;
        if (id == std.math.maxInt(u64)) {
            c.lua_settop(L, -2);
            return p.fail("visual handler ids exhausted");
        }
        p.next_id.* = id + 1;
        const ref = c.lua_ref(L, -1);
        c.lua_settop(L, -2);
        p.handlers.put(p.gpa, id, .{ .func_ref = ref, .expected = expected }) catch |e| {
            _ = c.lua_unref(L, ref);
            return e;
        };
        return id;
    }
};

// ---------------------------------------------------------------------------
// Tests (1:1 port of crates/visual/src/tests.rs)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testRender(body: []const u8) !struct { arena: std.heap.ArenaAllocator, node: ?Node, err: ?[]u8 } {
    const src = try std.fmt.allocPrint(testing.allocator, "return function() {s} end", .{body});
    defer testing.allocator.free(src);
    switch (Visual.init(testing.allocator, src)) {
        .err => |e| return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .node = null, .err = e },
        .ok => |v| {
            defer v.deinit();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            switch (v.render(arena.allocator())) {
                .ok => |n| return .{ .arena = arena, .node = n, .err = null },
                .err => |e| {
                    arena.deinit();
                    return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .node = null, .err = e };
                },
            }
        },
    }
}

test "documented dashboard and stateful button" {
    const src = @embedFile("test_dashboard.luau");
    const v = switch (Visual.init(testing.allocator, src)) {
        .ok => |v| v,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    defer v.deinit();

    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    const first = switch (v.render(a1.allocator())) {
        .ok => |n| n,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(Kind.column, first.kind);
    try testing.expectEqualStrings("Iterations: 3", first.children[1].children[0].text);
    const handler = first.children[3].handler.?;

    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const next = switch (v.call(a2.allocator(), handler, .click)) {
        .ok => |n| n,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("Iterations: 4", next.children[1].children[0].text);

    var a3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a3.deinit();
    switch (v.call(a3.allocator(), handler, .click)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "stale") != null);
        },
    }
    switch (v.call(a3.allocator(), 0, .click)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| testing.allocator.free(e),
    }
    switch (v.call(a3.allocator(), std.math.maxInt(u64), .click)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| testing.allocator.free(e),
    }
}

test "toggles and sliders receive typed values and preserve state" {
    const src =
        \\local enabled, amount = false, 2
        \\return function()
        \\    return ui.column{
        \\        ui.toggle{label='Enabled', value=enabled, onChange=function(v) enabled=v end},
        \\        ui.slider{label='Amount', value=amount, min=0, max=10, onChange=function(v) amount=v end}
        \\    }
        \\end
    ;
    const v = switch (Visual.init(testing.allocator, src)) {
        .ok => |v| v,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    defer v.deinit();

    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const first = switch (v.render(a.allocator())) {
        .ok => |n| n,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(f64, 0.0), first.children[0].value);
    const toggle = first.children[0].handler.?;
    switch (v.call(a.allocator(), toggle, .{ .number = 3.0 })) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| testing.allocator.free(e),
    }
    const second = switch (v.call(a.allocator(), toggle, .{ .boolean = true })) {
        .ok => |n| n,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(f64, 1.0), second.children[0].value);
    const slider = second.children[1].handler.?;
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -1.0, 11.0 }) |bad| {
        switch (v.call(a.allocator(), slider, .{ .number = bad })) {
            .ok => return error.TestUnexpectedResult,
            .err => |e| testing.allocator.free(e),
        }
    }
    const third = switch (v.call(a.allocator(), slider, .{ .number = 7.5 })) {
        .ok => |n| n,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(f64, 7.5), third.children[1].value);
    try testing.expectEqual(@as(f64, 1.0), third.children[0].value);
}

test "sandbox has only local safe capabilities" {
    const s =
        \\for _, name in ipairs({'io','os','debug','package','require','load','loadfile',
        \\    'loadstring','dofile','print','warn','getfenv','setfenv','newproxy',
        \\    'collectgarbage','coroutine','buffer'}) do
        \\    assert(_G[name] == nil, name)
        \\end
        \\assert(math.floor(1.5) == 1)
        \\assert(string.upper('ok') == 'OK')
        \\assert(not pcall(function() math.floor = function() return 9 end end))
        \\assert(not pcall(function() ui.text = function() end end))
        \\return function() return ui.text('safe') end
    ;
    if (check(testing.allocator, s)) |e| {
        testing.allocator.free(e);
        return error.TestUnexpectedResult;
    }
    const first = switch (Visual.init(testing.allocator, "private_value=7; return function() return ui.text{text=private_value} end")) {
        .ok => |v| v,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    defer first.deinit();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const tree = switch (first.render(a.allocator())) {
        .ok => |n| n,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("7", tree.text);
    if (check(testing.allocator, "assert(private_value == nil); return function() return ui.rule{} end")) |e| {
        testing.allocator.free(e);
        return error.TestUnexpectedResult;
    }
}

test "performance counter conversion preserves sandbox deadline units without overflow" {
    try testing.expectEqual(@as(i128, 20 * std.time.ns_per_ms), performanceCounterNs(200_000, 10_000_000));
    try testing.expectEqual(@as(i128, 1_000_000_000), performanceCounterNs(3_579_545, 3_579_545));
    try testing.expectEqual(@as(i128, 922_337_203_685_477_580_700), performanceCounterNs(std.math.maxInt(i64), 10_000_000));
}

test "visual deadline clock is monotonic and advances" {
    const start = nowNs();
    var previous = start;
    for (0..10_000) |_| {
        const current = nowNs();
        try testing.expect(current >= previous);
        previous = current;
    }
    try testing.expect(previous > start);
}

test "transcript fixture clock ignores host pauses but still enforces the budget" {
    const clock = TestClock.init();
    defer clock.deinit();
    var v: Visual = .{ .gpa = testing.allocator };
    v.armBudget();
    // A descheduled CI runner can pause for longer than the entire sandbox
    // budget even though the script has done no work.
    try std.Io.sleep(testing.io, .fromMilliseconds(25), .awake);
    try testing.expect(v.checkBudget() == null);
    TestClock.time_ns.? += call_budget_ns;
    try testing.expectEqualStrings("visual execution exceeded 20 ms", v.checkBudget().?);
}

test "transcript fixture clock still interrupts runaway scripts" {
    const clock = TestClock.init();
    defer clock.deinit();
    switch (Visual.init(testing.allocator, "while true do end")) {
        .ok => |v| {
            v.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |err| {
            defer testing.allocator.free(err);
            try testing.expectEqualStrings("visual execution exceeded 20 ms", err);
        },
    }
}

test "setup render and handler loops time out" {
    const start = nowNs();
    switch (Visual.init(testing.allocator, "while true do end")) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "20 ms") != null);
        },
    }
    var r = try testRender("while true do end");
    defer r.arena.deinit();
    try testing.expect(r.err != null);
    try testing.expect(std.mem.indexOf(u8, r.err.?, "20 ms") != null);
    testing.allocator.free(r.err.?);

    const v = switch (Visual.init(testing.allocator, "return function() return ui.button{label='Loop', onClick=function() while true do end end} end")) {
        .ok => |v| v,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    defer v.deinit();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const h = switch (v.render(a.allocator())) {
        .ok => |n| n.handler.?,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    switch (v.call(a.allocator(), h, .click)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "20 ms") != null);
        },
    }
    try testing.expectEqual(@as(usize, 0), v.handlers.count());
    try testing.expect((nowNs() - start) < 5 * std.time.ns_per_s);
}

test "caught timeout cannot turn into a successful render" {
    var r = try testRender("pcall(function() while true do end end); return ui.text('late')");
    defer r.arena.deinit();
    try testing.expect(r.err != null);
    try testing.expect(std.mem.indexOf(u8, r.err.?, "20 ms") != null);
    testing.allocator.free(r.err.?);
}

test "memory and source are bounded" {
    const too_big = try testing.allocator.alloc(u8, max_source_bytes + 1);
    defer testing.allocator.free(too_big);
    @memset(too_big, ' ');
    switch (Visual.init(testing.allocator, too_big)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "64 KiB") != null);
        },
    }
    switch (Visual.init(testing.allocator, "local huge = string.rep('x', 32 * 1024 * 1024); return function() return ui.text(huge) end")) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            defer testing.allocator.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "memory") != null);
        },
    }
    var r = try testRender("local huge=string.rep('x',32*1024*1024); return ui.text(huge)");
    defer r.arena.deinit();
    try testing.expect(r.err != null);
    try testing.expect(std.mem.indexOf(u8, r.err.?, "memory") != null);
    testing.allocator.free(r.err.?);
}

test "invalid kinds properties and values fail closed" {
    const cases = [_][]const u8{
        "return {__kind='html'}",
        "return ui.webview{}",
        "return ui.text{text='x', background='red'}",
        "return ui.text{text='x', style={}}",
        "return ui.text{text='x', font='large'}",
        "return ui.chart{values={1}, color='#fff'}",
        "return ui.row{children={ui.text('x')}}",
        "return ui.column{[2]=ui.text('hole')}",
        "return ui.rule{ui.text('child')}",
        "local n=ui.text('x'); n.rawcolors={}; return n",
        "return ui.slider{value=1,min=5,max=2}",
        "return ui.toggle{value=1}",
        "return ui.button{onClick='not a function'}",
        "return ui.chart{values={1,2},labels={'only one'}}",
        "return ui.chart{values={[1]=1,[3]=3}}",
        "return ui.chart{values={1,2,extra=3}}",
        "return ui.text{}",
        "return 'not a node'",
        "return setmetatable({}, {__index=function() while true do end end})",
        "return ui.chart{values={0/0}}",
        "return ui.slider{min=0,max=1,value=math.huge}",
        "return ui.text({text=-math.huge})",
        "return ui.stat{label='Bad',value=0/0}",
    };
    for (cases) |body| {
        var r = try testRender(body);
        defer r.arena.deinit();
        try testing.expect(r.err != null);
        testing.allocator.free(r.err.?);
    }
    for ([_][]const u8{ "return ui.text('not a renderer')", "not valid luau !" }) |bad| {
        switch (Visual.init(testing.allocator, bad)) {
            .ok => return error.TestUnexpectedResult,
            .err => |e| testing.allocator.free(e),
        }
    }
}

test "output limits cover cycles depth nodes text and series" {
    const bad = [_][]const u8{
        "local n=ui.column{}; n[1]=n; return n",
        "local n=ui.text('x'); for i=1,24 do n=ui.column{n} end; return n",
        "local t={}; for i=1,512 do t[i]=ui.rule{} end; return ui.column(t)",
        "return ui.text(string.rep('x',8193))",
        "return ui.column{ui.text(string.rep('x',4096)),ui.text(string.rep('x',4097))}",
        "local t={}; for i=1,257 do t[i]=i end; return ui.chart{values=t}",
    };
    for (bad) |body| {
        var r = try testRender(body);
        defer r.arena.deinit();
        try testing.expect(r.err != null);
        testing.allocator.free(r.err.?);
    }
    const ok = [_][]const u8{
        "local n=ui.text('x'); for i=1,23 do n=ui.column{n} end; return n",
        "local t={}; for i=1,511 do t[i]=ui.rule{} end; return ui.column(t)",
        "return ui.text(string.rep('x',8192))",
        "local t={}; for i=1,256 do t[i]=i end; return ui.chart{values=t}",
    };
    for (ok) |body| {
        var r = try testRender(body);
        defer r.arena.deinit();
        if (r.err) |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        }
    }
}

test "repeated renders release handlers and invalidate old ids" {
    const src =
        \\return function()
        \\    local payload=string.rep('x',4096)
        \\    return ui.button{onClick=function() assert(#payload==4096) end}
        \\end
    ;
    const v = switch (Visual.init(testing.allocator, src)) {
        .ok => |v| v,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    defer v.deinit();
    v.gcCollect();
    const baseline = v.usedMemory();

    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const old = switch (v.render(a.allocator())) {
        .ok => |n| n.handler.?,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    for (0..1000) |_| {
        var loop_a = std.heap.ArenaAllocator.init(testing.allocator);
        defer loop_a.deinit();
        switch (v.render(loop_a.allocator())) {
            .ok => {},
            .err => |e| {
                testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
        }
        try testing.expectEqual(@as(usize, 1), v.handlers.count());
    }
    v.gcCollect();
    try testing.expect(v.usedMemory() < baseline + 256 * 1024);
    switch (v.call(a.allocator(), old, .click)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| testing.allocator.free(e),
    }
}

test "failed render discards callbacks and check does not execute handlers" {
    if (check(testing.allocator, "return function() return ui.button{onClick=function() error('not run') end} end")) |e| {
        testing.allocator.free(e);
        return error.TestUnexpectedResult;
    }
    const src =
        \\local broken=false
        \\return function()
        \\    if broken then return ui.column{ui.button{onClick=function() end}, false} end
        \\    return ui.button{onClick=function() broken=true end}
        \\end
    ;
    const v = switch (Visual.init(testing.allocator, src)) {
        .ok => |v| v,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    defer v.deinit();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const h = switch (v.render(a.allocator())) {
        .ok => |n| n.handler.?,
        .err => |e| {
            testing.allocator.free(e);
            return error.TestUnexpectedResult;
        },
    };
    switch (v.call(a.allocator(), h, .click)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| testing.allocator.free(e),
    }
    try testing.expectEqual(@as(usize, 0), v.handlers.count());
    switch (v.call(a.allocator(), h, .click)) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| testing.allocator.free(e),
    }
}
