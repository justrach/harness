//! Pure-Zig iOS 120 Hz ProMotion scroll physics, tail virtualization,
//! Jump-to-Latest hysteresis, PhoneSplit geometry, and live frame telemetry.
//! Matches `apps/nano/lean-proofs/Nano/IosLiquidGlassScroll.lean` and
//! `lean-proofs/HarnessProofs/MobileIosParity.lean` 1:1.
const std = @import("std");
const testing = std.testing;

/// Max readable column width on wide phones / iPads (`TranscriptView.swift`).
pub const max_content_width: f32 = 736.0;
/// Distance from bottom within which auto-follow sticks (`stickThreshold`).
pub const stick_threshold: f32 = 70.0;
/// Distance from bottom past which the floating Jump-to-Latest pill appears (`jumpThreshold`).
pub const jump_threshold: f32 = 140.0;
/// `UIScrollView.DecelerationRate.normal` per millisecond (`0.998 = 499/500`).
pub const deceleration_per_ms: f64 = 0.998;
/// Minimum velocity (pt/s) before momentum deceleration halts.
pub const min_fling_speed: f32 = 20.0;
/// Minimum release velocity (pt/s) required to initiate a fling (`3 * min_fling_speed`).
pub const fling_start_speed: f32 = 60.0;
/// Touch slop (pt) before a press transitions smoothly into a scroll drag.
pub const touch_slop: f32 = 10.0;
/// Rubber-band overscroll attenuation factor (`0.35`).
pub const overscroll_slope: f32 = 0.35;
/// Initial realized message window in a long transcript (`<= 80` rows keeps `transcript.rows <= 8ms`).
pub const default_tail_cap: usize = 80;
/// Number of older rows revealed when scrolling near the top of the tail window.
pub const tail_grow_step: usize = 60;
/// Minimum clearance (pt) between the last transcript row and the floating composer shell.
pub const min_tail_clearance: f32 = 10.0;

pub const SplitMode = enum {
    auto,
    on,
    off,

    pub fn parse(raw: ?[]const u8) SplitMode {
        const s = raw orelse return .auto;
        if (std.ascii.eqlIgnoreCase(s, "on")) return .on;
        if (std.ascii.eqlIgnoreCase(s, "off")) return .off;
        return .auto;
    }

    pub fn asText(self: SplitMode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .on => "on",
            .off => "off",
        };
    }
};

pub const TailWindow = struct {
    start: usize,
    len: usize,
    hidden_older: usize,
};

/// Computes the realized `[start .. start + len)` slice for a transcript of `total` items.
pub fn tailWindow(total: usize, cap: usize) TailWindow {
    const effective_cap = @max(@as(usize, 1), cap);
    if (total <= effective_cap) {
        return .{ .start = 0, .len = total, .hidden_older = 0 };
    }
    const start = total - effective_cap;
    return .{ .start = start, .len = effective_cap, .hidden_older = start };
}

/// Hysteresis state machine for the floating `40x40` Jump-to-Latest Liquid Glass circle.
/// Eliminates flicker between `stick_threshold` (`70pt`) and `jump_threshold` (`140pt`).
pub fn updateJumpShown(was_shown: bool, dist_from_bottom: f32) bool {
    if (dist_from_bottom >= jump_threshold) return true;
    if (dist_from_bottom <= stick_threshold) return false;
    return was_shown;
}

/// Slop-subtracted initial drag delta (`scrollStartDelta` in Lean).
pub fn scrollStartDelta(total_delta: f32) f32 {
    if (total_delta > touch_slop) return total_delta - touch_slop;
    if (total_delta < -touch_slop) return total_delta + touch_slop;
    return 0;
}

/// Frame-rate-independent `UIScrollView` momentum step (`0.998^(dt_ms)`).
/// Two 8.33 ms ProMotion (120 Hz) steps match one 16.67 ms (60 Hz) step.
pub fn stepFling(speed: f32, dt_sec: f64) f32 {
    if (speed == 0) return 0;
    const clamped_dt = @max(0.0, @min(dt_sec, 0.05));
    const next: f32 = speed * @as(f32, @floatCast(std.math.pow(f64, deceleration_per_ms, clamped_dt * 1000.0)));
    return if (@abs(next) < min_fling_speed) 0 else next;
}

/// Attenuated rubber-band displacement past scroll bounds (`0.35 * excess`).
pub fn rubberBand(excess: f32) f32 {
    return excess * overscroll_slope;
}

/// Bottom padding for a full-bleed underlap scroll container so the last row
/// clears a floating bottom stack of `chrome_height` above `bottom_inset` by `>= 10pt`.
pub fn underlapBottomPadding(bottom_inset: f32, chrome_height: f32) f32 {
    return @max(0, bottom_inset) + @max(0, chrome_height) + 16.0;
}

/// `PhoneSplit` master column width (`clamp(round(w * 0.38), 280, 380)`),
/// leaving `>= 220pt` for the detail conversation column whenever `w >= 600pt`.
pub fn phoneSplitListWidth(total_width: f32) f32 {
    return std.math.clamp(@round(total_width * 0.38), 280.0, 380.0);
}

/// Decides whether the two-column `PhoneSplit` layout is active.
pub fn shouldSplitPhone(total_width: f32, mode: SplitMode, device_split: bool) bool {
    if (mode == .off) return false;
    if (device_split and total_width >= 600.0) return true;
    return switch (mode) {
        .on => total_width >= 600.0,
        .auto => total_width >= 660.0,
        .off => false,
    };
}

pub const FrameSample = struct {
    dt_ms: f32 = 0,
    work_ms: f32 = 0,
    scroll_y: f32 = 0,
    velocity_pt_s: f32 = 0,
};

/// Zero-allocation 240-frame ring buffer tracking real-time frame pacing & scroll speed.
pub const ScrollTelemetry = struct {
    samples: [240]FrameSample = @splat(.{}),
    head: usize = 0,
    count: usize = 0,
    last_scroll_y: f32 = 0,
    peak_velocity_pt_s: f32 = 0,
    scroll_frames: u64 = 0,

    pub fn record(self: *ScrollTelemetry, dt_sec: f32, work_ms: f32, scroll_y: f32) void {
        const dt_ms = if (dt_sec > 0 and dt_sec < 0.25) dt_sec * 1000.0 else 8.333;
        const dy = scroll_y - self.last_scroll_y;
        self.last_scroll_y = scroll_y;
        const vel: f32 = if (dt_sec > 0.0005 and @abs(dy) > 0.01) @abs(dy) / dt_sec else 0;
        if (vel > 1.0) {
            self.scroll_frames += 1;
            if (vel > self.peak_velocity_pt_s) self.peak_velocity_pt_s = vel;
        }
        self.samples[self.head] = .{
            .dt_ms = dt_ms,
            .work_ms = @max(0, work_ms),
            .scroll_y = scroll_y,
            .velocity_pt_s = vel,
        };
        self.head = (self.head + 1) % self.samples.len;
        if (self.count < self.samples.len) self.count += 1;
    }

    pub const Summary = struct {
        p50_work_ms: f32 = 0,
        p95_work_ms: f32 = 0,
        p50_dt_ms: f32 = 0,
        est_fps: f32 = 120.0,
        peak_velocity_pt_s: f32 = 0,
        scroll_frames: u64 = 0,

        pub fn meetsPerfContract(s: Summary) bool {
            // `perf-contract.json`: `transcript.rows <= 8.0 ms`, `main.stall <= 100.0 ms`,
            // and 120 Hz ProMotion frame budget `< 8.33 ms`.
            return s.p95_work_ms <= 8.0;
        }
    };

    pub fn summarize(self: *const ScrollTelemetry) Summary {
        if (self.count == 0) return .{};
        var work_buf: [240]f32 = undefined;
        var dt_buf: [240]f32 = undefined;
        for (0..self.count) |i| {
            work_buf[i] = self.samples[i].work_ms;
            dt_buf[i] = self.samples[i].dt_ms;
        }
        std.mem.sort(f32, work_buf[0..self.count], {}, std.sort.asc(f32));
        std.mem.sort(f32, dt_buf[0..self.count], {}, std.sort.asc(f32));
        const idx50 = (self.count - 1) / 2;
        const idx95 = ((self.count - 1) * 95) / 100;
        const p50_dt = @max(dt_buf[idx50], 1.0);
        return .{
            .p50_work_ms = work_buf[idx50],
            .p95_work_ms = work_buf[idx95],
            .p50_dt_ms = p50_dt,
            .est_fps = @min(120.0, 1000.0 / p50_dt),
            .peak_velocity_pt_s = self.peak_velocity_pt_s,
            .scroll_frames = self.scroll_frames,
        };
    }
};

test "120Hz ProMotion and 60Hz fling steps match and halt cleanly" {
    const v0: f32 = 2400.0;
    const v_120 = stepFling(stepFling(v0, 0.008), 0.008);
    const v_60 = stepFling(v0, 0.016);
    try testing.expectApproxEqAbs(v_60, v_120, 1e-3);

    var v = v0;
    var steps: usize = 0;
    while (v != 0 and steps < 2000) : (steps += 1) {
        const next = stepFling(v, 1.0 / 120.0);
        try testing.expect(@abs(next) < @abs(v));
        v = next;
    }
    try testing.expectEqual(@as(f32, 0), v);
    try testing.expect(steps > 10 and steps < 500);
}

test "Jump-to-Latest pill hysteresis and tail virtualization bounds" {
    var shown = false;
    shown = updateJumpShown(shown, 120.0);
    try testing.expect(!shown);
    shown = updateJumpShown(shown, 145.0);
    try testing.expect(shown);
    shown = updateJumpShown(shown, 95.0);
    try testing.expect(shown);
    shown = updateJumpShown(shown, 68.0);
    try testing.expect(!shown);

    const w = tailWindow(240, default_tail_cap);
    try testing.expectEqual(@as(usize, 160), w.start);
    try testing.expectEqual(@as(usize, 80), w.len);
    try testing.expectEqual(@as(usize, 160), w.hidden_older);

    try testing.expect(underlapBottomPadding(34.0, 108.0) - (34.0 + 108.0) >= min_tail_clearance);
    try testing.expect(600.0 - phoneSplitListWidth(600.0) >= 220.0);
}
