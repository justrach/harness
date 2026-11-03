//! Opt-in frame pacing counters, enabled with `GPUI_FRAME_STATS=1`.
//!
//! Once a second a background thread prints one line to stderr:
//!
//! ```text
//! gpui-frame-stats t=3s at=1790000000.000 ticks=240 steps=240 presents=239 interval_ms p50=4.17 p95=4.36 max=8.40 drawable_wait_ms p95=0.02 step_ms p95=2.10 gpu_ms p95=0.40 starts=0 wake_ms p50=0.00 cpu_ms=210.0
//! ```
//!
//! * `ticks`: display-link callbacks (vsyncs the link delivered),
//! * `steps`: frame callbacks that reached the main thread,
//! * `presents`: Metal drawables presented, with the interval between them,
//! * `starts`: times a window's frame source restarted after idling, and
//!   `wake_ms`, the delay from that restart to its first frame callback,
//! * `cpu_ms`: the whole process's CPU time in that second.
//!
//! When the variable is unset every hook is a single relaxed atomic load.

use std::{
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

static ENABLED: OnceLock<bool> = OnceLock::new();
static STARTED: AtomicBool = AtomicBool::new(false);
static TICKS: AtomicU64 = AtomicU64::new(0);
static STEPS: AtomicU64 = AtomicU64::new(0);
static STARTS: AtomicU64 = AtomicU64::new(0);
static WAKE: Mutex<Wake> = Mutex::new(Wake {
    started_at: None,
    latencies: Vec::new(),
});
static PRESENTS: Mutex<Presents> = Mutex::new(Presents::new());

struct Wake {
    started_at: Option<Instant>,
    latencies: Vec<Duration>,
}

struct Presents {
    last: Option<Instant>,
    intervals: Vec<Duration>,
    drawable_waits: Vec<Duration>,
    step_times: Vec<Duration>,
    gpu_times: Vec<Duration>,
}

impl Presents {
    const fn new() -> Self {
        Self {
            last: None,
            intervals: Vec::new(),
            drawable_waits: Vec::new(),
            step_times: Vec::new(),
            gpu_times: Vec::new(),
        }
    }
}

pub(crate) fn enabled() -> bool {
    *ENABLED.get_or_init(|| {
        let enabled = std::env::var("GPUI_FRAME_STATS").is_ok_and(|value| value == "1");
        if enabled && !STARTED.swap(true, Ordering::AcqRel) {
            std::thread::Builder::new()
                .name("gpui-frame-stats".into())
                .spawn(report_loop)
                .ok();
        }
        enabled
    })
}

/// A display link delivered a vsync (any thread).
pub(crate) fn link_tick() {
    if enabled() {
        TICKS.fetch_add(1, Ordering::Relaxed);
    }
}

/// A window's frame source (re)started after being idle.
pub(crate) fn link_start() {
    if enabled() {
        STARTS.fetch_add(1, Ordering::Relaxed);
        let mut wake = WAKE.lock().unwrap_or_else(|error| error.into_inner());
        wake.started_at.get_or_insert_with(Instant::now);
    }
}

/// A frame callback reached the main thread. Pass the result to [`step_end`].
pub(crate) fn step() -> Option<Instant> {
    if enabled() {
        STEPS.fetch_add(1, Ordering::Relaxed);
        let mut wake = WAKE.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(started_at) = wake.started_at.take() {
            wake.latencies.push(started_at.elapsed());
        }
        Some(Instant::now())
    } else {
        None
    }
}

/// A frame callback that began at `began` (from [`step`]) returned.
pub(crate) fn step_end(began: Option<Instant>) {
    if let Some(began) = began {
        let mut presents = PRESENTS.lock().unwrap_or_else(|error| error.into_inner());
        presents.step_times.push(began.elapsed());
    }
}

/// A drawable was presented after waiting `drawable_wait` for it.
pub(crate) fn present(drawable_wait: Duration, with_transaction: bool) {
    if !enabled() {
        return;
    }
    if drawable_wait > Duration::from_millis(50) {
        eprintln!(
            "gpui-frame-stats slow next_drawable: {:.1} ms (presents_with_transaction={with_transaction})",
            drawable_wait.as_secs_f64() * 1000.0
        );
    }
    let now = Instant::now();
    let mut presents = PRESENTS.lock().unwrap_or_else(|error| error.into_inner());
    if let Some(last) = presents.last.replace(now) {
        // A longer gap is a pause between bursts, not a frame interval.
        let interval = now - last;
        if interval < Duration::from_millis(250) {
            presents.intervals.push(interval);
        }
    }
    presents.drawable_waits.push(drawable_wait);
}

/// A presented frame's command buffer spent `seconds` on the GPU.
pub(crate) fn gpu_time(seconds: f64) {
    if !enabled() || !seconds.is_finite() || seconds < 0.0 {
        return;
    }
    let mut presents = PRESENTS.lock().unwrap_or_else(|error| error.into_inner());
    presents.gpu_times.push(Duration::from_secs_f64(seconds));
}

/// The `p`th percentile (0.0..=1.0) of `samples` in milliseconds, nearest rank.
pub(crate) fn percentile_ms(samples: &mut [Duration], p: f64) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    samples.sort_unstable();
    let rank = ((p * samples.len() as f64).ceil() as usize).clamp(1, samples.len());
    samples[rank - 1].as_secs_f64() * 1000.0
}

/// This process's CPU time, user plus system.
fn process_cpu_time() -> Duration {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: `getrusage` fills the struct it's given.
    let usage = unsafe {
        if libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) != 0 {
            return Duration::ZERO;
        }
        usage.assume_init()
    };
    let time = |value: libc::timeval| {
        Duration::from_secs(value.tv_sec as u64) + Duration::from_micros(value.tv_usec as u64)
    };
    time(usage.ru_utime) + time(usage.ru_stime)
}

fn report_loop() {
    let started = Instant::now();
    let mut second = 0u64;
    let mut last_cpu = process_cpu_time();
    loop {
        second += 1;
        let deadline = started + Duration::from_secs(second);
        std::thread::sleep(deadline.saturating_duration_since(Instant::now()));
        let cpu = process_cpu_time();
        let cpu_ms = cpu.saturating_sub(last_cpu).as_secs_f64() * 1000.0;
        last_cpu = cpu;
        let ticks = TICKS.swap(0, Ordering::Relaxed);
        let steps = STEPS.swap(0, Ordering::Relaxed);
        let starts = STARTS.swap(0, Ordering::Relaxed);
        let mut wakes = std::mem::take(
            &mut WAKE
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .latencies,
        );
        let (mut intervals, mut waits, mut step_times, mut gpu_times) = {
            let mut presents = PRESENTS.lock().unwrap_or_else(|error| error.into_inner());
            (
                std::mem::take(&mut presents.intervals),
                std::mem::take(&mut presents.drawable_waits),
                std::mem::take(&mut presents.step_times),
                std::mem::take(&mut presents.gpu_times),
            )
        };
        let presents = waits.len();
        let max = intervals
            .iter()
            .max()
            .map_or(0.0, |max| max.as_secs_f64() * 1000.0);
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();
        eprintln!(
            "gpui-frame-stats t={second}s at={at:.3} ticks={ticks} steps={steps} presents={presents} \
             interval_ms p50={:.2} p95={:.2} max={max:.2} drawable_wait_ms p95={:.2} step_ms p95={:.2} gpu_ms p95={:.2} starts={starts} wake_ms p50={:.2} cpu_ms={cpu_ms:.1}",
            percentile_ms(&mut intervals, 0.50),
            percentile_ms(&mut intervals, 0.95),
            percentile_ms(&mut waits, 0.95),
            percentile_ms(&mut step_times, 0.95),
            percentile_ms(&mut gpu_times, 0.95),
            percentile_ms(&mut wakes, 0.50),
        );
    }
}
