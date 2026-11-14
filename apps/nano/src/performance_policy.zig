//! Executable counterpart of Nano.Telemetry (Lean 4). The proof bounds abstract
//! operations and scheduling, NOT instruction latency, GPU time or zero overhead.
//! scripts/check-nano-telemetry-proof.py checks Lean-generated conformance vectors.

pub const bucket_bounds: usize = 22;
pub const histogram_cells: usize = 5 * 4 * 3 * 4;
pub const counter_slots: usize = histogram_cells * (bucket_bounds + 1);
pub const capacity: u32 = 1_000_000;
pub const interval_ms: i64 = 600_000;

pub fn shouldRecord(enabled: bool, active: bool, finite: bool) bool {
    return enabled and active and finite;
}

pub fn updateCount(enabled: bool, active: bool, finite: bool, cadence: bool) u8 {
    return if (shouldRecord(enabled, active, finite)) @as(u8, 4) + @intFromBool(cadence) else 0;
}

pub fn shouldPublish(enabled: bool, active: bool, samples: bool, idle: bool, now: i64, last: i64) bool {
    return enabled and active and samples and idle and now >= last and now -| last >= interval_ms;
}

pub fn nextCount(count: u32, valid: bool) u32 {
    return if (valid) @min(count +| 1, capacity) else count;
}
