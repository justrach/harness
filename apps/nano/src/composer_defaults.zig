//! The new chat's remembered agent, model and reasoning
//! (`{data_dir}/composer-defaults.json`, crates/ui/src/settings/composer.rs):
//! the GPUI app's own file, merged key by key so its favorites, model options
//! and fields this app doesn't know stay as they are.
const std = @import("std");
const json = std.json;
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

/// Before the first frame: the new chat starts on the last explicit picks.
pub fn apply(a: *App) void {
    var root_storage = load(a) orelse return;
    defer root_storage.deinit();
    const root = switch (root_storage.value) {
        .object => |o| o,
        else => return,
    };
    const harness: []const u8 = if (root.get("harness")) |v|
        if (v == .string and v.string.len > 0) v.string else a.new_harness
    else
        a.new_harness;
    setHarness(a, harness);
    if (root.get("modelByHarness")) |by_harness| if (by_harness == .object) {
        if (by_harness.object.get(harness)) |remembered| if (remembered == .object) {
            if (remembered.object.get("id")) |id| if (id == .string and id.string.len > 0) setNew(a, &a.new_model, id.string);
        };
    };
    if (root.get("reasoning")) |reasoning| switch (reasoning) {
        .string => |level| if (level.len > 0) setNew(a, &a.new_reasoning, level),
        .null => setNew(a, &a.new_reasoning, null),
        else => {},
    };
}

/// The picks remembered for `harness`, after a harness switch: its model and
/// the last reasoning level. The harness itself is the caller's.
pub fn adopt(a: *App, harness: []const u8) void {
    var root_storage = load(a) orelse return;
    defer root_storage.deinit();
    const root = switch (root_storage.value) {
        .object => |o| o,
        else => return,
    };
    if (root.get("modelByHarness")) |by_harness| if (by_harness == .object) {
        if (by_harness.object.get(harness)) |remembered| if (remembered == .object) {
            if (remembered.object.get("id")) |id| if (id == .string and id.string.len > 0) {
                setNew(a, &a.new_model, id.string);
            };
        };
    };
    if (root.get("reasoning")) |reasoning| {
        if (reasoning == .string and reasoning.string.len > 0) setNew(a, &a.new_reasoning, reasoning.string);
    }
}

pub fn rememberHarness(a: *App) void {
    save(a, .harness);
}

pub fn rememberModel(a: *App) void {
    save(a, .model);
}

pub fn rememberReasoning(a: *App) void {
    save(a, .reasoning);
}

const Change = enum { harness, model, reasoning };

/// Only the new-chat canvas is sticky. An open chat's config belongs to its
/// own row (`SetChatConfig`), and plain chats keep their code defaults.
fn save(a: *App, change: Change) void {
    if (a.selected != null or a.new_chat_mode) return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    var storage = load(a) orelse Loaded{ .arena = .init(a.gpa), .value = .{ .object = .empty } };
    defer storage.deinit();
    var root = switch (storage.value) {
        .object => |o| o,
        else => json.ObjectMap.empty,
    };
    root.put(gpa, "harness", .{ .string = a.new_harness }) catch return;
    switch (change) {
        .harness => {},
        .reasoning => root.put(gpa, "reasoning", if (a.new_reasoning) |level| .{ .string = level } else .null) catch return,
        .model => {
            const id = a.new_model orelse {
                // A model pick always carries its harness and level; with
                // neither there is nothing new to remember.
                write(a, gpa, root) catch {};
                return;
            };
            const label = modelLabel(a, id);
            var by_harness: json.ObjectMap = .empty;
            if (root.get("modelByHarness")) |v| if (v == .object) {
                by_harness = v.object;
            };
            var remembered: json.ObjectMap = .empty;
            if (by_harness.get(a.new_harness)) |v| if (v == .object) {
                remembered = v.object;
            };
            remembered.put(gpa, "id", .{ .string = id }) catch return;
            remembered.put(gpa, "label", .{ .string = label }) catch return;
            by_harness.put(gpa, a.new_harness, .{ .object = remembered }) catch return;
            root.put(gpa, "modelByHarness", .{ .object = by_harness }) catch return;
            root.put(gpa, "reasoning", if (a.new_reasoning) |level| .{ .string = level } else .null) catch return;
            var labels: json.ObjectMap = .empty;
            if (root.get("modelLabels")) |v| if (v == .object) {
                labels = v.object;
            };
            labels.put(gpa, id, .{ .string = label }) catch return;
            root.put(gpa, "modelLabels", .{ .object = labels }) catch return;
        },
    }
    write(a, gpa, root) catch {};
}

fn modelLabel(a: *const App, id: []const u8) []const u8 {
    for (a.models.items) |m| if (std.mem.eql(u8, m.id, id)) return m.label;
    return id;
}

fn setHarness(a: *App, harness: []const u8) void {
    const copy = a.gpa.dupe(u8, harness) catch return;
    a.gpa.free(a.new_harness);
    a.new_harness = copy;
}

fn setNew(a: *App, field: *?[]u8, value: ?[]const u8) void {
    if (field.*) |old| a.gpa.free(old);
    field.* = if (value) |v| a.gpa.dupe(u8, v) catch null else null;
}

fn defaultsPath(a: *const App, gpa: Allocator) ?[]u8 {
    const dir = a.settings.dataDir() orelse return null;
    return std.fs.path.join(gpa, &.{ dir, "composer-defaults.json" }) catch null;
}

const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    value: json.Value,

    fn deinit(l: *Loaded) void {
        l.arena.deinit();
    }
};

fn load(a: *const App) ?Loaded {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    errdefer arena.deinit();
    const gpa = arena.allocator();
    const path = defaultsPath(a, gpa) orelse {
        arena.deinit();
        return null;
    };
    const body = std.Io.Dir.cwd().readFileAlloc(a.io, path, gpa, .limited(1 << 20)) catch {
        arena.deinit();
        return null;
    };
    const value = json.parseFromSliceLeaky(json.Value, gpa, body, .{}) catch {
        arena.deinit();
        return null;
    };
    return .{ .arena = arena, .value = value };
}

fn write(a: *App, gpa: Allocator, root: json.ObjectMap) !void {
    const path = defaultsPath(a, gpa) orelse return error.NoDataDir;
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(a.io, dir);
    }
    const body = try json.Stringify.valueAlloc(gpa, json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    const tmp = try std.fmt.allocPrint(gpa, "{s}.nano-{d}.tmp", .{ path, std.Io.Clock.real.now(a.io).toNanoseconds() });
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = tmp, .data = body });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, a.io);
}
