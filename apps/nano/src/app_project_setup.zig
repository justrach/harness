//! v0.2.173 AddSpacePalette: name-first draft; browsing is read-only.
const std = @import("std");
const ui = @import("nanoui").ui;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const paths = @import("project_paths.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Step = enum { details, devices, locations, folders };
pub const Entry = struct { name: []const u8, isDir: bool = false, isRepo: bool = false };
pub const Listing = struct { path: []const u8, entries: []const Entry, truncated: bool = false };
pub const Drive = struct { name: []const u8, path: []const u8 };
const Drives = struct { drives: []const Drive };
pub const Folder = struct { device: []const u8, device_name: []const u8, path: []const u8, git: bool };
pub const State = struct {
    open: bool = false,
    /// Scopes the sheet's entrance motion across repeated opens.
    generation: u64 = 0,
    step: Step = .details,
    name: ui.TextBuffer = .{},
    query: ui.TextBuffer = .{},
    focus: bool = false,
    field: u64 = 0,
    controls: [3]u64 = .{ 0, 0, 0 },
    active: usize = 0,
    scroll: u64 = 0,
    reveal: bool = false,
    device: ?[]const u8 = null,
    device_name: []const u8 = "",
    folder: ?Folder = null,
    home: ?[]const u8 = null,
    root: ?[]const u8 = null,
    requested_path: ?[]const u8 = null,
    preferred: ?[]const u8 = null,
    loading: bool = false,
    loaded: bool = false,
    git: bool = false,
    listing: ?std.json.Parsed(Listing) = null,
    drives: ?std.json.Parsed(Drives) = null,
    load_call: ?u64 = null,
    drives_call: ?u64 = null,
    submit_call: ?u64 = null,
    submit_id: ?[]const u8 = null,
    busy: bool = false,
    err: ?[]const u8 = null,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(s: *State) void {
        @import("text_buffer.zig").deinit(&s.name);
        @import("text_buffer.zig").deinit(&s.query);
        if (s.listing) |*v| v.deinit();
        if (s.drives) |*v| v.deinit();
        if (s.arena) |*v| v.deinit();
    }
    fn alloc(s: *State) Allocator {
        return s.arena.?.allocator();
    }
    fn keep(s: *State, text: []const u8) []const u8 {
        return s.alloc().dupe(u8, text) catch "";
    }
};

pub fn open(a: *App) void {
    const s = &a.view.project_setup;
    if (s.busy) return;
    cancelReads(a);
    const generation = s.generation +% 1;
    s.deinit();
    s.* = .{ .open = true, .generation = generation, .focus = true, .arena = .init(a.gpa) };
    // A panel's explicit remote host must not silently fall back to this Mac.
    if (a.draftDevice()) |id| {
        s.device = s.keep(id);
        s.device_name = s.keep(a.deviceName(id));
    }
    a.view.palette.open = false;
    a.view.strip.menu = null;
    a.view.space_menu = false;
    a.view.filter_menu = false;
    a.view.focus_composer = false;
    a.redraw();
}

fn cancelReads(a: *App) void {
    const s = &a.view.project_setup;
    if (s.load_call) |id| a.engine.cancel(id);
    if (s.drives_call) |id| a.engine.cancel(id);
    s.load_call = null;
    s.drives_call = null;
    s.loading = false;
}

pub fn details(a: *App) void {
    const s = &a.view.project_setup;
    if (s.busy) return;
    cancelReads(a);
    s.step = .details;
    s.focus = true;
    s.err = null;
    a.redraw();
}

pub fn dismiss(a: *App) void {
    const s = &a.view.project_setup;
    if (s.busy) return;
    if (s.step != .details) return details(a);
    cancelReads(a);
    s.open = false;
    a.view.focus_composer = true;
    a.redraw();
}

pub fn devices(a: *App) void {
    const s = &a.view.project_setup;
    cancelReads(a);
    s.step = .devices;
    s.query.set("");
    s.active = 0;
    s.focus = true;
    s.err = null;
    a.redraw();
}

pub fn beginFolder(a: *App) void {
    const s = &a.view.project_setup;
    if (s.busy) return;
    const id = if (s.folder) |f| f.device else s.device;
    if (id) |want| {
        for (a.devices.items) |d| if (std.mem.eql(u8, d.id, want)) {
            pickDevice(a, d);
            if (s.folder) |f| {
                s.preferred = null;
                s.root = s.keep(f.path);
                browse(a, f.path, f.git);
            } else if (s.preferred == null) browse(a, null, false);
            return;
        };
        devices(a);
        s.err = "This computer is unavailable. Choose another device.";
    } else if (a.devices.items.len == 1) pickDevice(a, a.devices.items[0]) else devices(a);
}

pub fn pickDevice(a: *App, d: workspace.Device) void {
    cancelReads(a);
    const s = &a.view.project_setup;
    s.device = s.keep(d.id);
    s.device_name = s.keep(d.name);
    s.home = null;
    s.root = null;
    s.preferred = paths.starting(s.alloc(), a.settings.doc.get("projectFoldersByDevice"), d.id, a.spaces.items) catch null;
    if (s.drives) |*v| v.deinit();
    s.drives = null;
    locations(a);
    s.drives_call = a.send_(requests.listDrives(host(a)), .of(App, a, onDrives));
    if (s.preferred != null) browse(a, null, false);
}

fn host(a: *App) ?[]const u8 {
    const id = a.view.project_setup.device orelse return null;
    return if (std.mem.eql(u8, a.device_id orelse "", id)) null else id;
}

pub fn locations(a: *App) void {
    cancelReads(a);
    const s = &a.view.project_setup;
    s.step = .locations;
    s.query.set("");
    s.active = 0;
    s.focus = true;
    s.err = null;
    a.redraw();
}

pub fn browse(a: *App, path: ?[]const u8, git: bool) void {
    const s = &a.view.project_setup;
    if (s.busy or s.device == null) return;
    if (s.load_call) |id| a.engine.cancel(id);
    s.load_call = null;
    s.step = .folders;
    s.requested_path = if (path) |p| s.keep(p) else null;
    s.git = git;
    s.loading = true;
    s.loaded = false;
    s.query.set("");
    s.active = 0;
    s.reveal = true;
    s.focus = true;
    s.err = null;
    s.load_call = a.send_(requests.listFolders(s.requested_path, host(a)), .of(App, a, onFolders));
    if (s.load_call == null) {
        s.loading = false;
        if (s.err == null) s.err = "Not connected. Reconnect and try again.";
    }
    a.redraw();
}

fn onDrives(a: *App, id: u64, reply: rpc.Reply) void {
    const s = &a.view.project_setup;
    if (!s.open or (id != 0 and s.drives_call != id)) return;
    s.drives_call = null;
    if (reply == .ok) {
        const parsed = std.json.parseFromValue(Drives, a.gpa, reply.ok, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
        if (s.drives) |*v| v.deinit();
        s.drives = parsed;
    }
    // Drives are best-effort: Home still works on older hosts.
    a.redraw();
}

fn onFolders(a: *App, id: u64, reply: rpc.Reply) void {
    const s = &a.view.project_setup;
    if (!s.open or s.step != .folders or (id != 0 and s.load_call != id)) return;
    s.load_call = null;
    s.loading = false;
    switch (reply) {
        .ok => |v| {
            const parsed = std.json.parseFromValue(Listing, a.gpa, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
                s.err = "The computer returned an invalid folder listing.";
                a.redraw();
                return;
            };
            if (s.listing) |*old| old.deinit();
            s.listing = parsed;
            s.loaded = true;
            if (s.requested_path == null) {
                s.home = s.keep(parsed.value.path);
                s.root = s.home;
                if (s.preferred) |preferred| {
                    const target = paths.resolve(s.alloc(), preferred, s.home.?) catch s.home.?;
                    if (!std.mem.eql(u8, target, s.home.?)) {
                        browse(a, target, false);
                        return;
                    }
                    s.preferred = null;
                }
            } else if (s.preferred != null) {
                s.root = s.keep(parsed.value.path);
                s.preferred = null;
            }
        },
        .err => |why| {
            if (s.preferred != null and s.listing != null and s.home != null) {
                s.preferred = null;
                s.requested_path = s.home;
                s.loaded = true;
                s.err = "Default folder unavailable; opened Home. Change it in Settings → Files.";
            } else s.err = s.keep(why);
        },
        else => return,
    }
    a.redraw();
}

pub fn ready(s: *const State) ?Listing {
    // Even a failed refresh of the same path cannot confirm stale data.
    if (s.step != .folders or s.loading or !s.loaded) return null;
    return if (s.listing) |l| l.value else null;
}

pub fn useFolder(a: *App) void {
    const s = &a.view.project_setup;
    if (s.busy or s.step != .folders) return;
    const l = ready(s) orelse return;
    s.folder = .{ .device = s.keep(s.device orelse return), .device_name = s.keep(s.device_name), .path = s.keep(l.path), .git = s.git };
    details(a);
}

pub fn up(a: *App) void {
    const s = &a.view.project_setup;
    if (s.step == .locations) return devices(a);
    if (s.step != .folders) return;
    if (ready(s)) |l| {
        if (!std.mem.eql(u8, l.path, s.root orelse "")) if (paths.parent(l.path)) |p| return browse(a, p, false);
    }
    locations(a);
}

pub fn existing(a: *const App) ?workspace.Space {
    const f = a.view.project_setup.folder orelse return null;
    for (a.spaces.items) |space| if (std.mem.eql(u8, space.device_id orelse "", f.device) and std.mem.eql(u8, space.path, f.path)) return space;
    return null;
}

pub fn canSubmit(a: *const App) bool {
    const s = &a.view.project_setup;
    return s.open and !s.busy and s.step == .details and s.folder != null and
        (existing(a) != null or std.mem.trim(u8, s.name.text(), " \t\r\n").len != 0);
}

pub fn submit(a: *App) void {
    if (!canSubmit(a)) return;
    const s = &a.view.project_setup;
    if (existing(a)) |space| return finish(a, space.id);
    if (!a.engine.up()) {
        s.err = "Not connected. Reconnect and try again.";
        a.redraw();
        return;
    }
    const f = s.folder.?;
    var buf: [36]u8 = undefined;
    s.submit_id = s.keep(@import("app.zig").uuid(a.io, &buf));
    s.busy = true;
    s.err = null;
    s.submit_call = a.send_(requests.createNamedSpace(s.submit_id.?, f.device, f.path, std.mem.trim(u8, s.name.text(), " \t\r\n"), f.git), .of(App, a, onCreated));
    if (s.submit_call == null) {
        s.busy = false;
        if (s.err == null) s.err = "Could not send the project. Try again.";
    }
    a.redraw();
}

fn onCreated(a: *App, id: u64, reply: rpc.Reply) void {
    const s = &a.view.project_setup;
    if (!s.open or !s.busy or (id != 0 and s.submit_call != id)) return;
    s.submit_call = null;
    s.busy = false;
    switch (reply) {
        .ok => {
            // A watch can lag the acknowledgement. Echo only AFTER success,
            // so the draft has its actual host/path/name before WatchSpaces.
            const f = s.folder.?;
            // The watch may have already delivered this project (or a
            // concurrent create for the same host/folder). Never duplicate it.
            if (existing(a)) |space| {
                a.settings.recordProjectFolder(f.device, f.path, a.spaces.items);
                finish(a, space.id);
                return;
            }
            var rows: std.json.Array = .init(s.alloc());
            for (a.spaces.items) |space| {
                const v = std.json.Stringify.valueAlloc(s.alloc(), .{ .id = space.id, .deviceId = space.device_id, .path = space.path, .name = space.name, .gitDetected = space.git, .checkoutId = space.checkout_id }, .{}) catch return;
                rows.append(std.json.parseFromSliceLeaky(std.json.Value, s.alloc(), v, .{}) catch return) catch return;
            }
            const v = std.json.Stringify.valueAlloc(s.alloc(), .{ .id = s.submit_id.?, .deviceId = f.device, .path = f.path, .name = std.mem.trim(u8, s.name.text(), " \t\r\n"), .gitDetected = f.git }, .{}) catch return;
            rows.append(std.json.parseFromSliceLeaky(std.json.Value, s.alloc(), v, .{}) catch return) catch return;
            a.spaces.replace(.{ .array = rows }) catch return;
            a.settings.recordProjectFolder(f.device, f.path, a.spaces.items);
            finish(a, s.submit_id.?);
        },
        .err => |why| s.err = s.keep(why),
        else => return,
    }
    a.redraw();
}

fn finish(a: *App, id: []const u8) void {
    cancelReads(a);
    a.view.project_setup.open = false;
    a.newTab();
    a.select(null, id);
    a.setSpaceFilter(id);
    a.view.focus_composer = true;
    a.redraw();
}
