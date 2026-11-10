//! Per-device update controls (settings/devices/updates.rs). Only the
//! expanded host is watched; leaving the page or choosing another host drops
//! its stream. Nothing here infers what a host can do from its version or
//! its system: it says so in its status, or it isn't offered.
//!
//! Nano doesn't track the latest release itself, so the toggle never reads
//! "Update available · Details" as the GPUI app's can.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const set = @import("view_settings.zig");
const workspace = @import("workspace.zig");
const requests = @import("requests.zig");
const rpc = @import("rpc.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;
const json = std.json;

const offline_line = "Offline. Open Harness on this computer to check its updates.";
const reply_timeout: f64 = 30; // `UPDATE_CHECK_TIMEOUT`

pub const Mode = enum { managed, desktop, manual };
pub const Phase = enum { idle, checking, downloading, waitingForIdle, restarting, failed };
pub const Host = struct { mode: Mode, automatic: bool, phase: Phase };

/// One reply of the `UpdateStatus` stream.
pub const Status = struct {
    current: []const u8 = "",
    latest: ?[]const u8 = null,
    available: bool = false,
    err: ?[]const u8 = null,
    host: ?Host = null,
};

fn text(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `v` as a status, its strings copied into `arena`; null if it isn't one.
pub fn parse(arena: Allocator, v: json.Value) ?Status {
    if (v != .object) return null;
    const o = v.object;
    const current = text(o, "currentVersion") orelse return null;
    var s: Status = .{ .current = arena.dupe(u8, current) catch return null };
    if (text(o, "latestVersion")) |l| s.latest = arena.dupe(u8, l) catch return null;
    if (text(o, "error")) |e| s.err = arena.dupe(u8, e) catch return null;
    if (o.get("updateAvailable")) |a| s.available = a == .bool and a.bool;
    if (o.get("host")) |h| if (h == .object) {
        const mode = std.meta.stringToEnum(Mode, text(h.object, "mode") orelse return null) orelse return null;
        const phase = std.meta.stringToEnum(Phase, text(h.object, "phase") orelse "idle") orelse return null;
        const automatic = if (h.object.get("automatic")) |a| a == .bool and a.bool else false;
        s.host = .{ .mode = mode, .automatic = automatic, .phase = phase };
    };
    return s;
}

/// What can be installed remotely, and whether it can be asked for now.
pub const Summary = struct { line: []const u8, can_queue: bool };

/// `remote_summary`: never infer remote-install capability from a version
/// number or an OS. `a` holds a line that names an error.
pub fn summary(a: Allocator, s: Status) Summary {
    const host = s.host orelse return .{
        .line = "This older host doesn't report update controls. Update Harness on it once to enable remote scheduling.",
        .can_queue = false,
    };
    switch (host.mode) {
        .desktop => {
            const line = if (s.err) |e|
                std.fmt.allocPrint(a, "Couldn't check for updates: {s}", .{e}) catch "Couldn't check for updates."
            else if (host.phase == .checking)
                "Checking for updates…"
            else if (!host.automatic)
                "Automatic downloads are disabled on this computer. Update from its desktop app; remote restarts aren't offered."
            else
                "This computer's desktop app installs its own updates. Enable automatic restarts in its Settings → Devices; it waits for idle chats and unsaved work.";
            return .{ .line = line, .can_queue = false };
        },
        .manual => return .{
            .line = "This is a source or package-managed install. Update it on that computer using its original installation method.",
            .can_queue = false,
        },
        .managed => {},
    }
    const line = switch (host.phase) {
        .checking => "Checking for updates…",
        .downloading => "Downloading the update. Your chats can keep running.",
        .waitingForIdle => "Update downloaded. Waiting for chats to finish and terminals to close before restarting.",
        .restarting => "Restarting into the update. This device will reconnect.",
        .failed => std.fmt.allocPrint(a, "Update failed: {s}", .{s.err orelse "refresh to try again"}) catch "Update failed.",
        .idle => if (host.automatic)
            "Automatic updates are on. This host installs updates when chats and terminals are idle."
        else
            "Automatic updates are off on this host. You can request one update without changing that setting.",
    };
    return .{ .line = line, .can_queue = s.available and (host.phase == .idle or host.phase == .failed) };
}

/// `can_check`.
pub fn canCheck(s: Status) bool {
    const host = s.host orelse return false;
    return host.mode != .manual and (host.phase == .idle or host.phase == .failed);
}

/// `host_platform`: computers, which can run an engine to update.
pub fn hostPlatform(platform: []const u8) bool {
    for ([_][]const u8{ "linux", "macos", "darwin", "windows" }) |p| {
        if (std.mem.eql(u8, platform, p)) return true;
    }
    return false;
}

/// `Installed v…`, the line under the summary.
pub fn versionLine(a: Allocator, s: Status) []const u8 {
    const tail = if (s.err != null)
        "last check needs attention"
    else if (s.latest) |l|
        (if (s.available) std.fmt.allocPrint(a, "available v{s}", .{l}) catch "" else "up to date")
    else
        "not checked yet";
    return std.fmt.allocPrint(a, "Installed v{s} · {s}", .{ s.current, tail }) catch "";
}

/// What the page keeps of the expanded host.
pub const State = struct {
    device: std.ArrayList(u8) = .empty,
    status: ?Status = null,
    status_arena: ?std.heap.ArenaAllocator = null,
    err: std.ArrayList(u8) = .empty,
    /// A line of this file's, not owned.
    notice: ?[]const u8 = null,
    watch: ?u64 = null,
    deadline: f64 = 0,
    action: ?u64 = null,
    action_queues: bool = false,

    fn expanded(s: *const State, id: []const u8) bool {
        return s.device.items.len > 0 and std.mem.eql(u8, s.device.items, id);
    }

    fn clearStatus(s: *State, a: ?*App) void {
        if (s.status_arena) |x| {
            if (a) |app| app.retireArena(x) else {
                var ar = x;
                ar.deinit();
            }
        }
        s.status_arena = null;
        s.status = null;
    }

    fn setErr(s: *State, gpa: Allocator, line: []const u8) void {
        s.err.clearRetainingCapacity();
        s.err.appendSlice(gpa, line) catch {};
    }

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.clearStatus(null);
        s.device.deinit(gpa);
        s.err.deinit(gpa);
    }
};

fn state(a: *App) *State {
    return &a.view.devices.updates;
}

/// Drops the watch and everything known of the host, keeping which it is.
fn stopWatch(a: *App) void {
    const s = state(a);
    if (s.watch) |w| a.engine.cancel(w);
    s.watch = null;
    s.action = null;
    s.notice = null;
    s.clearStatus(a);
    s.err.clearRetainingCapacity();
}

fn collapse(a: *App) void {
    stopWatch(a);
    state(a).device.clearRetainingCapacity();
}

fn watch(a: *App, id: []const u8) void {
    const s = state(a);
    stopWatch(a);
    if (s.device.items.ptr != id.ptr) {
        s.device.clearRetainingCapacity();
        s.device.appendSlice(a.gpa, id) catch return;
    }
    s.deadline = a.now + reply_timeout;
    s.watch = a.send_(requests.updateStatus(s.device.items), .of(App, a, onStatus));
    if (s.watch == null) s.setErr(a.gpa, "Engine not connected");
    a.redraw();
}

fn onStatus(a: *App, id: u64, r: rpc.Reply) void {
    const s = state(a);
    if (s.watch != id) return;
    switch (r) {
        .item => |v| {
            var arena = std.heap.ArenaAllocator.init(a.gpa);
            const parsed = parse(arena.allocator(), v);
            if (parsed == null) {
                arena.deinit();
                s.setErr(a.gpa, "Invalid update status.");
            } else {
                s.clearStatus(a);
                s.status_arena = arena;
                s.status = parsed;
                s.err.clearRetainingCapacity();
            }
        },
        .err => |e| {
            s.watch = null;
            s.notice = null;
            s.clearStatus(a);
            s.setErr(a.gpa, e);
        },
        .done => {
            s.watch = null;
            s.notice = null;
            s.clearStatus(a);
            s.setErr(a.gpa, "Connection closed. The host may be restarting; refresh to confirm its version.");
        },
        .ok => {},
    }
    a.redraw();
}

/// `remote_update_command`.
fn command(a: *App, queue: bool) void {
    const s = state(a);
    if (s.action != null or s.err.items.len > 0) return;
    const status = s.status orelse return;
    var buf: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buf);
    const allowed = if (queue) summary(fixed.allocator(), status).can_queue else canCheck(status);
    if (!allowed) return;
    s.notice = null;
    s.action_queues = queue;
    s.action = if (queue)
        a.send_(requests.queueUpdate(s.device.items), .of(App, a, onCommand))
    else
        a.send_(requests.checkForUpdates(s.device.items), .of(App, a, onCommand));
    a.redraw();
}

fn onCommand(a: *App, id: u64, r: rpc.Reply) void {
    const s = state(a);
    if (s.action != id) return;
    s.action = null;
    switch (r) {
        .err => |e| {
            var buf: [512]u8 = undefined;
            s.setErr(a.gpa, std.fmt.bufPrint(&buf, "Request failed: {s}", .{e}) catch "Request failed.");
        },
        else => s.notice = if (s.action_queues)
            "Update requested. The host will wait for chats and terminals to finish."
        else
            "Update check requested.",
    }
    a.redraw();
}

/// Each frame: the watch ends with the page, and a host that never replied
/// doesn't leave the panel waiting.
pub fn settleFrame(a: *App) void {
    const s = state(a);
    if (s.device.items.len == 0) return;
    if (!a.view.settings_open or a.settings.section != .devices) return collapse(a);
    if (s.watch == null or s.status != null or a.now < s.deadline) return;
    if (s.watch) |w| a.engine.cancel(w);
    s.watch = null;
    s.setErr(a.gpa, "The host didn't reply. Refresh when it is online.");
}

/// `ghost_action`: no wash of its own here, as the GPUI app's has none.
fn action(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8) bool {
    ui.key(c, key);
    const b = ui.div(c).row().px(10).py(6).gap(6).itemsCenter().rounded(8);
    defer b.end();
    ui.text(c, label, set.st(c, 12, .{ .color = k.muted }));
    return b.clicked();
}

fn textLine(c: *ui.Context, k: theme.Colors, s: []const u8) void {
    ui.text(c, s, set.st(c, 12, .{ .color = k.muted, .wrap = true }));
}

/// `render_remote_update`: under a remote computer's row, the toggle and,
/// expanded, what its host says and what can be asked of it.
pub fn panel(c: *ui.Context, a: *App, k: theme.Colors, d: workspace.Device, local: bool, online: bool) void {
    if (local or !hostPlatform(d.platform)) return;
    const s = state(a);
    const selected = s.expanded(d.id);
    // `reconcile_remote_update`: nothing to watch on a host that's gone.
    if (selected and !online and s.watch != null) stopWatch(a);
    const p = ui.div(c).column().wFull().pl(66).pr(16).pb(12).gap(6);
    defer p.end();
    const older = if (d.version) |cur| if (a.release.version()) |latest| @import("graff_update.zig").newer(latest, cur) else false else false;
    const toggle_label = if (selected) "Hide updates" else if (older) "Update available · Details" else "Updates";
    if (action(c, k, c.print("device-updates-{s}", .{d.id}), toggle_label)) {
        if (selected) collapse(a) else if (online) watch(a, d.id) else {
            stopWatch(a);
            s.device.clearRetainingCapacity();
            s.device.appendSlice(a.gpa, d.id) catch {};
        }
        a.redraw();
        return;
    }
    if (!selected) return;
    const said: Summary = if (!online)
        .{ .line = offline_line, .can_queue = false }
    else if (s.err.items.len > 0)
        .{ .line = s.err.items, .can_queue = false }
    else if (s.status) |st|
        summary(c.alloc(), st)
    else
        .{ .line = "Reading this host's update status…", .can_queue = false };
    textLine(c, k, said.line);
    if (online) if (s.status) |st| textLine(c, k, versionLine(c.alloc(), st));
    if (s.notice) |n| textLine(c, k, n);
    if (!online) return;
    if (s.action != null) return textLine(c, k, "Contacting host…");
    const actions = ui.div(c).row().gap(8);
    defer actions.end();
    if (action(c, k, "remote-update-refresh", "Refresh status")) watch(a, s.device.items);
    if (s.status != null and s.err.items.len == 0 and canCheck(s.status.?)) {
        if (action(c, k, "remote-update-check", "Check now")) command(a, false);
    }
    if (said.can_queue) {
        ui.key(c, "remote-update-queue");
        const b = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
        defer b.end();
        ui.text(c, "Update when idle", set.st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
        if (b.clicked()) command(a, true);
    }
}

const testing = std.testing;

fn managed(phase: Phase, automatic: bool) Status {
    return .{ .current = "1.0.0", .latest = "1.0.1", .available = true, .host = .{ .mode = .managed, .automatic = automatic, .phase = phase } };
}

test "remote updates need a managed host that says so, and a release" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = managed(.idle, false);
    try testing.expect(summary(a, s).can_queue);
    try testing.expect(std.mem.indexOf(u8, summary(a, s).line, "off") != null);
    try testing.expect(canCheck(s));
    s.available = false;
    try testing.expect(!summary(a, s).can_queue);
    s.available = true;
    s.host = null;
    try testing.expect(!summary(a, s).can_queue);
    try testing.expect(!canCheck(s));
    s = managed(.idle, true);
    s.host.?.mode = .manual;
    try testing.expect(!canCheck(s));
    try testing.expect(!summary(a, s).can_queue);
    s.host.?.mode = .desktop;
    s.host.?.automatic = false;
    try testing.expect(std.mem.indexOf(u8, summary(a, s).line, "disabled") != null);
    s.err = "offline";
    try testing.expect(std.mem.indexOf(u8, summary(a, s).line, "offline") != null);
    try testing.expect(!summary(a, s).can_queue);
    for ([_]Phase{ .checking, .downloading, .waitingForIdle, .restarting }) |phase| {
        try testing.expect(!summary(a, managed(phase, true)).can_queue);
        try testing.expect(!canCheck(managed(phase, true)));
    }
    try testing.expect(std.mem.indexOf(u8, summary(a, managed(.waitingForIdle, true)).line, "terminals") != null);
}

test "only computers have updates to control" {
    try testing.expect(hostPlatform("linux"));
    try testing.expect(hostPlatform("macos"));
    try testing.expect(!hostPlatform("ios"));
    try testing.expect(!hostPlatform("android"));
    try testing.expect(!hostPlatform("web"));
}

test "a status from the wire, and the version line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"currentVersion":"1.0.0","latestVersion":"1.0.1","updateAvailable":true,
        \\ "host":{"mode":"managed","automatic":true,"phase":"waitingForIdle"}}
    , .{});
    const s = parse(a, v).?;
    try testing.expectEqual(Phase.waitingForIdle, s.host.?.phase);
    try testing.expectEqualStrings("Installed v1.0.0 · available v1.0.1", versionLine(a, s));
    try testing.expectEqualStrings("Installed v1.0.0 · not checked yet", versionLine(a, .{ .current = "1.0.0" }));
    try testing.expectEqualStrings("Installed v1.0.0 · last check needs attention", versionLine(a, .{ .current = "1.0.0", .err = "x" }));
    try testing.expectEqualStrings("Installed v1.0.0 · up to date", versionLine(a, .{ .current = "1.0.0", .latest = "1.0.0" }));
    try testing.expect(parse(a, .{ .bool = true }) == null);
}
