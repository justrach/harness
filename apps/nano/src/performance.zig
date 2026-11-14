//! Opt-in desktop responsiveness. Numeric histograms only; never read logs or
//! conversation data. A completed CPU frame is not a GPU/presentation sample.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const stats = @import("perf_stats.zig");
const App = @import("app.zig").App;
const policy = @import("performance_policy.zig");

pub const interval_ms = policy.interval_ms;

const Snapshot = struct {
    generation: u64,
    window: stats.Window,
    start_ms: i64,
    end_ms: i64,
};

pub const State = struct {
    /// Set only by the real, visible release application, never tests/previews.
    available: bool = false,
    enabled: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u64) = .init(0),
    /// Single producer (UI), single consumer. 0 idle, 1 ready, 2 sending,
    /// 3 shutdown. The UI never waits for the consumer or overwrites its slot.
    phase: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,
    worker_started: bool = false,
    io: ?std.Io = null,
    gpa: std.mem.Allocator = undefined,
    queued: Snapshot = undefined,
    window: stats.Window = .{},
    started_ms: i64 = 0,
    attempted_ms: i64 = 0,
    previous_time: ?f64 = null,
    previous_demand: bool = false,
    previous_cohort: ?stats.Cohort = null,
    input_frame: bool = false,
    scroll_frame: bool = false,

    /// Startup only, before app.run: one sleeping worker, never a per-frame
    /// thread spawn. Failure disables collection rather than doing UI work.
    pub fn start(s: *State, gpa: std.mem.Allocator, io: std.Io) void {
        if (s.worker != null) return;
        s.gpa = gpa;
        s.io = io;
        s.worker = std.Thread.spawn(.{}, workerMain, .{s}) catch {
            s.available = false;
            return;
        };
        s.worker_started = true;
    }

    pub fn deinit(s: *State) void {
        s.enabled.store(false, .release);
        _ = s.generation.fetchAdd(1, .acq_rel);
        if (s.worker) |t| {
            s.stopping.store(true, .release);
            s.phase.store(3, .release);
            s.io.?.futexWake(u32, &s.phase.raw, 1);
            t.join(); // Teardown only; never a frame/network wait.
        }
        s.worker = null;
        s.worker_started = false;
    }

    /// Nonblocking fixed-slot handoff. Busy/disabled/not-due means do nothing:
    /// no allocation, serialization, thread creation, joining or lock waiting.
    pub fn publish(s: *State, active: bool, now: i64) bool {
        const idle = s.worker_started and s.phase.load(.acquire) == 0;
        if (!policy.shouldPublish(s.enabled.load(.acquire), active, true, idle, now, s.attempted_ms) or s.window.empty()) return false;
        s.queued = .{ .generation = s.generation.load(.acquire), .window = s.window, .start_ms = s.started_ms, .end_ms = now };
        s.attempted_ms = now;
        s.started_ms = now;
        s.window = .{};
        s.phase.store(1, .release);
        s.io.?.futexWake(u32, &s.phase.raw, 1); // Wake the worker, not the UI.
        return true;
    }

    fn workerMain(s: *State) void {
        while (!s.stopping.load(.acquire)) {
            const phase = s.phase.load(.acquire);
            if (phase == 3) return;
            if (phase != 1) {
                s.io.?.futexWaitUncancelable(u32, &s.phase.raw, phase);
                continue;
            }
            s.phase.store(2, .release);
            s.deliver();
            s.phase.store(0, .release);
        }
    }

    fn deliver(s: *State) void {
        const job = &s.queued;
        if (!s.enabled.load(.acquire) or s.generation.load(.acquire) != job.generation) return;
        const body = job.window.json(s.gpa, @import("build_info").version, job.start_ms, job.end_ms) catch return;
        defer s.gpa.free(body);
        // Recheck just before the write. An already-started HTTP request cannot
        // be retracted. No response, retry or slow network blocks the UI.
        if (!s.enabled.load(.acquire) or s.generation.load(.acquire) != job.generation) return;
        if (!builtin.is_test) _ = @import("perf_transport.zig").post(s.gpa, s.io.?, body);
    }

    pub fn consent(s: *State, on: bool, now_ms: i64) void {
        if (s.enabled.load(.acquire) == on) return;
        s.enabled.store(on, .release);
        _ = s.generation.fetchAdd(1, .acq_rel);
        s.window = .{};
        s.started_ms = now_ms;
        s.attempted_ms = now_ms;
        s.previous_time = null;
        s.previous_demand = false;
        s.previous_cohort = null;
        s.input_frame = false;
        s.scroll_frame = false;
    }

    /// Pure numeric entry shared by production and deterministic tests.
    pub fn sample(s: *State, now: f64, active: bool, cohort: stats.Cohort, build: f64, layout: f64, paint: f64, demand: bool) void {
        if (!policy.shouldRecord(s.enabled.load(.acquire), active, std.math.isFinite(now))) {
            s.previous_time = null;
            s.previous_demand = false;
            s.previous_cohort = null;
            return;
        }
        s.window.add(.build, cohort, build);
        s.window.add(.layout, cohort, layout);
        s.window.add(.paint, cohort, paint);
        s.window.add(.cpu, cohort, build + layout + paint);
        // Only consecutive demand-driven frames in the SAME cohort. Idle,
        // suspended, hidden or newly activated windows never become jank.
        if (s.previous_time) |previous| if (s.previous_demand and demand and s.previous_cohort != null and std.meta.eql(s.previous_cohort.?, cohort)) {
            const gap = (now - previous) * 1000;
            if (gap > 0 and gap <= 1000) s.window.add(.interval, cohort, gap);
        };
        s.previous_time = now;
        s.previous_demand = demand;
        s.previous_cohort = cohort;
    }
};

fn reconcile(a: *App) bool {
    const s = &a.performance;
    const on = s.available and !a.offscreen and a.settings.get(.share_desktop_responsiveness);
    if (s.enabled.load(.acquire) != on) s.consent(on, a.nowMs());
    return on;
}

pub fn begin(a: *App, c: *ui.Context) void {
    if (!reconcile(a)) return;
    const s = &a.performance;
    // Keep only event presence, never keys, text, pointer positions or deltas.
    s.input_frame = s.input_frame or c.input.pressed or c.input.released or c.input.key != null or c.input.shortcut != null or c.input.ops.len > 0 or c.input.chars.len > 0;
    s.scroll_frame = s.scroll_frame or c.input.scroll.x != 0 or c.input.scroll.y != 0;
}

/// Installed on View, so retained scrolling and the final interaction frame
/// are counted once AFTER layout/paint, not with stale previous-frame stats.
pub fn completed(ptr: *anyopaque, c: *ui.Context) void {
    const a: *App = @ptrCast(@alignCast(ptr));
    if (!reconcile(a)) return;
    const s = &a.performance;
    const interaction: stats.Interaction = if (s.scroll_frame or c.scroll_moved.count() > 0 or c.stats.retained) .scroll else if (s.input_frame) .input else if (c.animating) .animation else .other;
    const pane_count = if (a.tabs.layout()) |split| split.panes.items.len else 1;
    const renderer: stats.Renderer = if (std.ascii.eqlIgnoreCase(c.renderer, "Metal")) .metal else if (std.ascii.eqlIgnoreCase(c.renderer, "Direct3D 11") or std.ascii.eqlIgnoreCase(c.renderer, "D3D11")) .d3d11 else if (std.ascii.eqlIgnoreCase(c.renderer, "OpenGL")) .opengl else .cpu;
    const cohort: stats.Cohort = .{ .interaction = interaction, .panes = if (pane_count <= 1) .single else if (pane_count == 2) .split else .many, .renderer = renderer };
    const demand = c.animating or interaction == .scroll;
    s.sample(c.time, c.input.window_active, cohort, c.stats.build_ms, c.stats.layout_ms, c.stats.paint_ms, demand);
    s.input_frame = false;
    s.scroll_frame = false;
    if (s.enabled.load(.acquire) and c.input.window_active) _ = s.publish(true, a.nowMs());
}
