//! One destination chooser for a new tab, a split, or a project. It only
//! changes the draft picks; the actual tab or split is made after the choice.
const std = @import("std");
const ui = @import("nanoui").ui;
const tabs = @import("tabs.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Intent = enum {
    new_tab,
    split_right,
    split_down,
    new_project,

    pub fn title(i: Intent) []const u8 {
        return switch (i) {
            .new_tab => "New session",
            .split_right => "Split to the right",
            .split_down => "Split below",
            .new_project => "Open a project",
        };
    }
};

pub const State = struct {
    open: bool = false,
    intent: Intent = .new_tab,
    generation: u64 = 0,
    device: ?[]u8 = null,
    cursor: usize = 0,
    focus: bool = false,
    query: ui.TextBuffer = .{},
    field: u64 = 0,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(s: *State) void {
        @import("text_buffer.zig").deinit(&s.query);
        if (s.arena) |*a| a.deinit();
        s.arena = null;
    }

    fn reset(s: *State, gpa: Allocator) Allocator {
        @import("text_buffer.zig").deinit(&s.query);
        if (s.arena) |*a| a.deinit();
        const generation = s.generation;
        s.* = .{ .open = true, .generation = generation, .focus = true, .arena = .init(gpa) };
        return s.arena.?.allocator();
    }
};

pub fn open(a: *App, intent: Intent) void {
    const s = &a.view.open_chooser;
    const generation = s.generation +% 1;
    const alloc = s.reset(a.gpa);
    s.generation = generation;
    s.intent = intent;
    s.device = if (a.draftDevice()) |id| alloc.dupe(u8, id) catch null else null;
    if (s.device == null) s.device = if (a.device_id) |id| alloc.dupe(u8, id) catch null else null;
    a.view.focus_composer = false;
    a.redraw();
}

pub fn close(a: *App) void {
    const s = &a.view.open_chooser;
    if (!s.open) return;
    s.open = false;
    a.view.focus_composer = true;
    a.redraw();
}

/// A chip changes the folder list without changing the current draft.
pub fn pickDevice(a: *App, id: ?[]const u8) void {
    const s = &a.view.open_chooser;
    const alloc = s.arena.?.allocator();
    const copy = if (id) |want| alloc.dupe(u8, want) catch return else return;
    s.device = copy;
    s.cursor = 0;
    s.query.set("");
    s.focus = true;
    a.redraw();
}

pub fn currentDevice(a: *const App) ?[]const u8 {
    return a.view.open_chooser.device orelse a.device_id;
}

pub fn projects(a: *const App, alloc: Allocator) ![]workspace.Space {
    const s = &a.view.open_chooser;
    const device = s.device orelse a.device_id;
    var out: std.ArrayList(workspace.Space) = .empty;
    for (a.spaces.items) |space| {
        if (device) |want| if (space.device_id) |have| {
            if (!std.mem.eql(u8, want, have)) continue;
        };
        if (!containsIgnoreCase(space.name, s.query.text())) continue;
        try out.append(alloc, space);
    }
    std.mem.sort(workspace.Space, out.items, {}, struct {
        fn lessThan(_: void, x: workspace.Space, y: workspace.Space) bool {
            const order = std.ascii.orderIgnoreCase(x.name, y.name);
            return if (order == .eq) std.mem.order(u8, x.id, y.id) == .lt else order == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn setDestination(a: *App, device: ?[]const u8, space_id: ?[]const u8) bool {
    var host = device;
    if (space_id) |id| {
        if (a.findSpace(id)) |space| host = space.device_id orelse host;
    }
    const space_copy = if (space_id) |id| a.gpa.dupe(u8, id) catch return false else null;
    const device_copy = if (host) |id| a.gpa.dupe(u8, id) catch {
        if (space_copy) |copy| a.gpa.free(copy);
        return false;
    } else null;
    if (a.space) |old| a.gpa.free(old);
    if (a.new_device) |old| a.gpa.free(old);
    a.space = space_copy;
    a.new_device = device_copy;
    a.new_no_project = space_id == null;
    return true;
}

pub fn choose(a: *App, space_id: ?[]const u8) void {
    const s = &a.view.open_chooser;
    if (!s.open) return;
    const intent = s.intent;
    const device = s.device;
    s.open = false;
    // Creating a tab or pane copies the outgoing chat's destination, so the
    // explicit choice is applied to the fresh draft afterwards.
    switch (intent) {
        .new_tab => a.addChatTab(false),
        .new_project => a.newTab(),
        .split_right => a.splitPane(.horizontal),
        .split_down => a.splitPane(.vertical),
    }
    if (setDestination(a, device, space_id)) a.select(null, space_id);
    a.view.focus_composer = true;
    a.redraw();
}

pub fn chooseProjectless(a: *App) void {
    choose(a, null);
}

/// The same chooser's folder step opens the real project form with the
/// selected computer already in hand.
pub fn newProject(a: *App) void {
    const s = &a.view.open_chooser;
    const device = s.device orelse a.device_id;
    if (!setDestination(a, device, null)) return;
    s.open = false;
    @import("app_project_setup.zig").open(a);
    a.redraw();
}
