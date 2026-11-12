//! Device-local and remote-device agent CLI update state (`WatchHarnessUpdates`,
//! `ApplyHarnessUpdate`, `CancelHarnessUpdate`, `CheckHarnessUpdates`).
//! Mirrors Zeron's `crates/ui/src/shell/harness_updates.rs`.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const workspace = @import("workspace.zig");
const motion_rules = @import("motion_rules.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const capability_v1 = "harness-updates-v1";
const retry_s = 2.0;
pub const resize_duration: f64 = 0.20;

pub const Phase = enum {
    dormant,
    checking,
    current,
    available,
    waiting_for_idle,
    preparing,
    downloading,
    installing,
    verifying,
    updated,
    manual_action_required,
    failed,

    pub fn fromWire(s: []const u8) Phase {
        const eq = std.mem.eql;
        if (eq(u8, s, "checking")) return .checking;
        if (eq(u8, s, "current")) return .current;
        if (eq(u8, s, "available")) return .available;
        if (eq(u8, s, "waiting-for-idle")) return .waiting_for_idle;
        if (eq(u8, s, "preparing")) return .preparing;
        if (eq(u8, s, "downloading")) return .downloading;
        if (eq(u8, s, "installing")) return .installing;
        if (eq(u8, s, "verifying")) return .verifying;
        if (eq(u8, s, "updated")) return .updated;
        if (eq(u8, s, "manual-action-required")) return .manual_action_required;
        if (eq(u8, s, "failed")) return .failed;
        return .dormant;
    }

    pub fn showUpdateNotice(p: Phase) bool {
        return switch (p) {
            .available,
            .waiting_for_idle,
            .preparing,
            .downloading,
            .installing,
            .verifying,
            .updated,
            .failed,
            => true,
            .dormant, .checking, .current, .manual_action_required => false,
        };
    }

    pub fn isActive(p: Phase) bool {
        return switch (p) {
            .waiting_for_idle, .preparing, .downloading, .installing, .verifying => true,
            else => false,
        };
    }
};

pub const FailureKind = enum {
    check,
    install,

    pub fn fromWire(s: []const u8) FailureKind {
        return if (std.mem.eql(u8, s, "install")) .install else .check;
    }
};

pub const Status = struct {
    harness: []const u8,
    installed_version: ?[]const u8 = null,
    latest_version: ?[]const u8 = null,
    phase: Phase = .dormant,
    can_apply: bool = false,
    manual_command: ?[]const u8 = null,
    progress_message: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    error_kind: FailureKind = .check,
};

pub const Tween = struct {
    from: f32,
    to: f32,
    start: f64,
    duration: f64 = resize_duration,

    pub fn sample(tw: Tween, now: f64, reduced: bool) f32 {
        if (reduced or tw.duration <= 0) return tw.to;
        const raw: f32 = @floatCast(std.math.clamp((now - tw.start) / tw.duration, 0, 1));
        return motion_rules.sampleTween(tw.from, tw.to, ui.motion.Easing.css_ease_out.sample(raw)[0]);
    }

    pub fn animating(tw: Tween, now: f64, reduced: bool) bool {
        if (reduced) return false;
        return (now - tw.start) < tw.duration and @abs(tw.to - tw.from) > 0.001;
    }
};

pub const DeviceWatch = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    device_id: []u8,
    online: bool = true,
    connected: bool = false,
    statuses: []Status = &.{},
    watch_id: ?u64 = null,
    retry_at: ?f64 = null,

    fn onStream(w: *DeviceWatch, id: u64, r: rpc.Reply) void {
        if (w.watch_id != id) return;
        const a = w.app;
        switch (r) {
            .item => |v| {
                w.replaceJson(a, v) catch {};
                w.connected = true;
            },
            .done => {
                w.watch_id = null;
                w.connected = false;
                if (a.engine.state == .connected and w.online) w.retry_at = a.now + retry_s;
            },
            .err => {
                w.watch_id = null;
                w.connected = false;
            },
            .ok => {},
        }
        a.redraw();
    }

    fn replaceJson(w: *DeviceWatch, a: *App, val: json.Value) !void {
        if (val != .array) return;
        var next_arena = std.heap.ArenaAllocator.init(a.gpa);
        errdefer next_arena.deinit();
        const alloc = next_arena.allocator();
        var list: std.ArrayList(Status) = .empty;
        for (val.array.items) |item| {
            if (item != .object) continue;
            if (parseStatus(alloc, item.object)) |st| try list.append(alloc, st);
        }
        const prev = w.arena;
        w.arena = next_arena;
        w.statuses = list.items;
        a.retireArena(prev);
    }
};

pub const LastAction = struct {
    device_id: []u8,
    method: []const u8,
    harness: []u8,
};

pub const State = struct {
    gpa: Allocator,
    devices: std.ArrayList(*DeviceWatch) = .empty,
    local_supported: bool = false,
    expanded: bool = false,
    reveal_tween: ?Tween = null,
    width_tween: ?Tween = null,
    height_tween: ?Tween = null,
    card_rect: ?ui.Rect = null,
    last_action: ?LastAction = null,
    /// `visibleSignature` of the notices the person dismissed. The island stays
    /// hidden while the visible set is unchanged; any new update, phase change
    /// or version brings it back.
    dismissed_signature: ?u64 = null,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *State) void {
        for (s.devices.items) |w| {
            w.arena.deinit();
            s.gpa.free(w.device_id);
            s.gpa.destroy(w);
        }
        s.devices.deinit(s.gpa);
        s.clearLastAction();
    }

    pub fn clearLastAction(s: *State) void {
        if (s.last_action) |la| {
            s.gpa.free(la.device_id);
            s.gpa.free(la.harness);
        }
        s.last_action = null;
    }
};

pub fn parseStatus(alloc: Allocator, o: json.ObjectMap) ?Status {
    const harness = workspace.str(alloc, o, "harness") orelse return null;
    const phase_raw = if (o.get("phase")) |v| (if (v == .string) v.string else "dormant") else "dormant";
    const can_apply = if (o.get("canApply")) |v| (if (v == .bool) v.bool else false) else false;
    var progress_message: ?[]const u8 = null;
    if (o.get("progress")) |pv| if (pv == .object) {
        progress_message = workspace.str(alloc, pv.object, "message");
    };
    var error_message: ?[]const u8 = null;
    var error_kind: FailureKind = .check;
    if (o.get("error")) |ev| if (ev == .object) {
        error_message = workspace.str(alloc, ev.object, "message");
        if (ev.object.get("kind")) |kv| if (kv == .string) {
            error_kind = FailureKind.fromWire(kv.string);
        };
    };
    return .{
        .harness = harness,
        .installed_version = workspace.str(alloc, o, "installedVersion"),
        .latest_version = workspace.str(alloc, o, "latestVersion"),
        .phase = Phase.fromWire(phase_raw),
        .can_apply = can_apply,
        .manual_command = workspace.str(alloc, o, "manualCommand"),
        .progress_message = progress_message,
        .error_message = error_message,
        .error_kind = error_kind,
    };
}

pub fn readEngineCaps(a: *App, items: []const json.Value) void {
    var supported = false;
    for (items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, capability_v1)) {
            supported = true;
            break;
        }
    }
    a.agent_updates.local_supported = supported;
    reconcile(a);
}

pub fn reconcile(a: *App) void {
    if (a.engine.state != .connected or !a.agent_updates.local_supported) return;
    const local_id = a.device_id orelse return;
    ensureWatch(a, local_id, true);
    for (a.devices.items) |dev| {
        if (std.mem.eql(u8, dev.id, local_id)) continue;
        const online = @import("view_sidebar_menus.zig").online(a, dev.id, a.nowMs());
        ensureWatch(a, dev.id, online);
    }
}

fn ensureWatch(a: *App, device_id: []const u8, online: bool) void {
    const s = &a.agent_updates;
    var entry: ?*DeviceWatch = null;
    for (s.devices.items) |w| {
        if (std.mem.eql(u8, w.device_id, device_id)) {
            entry = w;
            break;
        }
    }
    if (entry == null) {
        if (!online) return;
        const owned = s.gpa.dupe(u8, device_id) catch return;
        const created = s.gpa.create(DeviceWatch) catch {
            s.gpa.free(owned);
            return;
        };
        created.* = .{
            .app = a,
            .arena = .init(s.gpa),
            .device_id = owned,
            .online = online,
        };
        s.devices.append(s.gpa, created) catch {
            created.arena.deinit();
            s.gpa.free(owned);
            s.gpa.destroy(created);
            return;
        };
        entry = created;
    }
    const w = entry.?;
    w.online = online;
    if (!online) {
        if (w.watch_id) |id| a.engine.cancel(id);
        w.watch_id = null;
        w.retry_at = null;
        w.connected = false;
        return;
    }
    if (w.watch_id == null and w.retry_at == null) startWatch(a, w);
}

fn startWatch(a: *App, w: *DeviceWatch) void {
    const target: ?[]const u8 = if (a.device_id) |me| (if (std.mem.eql(u8, me, w.device_id)) null else w.device_id) else w.device_id;
    w.watch_id = a.send_(requests.watchHarnessUpdates(target), .of(DeviceWatch, w, DeviceWatch.onStream));
}

pub fn disconnected(a: *App) void {
    for (a.agent_updates.devices.items) |w| {
        w.watch_id = null;
        w.retry_at = null;
        w.connected = false;
    }
}

pub fn tick(a: *App, now: f64) ?f64 {
    var next: ?f64 = null;
    for (a.agent_updates.devices.items) |w| {
        if (w.retry_at) |t| {
            if (now >= t) {
                w.retry_at = null;
                if (a.engine.state == .connected and w.online) startWatch(a, w);
            } else {
                next = if (next) |n| @min(n, t) else t;
            }
        }
    }
    return next;
}

pub const VisibleRow = struct {
    device_id: []const u8,
    device_name: []const u8,
    connected: bool,
    status: Status,
};

fn noticeCount(a: *const App) usize {
    var n: usize = 0;
    for (a.agent_updates.devices.items) |w| {
        for (w.statuses) |st| if (st.phase.showUpdateNotice()) {
            n += 1;
        };
    }
    return n;
}

/// Identity of everything the island would show right now: which agents on
/// which devices, in which phase, at which target version.
pub fn visibleSignature(a: *const App) u64 {
    var h = std.hash.Wyhash.init(0);
    for (a.agent_updates.devices.items) |w| {
        for (w.statuses) |st| if (st.phase.showUpdateNotice()) {
            h.update(w.device_id);
            h.update(&.{0});
            h.update(st.harness);
            h.update(&.{ 0, @backingInt(st.phase), 0 });
            h.update(st.latest_version orelse "");
            h.update(&.{0});
        };
    }
    return h.final();
}

fn isDismissed(a: *const App) bool {
    const sig = a.agent_updates.dismissed_signature orelse return false;
    return noticeCount(a) > 0 and sig == visibleSignature(a);
}

/// Hide the island until the visible updates change.
pub fn dismiss(a: *App) void {
    const s = &a.agent_updates;
    if (noticeCount(a) == 0) return;
    s.dismissed_signature = visibleSignature(a);
    s.expanded = false;
    s.reveal_tween = null;
    s.width_tween = null;
    s.height_tween = null;
    s.card_rect = null;
    a.redraw();
}

pub fn visibleCount(a: *const App) usize {
    if (isDismissed(a)) return 0;
    return noticeCount(a);
}

pub fn hasVisible(a: *const App) bool {
    return visibleCount(a) > 0;
}

pub fn collectVisible(a: *const App, alloc: Allocator) []const VisibleRow {
    var out: std.ArrayList(VisibleRow) = .empty;
    if (isDismissed(a)) return out.items;
    for (a.agent_updates.devices.items) |w| {
        const name = resolveDeviceName(a, w.device_id);
        for (w.statuses) |st| {
            if (!st.phase.showUpdateNotice()) continue;
            out.append(alloc, .{
                .device_id = w.device_id,
                .device_name = name,
                .connected = w.online and w.connected,
                .status = st,
            }) catch break;
        }
    }
    return out.items;
}

fn resolveDeviceName(a: *const App, id: []const u8) []const u8 {
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, id)) return d.name;
    if (a.device_id) |me| if (std.mem.eql(u8, me, id)) return "This Mac";
    return id;
}

pub fn setExpanded(a: *App, want: bool, now: f64, reduced: bool) void {
    const s = &a.agent_updates;
    const allowed = want and visibleCount(a) > 1;
    if (s.expanded == allowed) return;
    const cur = if (s.reveal_tween) |tw| tw.sample(now, reduced) else if (s.expanded) @as(f32, 1) else @as(f32, 0);
    s.expanded = allowed;
    s.reveal_tween = .{
        .from = cur,
        .to = if (allowed) 1 else 0,
        .start = now,
    };
    a.redraw();
}

pub fn runAction(a: *App, device_id: []const u8, method: []const u8, harness: []const u8) void {
    const s = &a.agent_updates;
    s.clearLastAction();
    if (s.gpa.dupe(u8, device_id)) |owned_dev| {
        if (s.gpa.dupe(u8, harness)) |owned_h| {
            s.last_action = .{ .device_id = owned_dev, .method = method, .harness = owned_h };
        } else |_| s.gpa.free(owned_dev);
    } else |_| {}

    const host: ?[]const u8 = if (a.device_id) |me| (if (std.mem.eql(u8, me, device_id)) null else device_id) else device_id;
    if (std.mem.eql(u8, method, "ApplyHarnessUpdate")) {
        a.request(requests.applyHarnessUpdate(harness, host), .of(App, a, App.onNotice));
    } else if (std.mem.eql(u8, method, "CancelHarnessUpdate")) {
        a.request(requests.cancelHarnessUpdate(harness, host), .of(App, a, App.onNotice));
    } else if (std.mem.eql(u8, method, "CheckHarnessUpdates")) {
        a.request(requests.checkHarnessUpdates(harness, host), .of(App, a, App.onNotice));
    }
    a.redraw();
}

pub fn agentName(harness: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, harness, "claude-code")) return "Claude Code";
    if (eq(u8, harness, "codex")) return "Codex";
    if (eq(u8, harness, "cursor")) return "Cursor";
    if (eq(u8, harness, "devin")) return "Devin";
    if (eq(u8, harness, "grok")) return "Grok";
    if (eq(u8, harness, "hermes")) return "Hermes";
    if (eq(u8, harness, "graff")) return "Graff";
    if (eq(u8, harness, "pi")) return "Pi";
    if (eq(u8, harness, "opencode")) return "OpenCode";
    if (eq(u8, harness, "antigravity")) return "Antigravity";
    if (eq(u8, harness, "exo")) return "Exo";
    return harness;
}

/// Synthetic injection helper for deterministic UI & animation tests.
pub fn setTestStatuses(a: *App, device_id: []const u8, connected: bool, json_text: []const u8) !void {
    const parsed = try json.parseFromSlice(json.Value, a.gpa, json_text, .{});
    defer parsed.deinit();
    const s = &a.agent_updates;
    var target: ?*DeviceWatch = null;
    for (s.devices.items) |w| {
        if (std.mem.eql(u8, w.device_id, device_id)) {
            target = w;
            break;
        }
    }
    if (target == null) {
        const owned = try s.gpa.dupe(u8, device_id);
        errdefer s.gpa.free(owned);
        const created = try s.gpa.create(DeviceWatch);
        created.* = .{
            .app = a,
            .arena = .init(s.gpa),
            .device_id = owned,
            .online = true,
            .connected = connected,
        };
        try s.devices.append(s.gpa, created);
        target = created;
    }
    const w = target.?;
    w.online = true;
    w.connected = connected;
    try w.replaceJson(a, parsed.value);
}
