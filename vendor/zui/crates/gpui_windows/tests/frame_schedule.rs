//! The frame-scheduling rules are plain Rust, so they are tested on every OS, not only where
//! the rest of this crate builds. This compiles `src/frame_schedule.rs` and runs its tests.
//!
//! Modified by Harness (new file); see `src/frame_schedule.rs` and vendor/zui/NOTICE.

#[allow(dead_code)]
#[path = "../src/frame_schedule.rs"]
mod frame_schedule;
